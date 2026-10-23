# CBT-EXP-08V1 scenario projections, loaded with
# `jq -L <bundle> 'include "checks"; ...'` (or `jq -n -L <bundle> ...`).
#
# These helpers describe machine-readable state for the criteria in
# jira-issue.md's "Expected behaviour (contract) and pass/fail criteria" table.
# They never encode a product verdict: the independent Analyst grades the raw
# evidence. Every helper is total over a missing/null field so a degraded read
# projects a value instead of aborting a capture.

# --- VirtualMachineBackup / tracker status -----------------------------------
def done_status: [.status.conditions[]? | select(.type == "Done") | .status] | last // "False";
def done_reason: [.status.conditions[]? | select(.type == "Done") | .reason] | last // "";
def terminal: any(.status.conditions[]?; .type == "Done" and .status == "True");
def progressing: any(.status.conditions[]?; .type == "Progressing" and .status == "True");
def initializing: any(.status.conditions[]?; .type == "Initializing" and .status == "True");
def deleting: .metadata.deletionTimestamp != null;
def resource_version: .metadata.resourceVersion // null;
# Condition reasons are the primary evidence surface for a tracker-absence
# requeue or a terminal failure, so they are projected verbatim, never
# normalized or prefix-matched here.
def progress_reason: [.status.conditions[]? | select(.type == "Progressing") | .reason] | last // "";
def initializing_reason: [.status.conditions[]? | select(.type == "Initializing") | .reason] | last // "";
# The backup must be this lifecycle's own object, sourced from this run's
# tracker and pointing at this run's destination PVC; a name match alone is not
# proof of ownership.
def run_scoped($life; $tracker; $pvc):
  .metadata.labels["virt-cbt-lab/run-id"] == $life
  and (.spec.source.kind // "") == "VirtualMachineBackupTracker"
  and (.spec.source.name // "") == $tracker
  and (.spec.pvcName // "") == $pvc;

# --- guest copy signal (read-only QMP through the existing launcher) ---------
# Active copy requires a running backup job with a nonzero offset below its
# declared length; a Progressing condition alone is not a copy signal.
def active_jobs: [.return[]? | select(.type == "backup" and .status == "running"
  and (.offset | type == "number") and (.len | type == "number")
  and .offset > 0 and .offset < .len)] | length > 0;

# --- pods / VMI --------------------------------------------------------------
def ready: .metadata.deletionTimestamp == null and .status.phase == "Running"
  and any(.status.conditions[]?; .type == "Ready" and .status == "True");
def owned_by($kind; $uid): any(.metadata.ownerReferences[]?; .kind == $kind and .uid == $uid);
def paused_condition: [.status.conditions[]? | select(.type == "Paused")] | last // null;
# Destination-volume attachment surface of the running VMI. The hotplugged
# backup target appears as a volumeStatus entry whose hotplugVolume is set (and,
# for filesystem-mode PVCs, whose persistentVolumeClaimInfo names the claim).
# API-level absence is not host-level release.
def volume_status: [.status.volumeStatus[]? | {name, target, phase:(.phase // null),
  claim:(.persistentVolumeClaimInfo.claimName // null),
  hotplug:(.hotplugVolume != null),
  attach_pod:(.hotplugVolume.attachPodName // null)}];
def hotplug_attachment($pvc): [.status.volumeStatus[]?
  | select((.persistentVolumeClaimInfo.claimName // "") == $pvc)
  | {name, target, hotplug:(.hotplugVolume != null),
     attach_pod:(.hotplugVolume.attachPodName // null)}];
def any_hotplug: [.status.volumeStatus[]? | select(.hotplugVolume != null)
  | {name, target, claim:(.persistentVolumeClaimInfo.claimName // null),
     attach_pod:(.hotplugVolume.attachPodName // null)}];

# --- tracker ----------------------------------------------------------------
def tracker_checkpoint: .status.latestCheckpoint.name // "";
def tracker_unset: ((.status.latestCheckpoint.name // "") == "");
# The fault target must be the run's VM-backed tracker, not merely a name match.
def tracker_source_vm($vm): (.spec.source.kind // "") == "VirtualMachine"
  and (.spec.source.name // "") == $vm;

# --- exclusions / blast radius ----------------------------------------------
# Names owned by this attempt are excluded when comparing the pre/post namespace
# inventory: everything else must keep the same name->UID mapping.
def others($excluded): [.items[]? | .metadata.name as $n
  | select(($excluded | index($n)) == null)
  | {name:.metadata.name, uid:.metadata.uid, deleting:(.metadata.deletionTimestamp != null)}]
  | sort_by(.name);

# --- environment -------------------------------------------------------------
def pool_headroom($pool; $required): [.pools[]? | select(.name == $pool)] as $p
  | ($p | length) == 1 and ($p[0].stats.max_avail | type == "number")
  and $p[0].stats.max_avail >= $required;
def no_storage_quota: [.items[]? | (.status.hard // {}) | to_entries[]
  | select(.key | test("storage|persistentvolumeclaims"))] | length == 0;
