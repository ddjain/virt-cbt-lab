#!/usr/bin/env bash
set -euo pipefail
# Offline interface/identity checks only; never a chaos/product acceptance authority.
# Skill: cbt-chaos-trigger-preparer-v2. No cluster access or lifecycle execution.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
python3 - "$ROOT" <<'PY'
import ast
import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
source = root / 'cbt-chaos/scenarios_v2/CBT-EXP-06'
with tempfile.TemporaryDirectory() as tmp:
    checkout = Path(tmp)
    bundle = checkout / 'cbt-chaos/scenarios_v2/CBT-EXP-06'
    bundle.mkdir(parents=True)
    (checkout / 'scripts').mkdir()
    shutil.copyfile(root / 'scripts/dotenv.sh', checkout / 'scripts/dotenv.sh')
    for name in ('run.sh', 'pipeline.py', 'observe.py', 'guest-read.sh', 'vm-2disk.json', 'bundle-files.txt'):
        shutil.copyfile(source / name, bundle / name)
    env = dict(os.environ, CONTROL_LIFECYCLE_ID='exp06-control', LIFECYCLE_ID='exp06-surgery',
               CHAOS_RUN_ID='17-10-2026-00-00-00-vm-exp06-surgery-bitmap-drop-iteration-1',
               KUBECONFIG_PATH='/unreadable/not-used-by-plan', PYTHONDONTWRITEBYTECODE='1')
    def invoke(mode):
        return subprocess.run(['bash', str(bundle / 'run.sh'), mode], cwd=checkout, env=env,
                              capture_output=True, text=True)
    result = invoke('--plan')
    assert result.returncode == 0, result.stderr
    plan = json.loads(result.stdout)
    assert plan['control_vm'] == 'vm-exp06-control' and plan['surgery_vm'] == 'vm-exp06-surgery'
    assert plan['root_data_full_incremental_Gi'] == [40, 2, 80, 30]
    assert plan['stage_owner'] == 'run.sh (pipeline.py)'
    # Focused regression: iteration 3 closed with the surgery incremental NONTERMINAL_AT_BOUND after the
    # shared 20m wait, so iteration 4 pre-approves a 4500s two-phase surgery budget (2700s stage-bound
    # probe plus 1800s read-only wedge observation) inside the unchanged 10800s pipeline bound, while
    # the control-stage bounds stay at their approved values.
    bounds = plan['bounds_seconds']
    assert bounds['incremental'] == 4500, bounds
    assert bounds['incremental_phase_a_stage_probe'] == 2700, bounds
    assert bounds['incremental_phase_b_read_only_observation'] == 1800, bounds
    assert (bounds['total_pipeline'], bounds['setup'], bounds['full'], bounds['verify']) == (10800, 2400, 1500, 2100), bounds
    note = plan['incremental_budget_note']
    assert 'wedge-observation' in note and '--timeout=20m' in note and 'no mutation/retry/reconcile' in note, note
    stages = '\n'.join(plan['sequence'])
    assert 'make vm-cbt-verify RUN_ID=exp06-control' in stages
    assert 'make vm-cbt-backup RUN_ID=exp06-surgery' in stages
    assert 'TYPE=recover' not in stages and 'TYPE=all' not in stages
    assert not (checkout / 'runs').exists() and not (bundle / 'runs').exists()
    assert invoke('--manifest').stdout == (source / 'bundle-files.txt').read_text()
    assert invoke('--check-root').returncode != 0
    run = bundle / 'runs' / env['CHAOS_RUN_ID']
    run.mkdir(parents=True)
    state = {'scenario_id': 'CBT-EXP-06', 'run_id': env['CHAOS_RUN_ID'], 'vm_name': 'vm-exp06-surgery',
             'lifecycle_ids': ['exp06-control', 'exp06-surgery'],
             'phase': 'started', 'verdict': None}
    (run / 'run.json').write_text(json.dumps(state))
    (run / 'preflight').mkdir()
    (run / 'observer').mkdir()
    assert invoke('--check-root').returncode == 0
    state['lifecycle_roles'] = {'control': 'exp06-control', 'surgery': 'exp06-surgery'}
    (run / 'run.json').write_text(json.dumps(state))
    assert invoke('--check-root').returncode == 0
    for invalid in ({'control': 'exp06-control', 'surgery': 'exp06-surgery'},
                    ['exp06-surgery', 'exp06-control'], ['exp06-control'], ['exp06-control', 'exp06-control']):
        state['lifecycle_ids'] = invalid
        (run / 'run.json').write_text(json.dumps(state))
        assert invoke('--check-root').returncode != 0
    state['lifecycle_ids'] = ['exp06-control', 'exp06-surgery']
    state['lifecycle_roles']['control'] = 'exp06-surgery'
    (run / 'run.json').write_text(json.dumps(state))
    assert invoke('--check-root').returncode != 0
    state['lifecycle_roles']['control'] = 'exp06-control'
    (run / 'run.json').write_text(json.dumps(state))
    for path in ('execution', 'trigger', 'observer/effect', 'action.json', 'effect.json', 'injection-confirmation.json'):
        output = run / path
        output.parent.mkdir(exist_ok=True)
        output.write_text('retained evidence\n')
        assert invoke('--check-root').returncode != 0, path
        assert output.read_text() == 'retained evidence\n'
        output.unlink()
    state['run_id'] = 'mismatch'
    (run / 'run.json').write_text(json.dumps(state))
    assert invoke('--check-root').returncode != 0
    state['run_id'] = env['CHAOS_RUN_ID']
    state['lifecycle_ids'][0] = state['lifecycle_ids'][1]
    (run / 'run.json').write_text(json.dumps(state))
    assert invoke('--check-root').returncode != 0

    template = (source / 'vm-2disk.json').read_text()
    tokens = set(re.findall(r'__[A-Z_]+__', template))
    assert tokens == {'__VM__', '__NAMESPACE__', '__LIFECYCLE__', '__NODE__', '__PUBLIC_KEY__'}
    for token, value in {'__VM__':'vm-fixture', '__NAMESPACE__':'vm-cbt-demo', '__LIFECYCLE__':'fixture',
                         '__NODE__':'worker-fixture', '__PUBLIC_KEY__':'ssh-ed25519 AAAA'}.items():
        template = template.replace(token, value)
    vm, service = json.loads(template)['items']
    assert vm['spec']['dataVolumeTemplates'][0]['spec']['storage']['resources']['requests']['storage'] == '40Gi'
    assert vm['spec']['dataVolumeTemplates'][1]['spec']['storage']['resources']['requests']['storage'] == '2Gi'
    assert vm['metadata']['labels']['virt-cbt-lab/pool'] == 'exp06'
    assert vm['metadata']['annotations']['virt-cbt-lab/manifest-variant'] == 'large-odf'
    assert vm['metadata']['annotations']['virt-cbt-lab/incremental-passes'] == '1'
    assert {d['name'] for d in vm['spec']['template']['spec']['domain']['devices']['disks']} == {'rootdisk','datadisk','cloudinitdisk'}
    assert service['kind'] == 'Service'

    spec = importlib.util.spec_from_file_location('exp06_observe', source / 'observe.py')
    observer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(observer)
    raw = {'return': [
        {'node-name':'libvirt-2-storage', 'drv':'file', 'file':'/cbt/datadisk.qcow2'},
        {'node-name':'libvirt-2-format', 'drv':'qcow2', 'file':'/cbt/datadisk.qcow2', 'dirty-bitmaps':[{'name':'checkpoint'}]},
        {'node-name':'libvirt-4-format', 'drv':'qcow2', 'file':'/cbt/rootdisk.qcow2', 'dirty-bitmaps':[{'name':'checkpoint'}]}]}
    nodes = observer.disk_nodes(raw)
    assert nodes['datadisk']['node-name'] == 'libvirt-2-format'
    assert observer.bitmap_names(nodes['rootdisk']) == ['checkpoint']
    ambiguous = copy.deepcopy(raw)
    ambiguous['return'].append(copy.deepcopy(raw['return'][1]))
    try:
        observer.disk_nodes(ambiguous)
    except AssertionError:
        pass
    else:
        raise AssertionError('ambiguous QMP format-node selection was accepted')
    capture = checkout / 'immutable-qmp.json'
    observer.save(capture, raw)
    try:
        observer.save(capture, [])
    except FileExistsError:
        pass
    else:
        raise AssertionError('raw QMP capture overwritten')
    assert json.loads(capture.read_text()) == raw
    logs = checkout / 'scoped-controller-logs'
    observer.command(logs, 'controller', ['printf', '%s\n', 'vm-exp06-surgery: current',
                     'vm-exp06-surgery-other: excluded', 'unrelated error'], text_scope={'vm-exp06-surgery'})
    assert (logs / 'controller.stdout').read_text() == 'vm-exp06-surgery: current\n'
    status = json.loads((logs / 'controller.status.json').read_text())
    assert status['operation_rc'] == status['evidence_rc'] == 0
    assert status['log_filter']['matched_lines'] == 1 and status['log_filter']['excluded_lines'] == 2

    # Focused regression: observe.command() JSON-decodes stdout, so `stat -c %s` arrived as int in
    # iteration 1 (bare 32212254720) and .strip() aborted preflight. The boundary must accept both
    # the int and str decodings and keep the exact 0 < size <= 40Gi*0.94 condition and message.
    sys.path.insert(0, str(bundle))
    try:
        pipeline_spec = importlib.util.spec_from_file_location('exp06_pipeline', bundle / 'pipeline.py')
        pipeline = importlib.util.module_from_spec(pipeline_spec)
        pipeline_spec.loader.exec_module(pipeline)
    finally:
        sys.path.remove(str(bundle))
    limit = int(40 * pipeline.Gi * .94)
    assert limit == 40372692582
    for accepted in (32212254720, '32212254720', limit, str(limit)):
        pipeline.check_source_geometry(accepted, limit)
    refused = ((0, 'source image exceeds usable clone capacity'), (-1, 'source image exceeds usable clone capacity'),
               (limit + 1, 'source image exceeds usable clone capacity'),
               (str(limit + 1), 'source image exceeds usable clone capacity'),
               (True, 'source geometry decoded to an unexpected type'),
               (32212254720.0, 'source geometry decoded to an unexpected type'))
    for value, message in refused:
        try:
            pipeline.check_source_geometry(value, limit)
        except AssertionError as exc:
            assert str(exc) == message, (value, str(exc))
        else:
            raise AssertionError('source geometry boundary accepted ' + repr(value))
    try:
        pipeline.check_source_geometry('40Gi', limit)
    except ValueError:
        pass
    else:
        raise AssertionError('non-numeric source geometry text was accepted')

    # Focused regression: the restore-tool-probe must report per-tool presence without aborting and
    # must fail only on REQUIRED absence. Iteration 2 aborted at the 8th tool (udevadm) because
    # `command -v` under `set -e` failed inside the loop, so the probe exited 1 against the pinned
    # image and preflight blocked, even though manifests/restore-verify-pod.yaml guards udevadm,
    # qemu-nbd and modprobe with fallbacks. The script under test is extracted from the real
    # pipeline source so drift in the embedded string fails here.
    tree = ast.parse((source / 'pipeline.py').read_text())
    probe_scripts = []
    for node in ast.walk(tree):
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'command'
                and len(node.args) > 2 and isinstance(node.args[1], ast.Constant)
                and node.args[1].value == 'restore-tool-probe'):
            argv = node.args[2]
            assert isinstance(argv, ast.List), 'probe argv must stay a literal list'
            assert isinstance(argv.elts[-2], ast.Constant) and argv.elts[-2].value == '-euc', 'probe entrypoint flag changed'
            assert isinstance(argv.elts[-1], ast.Constant) and isinstance(argv.elts[-1].value, str), 'probe script must stay a literal'
            probe_scripts.append(argv.elts[-1].value)
    assert len(probe_scripts) == 1, 'expected exactly one restore-tool-probe invocation'
    probe_script = probe_scripts[0]
    assert "'" not in probe_script and '\n' not in probe_script, 'probe script must stay a single-line literal without quotes'
    required = ['qemu-img', 'mount', 'umount', 'losetup', 'lsblk', 'find', 'sha256sum', 'stat', 'sort', 'awk', 'cp']
    optional = ['qemu-nbd', 'modprobe', 'udevadm']
    toolbelt = checkout / 'probe-tools'
    toolbelt.mkdir()
    def run_probe(present):
        for stale in toolbelt.iterdir():
            stale.unlink()
        for name in present:
            (toolbelt / name).write_text('#!/bin/sh\n')
            (toolbelt / name).chmod(0o755)
        (toolbelt / 'qemu-img').write_text('#!/bin/sh\nprintf "qemu-img stub version\\n"\n')
        (toolbelt / 'qemu-img').chmod(0o755)
        return subprocess.run(['/bin/bash', '-euc', probe_script], env={'PATH': str(toolbelt)},
                              capture_output=True, text=True)
    pinned = run_probe(required + ['qemu-nbd', 'modprobe'])
    assert pinned.returncode == 0, (pinned.returncode, pinned.stdout, pinned.stderr)
    stdout_lines = pinned.stdout.splitlines()
    assert [line for line in stdout_lines if line.startswith('MISSING:')] == ['MISSING:udevadm'], stdout_lines
    assert 'qemu-img stub version' in stdout_lines, stdout_lines
    for tool in required + optional:
        assert any(line == 'MISSING:' + tool or line.endswith('/' + tool) for line in stdout_lines), (tool, stdout_lines)
    only_required = run_probe(required)
    assert only_required.returncode == 0, (only_required.returncode, only_required.stdout, only_required.stderr)
    assert sorted(line for line in only_required.stdout.splitlines() if line.startswith('MISSING:')) == \
        ['MISSING:modprobe', 'MISSING:qemu-nbd', 'MISSING:udevadm'], only_required.stdout
    assert 'MISSING-REQUIRED' not in only_required.stdout + only_required.stderr, only_required.stderr
    broken = run_probe([tool for tool in required + optional if tool != 'losetup'])
    assert broken.returncode != 0, (broken.returncode, broken.stdout)
    assert 'MISSING:losetup' in broken.stdout.splitlines(), broken.stdout
    assert 'MISSING-REQUIRED: losetup' in broken.stderr, broken.stderr
print('PASS: EXP06 plan, two-lifecycle root identity, evidence freshness, manifest, exact QMP node selection, immutable captures, explicit int/str source-geometry boundary and REQUIRED/OPTIONAL restore tool-probe split (offline only).')
PY
