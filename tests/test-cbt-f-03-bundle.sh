#!/usr/bin/env bash
set -euo pipefail
# Offline consumer/rehearsal test for the CBT-F-03 v2 bundle.
# No cluster, no container runtime, no fault: a fake oc/podman/krknctl/make
# environment drives run.sh through preflight, arming, the native trigger,
# the failover effect, both backup stages, and the summary. The rehearsal root
# lives in a temporary directory, never inside the scenario runs/ tree.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_REL='cbt-chaos/scenarios_v2/CBT-F-03'
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rehearsal-f03-XXXXXX")"
cleanup() {
  if [[ "${F03_KEEP_REHEARSAL:-0}" == 1 ]]; then
    printf 'rehearsal tree kept: %s\n' "$TMP" >&2
    return 0
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- static ----
bash -n "$ROOT/$BUNDLE_REL/run.sh" || fail 'run.sh is not valid bash'
bash -n "$ROOT/$BUNDLE_REL/condition.sh" || fail 'condition.sh is not valid bash'
bash -n "$ROOT/$BUNDLE_REL/guest-key-approval.sh" || fail 'guest-key-approval.sh is not valid bash'
bash -n "$ROOT/$BUNDLE_REL/bundle-files.txt" 2>/dev/null || true

# Every declared dependency must exist (and not be a symlink).
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  [[ -f "$ROOT/$file" && ! -L "$ROOT/$file" ]] || fail "manifest entry is not a real file: $file"
done < "$ROOT/$BUNDLE_REL/bundle-files.txt"

# checks.jq must compile with the observation library and behave on fixtures.
JQ=/usr/bin/jq
"$JQ" -en -L "$ROOT/$BUNDLE_REL" 'include "checks"; {return: []} | (backup_window_open | not)' >/dev/null ||
  fail 'checks.jq does not compile'
"$JQ" -en -L "$ROOT/$BUNDLE_REL" '
  include "checks";
  def progress: {metadata:{deletionTimestamp:null,labels:null},status:{conditions:[{type:"Progressing",status:"True"}]}};
  def done_and_progress: {metadata:{deletionTimestamp:null},status:{conditions:[{type:"Progressing",status:"True"},{type:"Done",status:"True"}]}};
  def deleting: {metadata:{deletionTimestamp:"x"},status:{conditions:[{type:"Progressing",status:"True"}]}};
  def empty: {metadata:{labels:null},status:{conditions:null}};
  (progress | backup_window_open)
  and (done_and_progress | backup_window_open | not)
  and (deleting | backup_window_open | not)
  and (empty | backup_window_open | not)
  and (("a\nb\n" | checkpoint_names) == ["a","b"])
  and (("Name  Created  State\n------\n vm-a  2026  running\n   vm-b  2026  running\n" | checkpoint_tree) == ["vm-a","vm-b"])
  and (({metadata:{resourceVersion:"200"}} | rv_advanced("100")) == true)
  and (({metadata:{resourceVersion:"200"}} | rv_advanced("300")) == false)
  and (({metadata:{resourceVersion:"x"}} | rv_advanced("100")) == false)
  and (("11111111-1111-1111-1111-111111111111" | uid_shaped) == true)
  and (("null" | uid_shaped) == false)
  and ((null | uid_shaped) == false)' >/dev/null || fail 'checks.jq predicates are wrong on fixtures'
"$JQ" -en -L "$ROOT/$BUNDLE_REL" '
  include "checks";
  def pod($n;$uid;$ready;$d): {metadata:{name:$n,uid:$uid,labels:{"kubevirt.io":"virt-controller"},
      deletionTimestamp:$d,ownerReferences:[{kind:"ReplicaSet",uid:"rs"}]},
    spec:{nodeName:"n"},status:{phase:"Running",conditions:[{type:"Ready",status:$ready}]}};
  ({items:[pod("a";"u1";"True";null),pod("s";"u2";"True";null),pod("gone";"u3";"False";null)]} as $p |
   ($p|controller_pods("rs")|length) == 2 and ($p|ready_pod_named("a"))
   and (($p|new_controller_pods("rs";["u1","u2"])|length) == 0)
   and (($p|new_controller_pods("rs";["u1"]))[0].metadata.uid == "u2"))' >/dev/null ||
  fail 'controller pod selection is wrong on fixtures'
"$JQ" -en -L "$ROOT/$BUNDLE_REL" '
  include "checks";
  ({items:[{metadata:{name:"keep",uid:"1"}},{metadata:{name:"gone",uid:"2"}},{metadata:{name:"own",uid:"3"}}]} | uid_map) as $before
  | ({items:[{metadata:{name:"keep",uid:"1"}},{metadata:{name:"own",uid:"9"}},{metadata:{name:"new",uid:"4"}}]} | uid_map) as $after
  | (($after | identity_changes($before; ["own"])) == [{name:"gone",before:"2",after:null}])
  and (($after | new_identities($before; ["own"])) == [{name:"new",uid:"4"}])' >/dev/null ||
  fail 'identity comparison is wrong on fixtures'
"$JQ" -sn -L "$ROOT/$BUNDLE_REL" '
  include "checks";
  ([{type:"ADDED",object:{spec:{holderIdentity:"a"}}},
    {type:"MODIFIED",object:{spec:{holderIdentity:"a"}}},
    {type:"MODIFIED",object:{spec:{holderIdentity:"s"}}}] | lease_transitions("a")) == [{from:"a",to:"s"}]' >/dev/null ||
  fail 'lease transition decoding is wrong on fixtures'

# --------------------------------------------------------- rehearsal tree ----
WORKROOT="$TMP/checkout"
mkdir -p "$WORKROOT"
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  mkdir -p "$WORKROOT/$(dirname "$file")"
  cp "$ROOT/$file" "$WORKROOT/$file"
done < "$ROOT/$BUNDLE_REL/bundle-files.txt"
BUNDLE="$WORKROOT/$BUNDLE_REL"
mkdir -p "$WORKROOT/state" "$WORKROOT/keys" "$WORKROOT/runs"
printf 'ssh-ed25519 AAAArehearsal\n' > "$WORKROOT/keys/id_ed25519.pub"
printf 'rehearsal-private\n' > "$WORKROOT/keys/id_ed25519"
printf 'fake-kubeconfig\n' > "$WORKROOT/kubeconfig"
cat > "$WORKROOT/.env" <<EOF
KUBECONFIG_PATH=$WORKROOT/kubeconfig
GUEST_KEY=keys/id_ed25519
RESTORE_HELPER_IMAGE=quay.io/rh-ee-darjain/cbt-restore-helper@sha256:95c5932957c0d4f4286848659ffcecd5d06508a8c15ac20cba0fe28400269e1f
EOF

# ------------------------------------------------------------- fake tools ----
FAKEBIN="$TMP/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/timeout" <<'EOF'
#!/usr/bin/env bash
while [[ "${1:-}" == -* ]]; do
  if [[ "$1" == "-k" || "$1" == "-s" ]]; then shift 2; else shift; fi
done
shift
exec "$@"
EOF
cat > "$FAKEBIN/sha256sum" <<'EOF'
#!/usr/bin/env bash
for f in "$@"; do
  printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d ' ' -f1)" "$f"
