$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$pythonHome = 'C:\Program Files\Python312'
$python = Join-Path $pythonHome 'python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $installer = Join-Path $env:TEMP 'python-3.12.4-amd64.exe'
    Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/3.12.4/python-3.12.4-amd64.exe' `
        -OutFile $installer -UseBasicParsing
    $install = Start-Process -FilePath $installer `
        -ArgumentList '/quiet InstallAllUsers=1 PrependPath=1' -Wait -PassThru
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    if ($install.ExitCode -ne 0 -and $install.ExitCode -ne 3010) {
        throw "Python 3.12.4 installation failed with exit code $($install.ExitCode)"
    }
}
if (-not (Test-Path -LiteralPath $python)) {
    throw 'Python 3.12.4 was not installed at C:\Program Files\Python312\python.exe'
}
$pythonVersion = (& $python -c 'import platform; print(platform.python_version())').Trim()
if ($pythonVersion -ne '3.12.4') {
    throw "Expected Python 3.12.4, found $pythonVersion"
}

$workloads = 'C:\workloads'
$data = 'C:\data\test'
New-Item -ItemType Directory -Force -Path $workloads, $data | Out-Null

@'
import datetime
import os
import time

LOG = r"C:\data\test\log.txt"
os.makedirs(os.path.dirname(LOG), exist_ok=True)
while True:
    with open(LOG, "a", encoding="utf-8", buffering=1) as stream:
        stream.write(f"{datetime.datetime.now(datetime.timezone.utc).isoformat()} heartbeat\n")
    time.sleep(1)
'@ | Set-Content -LiteralPath (Join-Path $workloads 'file-writer.py') -Encoding UTF8

@'
import os
import sqlite3
import time
from datetime import datetime, timezone

DB = r"C:\data\test\test.db"
os.makedirs(os.path.dirname(DB), exist_ok=True)
connection = sqlite3.connect(DB, timeout=30)
connection.execute("PRAGMA journal_mode=WAL")
connection.execute("CREATE TABLE IF NOT EXISTS heartbeats (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL)")
connection.commit()
try:
    while True:
        connection.execute("INSERT INTO heartbeats (ts) VALUES (?)", (datetime.now(timezone.utc).isoformat(),))
        connection.commit()
        time.sleep(2)
finally:
    connection.close()
'@ | Set-Content -LiteralPath (Join-Path $workloads 'sqlite-writer.py') -Encoding UTF8

@'
import http.server
import os
from functools import partial

os.chdir(r"C:\data")
handler = partial(http.server.SimpleHTTPRequestHandler, directory=r"C:\data")
server = http.server.ThreadingHTTPServer(("0.0.0.0", 8080), handler)
server.serve_forever()
'@ | Set-Content -LiteralPath (Join-Path $workloads 'http-server.py') -Encoding UTF8

@'
$ErrorActionPreference = 'Stop'
$python = 'C:\Program Files\Python312\python.exe'
$workloads = 'C:\workloads'
$processes = @(
    @{ Name = 'file-writer.py'; Path = (Join-Path $workloads 'file-writer.py') },
    @{ Name = 'sqlite-writer.py'; Path = (Join-Path $workloads 'sqlite-writer.py') },
    @{ Name = 'http-server.py'; Path = (Join-Path $workloads 'http-server.py') }
)
foreach ($workload in $processes) {
    $running = Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" |
        Where-Object { $_.CommandLine -like "*$($workload.Path)*" }
    if (-not $running) {
        Start-Process -FilePath $python -ArgumentList $workload.Path `
            -WorkingDirectory $workloads -WindowStyle Hidden
    }
}
'@ | Set-Content -LiteralPath (Join-Path $workloads 'start-workloads.ps1') -Encoding UTF8

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\workloads\start-workloads.ps1"'
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
    -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'StartWorkloads' -Action $action `
    -Trigger $trigger -Principal $principal -Force | Out-Null

# Exercise the same task action before sysprep, then leave the image clean.
Get-Process -Name python -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $data -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
try {
    Start-ScheduledTask -TaskName 'StartWorkloads'
    $deadline = (Get-Date).AddSeconds(90)
    do {
        Start-Sleep -Seconds 2
        $lineCount = if (Test-Path -LiteralPath (Join-Path $data 'log.txt')) {
            (Get-Content -LiteralPath (Join-Path $data 'log.txt') | Measure-Object -Line).Lines
        } else { 0 }
        $rowText = if (Test-Path -LiteralPath (Join-Path $data 'test.db')) {
            & $python -c "import sqlite3; print(sqlite3.connect(r'C:\data\test\test.db').execute('SELECT COUNT(*) FROM heartbeats').fetchone()[0])" 2>$null
        } else { '0' }
        $rowCount = 0
        [void][int]::TryParse(($rowText | Select-Object -Last 1), [ref]$rowCount)
        $httpStatus = 0
        try {
            $httpStatus = [int](Invoke-WebRequest -Uri 'http://localhost:8080/' `
                -UseBasicParsing -TimeoutSec 5).StatusCode
        } catch { }
        $processCount = @(Get-Process -Name python -ErrorAction SilentlyContinue).Count
    } while (($lineCount -lt 5 -or $rowCount -lt 3 -or $httpStatus -ne 200 -or $processCount -lt 3) -and (Get-Date) -lt $deadline)

    if ($lineCount -lt 5 -or $rowCount -lt 3 -or $httpStatus -ne 200 -or $processCount -lt 3) {
        throw "Workload check failed: file-lines=$lineCount sqlite-rows=$rowCount http=$httpStatus python-processes=$processCount"
    }
    $task = Get-ScheduledTask -TaskName 'StartWorkloads'
    if ($task.Principal.UserId -notmatch '(?i)(^|\\)SYSTEM$') {
        throw "StartWorkloads principal is not SYSTEM: $($task.Principal.UserId)"
    }
    Write-Output "PYTHON_VERSION=$pythonVersion"
    Write-Output "FILE_LINES=$lineCount"
    Write-Output "SQLITE_ROWS=$rowCount"
    Write-Output "HTTP_STATUS=$httpStatus"
    Write-Output "WORKLOAD_PROCESSES=$processCount"
    Write-Output 'STARTUP_TASK=StartWorkloads (SYSTEM)'
} finally {
    Get-Process -Name python -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Get-ChildItem -LiteralPath $data -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
