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
source = root / 'cbt-chaos/scenarios_v2/CBT-EXP-10'
CHAOS = '17-10-2026-00-00-00-vm-exp10-fixture-redefinition-outage-iteration-1'
NODE_UID = '0f1a6f4a-9d5f-4c1c-9c25-93ef0a0f5f11'
FIXTURE = dict(LIFECYCLE_ID='exp10-fixture', CHAOS_RUN_ID=CHAOS, TARGET_NODE='d38-h18-000-r660',
               TARGET_NODE_UID=NODE_UID,
               RESTORE_HELPER_IMAGE='registry.example/cbt-restore-helper@sha256:' + 'a' * 64,
               KUBECONFIG_PATH='/unreadable/not-used-by-plan', PYTHONDONTWRITEBYTECODE='1')

with tempfile.TemporaryDirectory() as tmp:
    checkout = Path(tmp)
    bundle = checkout / 'cbt-chaos/scenarios_v2/CBT-EXP-10'
    bundle.mkdir(parents=True)
    (checkout / 'scripts').mkdir()
    shutil.copyfile(root / 'scripts/dotenv.sh', checkout / 'scripts/dotenv.sh')
    names = ('run.sh', 'pipeline.py', 'observe.py', 'guest-read.sh', 'suppress.sh', 'vm-node-pinned.json',
             'bundle-files.txt')
    for name in names:
        shutil.copyfile(source / name, bundle / name)
    # The manifest itself must name real, hashable files: reproduce the approval dry-run offline.
    manifest = (source / 'bundle-files.txt').read_text().split()
    assert len(manifest) == len(set(manifest))
    assert 'cbt-chaos/scenarios_v2/CBT-EXP-10/suppress.sh' in manifest
    for name in manifest:
        target = checkout / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, target)
    env = dict(os.environ, **FIXTURE)

    def invoke(mode):
        return subprocess.run(['bash', str(bundle / 'run.sh'), mode], cwd=checkout, env=env,
                              capture_output=True, text=True)

    # --- shell/py syntax -------------------------------------------------
    for name in ('run.sh', 'guest-read.sh', 'suppress.sh'):
        result = subprocess.run(['bash', '-n', str(bundle / name)], capture_output=True, text=True)
        assert result.returncode == 0, (name, result.stderr)
    for name in ('pipeline.py', 'observe.py'):
        result = subprocess.run(['python3', '-m', 'py_compile', str(bundle / name)], capture_output=True, text=True)
        assert result.returncode == 0, (name, result.stderr)

    # --- plan ------------------------------------------------------------
    result = invoke('--plan')
    assert result.returncode == 0, result.stderr
    plan = json.loads(result.stdout)
    assert plan['scenario_id'] == 'CBT-EXP-10' and plan['lifecycle_id'] == 'exp10-fixture'
    assert plan['vm'] == 'vm-exp10-fixture' and plan['target_node'] == 'd38-h18-000-r660'
    assert plan['stage_owner'].startswith('run.sh (pipeline.py')
    assert 'no krkn primitive deletes and holds a specific node' in plan['krkn_justification']
    assert 'bounded fallback' in plan['krkn_justification']
    assert plan['trigger'].startswith('oc/kubectl fault action (Pattern C)')
    assert plan['bounds_seconds']['total_pipeline'] == 14400
    assert plan['suppression']['effective_seconds'] == 480
    assert plan['suppression']['allowed_seconds'] == [300, 900]
    assert plan['suppression']['suppressor_hard_deadline_seconds'] == 540
    assert plan['suppression']['handler_delete_grace_seconds'] == 0
    assert plan['suppression']['suppressor'].endswith('suppress.sh <node> <window-seconds> <dir>')
    assert plan['request_sizes_Gi'] == {'root': 80, 'full_backup': 80, 'second_backup': 80, 'recovery_full': 80}
    assert plan['ceph_pool_min_free_Gi'] == 400 and plan['blast_radius'].count('vm-exp10-fixture') == 1
    stages = '\n'.join(plan['sequence'])
    assert 'make vm-setup RUN_ID=exp10-fixture EXISTING_VM=vm-exp10-fixture' in stages
    assert 'make vm-backup RUN_ID=exp10-fixture' in stages
    assert 'vm-p5-second-exp10-fixture' in stages
    assert 'vm-p5-recovery-full-exp10-fixture' in stages and 'vm-p5-recovery-pvc-exp10-fixture' in stages
    assert 'TYPE=recover' not in stages and 'TYPE=all' not in stages and 'vm-cbt-verify' not in stages
    assert 'checkpointRedefinitionRequired' not in stages and 'redefinition' in stages
    assert not (checkout / 'runs').exists() and not (bundle / 'runs').exists()

    # --- manifest --------------------------------------------------------
    assert invoke('--manifest').stdout == (source / 'bundle-files.txt').read_text()

    # --- parameters ------------------------------------------------------
    result = invoke('--parameters')
    assert result.returncode == 0, result.stderr
    params = json.loads(result.stdout)
    assert params['lifecycle_id'] == 'exp10-fixture' and params['vm'] == 'vm-exp10-fixture'
    assert params['namespace'] == 'vm-cbt-demo' and params['manifest_variant'] == 'large-odf'
    assert params['suppression_seconds'] == 480 and params['suppressor_hard_deadline_seconds'] == 540
    assert params['target_node_uid'] == NODE_UID and params['root_Gi'] == 80 and params['second_Gi'] == 80
    assert params['max_vmi_deletions'] == 1 and params['pipeline_timeout_seconds'] == 14400
    assert params['context_sha256'] is None and params['context_unavailable_reason']
    assert params['krkn']['used'] is False and 'virt-handler' in params['krkn']['justification']
    assert params['restore_image'].endswith('@sha256:' + 'a' * 64)
    assert invoke('--parameters').stdout == result.stdout, 'parameters() must reproduce exactly'
    for override, expected in (('300', 300), ('900', 900)):
        overridden = dict(env, SUPPRESS_SECONDS=override)
        out = subprocess.run(['bash', str(bundle / 'run.sh'), '--parameters'], cwd=checkout, env=overridden,
                             capture_output=True, text=True)
        assert out.returncode == 0, out.stderr
        assert json.loads(out.stdout)['suppression_seconds'] == expected
    for bad in ('299', '901', 'x'):
        out = subprocess.run(['bash', str(bundle / 'run.sh'), '--parameters'], cwd=checkout, env=dict(env, SUPPRESS_SECONDS=bad),
                             capture_output=True, text=True)
        assert out.returncode != 0, bad
    out = subprocess.run(['bash', str(bundle / 'run.sh'), '--plan'], cwd=checkout,
                         env=dict(env, PIPELINE_TIMEOUT_SECONDS='20000'), capture_output=True, text=True)
    assert out.returncode != 0, 'a longer pipeline bound must be refused'

    # --- check-root ------------------------------------------------------
    assert invoke('--check-root').returncode != 0, 'missing run root must be refused'
    run = bundle / 'runs' / CHAOS
    run.mkdir(parents=True)
    state = {'scenario_id': 'CBT-EXP-10', 'run_id': CHAOS, 'vm_name': 'vm-exp10-fixture',
             'lifecycle_ids': ['exp10-fixture'], 'phase': 'started', 'verdict': None}
    (run / 'run.json').write_text(json.dumps(state))
    assert invoke('--check-root').returncode == 0
    accepted = json.loads(invoke('--check-root').stdout)
    assert accepted['matching_fresh_root'] == 'cbt-chaos/scenarios_v2/CBT-EXP-10/runs/' + CHAOS
    for phase in ('running', 'started'):
        state['phase'] = phase
        (run / 'run.json').write_text(json.dumps(state))
        assert invoke('--check-root').returncode == 0, phase
    state['lifecycle_id'] = state.pop('lifecycle_ids')
    (run / 'run.json').write_text(json.dumps(state))
    assert invoke('--check-root').returncode == 0, 'the single lifecycle_id form is accepted'
    state['lifecycle_ids'] = state.pop('lifecycle_id')
    for invalid in ({'scenario_id': 'CBT-EXP-01'}, {'scenario_id': 'CBT-EXP-08'}, {'phase': 'closed'},
                    {'phase': 'finished'}, {'verdict': 'PASS'}, {'run_id': 'mismatch'},
                    {'vm_name': 'vm-other'}, {'lifecycle_ids': ['other-fixture']}, {'lifecycle_ids': []},
                    {'lifecycle_ids': ['exp10-fixture', 'exp10-fixture']}):
        broken = dict(state)
        broken.update(invalid)
        (run / 'run.json').write_text(json.dumps(broken))
        assert invoke('--check-root').returncode != 0, invalid
    (run / 'run.json').write_text(json.dumps(state))
    for path in ('execution', 'trigger', 'action.json', 'effect.json', 'condition.json',
                 'injection-confirmation.json', 'run-report.md', 'analysis.json'):
        output = run / path
        output.parent.mkdir(exist_ok=True)
        output.mkdir() if path == 'execution' else output.write_text('retained evidence\n')
        assert invoke('--check-root').returncode != 0, path
        assert output.is_dir() if path == 'execution' else output.read_text() == 'retained evidence\n'
        output.rmdir() if path == 'execution' else output.unlink()
    assert invoke('--check-root').returncode == 0
    link_name = '17-10-2026-00-00-01-vm-exp10-fixture-redefinition-outage-iteration-1'
    link = bundle / 'runs' / link_name
    link.symlink_to(run)
    linked_env = dict(env, CHAOS_RUN_ID=link_name)
    assert subprocess.run(['bash', str(bundle / 'run.sh'), '--check-root'], cwd=checkout, env=linked_env,
                          capture_output=True, text=True).returncode != 0, 'a symlinked run root must be refused'
    link.unlink()

    # --- node-pinned VM template ----------------------------------------
    template = (source / 'vm-node-pinned.json').read_text()
    assert set(re.findall(r'__[A-Z_]+__', template)) == {'__VM__', '__NAMESPACE__', '__LIFECYCLE__', '__NODE__', '__PUBLIC_KEY__'}
    for token, value in {'__VM__': 'vm-fixture', '__NAMESPACE__': 'vm-cbt-demo', '__LIFECYCLE__': 'fixture',
                         '__NODE__': 'worker-fixture', '__PUBLIC_KEY__': 'ssh-ed25519 AAAA'}.items():
        template = template.replace(token, value)
    vm, service = json.loads(template)['items']
    assert vm['spec']['runStrategy'] == 'Always'
    templates = vm['spec']['dataVolumeTemplates']
    assert len(templates) == 1, 'the EXP-10 VM is single-disk'
    assert templates[0]['metadata']['name'] == 'vm-disk-fixture'
    storage = templates[0]['spec']['storage']
    assert storage['resources']['requests']['storage'] == '80Gi'
    assert storage['storageClassName'] == 'ocs-storagecluster-ceph-rbd'
    assert templates[0]['spec']['sourceRef'] == {'kind': 'DataSource', 'name': 'rhel9',
                                                 'namespace': 'openshift-virtualization-os-images'}
    assert vm['metadata']['labels']['cbt-demo'] == 'enabled'
    assert vm['metadata']['labels']['virt-cbt-lab/pool'] == 'exp10'
    assert vm['metadata']['labels']['app.kubernetes.io/managed-by'] == 'virt-cbt-lab'
    assert vm['metadata']['labels']['virt-cbt-lab/run-id'] == 'fixture'
    assert vm['metadata']['annotations'] == {'virt-cbt-lab/os-profile': 'rhel9',
                                             'virt-cbt-lab/manifest-variant': 'large-odf',
                                             'virt-cbt-lab/incremental-passes': '1'}
    spec = vm['spec']['template']['spec']
    assert spec['nodeSelector'] == {'kubernetes.io/hostname': 'worker-fixture'}
    assert spec['evictionStrategy'] == 'None'
    assert {d['name'] for d in spec['domain']['devices']['disks']} == {'rootdisk', 'cloudinitdisk'}
    assert [v['name'] for v in spec['volumes']] == ['rootdisk', 'cloudinitdisk']
    assert spec['volumes'][0]['dataVolume']['name'] == 'vm-disk-fixture'
    assert 'exp06-data' not in template and 'datadisk' not in template
    assert 'cbt-demo' in spec['volumes'][1]['cloudInitNoCloud']['userData']
    assert 'qemu-guest-agent' in spec['volumes'][1]['cloudInitNoCloud']['userData']
    assert service['metadata']['name'] == 'vm-ssh-fixture'
    assert service['spec']['selector'] == {'vm.kubevirt.io/name': 'vm-fixture'}

    # --- bundle manifest round-trip --------------------------------------
    os.environ.update(FIXTURE)
    sys.path.insert(0, str(bundle))
    try:
        spec_observe = importlib.util.spec_from_file_location('exp10_observe', bundle / 'observe.py')
        observer = importlib.util.module_from_spec(spec_observe)
        spec_observe.loader.exec_module(observer)
        pipeline_spec = importlib.util.spec_from_file_location('exp10_pipeline', bundle / 'pipeline.py')
        pipeline = importlib.util.module_from_spec(pipeline_spec)
        pipeline_spec.loader.exec_module(pipeline)
    finally:
        sys.path.remove(str(bundle))

    hashes = pipeline.bundle_files()
    assert sorted(hashes) == sorted(manifest), 'bundle manifest and hash set must agree'
    assert all(re.fullmatch(r'[0-9a-f]{64}', value) for value in hashes.values())
    assert pipeline.VM == 'vm-exp10-fixture' and pipeline.TRACKER == 'vm-tracker-exp10-fixture'
    assert pipeline.SECOND == 'vm-p5-second-exp10-fixture'
    assert pipeline.RECOVERY_BACKUP == 'vm-p5-recovery-full-exp10-fixture'
    assert pipeline.RECOVERY_PVC == 'vm-p5-recovery-pvc-exp10-fixture'
    assert pipeline.RUN_LABELS == {'app.kubernetes.io/managed-by': 'virt-cbt-lab', 'virt-cbt-lab/run-id': 'exp10-fixture'}
    assert 'GUEST_BASE_FILE_COUNT=1000' in pipeline.PROFILE and 'MANIFEST_VARIANT=large-odf' in pipeline.PROFILE
    assert pipeline.APPROVED_NODE == 'd38-h18-000-r660'
    for entry in ('execution', 'injection-confirmation.json', 'analysis.json', 'run-report.md', 'effect.json'):
        assert entry in pipeline.FORBIDDEN_ROOT_ENTRIES

    # --- pure pipeline helpers -------------------------------------------
    os.environ.pop('SUPPRESS_SECONDS', None)
    assert pipeline.suppress_seconds() == 480
    os.environ['SUPPRESS_SECONDS'] = '300'
    assert pipeline.suppress_seconds() == 300
    os.environ['SUPPRESS_SECONDS'] = '900'
    assert pipeline.suppress_seconds() == 900
    for bad in ('299', '901', '0', 'abc'):
        os.environ['SUPPRESS_SECONDS'] = bad
        try:
            pipeline.suppress_seconds()
        except (AssertionError, ValueError):
            pass
        else:
            raise AssertionError('suppression window accepted ' + bad)
    os.environ.pop('SUPPRESS_SECONDS', None)
    assert pipeline.pipeline_bound() == 14400
    os.environ['PIPELINE_TIMEOUT_SECONDS'] = '900'
    assert pipeline.pipeline_bound() == 900
    os.environ['PIPELINE_TIMEOUT_SECONDS'] = '14401'
    try:
        pipeline.pipeline_bound()
    except AssertionError:
        pass
    else:
        raise AssertionError('a longer pipeline bound was accepted')
    os.environ.pop('PIPELINE_TIMEOUT_SECONDS', None)

    started, released = '2026-10-17T03:00:00+00:00', '2026-10-17T03:08:00+00:00'
    deleted = {'uid-deleted-old', 'uid-deleted-new'}
    inside_deleted = json.dumps({'at': '2026-10-17T03:00:30+00:00',
                                'pods': [{'name': 'h1', 'uid': 'uid-deleted-new', 'phase': 'Running', 'deleting': False}]})
    inside_undeleted = json.dumps({'at': '2026-10-17T03:00:30+00:00',
                                  'pods': [{'name': 'h2', 'uid': 'uid-served', 'phase': 'Running', 'deleting': False}]})
    outside = json.dumps({'at': '2026-10-17T02:59:00+00:00',
                          'pods': [{'name': 'h3', 'uid': 'uid-served', 'phase': 'Running', 'deleting': False}]})
    unknown = json.dumps({'at': '2026-10-17T03:01:00+00:00', 'pods': 'UNKNOWN', 'error': 'rc=1'})
    clean = pipeline.handler_absence(inside_deleted + '\n' + outside + '\n' + unknown, started, released, deleted)
    assert clean['handler_absent_across_window'] is True and clean['undelivered'] == []
    assert clean['observed_running_uids'] == ['uid-deleted-new'] and clean['usable_window_records'] == 1
    served = pipeline.handler_absence(inside_deleted + '\n' + inside_undeleted, started, released, deleted)
    assert served['handler_absent_across_window'] is False
    assert [entry['uid'] for entry in served['undelivered']] == ['uid-served']
    assert pipeline.handler_absence('', started, released, deleted)['handler_absent_across_window'] is None
    assert pipeline.handler_absence(unknown + '\n', started, released, deleted)['handler_absent_across_window'] is None
    assert pipeline.handler_absence(outside + '\n', started, released, deleted)['usable_window_records'] == 0
    malformed = pipeline.handler_absence('not json\n' + inside_deleted, started, released, deleted)
    assert malformed['unusable_lines'] == 1 and malformed['handler_absent_across_window'] is True
    deleting = json.dumps({'at': '2026-10-17T03:02:00+00:00',
                           'pods': [{'name': 'h4', 'uid': 'uid-terminating', 'phase': 'Running', 'deleting': True}]})
    assert pipeline.handler_absence(deleting, started, released, deleted)['observed_running_uids'] == []

    history = pipeline.redefinition_history('\n'.join([
        json.dumps({'at': '2026-10-17T03:00:00+00:00', 'tracker_redefinition_required': 'false',
                    'vmi_cbt_state': 'Initializing', 'vmi_phase': 'Running'}),
        json.dumps({'at': '2026-10-17T03:00:01+00:00', 'tracker_redefinition_required': 'true',
                    'vmi_cbt_state': 'Initializing', 'vmi_phase': 'Running'}),
        json.dumps({'at': '2026-10-17T03:00:02+00:00', 'tracker_redefinition_required': 'false',
                    'vmi_cbt_state': 'Enabled', 'vmi_phase': 'Running'}),
        json.dumps({'at': '2026-10-17T03:00:03+00:00', 'tracker_redefinition_required': None,
                    'vmi_cbt_state': 'Enabled', 'vmi_phase': 'Running', 'tracker_error': 'rc=1: gone'}),
        'not json']))
    assert history['true_observations'] == 1 and history['first_true_at'] == '2026-10-17T03:00:01+00:00'
    assert history['false_observations'] == 2 and history['cbt_enabled_observations'] == 2
    assert history['poll_errors'] == 1 and history['state'] == 'true-observed' and history['polls'] == 4
    assert pipeline.redefinition_history('')['state'] == 'never-true-observed'
    assert pipeline.redefinition_history('', {'vmi': {}})['watch_flag_summary'] == {'vmi': {}}

    full = {'metadata': {'uid': 'u1', 'creationTimestamp': '2026-10-17T03:00:00Z', 'resourceVersion': '7'},
            'spec': {'source': {'kind': 'VirtualMachineBackupTracker', 'name': 'vm-tracker-exp10-fixture'},
                     'pvcName': 'vm-p5-second-exp10-fixture'},
            'status': {'type': 'Full', 'checkpointName': 'cp-1',
                       'conditions': [{'type': 'Initializing', 'status': 'False', 'reason': 'PrerequisitesVerified'},
                                      {'type': 'Done', 'status': 'True', 'reason': 'Succeeded'}],
                       'includedVolumes': [{'volumeName': 'rootdisk'}]}}
    projection = observer.backup_state_from(full)
    assert projection['done'] == 'True' and projection['type'] == 'Full' and projection['checkpoint'] == 'cp-1'
    assert projection['included_volumes'] == ['rootdisk'] and projection['uid'] == 'u1'
    assert [c['type'] for c in projection['conditions']] == ['Initializing', 'Done']
    wedge = copy.deepcopy(full)
    wedge['status']['conditions'] = [{'type': 'Initializing', 'status': 'True', 'reason': 'PrerequisitesNotVerified'}]
    wedge['status']['type'] = None
    assert observer.backup_state_from(wedge)['done'] is None
    assert observer.backup_state_from(None) == {'present': False, 'raw_available': False}
    assert observer.backup_state_from('')['present'] is False
    assert observer.backup_state_from(None)['present'] is False

    # --- observe.py disk/bitmap identity ---------------------------------
    raw = {'return': [
        {'node-name': 'libvirt-0-storage', 'drv': 'file', 'file': '/var/run/kubevirt-private/libvirt/qemu/cbt/rootdisk.qcow2'},
        {'node-name': 'libvirt-1-format', 'drv': 'qcow2', 'file': '/var/run/kubevirt-private/libvirt/qemu/cbt/rootdisk.qcow2',
         'dirty-bitmaps': [{'name': 'cp-1', 'recording': True, 'persistent': True, 'busy': False}]}]}
    nodes = observer.disk_nodes(raw)
    assert nodes['rootdisk']['node-name'] == 'libvirt-1-format'
    assert observer.bitmap_names(nodes['rootdisk']) == ['cp-1']
    ambiguous = copy.deepcopy(raw)
    ambiguous['return'].append(copy.deepcopy(raw['return'][1]))
    try:
        observer.disk_nodes(ambiguous)
    except AssertionError:
        pass
    else:
        raise AssertionError('ambiguous QMP format-node selection was accepted')
    other_disk = copy.deepcopy(raw)
    other_disk['return'][1]['file'] = '/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2'
    try:
        observer.disk_nodes(other_disk)
    except AssertionError:
        pass
    else:
        raise AssertionError('a non-rootdisk format node was accepted by the single-disk selector')
    try:
        observer.disk_nodes({'error': {'desc': 'no such domain'}})
    except AssertionError:
        pass
    else:
        raise AssertionError('a QMP error reply was accepted as a disk inventory')
    assert observer.redefinition_fields({'status': {'checkpointRedefinitionRequired': True,
                                                   'latestCheckpoint': {'name': 'cp'}}}) == {'.status.checkpointRedefinitionRequired': True}
    assert observer.redefinition_fields({'status': {'latestCheckpoint': {'name': 'cp'}}}) == {}
    capture = checkout / 'immutable-qmp.json'
    observer.save(capture, raw)
    try:
        observer.save(capture, [])
    except FileExistsError:
        pass
    else:
        raise AssertionError('raw QMP capture overwritten')
    assert json.loads(capture.read_text()) == raw
    logs = checkout / 'scoped-handler-logs'
    observer.command(logs, 'handler', ['printf', '%s\n', 'vm-exp10-fixture: current', 'vm-exp10-other: excluded',
                                       'unrelated error'], text_scope={'vm-exp10-fixture'})
    assert (logs / 'handler.stdout').read_text() == 'vm-exp10-fixture: current\n'
    status = json.loads((logs / 'handler.status.json').read_text())
    assert status['operation_rc'] == status['evidence_rc'] == 0
    assert status['log_filter']['matched_lines'] == 1 and status['log_filter']['excluded_lines'] == 2
    assert observer.project_handlers({'items': [
        {'metadata': {'name': 'virt-handler-x', 'uid': 'u-1'}, 'spec': {'nodeName': 'n1'},
         'status': {'phase': 'Running', 'startTime': '2026-10-17T03:00:00Z',
                    'conditions': [{'type': 'Ready', 'status': 'True'}]}}]}) == \
        [{'name': 'virt-handler-x', 'uid': 'u-1', 'startTime': '2026-10-17T03:00:00Z', 'phase': 'Running',
          'ready': True, 'deleting': False, 'nodeName': 'n1'}]
    assert observer.project_handlers({'items': [{'metadata': {}, 'spec': {}, 'status': {}}]}) == \
        [{'name': None, 'uid': None, 'startTime': None, 'phase': None, 'ready': False, 'deleting': False,
          'nodeName': None}]
    assert observer.project_handlers(None) == []
    assert pipeline.project_handler_pods({'items': [
        {'metadata': {'name': 'virt-handler-x', 'uid': 'u-1'}, 'spec': {'nodeName': 'n1'}, 'status': {}},
        {'metadata': {'name': 'virt-handler-y', 'uid': 'u-2'}, 'spec': {'nodeName': 'n2'}, 'status': {}}]}) == \
        {'n1': {'virt-handler-x': 'u-1'}, 'n2': {'virt-handler-y': 'u-2'}}
    assert pipeline.project_handler_pods(None) == {}
    source_text = (source / 'observe.py').read_text()
    assert 'redefinition-poller.jsonl' in source_text and 'handler-pods.jsonl' in source_text
    assert 'def handlers(' in source_text and 'def redefinition_poller(' in source_text
    assert 'def snapshot(' in source_text and 'def watch(' in source_text and 'def collect(' in source_text

    # --- repeated probe naming (regression: attempt 1's collector crash) ---
    # collect() re-probes the VMI nodeName every cadence while the VMI has no node, and
    # snapshot() probes every candidate node of one PVC. Both write exclusively created
    # artifacts (save() uses "x", command() uses "xb"), so two probes that share one
    # output name raise FileExistsError and kill the read-only collector before any
    # mutating stage - exactly the BLOCKED attempt 1. Every probe below is the real
    # function with only the oc subprocess faked, so the old naming fails here.
    VM_UID_FLOW, PVC_UID_FLOW, PV_FLOW, PVC_FLOW = 'uid-vm-flow', 'uid-pvc-flow', 'pv-flow', 'vm-p5-second-exp10-fixture'
    UNPINNED_NODE, PINNED_NODE = 'node-aa-unpinned', 'node-zz-pinned'

    def canned_stdout(argv):
        tokens = [str(token) for token in argv]
        if tokens[0] != 'oc':
            return b''  # the nested `python3 observe.py snapshot` call is faked out too
        resource = tokens[tokens.index('get') + 1] if 'get' in tokens else ''
        if resource == 'vm':
            return json.dumps({'metadata': {'uid': VM_UID_FLOW}}).encode()
        if resource == 'vmi':
            return json.dumps({'metadata': {'uid': 'uid-vmi-flow'}, 'status': {'nodeName': None}}).encode()
        if resource == 'pvc':
            return json.dumps({'items': [{'metadata': {'name': PVC_FLOW, 'uid': PVC_UID_FLOW},
                                          'spec': {'volumeName': PV_FLOW, 'storageClassName': 'ocs-storagecluster-ceph-rbd'}}]}).encode()
        if resource == 'pv':
            return json.dumps({'metadata': {'uid': 'uid-pv-flow'},
                               'spec': {'claimRef': {'uid': PVC_UID_FLOW},
                                        'csi': {'volumeAttributes': {'imageName': 'image-flow'},
                                                'volumeHandle': 'handle-flow'}}}).encode()
        if resource == 'volumeattachments':
            return json.dumps({'items': [{'spec': {'nodeName': UNPINNED_NODE,
                                                   'source': {'persistentVolumeName': PV_FLOW}}}]}).encode()
        if resource == 'node':
            return json.dumps({'metadata': {'uid': 'uid-node-flow'}, 'status': {}}).encode()
        if resource == 'pods' and 'kubevirt.io=virt-handler' in tokens:
            return json.dumps({'items': [{'metadata': {'name': 'virt-handler-flow', 'uid': 'uid-handler-flow'},
                                          'status': {'phase': 'Running'}}]}).encode()
        if resource in ('pods', 'events', 'vmbackup', 'vmbackuptracker', 'dv'):
            return json.dumps({'items': []}).encode()
        return b'{}'

    class FakeProcess:
        def __init__(self, stdout):
            self.stdout, self.pid, self.returncode = stdout, 4321, 0

        def communicate(self, data=None, timeout=None):
            return self.stdout, b''

    real_popen = observer.subprocess.Popen
    real_monotonic, real_sleep = observer.time.monotonic, observer.time.sleep
    ticks = [0]

    def fake_monotonic():
        ticks[0] += 1000
        return float(ticks[0])

    observer.subprocess.Popen = lambda argv, **kwargs: FakeProcess(canned_stdout(argv))
    observer.time.monotonic = fake_monotonic
    observer.time.sleep = lambda seconds: None
    try:
        collector_dir = checkout / 'collector-repeat-probe'
        collector_rc = observer.collect('exp10-fixture', VM_UID_FLOW, collector_dir)
        snapshot_dir = checkout / 'snapshot-two-nodes'
        observer.snapshot(snapshot_dir, 'exp10-fixture', VM_UID_FLOW,
                          {PVC_UID_FLOW: {'uid-pod-flow': PINNED_NODE}})
    finally:
        observer.subprocess.Popen = real_popen
        observer.time.monotonic, observer.time.sleep = real_monotonic, real_sleep

    assert collector_rc in (0, 1), collector_rc
    for stale in ('node-probe.status.json', 'node-probe.stdout', 'node-probe.json'):
        assert not (collector_dir / stale).exists(), 'the collision-prone fixed probe name returned: ' + stale
    probes = sorted(path.name for path in collector_dir.glob('node-probe-*.status.json'))
    assert len(probes) >= 2, ('the pending-node probe did not repeat; naming was not exercised', probes)
    assert all(re.fullmatch(r'node-probe-\d{4}\.status\.json', name) for name in probes), probes
    assert all(json.loads((collector_dir / name).read_text())['readable'] is True for name in probes), probes
    # The unpinned node is probed first and appends no host result, so the pinned node's
    # probe must not reuse its output name (that reuse raised FileExistsError).
    for index in ('0', '1'):
        assert (snapshot_dir / ('node-' + PVC_UID_FLOW + '-' + index + '.json')).is_file(), index
        assert (snapshot_dir / ('handlers-' + PVC_UID_FLOW + '-' + index + '.stdout')).is_file(), index
    snapshot_flow = json.loads((snapshot_dir / 'snapshot.json').read_text())
    assert snapshot_flow['layers']['storage'] == 'OBSERVED'
    assert snapshot_flow['storage'][0]['pvc_uid'] == PVC_UID_FLOW
    assert snapshot_flow['storage'][0]['csi_handle'] == 'handle-flow'

    # --- exclusion snapshot name (regression: `(Path / str) + str`) ------
    # exclusions() writes one snapshot per label. The unparenthesized
    # `directory / "exclusion-" + label + ".json"` parses as `((directory / "exclusion-") + label)
    # + ".json"`, so its first `+` adds a str to a PosixPath and raises TypeError before the
    # snapshot exists. No Add may therefore take a Div as its left operand in either bundle file,
    # and the real exclusions() body must still write the joined name onto disk.
    for name in ('pipeline.py', 'observe.py'):
        for node in ast.walk(ast.parse((source / name).read_text())):
            if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add) and \
                    isinstance(node.left, ast.BinOp) and isinstance(node.left.op, ast.Div):
                raise AssertionError(name + ':' + str(node.lineno) +
                                     ' concatenates onto a path join without parentheses: ' + ast.unparse(node))

    class ProbeStub:
        """The real exclusions() body with only self.probe/vmi_inventory/run_objects faked."""

        def __init__(self):
            self.names = []

        def probe(self, directory, name, args):
            self.names.append(name)
            resource = args[1]
            if resource == 'node':
                value = {'metadata': {'uid': 'uid-node', 'labels': {'cbt-demo': 'enabled'}}, 'spec': {},
                         'status': {'conditions': [{'type': 'Ready', 'status': 'True'}]}}
            elif resource == 'vm':
                value = {'metadata': {'uid': 'uid-vm'}, 'spec': {'runStrategy': 'Always'}}
            elif resource == 'vmi':
                value = {'items': [{'metadata': {'name': pipeline.VM, 'uid': 'uid-vmi'},
                                    'status': {'nodeName': pipeline.NODE}}]}
            elif '-l' in args:
                value = {'items': [{'metadata': {'name': 'virt-handler-on-node', 'uid': 'uid-h-on'},
                                    'spec': {'nodeName': pipeline.NODE}, 'status': {'phase': 'Running'}},
                                   {'metadata': {'name': 'virt-handler-elsewhere', 'uid': 'uid-h-else'},
                                    'spec': {'nodeName': 'node-elsewhere'}, 'status': {'phase': 'Running'}}]}
            else:
                value = {'items': [{'metadata': {'name': 'launcher-1', 'uid': 'uid-launcher',
                                                 'labels': {'vm.kubevirt.io/name': pipeline.VM}},
                                    'spec': {'nodeName': pipeline.NODE}, 'status': {'phase': 'Running'}}]}
            return value, {'operation_rc': 0, 'evidence_rc': 0}

    real_vmi_inventory, real_run_objects = pipeline.vmi_inventory, pipeline.run_objects
    pipeline.vmi_inventory = lambda directory, name: {'probe': name}
    pipeline.run_objects = lambda directory, name, lifecycle: {'probe': name, 'lifecycle': lifecycle}
    try:
        exclusions_dir = checkout / 'exclusion-path-join'
        stub = ProbeStub()
        before_record = pipeline.Pipeline.exclusions(stub, exclusions_dir, 'before')
    finally:
        pipeline.vmi_inventory, pipeline.run_objects = real_vmi_inventory, real_run_objects
    snapshot = exclusions_dir / 'exclusion-before.json'
    assert snapshot.is_file(), 'exclusions() did not write its snapshot under the joined name'
    assert json.loads(snapshot.read_text()) == before_record and before_record['label'] == 'before'
    assert stub.names == ['node-before', 'handlers-all-before', 'vm-before', 'vmis-before', 'pods-before']
    assert before_record['handlers_target_node'] == {'virt-handler-on-node': 'uid-h-on'}
    assert before_record['handlers_other_nodes'] == {'node-elsewhere': {'virt-handler-elsewhere': 'uid-h-else'}}
    assert before_record['node_vmis'] == {pipeline.VM: {'uid': 'uid-vmi', 'phase': None}}
    assert before_record['node_launchers'] == {'launcher-1': {'uid': 'uid-launcher', 'phase': 'Running'}}

    # --- identity-key contract (regression: iteration-3 KeyError 'vmi' at pipeline.py:1148) ---
    # observe.identity() returns exactly these keys; every `target[...]` read must use one.
    # The unfixed pipeline.py read target['vmi'] (the VMI has no name key) and raised
    # KeyError 0.4 ms after wait_new_vmi returned, ending the hold 64 s into a 480 s window.
    identity_keys = {'vm', 'vm_uid', 'vmi_uid', 'pod', 'pod_uid', 'node', 'domain'}
    for node in ast.walk(ast.parse((source / 'pipeline.py').read_text())):
        if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name) and node.value.id == 'target':
            assert isinstance(node.slice, ast.Constant) and node.slice.value in identity_keys, \
                'pipeline.py:' + str(node.lineno) + ' reads target[' + ast.unparse(node.slice) + '], not an observe.identity() key'
    real_target = {'vm': 'vm-x', 'vm_uid': 'uid-vm', 'vmi_uid': 'uid-vmi-old',
                   'pod': 'virt-launcher-old', 'pod_uid': 'uid-pod-old', 'node': 'n', 'domain': 'd'}
    real_replacement = {'metadata': {'uid': 'uid-vmi-new'}}
    built = {"before": {"vmi_uid": real_target["vmi_uid"], "vmi": real_target["vmi_uid"],
                        "pod": real_target["pod"], "pod_uid": real_target["pod_uid"]},
             "after": {"vmi_uid": real_replacement["metadata"]["uid"]},
             "vm_uid": real_target["vm_uid"]}
    assert built["before"]["vmi"] == 'uid-vmi-old' and built["after"]["vmi_uid"] == 'uid-vmi-new'

    # --- collector terminal-marker directory (regression: collect join timeout, no 300 s window) ---
    # finish() wrote execution/<collector-key>/terminal.json, i.e. execution/collect/, but the
    # collect collector polls the directory it was spawned with, execution/collector/. The marker
    # never arrived, so the collector timed out (rc 124) after every attempt and a clean run
    # still exited 1 with no terminal-window evidence.
    pipeline_text = (source / 'pipeline.py').read_text()
    assert 'str(self.work / "collector")' in pipeline_text          # spawn directory
    assert 'self.collector_dirs' in pipeline_text                   # dirs recorded at spawn
    assert 'self.work / name / "terminal.json"' not in pipeline_text  # name-keyed marker path removed
    finish_node = next(node for node in ast.walk(ast.parse(pipeline_text))
                       if isinstance(node, ast.FunctionDef) and node.name == 'finish')
    finish_source = ast.unparse(finish_node)
    # The watch projection is consumed only after the collector join (F4b). Before that fix
    # observe_window() read a transitions.json that the still-running collector had not written.
    assert 'watch_flag_summary' in finish_source, 'finish() no longer enriches the redefinition check from the watch projection'
    assert finish_source.index('collector.wait') < finish_source.index('watch_flag_summary'), \
        'the watch projection must be consumed after the collector join'

    # --- component_logs parse guard (regression: unguarded json.loads on collector exit) ---
    # A failed/timed-out snapshot leaves an empty or partial vmbackup.stdout. The unguarded
    # json.loads('') raised JSONDecodeError after all samples were preserved but before
    # terminal-collection.json and the component-log windows were written.
    bad_dir = checkout / 'component-logs-bad-sample'
    bad_dir.mkdir()
    (checkout / 'sample-bad').mkdir(exist_ok=True)
    (checkout / 'sample-bad' / 'vmbackup.stdout').write_text('')   # failed probe shape
    (checkout / 'sample-valid').mkdir(exist_ok=True)
    (checkout / 'sample-valid' / 'vmbackup.stdout').write_text(json.dumps({'items': [
        {'metadata': {'name': 'vm-backup-exp10-fixture', 'uid': 'uid-backup-flow'}}]}))
    real_command = observer.command
    scopes = []

    def recording_command(directory, name, argv, *args, **kwargs):
        scopes.append(set(kwargs.get('text_scope') or ()))
        return real_command(directory, name, argv, *args, **kwargs)

    observer.subprocess.Popen = lambda argv, **kwargs: FakeProcess(
        json.dumps({'items': [{'metadata': {'name': 'virt-controller-fixture'}}]}).encode()
        if argv[:1] == ['oc'] and 'kubevirt.io=virt-controller' in argv else b'{}')
    observer.command = recording_command
    try:
        observer.component_logs(bad_dir, '2026-10-18T00:00:00Z', 'exp10-fixture', VM_UID_FLOW, None)
    finally:
        observer.command = real_command
        observer.subprocess.Popen = real_popen
    scoped = [scope for scope in scopes if scope]
    assert len(scoped) == 1, scopes
    assert {'vm-backup-exp10-fixture', 'uid-backup-flow', VM_UID_FLOW} <= scoped[0], \
        'a valid sample stopped contributing its backup identity to the component-log scope'

    # --- watch stream decoding (regression: pretty-printed events dropped) ---
    # `oc get -w -o json` emits one pretty-printed multi-line document per event; a
    # line-by-line parse dropped all 2497 VMI lines and all 38 tracker lines (0 events).
    pretty = ('{\n  "kind": "VirtualMachineInstance",\n  "metadata": {"uid": "u-1"},\n'
              '  "status": {"phase": "Scheduling"}\n}\n{\n  "kind": "VirtualMachineInstance",\n'
              '  "metadata": {"uid": "u-1"},\n  "status": {"phase": "Running"}\n}\n')
    documents = observer.decode_watch_stream('\n  ' + pretty + '{"kind": "VirtualMachineInstance", "metadata": {')
    assert len(pretty.splitlines()) > 2
    assert len(documents) == 2, documents                       # a truncated tail is dropped, never raised
    assert [document['status']['phase'] for document in documents] == ['Scheduling', 'Running']
    assert observer.decode_watch_stream('') == []
    envelope = {'type': 'ADDED', 'object': {'kind': 'VirtualMachineInstance', 'metadata': {'uid': 'u-2'}}}
    assert observer.parse_watch_document(envelope) == ('ADDED', envelope['object'])
    assert observer.parse_watch_document({'kind': 'List', 'items': [{'a': 1}]}) == ('LIST', {'a': 1})
    assert observer.parse_watch_document({'kind': 'VirtualMachineBackupTracker'}) == \
        ('MODIFIED', {'kind': 'VirtualMachineBackupTracker'})
    assert observer.parse_watch_document('not an object') == (None, None)

    # --- suppressor contract (structure only; never executed here) --------
    suppressor = (source / 'suppress.sh').read_text()
    assert 'kubevirt.io=virt-handler' in suppressor
    assert '--grace-period=0' in suppressor and '--wait=false' in suppressor
    assert 'hard_deadline=$((started_epoch + window + 60))' in suppressor
    assert "trap 'stop sigterm' TERM" in suppressor and "trap 'stop sigint' INT" in suppressor
    assert 'suppressor-deletions.jsonl' in suppressor and 'suppressor-stopped.json' in suppressor
    assert 'select(.spec.nodeName == $node)' in suppressor
    assert 'select(.metadata.deletionTimestamp == null)' in suppressor
    assert 'delete pvc' not in suppressor and 'delete vmi' not in suppressor and 'delete vm ' not in suppressor
    assert 'delete pod "$name" -n openshift-cnv' in suppressor
    assert (suppressor.count('oc --request-timeout') == 2), 'the suppressor holds only list/delete oc calls'
    pipeline_text = (source / 'pipeline.py').read_text()
    assert 'suppress.sh' in pipeline_text and 'str(self.suppress)' in pipeline_text
    assert 'killpg' in pipeline_text and 'preconditions' in pipeline_text
    assert '--for=condition=Done' in pipeline_text
    assert 'os.killpg(self.suppressor.pid, signal.SIGTERM)' in pipeline_text
    assert 'gracePeriodSeconds": 0' in pipeline_text
    assert 'injection-confirmation.json' in pipeline_text

print('PASS: EXP10 plan/parameters/check-root identity, suppression bounds, node-pinned single-disk template, '
      'bundle manifest hashes, pure outage/redefinition projections, QMP single-disk selection, repeated '
      'collector/snapshot probe naming, exclusion snapshot path join, identity-key target reads, '
      'collector terminal-marker directories, component-log parse guard, concatenated watch-stream '
      'decoding and suppressor bounds (offline only).')
PY