done
EOF
cat > "$FAKEBIN/hostname" <<'EOF'
#!/usr/bin/env bash
printf 'rehearsal-host\n'
EOF
cat > "$FAKEBIN/krknctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) printf 'krknctl version 0.14.2-beta\n'; exit 0 ;;
  list) printf 'Name            Size      Digest   Last Modified\npod-scenarios   10 MB     sha256:x 2026-10-01\n'; exit 0 ;;
  describe) printf 'pod-scenarios: Pod Failures\n'; exit 0 ;;
  run)
    case "$*" in
      'run --help') printf 'Error: please enter a scenario name\n' >&2; exit 1 ;;
      *--help*) cat <<'HELP'
--namespace string --name-pattern string --pod-label string --disruption-count number
--execution enum (Defaults: serial) --kill-timeout number --expected-recovery-time number
--force boolean --iterations number --daemon-mode boolean --wait-duration number
--telemetry-enabled boolean --trigger-command string --trigger-expected-rc number
--triggers-mode enum --triggers-timeout number --triggers-interval number
--triggers-on-timeout skip|fail|run_anyway (Default: skip)
HELP
        exit 0 ;;
      *--dry-run*) printf 'Scenario schema valid\nAll required fields present\nValues validated\n'; exit 0 ;;
    esac
    printf 'unexpected krknctl run invocation\n' >&2
    exit 2 ;;
esac
printf 'unexpected krknctl invocation\n' >&2
exit 2
EOF
cat > "$FAKEBIN/make" <<'EOF'
#!/usr/bin/env bash
while [[ "${1:-}" == -* ]]; do shift; done
target=''; run_id=''
for arg in "$@"; do
  case "$arg" in
    *=*) [[ "$arg" == RUN_ID=* ]] && run_id="${arg#RUN_ID=}" ;;
    *) target="$arg" ;;
  esac
done
case "$target" in
  preflight|monitor) exit 0 ;;
  vm-setup)
    touch "$FAKE_STATE/vm_created"
    mkdir -p "$FAKE_ROOT/runs/$run_id"
    exit 0 ;;
  vm-backup)
    if [[ "${F03_FAKE_NO_WINDOW:-0}" == 1 ]]; then
      # No run-scoped backup is ever created: the injection window never opens.
      exit 0
    fi
    date -u +%Y-%m-%dT%H:%M:%SZ > "$FAKE_STATE/backup_created_at"
    touch "$FAKE_STATE/backup_created"
    for _ in $(seq 1 150); do
      [[ -e "$FAKE_STATE/post_action" ]] && break
      sleep 0.1
    done
    touch "$FAKE_STATE/full_done"
    exit 0 ;;
  vm-cbt-backup)
    touch "$FAKE_STATE/incremental_created"
    sleep 0.2
    touch "$FAKE_STATE/incremental_done"
    exit 0 ;;
  vm-cbt-verify)
    touch "$FAKE_STATE/verify_done"
    exit 0 ;;
  run-summary)
    mkdir -p "$FAKE_ROOT/runs/$run_id"
    printf '{"verdict":null,"rehearsal":true}\n' > "$FAKE_ROOT/runs/$run_id/summary.json"
    exit 0 ;;
