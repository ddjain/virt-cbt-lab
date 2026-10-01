$ErrorActionPreference = 'Stop'
$python = 'C:\Program Files\Python312\python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    throw 'Python 3.12.4 is missing from the cloned Windows image'
}

$data = 'C:\data\test'
$logPath = Join-Path $data 'log.txt'
$dbPath = Join-Path $data 'test.db'
$deadline = (Get-Date).AddSeconds(120)
do {
    $lineCount = if (Test-Path -LiteralPath $logPath) {
        (Get-Content -LiteralPath $logPath | Measure-Object -Line).Lines
    } else { 0 }

    $rowCount = 0
    if (Test-Path -LiteralPath $dbPath) {
        $rowText = & $python -c "import sqlite3; print(sqlite3.connect(r'C:\data\test\test.db', timeout=10).execute('SELECT COUNT(*) FROM heartbeats').fetchone()[0])" 2>$null
        if ($LASTEXITCODE -eq 0) {
            [void][int]::TryParse([string]$rowText, [ref]$rowCount)
        }
    }

    $httpStatus = 0
    try {
        $httpStatus = [int](Invoke-WebRequest -Uri 'http://localhost:8080/' `
            -UseBasicParsing -TimeoutSec 5).StatusCode
    } catch { }

    $processCount = @(Get-Process -Name python -ErrorAction SilentlyContinue).Count
    $task = Get-ScheduledTask -TaskName 'StartWorkloads' -ErrorAction SilentlyContinue
    $taskReady = $null -ne $task -and $task.Principal.UserId -match '(?i)(^|\\)SYSTEM$'
    if ($lineCount -ge 5 -and $rowCount -ge 3 -and $httpStatus -eq 200 -and
        $processCount -ge 3 -and $taskReady) {
        break
    }
    Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadline)

if ($lineCount -lt 5 -or $rowCount -lt 3 -or $httpStatus -ne 200 -or
    $processCount -lt 3 -or -not $taskReady) {
    throw "Windows workload check failed: file-lines=$lineCount sqlite-rows=$rowCount http=$httpStatus python-processes=$processCount task-ready=$taskReady"
}

Write-Output "PYTHON_VERSION=$(& $python --version)"
Write-Output "FILE_LINES=$lineCount"
Write-Output "SQLITE_ROWS=$rowCount"
Write-Output "HTTP_STATUS=$httpStatus"
Write-Output "WORKLOAD_PROCESSES=$processCount"
Write-Output 'STARTUP_TASK=StartWorkloads (SYSTEM)'