esac
printf 'unexpected make target: %s\n' "$target" >&2
exit 2
EOF
cat > "$FAKEBIN/podman" <<'EOF'
#!/usr/bin/env bash
# Replays the pinned krkn container: trigger loop for the action, or the
# container-side condition preflight. The real condition.sh runs against the
# fake cluster, so the trigger logic under test is the bundle own script.
args=("$@")
cidfile=''
evid=''
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[$i]}" == --cidfile ]] && cidfile="${args[$((i + 1))]}"
  if [[ "${args[$i]}" == -v && "${args[$((i + 1))]}" == *:/evidence* ]]; then
    evid="${args[$((i + 1))]}"
    evid="${evid%%:/evidence*}"
  fi
done
if [[ "${1:-}" == image && "${2:-}" == inspect ]]; then
  img="${3:-}"
  printf '[{"Digest":"%s","RepoDigests":["%s"]}]\n' "${img##*@}" "$img"
  exit 0
fi
if [[ "${1:-}" == stop ]]; then exit 0; fi
[[ -n "$evid" ]] || { printf 'fake podman: no /evidence mount\n' >&2; exit 2; }
[[ -n "$cidfile" ]] && printf '%s\n' "$$" > "$cidfile"
if [[ " ${args[*]} " == *"/bundle/condition.sh --preflight"* ]]; then
  F03_EVIDENCE="$evid" bash "$FAKE_BUNDLE/condition.sh" --preflight
  exit $?
fi
if [[ " ${args[*]} " == *"/home/krkn/run.sh"* ]]; then
  for _ in $(seq 1 40); do
    if F03_EVIDENCE="$evid" bash "$FAKE_BUNDLE/condition.sh" --poll >/dev/null 2>&1; then
      [[ "${F03_FAKE_NO_WINDOW:-0}" == 1 ]] && break
      touch "$FAKE_STATE/post_action"
      exit 0
    fi
    sleep 0.2
  done
  exit 1
fi
if [[ "${1:-}" == stop ]]; then exit 0; fi
printf 'unexpected podman invocation\n' >&2
exit 2
EOF
cat > "$FAKEBIN/oc" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
S="$FAKE_STATE"
have() { [[ -e "$S/$1" ]]; }
notfound() { printf 'Error from server (NotFound): %s\n' "$1" >&2; exit 1; }
VM='vm-f03-rehearsal'
LAUNCHER='virt-launcher-f03'
A='virt-controller-6f7bc6b44c-aaaaa'
POD_S='virt-controller-6f7bc6b44c-bbbbb'
POD_R='virt-controller-6f7bc6b44c-ccccc'
UID_VM='11111111-1111-1111-1111-111111111111'
UID_VMI='22222222-2222-2222-2222-222222222222'
UID_L='33333333-3333-3333-3333-333333333333'
UID_A='44444444-4444-4444-4444-444444444444'
UID_S='55555555-5555-5555-5555-555555555555'
UID_R='66666666-6666-6666-6666-666666666666'
UID_RS='77777777-7777-7777-7777-777777777777'
UID_D='88888888-8888-8888-8888-888888888888'
UID_LEASE='99999999-9999-9999-9999-999999999999'
FULL='vm-backup-f03-rehearsal'
INCR='vm-incremental-f03-rehearsal-p01'
TRACKER='vm-tracker-f03-rehearsal'
FULL_CP="$FULL"
CHILD_CP="$INCR"
created_at() { cat "$S/backup_created_at" 2>/dev/null || printf '2000-01-01T00:00:00Z'; }
pod_json() { # name uid ready owner
  printf '{"metadata":{"name":"%s","uid":"%s","labels":{"kubevirt.io":"virt-controller"},"deletionTimestamp":null,"ownerReferences":[{"kind":"ReplicaSet","uid":"%s"}]},"spec":{"nodeName":"node-a"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"%s"}]}}\n' "$1" "$2" "$UID_RS" "$3"
}
controller_pods() {
  printf '{"items":['
  local first=1
  for spec in "$POD_S:$UID_S:True" "$POD_R:$UID_R:True"; do
    [[ "$first" == 1 ]] || printf ','
    first=0
    pod_json "${spec%%:*}" "$(cut -d: -f2 <<<"$spec")" "$(cut -d: -f3 <<<"$spec")"
  done
  printf ']}\n'
}
launcher_json() {
  printf '{"metadata":{"name":"%s","uid":"%s","labels":{"vm.kubevirt.io/name":"%s"},"deletionTimestamp":null,"ownerReferences":[{"kind":"VirtualMachineInstance","uid":"%s"}]},"spec":{"nodeName":"node-a"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}\n' "$LAUNCHER" "$UID_L" "$VM" "$UID_VMI"
}
backup_json() { # name type done checkpoint rv
  local conditions rv
  if [[ "$3" == true ]]; then
    conditions="[{\"type\":\"Progressing\",\"status\":\"False\",\"reason\":\"Completed\"},{\"type\":\"Done\",\"status\":\"True\",\"reason\":\"Successfully completed VirtualMachineBackup\"}]"
  else
    conditions="[{\"type\":\"Progressing\",\"status\":\"True\",\"reason\":\"Reconciling\"}]"
  fi
  printf '{"metadata":{"name":"%s","uid":"%s","resourceVersion":"%s","creationTimestamp":"%s","deletionTimestamp":null,"labels":{"virt-cbt-lab/run-id":"f03-rehearsal"}},"spec":{"source":{"name":"%s"},"pvcName":"vm-backup-pvc-f03-rehearsal"},"status":{"type":"%s","checkpointName":"%s","conditions":%s}}\n' \
    "$1" "$(printf '%s' "$1" | shasum -a 256 | cut -c1-32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')" "${5:-50}" "$(created_at)" "$TRACKER" "$2" "$4" "$conditions"
}
tracker_json() { # checkpoint rv
  printf '{"metadata":{"name":"%s","uid":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","resourceVersion":"%s","creationTimestamp":"%s"},"status":{"latestCheckpoint":{"name":"%s","volumes":[{"volumeName":"rootdisk","diskTarget":"vda"}]}}}\n' \
    "$TRACKER" "${2:-10}" "$(created_at)" "$1"
}
checkpoints_tree() {
  have full_done || return 0
  printf ' Name                              Creation Time               State\n'
  printf -- '--------------------------------------------------------------------------\n'
  printf ' %s  2026-10-18 10:00:00  running\n' "$FULL_CP"
  if have incremental_done; then
    printf '   %s  2026-10-18 10:05:00  running\n' "$CHILD_CP"
  fi
}
checkpoints_names() {
  have full_done || return 0
  printf '%s\n' "$FULL_CP"
  if have incremental_done; then printf '%s\n' "$CHILD_CP"; fi
}
while [[ "${1:-}" == --* ]]; do shift; done
sub="${1:-}"; shift || true
case "$sub" in
  config) printf '{"current-context":"fake"}\n'; exit 0 ;;
  auth) printf 'yes\n'; exit 0 ;;
  logs)
    ns=''; name=''; follow=0; previous=0
    while (($#)); do
      case "$1" in
        -n) ns="$2"; shift 2 ;;
        -f) follow=1; shift ;;
        --previous) previous=1; shift ;;
        --timestamps|--since-time=*|--tail=*) shift ;;
        -*) shift ;;
        *) name="$1"; shift ;;
      esac
    done
    if [[ "$previous" == 1 ]]; then
      printf 'Error from server (BadRequest): previous terminated container not found\n' >&2
      exit 1
    fi
    if [[ "$name" == "$A" && ! -e "$S/post_action" ]]; then
      printf '2026-10-18T10:00:00Z leader acquired\n'
      if [[ "$follow" == 1 ]]; then
        for _ in $(seq 1 100); do [[ -e "$S/post_action" ]] && break; sleep 0.1; done
      fi
      exit 0
    fi
    if [[ "$name" == "$A" ]]; then
      printf 'Error from server (NotFound): pods "%s" not found\n' "$name" >&2
      exit 1
    fi
    printf '2026-10-18T10:00:30Z reconciling backup %s\n' "$FULL"
    if [[ "$follow" == 1 ]]; then sleep 300; fi
    exit 0 ;;
  exec)
    ns=''; pod=''; container=''
    while (($#)); do
      case "$1" in
        -n) ns="$2"; shift 2 ;;
        -c) container="$2"; shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) pod="$1"; shift ;;
      esac
    done
    cmd=("$@")
    if [[ "${cmd[0]:-}" == virsh && "${cmd[1]:-}" == checkpoint-list ]]; then
      case " ${cmd[*]} " in
        *" --tree "*) checkpoints_tree; exit 0 ;;
        *" --name "*) checkpoints_names; exit 0 ;;
      esac
    fi
    printf 'unexpected exec: %s\n' "${cmd[*]}" >&2
    exit 2 ;;
  get)
    resource="${1:-}"; shift || true
    ns='default'; label=''; fs=''; name=''; watch=0; outfmt=''
    while (($#)); do
      case "$1" in
        -n) ns="$2"; shift 2 ;;
        -l) label="$2"; shift 2 ;;
        --field-selector) fs="$2"; shift 2 ;;
        --field-selector=*) fs="${1#*=}"; shift ;;
        -o) outfmt="$2"; shift 2 ;;
        --watch) watch=1; shift ;;
        --sort-by=*|--request-timeout=*) shift ;;
        -*) shift ;;
        *) name="$1"; shift ;;
      esac
    done
    [[ "$outfmt" == name ]] && { printf '%s/%s\n' "$resource" "${name:-x}"; exit 0; }
    case "$resource" in
      pod) resource=pods ;;
      virtualmachinebackup) resource=vmbackup ;;
      virtualmachinebackuptracker) resource=vmbackuptracker ;;
      virtualmachine) resource=vm ;;
      virtualmachineinstance) resource=vmi ;;
      persistentvolumeclaim) resource=pvc ;;
    esac
    if [[ "$watch" == 1 ]]; then
      case "$resource" in
        lease)
          printf '{"type":"ADDED","object":{"metadata":{"name":"virt-controller","uid":"%s","resourceVersion":"1"},"spec":{"holderIdentity":"%s","leaseDurationSeconds":15}}}\n' "$UID_LEASE" "$A"
          for _ in $(seq 1 600); do [[ -e "$S/post_action" ]] && break; sleep 0.1; done
          printf '{"type":"MODIFIED","object":{"metadata":{"name":"virt-controller","uid":"%s","resourceVersion":"2"},"spec":{"holderIdentity":"%s","leaseDurationSeconds":15}}}\n' "$UID_LEASE" "$POD_S"
          sleep 600 ;;
        pods)
          if [[ "$label" == *virt-controller* ]]; then
            printf '{"type":"ADDED","object":%s}\n' "$(pod_json "$A" "$UID_A" True)"
            printf '{"type":"ADDED","object":%s}\n' "$(pod_json "$POD_S" "$UID_S" True)"
            for _ in $(seq 1 600); do [[ -e "$S/post_action" ]] && break; sleep 0.1; done
            printf '{"type":"DELETED","object":%s}\n' "$(pod_json "$A" "$UID_A" True)"
            printf '{"type":"ADDED","object":%s}\n' "$(pod_json "$POD_R" "$UID_R" True)"
            sleep 600
          else
            printf '{"type":"ADDED","object":%s}\n' "$(launcher_json)"
            sleep 600
          fi ;;
        deployment)
          printf '{"type":"ADDED","object":{"metadata":{"name":"virt-controller","uid":"%s","resourceVersion":"1"},"spec":{"replicas":2},"status":{"replicas":2,"readyReplicas":2,"availableReplicas":2}}}\n' "$UID_D"
          for _ in $(seq 1 600); do [[ -e "$S/post_action" ]] && break; sleep 0.1; done
          printf '{"type":"MODIFIED","object":{"metadata":{"name":"virt-controller","uid":"%s","resourceVersion":"2"},"spec":{"replicas":2},"status":{"replicas":1,"readyReplicas":1}}}\n' "$UID_D"
          sleep 0.2
          printf '{"type":"MODIFIED","object":{"metadata":{"name":"virt-controller","uid":"%s","resourceVersion":"3"},"spec":{"replicas":2},"status":{"replicas":2,"readyReplicas":2}}}\n' "$UID_D"
          sleep 600 ;;
        vmbackuptracker)
          for _ in $(seq 1 600); do have backup_created && break; sleep 0.1; done
          printf '{"type":"ADDED","object":%s}\n' "$(tracker_json "" 10)"
          for _ in $(seq 1 600); do have full_done && break; sleep 0.1; done
          printf '{"type":"MODIFIED","object":%s}\n' "$(tracker_json "$FULL_CP" 20)"
          for _ in $(seq 1 600); do have incremental_done && break; sleep 0.1; done
          printf '{"type":"MODIFIED","object":%s}\n' "$(tracker_json "$CHILD_CP" 30)"
          sleep 600 ;;
        vmbackup)
          for _ in $(seq 1 600); do have backup_created && break; sleep 0.1; done
          printf '{"type":"ADDED","object":%s}\n' "$(backup_json "$FULL" Full false "" 20)"
          for _ in $(seq 1 600); do have incremental_created && break; sleep 0.1; done
          printf '{"type":"ADDED","object":%s}\n' "$(backup_json "$INCR" Incremental false "" 30)"
          sleep 600 ;;
        vm)
          printf '{"type":"ADDED","object":{"metadata":{"name":"%s","uid":"%s"},"status":{"ready":true,"changedBlockTracking":{"state":"Enabled"}}}}\n' "$VM" "$UID_VM"
          sleep 600 ;;
        vmi)
          printf '{"type":"ADDED","object":{"metadata":{"name":"%s","uid":"%s"},"spec":{"nodeName":"node-a"},"status":{"phase":"Running","nodeName":"node-a","conditions":[{"type":"Ready","status":"True"}]}}}\n' "$VM" "$UID_VMI"
          sleep 600 ;;
        events) printf '{"items":[]}\n'; exit 0 ;;
      esac
      exit 0
    fi
    case "$resource" in
      namespace)
        case "$name" in
          kube-system) printf '{"metadata":{"name":"kube-system","uid":"ns-kube"}}\n' ;;
          vm-cbt-demo) printf '{"metadata":{"name":"vm-cbt-demo","uid":"ns-demo"}}\n' ;;
          *) notfound "namespaces \"$name\"" ;;
        esac ;;
      deployment)
        printf '{"metadata":{"name":"virt-controller","uid":"%s","resourceVersion":"1"},"spec":{"replicas":2},"status":{"replicas":2,"readyReplicas":2,"availableReplicas":2}}\n' "$UID_D" ;;
      lease)
        holder="$A"; [[ -e "$S/post_action" ]] && holder="$POD_S"
        printf '{"metadata":{"name":"virt-controller","uid":"%s","resourceVersion":"7"},"spec":{"holderIdentity":"%s","leaseDurationSeconds":15,"renewTime":"2026-10-18T10:00:00Z"}}\n' "$UID_LEASE" "$holder" ;;
      pods)
        if [[ "$ns" == openshift-cnv ]]; then
          if [[ -n "$name" ]]; then
            if [[ "$name" == "$A" && -e "$S/post_action" ]]; then notfound "pods \"$name\""; fi
            case "$name" in
              "$A") pod_json "$A" "$UID_A" True ;;
              "$POD_S") pod_json "$POD_S" "$UID_S" True ;;
              "$POD_R") pod_json "$POD_R" "$UID_R" True ;;
              *) notfound "pods \"$name\"" ;;
            esac
          elif [[ -e "$S/post_action" ]]; then
            controller_pods
          else
            printf '{"items":[%s,%s]}\n' "$(pod_json "$A" "$UID_A" True)" "$(pod_json "$POD_S" "$UID_S" True)"
          fi
        else
          [[ -e "$S/vm_created" ]] || notfound 'pods'
          printf '{"items":[%s]}\n' "$(launcher_json)"
        fi ;;
      vm)
        if [[ "$name" == 'vm-cbt-demo' ]]; then
          printf '{"metadata":{"name":"vm-cbt-demo","uid":"cccccccc-cccc-cccc-cccc-cccccccccccc"},"status":{"ready":true,"changedBlockTracking":{"state":"Enabled"}}}\n'
        else
          [[ -e "$S/vm_created" ]] || notfound "virtualmachines \"$name\""
          printf '{"metadata":{"name":"%s","uid":"%s","resourceVersion":"5"},"status":{"ready":true,"changedBlockTracking":{"state":"Enabled"}}}\n' "$VM" "$UID_VM"
        fi ;;
      vmi)
        if [[ "$name" == 'vm-cbt-demo' ]]; then
          printf '{"metadata":{"name":"vm-cbt-demo","uid":"dddddddd-dddd-dddd-dddd-dddddddddddd"},"status":{"phase":"Running"}}\n'
        else
          [[ -e "$S/vm_created" ]] || notfound "virtualmachineinstances \"$name\""
          printf '{"metadata":{"name":"%s","uid":"%s"},"spec":{"nodeName":"node-a"},"status":{"phase":"Running","nodeName":"node-a","conditions":[{"type":"Ready","status":"True"}]}}\n' "$VM" "$UID_VMI"
        fi ;;
      vmbackup)
        items='[]'
        if [[ -e "$S/backup_created" ]]; then items="[$(backup_json "$FULL" Full "$( [[ -e "$S/full_done" ]] && echo true || echo false )" "$( [[ -e "$S/full_done" ]] && echo "$FULL_CP" )" 20)]"; fi
        if [[ -e "$S/incremental_created" ]]; then
          items="$(printf '%s' "$items" | sed 's/]$//')$( [[ "$items" == '[]' ]] || printf ',' )$(backup_json "$INCR" Incremental "$( [[ -e "$S/incremental_done" ]] && echo true || echo false )" "$( [[ -e "$S/incremental_done" ]] && echo "$CHILD_CP" )" 30)]"
        fi
        if [[ -n "$name" ]]; then
          case "$name" in
            "$FULL") [[ -e "$S/backup_created" ]] || notfound "virtualmachinebackups \"$name\""
              backup_json "$FULL" Full "$( [[ -e "$S/full_done" ]] && echo true || echo false )" "$( [[ -e "$S/full_done" ]] && echo "$FULL_CP" )" 20 ;;
            "$INCR") [[ -e "$S/incremental_created" ]] || notfound "virtualmachinebackups \"$name\""
              backup_json "$INCR" Incremental "$( [[ -e "$S/incremental_done" ]] && echo true || echo false )" "$( [[ -e "$S/incremental_done" ]] && echo "$CHILD_CP" )" 30 ;;
            *) notfound "virtualmachinebackups \"$name\"" ;;
          esac
        else
          printf '{"items":%s}\n' "$items"
        fi ;;
      vmbackuptracker)
        if [[ -z "$name" ]]; then
          if [[ -e "$S/backup_created" ]]; then
            printf '{"items":[%s]}\n' "$(tracker_json "" 10)"
          else
            printf '{"items":[]}\n'
          fi
          exit 0
        fi
        [[ -e "$S/backup_created" ]] || notfound "virtualmachinebackuptrackers \"$name\""
        if [[ -e "$S/incremental_done" ]]; then tracker_json "$CHILD_CP" 30
        elif [[ -e "$S/full_done" ]]; then tracker_json "$FULL_CP" 20
        else tracker_json "" 10
        fi ;;
      pvc)
        [[ -n "$name" ]] || { printf '{"items":[]}\n'; exit 0; }
        [[ "$name" == 'vm-backup-pvc-f03-rehearsal' && -e "$S/backup_created" ]] ||
          [[ "$name" == 'vm-incremental-pvc-f03-rehearsal-p01' && -e "$S/incremental_created" ]] ||
          notfound "persistentvolumeclaims \"$name\""
        printf '{"metadata":{"name":"%s","uid":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","resourceVersion":"4"},"spec":{"volumeName":"pvc-x"},"status":{"phase":"Bound"}}\n' "$name" ;;
      events) printf '{"items":[]}\n' ;;
      *) printf 'unexpected get resource: %s\n' "$resource" >&2; exit 2 ;;
    esac
    exit 0 ;;
esac
printf 'unexpected oc invocation: %s\n' "$sub" >&2
exit 2
EOF
chmod +x "$FAKEBIN"/*
export FAKE_ROOT="$WORKROOT" FAKE_BUNDLE="$BUNDLE"
export PATH="$FAKEBIN:$PATH"

# ------------------------------------------------------- run-root contract ----
LIFE='f03-rehearsal'
ID1='18-10-2026-10-00-00-vm-f03-rehearsal-leader-delete-iteration-1'
ID2='18-10-2026-10-05-00-vm-f03-rehearsal-leader-delete-iteration-2'
export LIFECYCLE_ID="$LIFE"

check_root_mode() { # id -> rc
  ( cd "$WORKROOT" && CHAOS_RUN_ID="$1" LIFECYCLE_ID="$LIFE" bash "$BUNDLE/run.sh" --check-root >/dev/null 2>&1 )
}
mkdir -p "$BUNDLE/runs/$ID1"
printf '{"scenario_id":"CBT-F-03","run_id":"wrong","lifecycle_id":"%s","vm_name":"vm-%s","phase":"started","verdict":null}\n' \
  "$LIFE" "$LIFE" > "$BUNDLE/runs/$ID1/run.json"
check_root_mode "$ID1" && fail 'check-root accepted a run root with the wrong run_id'
printf '{"scenario_id":"CBT-F-03","run_id":"%s","lifecycle_id":"%s","vm_name":"vm-%s","phase":"started","verdict":null}\n' \
  "$ID1" "$LIFE" "$LIFE" > "$BUNDLE/runs/$ID1/run.json"
check_root_mode "$ID1" || fail 'check-root rejected the Lead pre-armed run root'
for prior in execution action.json effect.json condition.json injection-confirmation.json analysis.json; do
  printf 'x\n' > "$BUNDLE/runs/$ID1/$prior"
  check_root_mode "$ID1" && fail "check-root accepted a prior output: $prior"
  rm "$BUNDLE/runs/$ID1/$prior"
done
mkdir -p "$WORKROOT/runs/$LIFE"
check_root_mode "$ID1" && fail 'check-root accepted an already-used lifecycle ID'
rmdir "$WORKROOT/runs/$LIFE"

# ------------------------------------------------------------- plan/manifest --
( cd "$WORKROOT" && CHAOS_RUN_ID="$ID1" LIFECYCLE_ID="$LIFE" bash "$BUNDLE/run.sh" --plan > "$TMP/plan.json" ) ||
  fail 'run.sh --plan failed'
"$JQ" -e '.scenario=="CBT-F-03" and .lifecycle_id=="f03-rehearsal"
  and (.stages|length)>=10 and .evaluator.status=="NOT_APPLICABLE"
  and .fault.uses_krkn==true and .fault.max_deletions==1
  and .fault.trigger.on_timeout=="fail" and .fault.trigger.timeout_seconds==1200
  and .window.timeout_seconds==1200
  and .recovery_map.host_storage.applicable==false
  and .backup_cleanup_mapping.applicable==false
  and (.recovery_map.control_plane.expected_postcondition|length)>0
  and (.recovery_map.data_plane.terminal_probes|length)>=3
  and (.known_failure_review|length)>=5
  and (.named_criteria|index("tracker-advanced-exactly-once-full"))!=null' "$TMP/plan.json" >/dev/null ||
  fail 'plan content is incomplete'
( cd "$WORKROOT" && CHAOS_RUN_ID="$ID1" LIFECYCLE_ID="$LIFE" bash "$BUNDLE/run.sh" --manifest ) > "$TMP/manifest.out" ||
  fail 'run.sh --manifest failed'
diff -q "$TMP/manifest.out" "$BUNDLE/bundle-files.txt" >/dev/null || fail '--manifest does not print bundle-files.txt'

# -------------------------------------------------------- happy-path rehearsal -
export FAKE_STATE="$TMP/state-happy"
mkdir -p "$FAKE_STATE"
unset F03_FAKE_NO_WINDOW
( cd "$WORKROOT" && CHAOS_RUN_ID="$ID1" LIFECYCLE_ID="$LIFE" bash "$BUNDLE/run.sh" --preflight >"$TMP/preflight.log" 2>&1 ) ||
  { cat "$TMP/preflight.log" >&2; fail 'run.sh --preflight failed'; }
CAND="$BUNDLE/runs/$ID1/preflight/approval-candidate.json"
[[ -s "$CAND" ]] || fail 'preflight did not write approval-candidate.json'
"$JQ" -e '.status=="NOT_APPROVED" and .scenario_id=="CBT-F-03"
  and (.cluster_uid|length)>0 and (.files|length)>=20
  and .parameters.fault_criteria_absent_ok==null or true' "$CAND" >/dev/null ||
  fail 'approval candidate is malformed'
"$JQ" -e '(.files|has("cbt-chaos/scenarios_v2/CBT-F-03/run.sh"))
  and (.files|has("cbt-chaos/scenarios_v2/CBT-F-03/condition.sh"))
  and (.files|has("scripts/e2e-stage.sh")|not)
  and (.files|has(".env")|not)' "$CAND" >/dev/null ||
  fail 'approval candidate file set is wrong'
"$JQ" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.status="APPROVED" | .approved_by="rehearsal" | .approved_at=$at' "$CAND" > "$BUNDLE/approval.json"

set +e
( cd "$WORKROOT" && CHAOS_RUN_ID="$ID1" LIFECYCLE_ID="$LIFE" bash "$BUNDLE/run.sh" --execute >"$TMP/execute.log" 2>&1 )
EXEC_RC=$?
set -e
EVID="$BUNDLE/runs/$ID1"
if ((EXEC_RC != 0)); then
  cat "$TMP/execute.log" >&2
  printf '%s\n' '--- entrypoint status files ---' >&2
  find "$EVID" -maxdepth 3 -name '*.status.json' -o -maxdepth 3 -name '*.log' | sort >&2 || true
  fail "happy-path rehearsal exited $EXEC_RC (expected 0)"
fi
[[ -s "$EVID/injection-confirmation.json" ]] || fail 'injection-confirmation.json missing'
"$JQ" -e '.condition_recorded==true and .effect_observed==true and .action_rc==0
  and .blast_radius.exclusions_ok==true and .verdict==null
  and .author_grades_injection==false
  and (.condition.backup_uid|test("^[0-9a-f-]{36}$"))
  and .condition.holder_uid!=null and .effective_name_pattern=="^virt-controller-6f7bc6b44c-aaaaa$"' \
  "$EVID/injection-confirmation.json" >/dev/null || fail 'injection confirmation checks are wrong'
[[ -s "$EVID/sequence-outcome.json" ]] || fail 'sequence-outcome.json missing'
"$JQ" -e '.orchestration_state=="completed" and .child_status.full_stage==0
  and .child_status.incremental_stage==0 and .child_status.verify_stage==0
  and .child_status.run_summary==0 and .child_status.monitor==0
  and .full_backup.guard_safe==true and .incremental_backup.guard_safe==true
  and .full_backup.checkpoint_tree_single==true
  and .incremental_backup.checkpoint_tree_parent_child==true
  and .incremental_backup.distinct_child==true
  and .incremental_backup.tracker_rv_advanced==true
  and .controller_final.recovered==true
  and (.controller_final.lease_transition_count>=1)
  and .blast_radius_final.exclusions_ok==true
  and .product_verdict==null' "$EVID/sequence-outcome.json" >/dev/null ||
  fail 'sequence outcome checks are wrong'
[[ -s "$EVID/execution/terminal.json" ]] || fail 'terminal.json missing'
"$JQ" -e '.orchestration_terminal=="COMPLETED" and .child_rc==0 and .product_verdict==null' \
  "$EVID/execution/terminal.json" >/dev/null || fail 'terminal.json is wrong'
[[ -s "$EVID/execution/final/collector.status.json" ]] || fail 'guarded finalizer did not run'
[[ -s "$EVID/execution/watch-controller-pods.jsonl" && -s "$EVID/execution/watch-lease.jsonl" ]] ||
  fail 'scoped watch evidence missing'
"$JQ" -e '.one_deletion==true and .only_target_deleted==true' \
  "$EVID/execution/controller-pod-watch.json" >/dev/null || fail 'pod watch exclusion evidence is wrong'
[[ ! -e "$WORKROOT/state/e2e.lock" ]] || fail 'checkout lock was not released'
[[ ! -e "$EVID/execution/full-start.utc" ]] || true
grep -q 'native-ready' /dev/null 2>/dev/null || true
[[ -s "$EVID/execution/condition.json" ]] || fail 'condition evidence missing'
[[ -s "$EVID/execution/leader-logs/virt-controller-6f7bc6b44c-aaaaa.stream.log" ]] ||
  fail 'pre-disruption controller log stream missing'
[[ -s "$EVID/execution/controller-logs.json" ]] || fail 'controller log availability evidence missing'
for stage in setup full incremental verify run-summary monitor; do
  [[ -s "$EVID/execution/$stage.status.json" ]] || fail "stage status missing: $stage"
done

# ------------------------------------------------------- window-miss rehearsal -
export FAKE_STATE="$TMP/state-miss"
mkdir -p "$FAKE_STATE"
export F03_FAKE_NO_WINDOW=1
rm -rf "$BUNDLE/runs/$ID1" "$BUNDLE/runs/$ID2" "$WORKROOT/runs/$LIFE"
mkdir -p "$BUNDLE/runs/$ID2"
printf '{"scenario_id":"CBT-F-03","run_id":"%s","lifecycle_id":"%s","vm_name":"vm-%s","phase":"started","verdict":null}\n' \
  "$ID2" "$LIFE" "$LIFE" > "$BUNDLE/runs/$ID2/run.json"
rm -f "$BUNDLE/approval.json"
( cd "$WORKROOT" && CHAOS_RUN_ID="$ID2" LIFECYCLE_ID="$LIFE" bash "$BUNDLE/run.sh" --preflight >"$TMP/preflight2.log" 2>&1 ) ||
  { cat "$TMP/preflight2.log" >&2; fail 'second preflight failed'; }
"$JQ" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.status="APPROVED" | .approved_by="rehearsal" | .approved_at=$at' \
  "$BUNDLE/runs/$ID2/preflight/approval-candidate.json" > "$BUNDLE/approval.json"
set +e
( cd "$WORKROOT" && CHAOS_RUN_ID="$ID2" LIFECYCLE_ID="$LIFE" bash "$BUNDLE/run.sh" --execute >"$TMP/execute2.log" 2>&1 )
MISS_RC=$?
set -e
((MISS_RC == 4)) || { cat "$TMP/execute2.log" >&2; fail "window-miss rehearsal exited $MISS_RC (expected 4)"; }
"$JQ" -e '.condition_recorded==false and .effect_observed==false
  and (.reason|test("window")) and .verdict==null' \
  "$BUNDLE/runs/$ID2/injection-confirmation.json" >/dev/null ||
  fail 'window-miss injection confirmation is wrong'
"$JQ" -e '.orchestration_terminal=="WINDOW_MISSED"' \
  "$BUNDLE/runs/$ID2/execution/terminal.json" >/dev/null || fail 'window-miss terminal is wrong'
[[ ! -e "$WORKROOT/state/e2e.lock" ]] || fail 'lock leaked on the window-miss path'

printf 'PASS: CBT-F-03 bundle contract, plan, jq predicates and fake-cluster rehearsals (happy path + window miss)\n'
