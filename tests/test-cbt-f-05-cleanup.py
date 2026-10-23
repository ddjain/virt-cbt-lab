#!/usr/bin/env python3
"""Offline consumer regressions: real product guard and cleanup projections.

No cluster commands, mocked command output, source-text assertions, or elapsed waits.
"""
import copy
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "cbt-chaos/scenarios_v2/CBT-F-05"
spec = importlib.util.spec_from_file_location("f05_cleanup", BUNDLE / "cleanup-observer.py")
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class ProductGuard(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = pathlib.Path(self.temporary.name)
        self.volumes = [{"volumeName": "rootdisk", "diskTarget": "vda"}]
        self.backup = {"metadata": {"uid": "backup-uid"}, "spec": {"pvcName": "new-pvc"}, "status": {
            "type": "Full", "checkpointName": "full-checkpoint", "includedVolumes": self.volumes,
            "conditions": [{"type": "Done", "status": "True", "reason": "Successfully completed VirtualMachineBackup"}]}}
        self.tracker = {"metadata": {"uid": "tracker-uid"}, "status": {"latestCheckpoint": {
            "name": "full-checkpoint", "volumes": self.volumes}}}
        self.prior = {"metadata": {"uid": "tracker-uid"}}
        self.claim = {"metadata": {"uid": "new-pvc-uid", "name": "new-pvc"}}
        self.names = "full-checkpoint\n\n"
        self.initial = copy.deepcopy(self.backup)
        self.preserved_claim = copy.deepcopy(self.claim)

    def guard(self, full_rc=0):
        values = {"original-terminal.json": self.backup, "tracker-before-followup.json": self.tracker,
                  "polls/one/tracker-before.json": self.prior, "condition.json": {"raw": "polls/one"},
                  "original-backup-initial.json": self.initial, "original-pvc.json": self.claim,
                  "original-pvc-preserved.json": self.preserved_claim}
        for name, value in values.items():
            path = self.work / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(value))
        (self.work / "checkpoint-names.log").write_text(self.names)
        result = subprocess.run(["bash", str(BUNDLE / "product-guard.sh"), str(self.work), str(full_rc)],
                                capture_output=True, text=True, check=True, timeout=15)
        return json.loads(result.stdout)

    def test_success_wording_and_benign_failed_warning_do_not_block_safe_chain(self):
        for reason in ["Successfully completed VirtualMachineBackup", "Completed VirtualMachineBackup, warning: Failed freezing guest filesystem: timeout"]:
            with self.subTest(reason=reason):
                self.backup["status"]["conditions"][0]["reason"] = reason
                result = self.guard()
                self.assertEqual(result["branch"], "success")
                self.assertTrue(result["followup_safe"])
                self.assertFalse(result["terminal_reason_is_failure"])
        result = self.guard(full_rc=1)
        self.assertTrue(result["followup_safe"])
        self.assertEqual(result["full_command_rc"], 1)

    def test_failure_reason_selects_distinct_recovery_despite_done_true(self):
        self.backup["status"]["conditions"][0]["reason"] = "Backup has failed: VMI backup status was lost"
        self.backup["status"]["checkpointName"] = ""
        self.tracker["status"] = {}
        self.names = "\n"
        result = self.guard(full_rc=1)
        self.assertEqual(result["branch"], "failure")
        self.assertTrue(result["followup_safe"])
        self.assertEqual(result["full_command_rc"], 1)
        self.tracker["status"] = {"latestCheckpoint": {"name": "", "volumes": self.volumes}}
        result = self.guard(full_rc=1)
        self.assertFalse(result["followup_safe"])
        self.assertFalse(result["guard_operands"]["failed_tracker_volumes_unchanged"])
        # A failed copy must not silently adopt even an otherwise consistent checkpoint.
        self.tracker["status"] = {"latestCheckpoint": {"name": "full-checkpoint", "volumes": self.volumes}}
        self.names = "full-checkpoint\n"
        result = self.guard(full_rc=1)
        self.assertFalse(result["followup_safe"])
        self.assertFalse(result["guard_operands"]["failed_tracker_unchanged"])

    def test_reason_only_error_does_not_masquerade_as_tracker_mismatch(self):
        self.backup["status"]["conditions"][0]["reason"] = ""
        result = self.guard()
        self.assertFalse(result["followup_safe"])
        self.assertFalse(result["guard_operands"]["reason_present"])
        self.assertTrue(result["tracker_checkpoint_consistent"])
        self.backup["status"]["conditions"][0]["reason"] = "Successfully completed VirtualMachineBackup"
        self.tracker["status"]["latestCheckpoint"]["name"] = "other-checkpoint"
        result = self.guard()
        self.assertFalse(result["followup_safe"])
        self.assertFalse(result["guard_operands"]["tracker_matches_checkpoint"])
        self.assertTrue(result["guard_operands"]["reason_present"])

    def test_wrong_volume_and_nonterminal_success_never_select_restore(self):
        self.tracker["status"]["latestCheckpoint"]["volumes"] = [{"volumeName": "rootdisk", "diskTarget": "vdb"}]
        result = self.guard()
        self.assertFalse(result["followup_safe"])
        self.assertFalse(result["guard_operands"]["tracker_volumes_match"])
        self.tracker["status"]["latestCheckpoint"]["volumes"] = self.volumes
        self.backup["status"]["conditions"][0]["status"] = "False"
        self.assertFalse(self.guard()["followup_safe"])

    def test_destination_uid_change_is_not_a_safe_preserved_artifact(self):
        self.preserved_claim["metadata"]["uid"] = "replacement-pvc-uid"
        result = self.guard()
        self.assertFalse(result["followup_safe"])
        self.assertFalse(result["guard_operands"]["pvc_identity"])
        self.assertTrue(result["tracker_checkpoint_consistent"])


class CleanupObservations(unittest.TestCase):
    def setUp(self):
        self.target = "/pods/original-uid/volumes/kubernetes.io~empty-dir/hotplug-disks/new-full-backup-target-pvc"
        self.identity = {"mount_path": self.target, "storage": {"image_name": "csi-vol-exact"}}
        self.tokens = {"new-pvc", "new-full-backup-target-pvc"}

    def test_exact_pv_handle_and_pvc_exclude_prefix_collisions_and_old_destinations(self):
        attachments = {"items": [
            {"metadata": {"name": "old"}, "spec": {"source": {"persistentVolumeName": "pv-old"}}, "status": {"attached": True}},
            {"metadata": {"name": "prefix"}, "spec": {"source": {"persistentVolumeName": "pv-new-extra"}}, "status": {"attached": True}},
            {"metadata": {"name": "new"}, "spec": {"source": {"persistentVolumeName": "pv-new"}}, "status": {"attached": False}}]}
        self.assertEqual([v["metadata"]["name"] for v in cleanup.project_attachments(attachments, "pv-new")], ["new"])
        node = {"metadata": {"uid": "node"}, "status": {"conditions": [{"type": "Ready"}],
                "volumesInUse": ["driver^exact-handle-old", "driver^exact-handle"], "volumesAttached": []}}
        self.assertEqual(cleanup.project_node(node, "exact-handle")["volumesInUse"], ["driver^exact-handle"])
        pods = {"items": [{"metadata": {"name": name}, "spec": {"volumes": [{"persistentVolumeClaim": {"claimName": pvc}}]}}
                          for name, pvc in [("previous", "old-pvc"), ("prefix", "new-pvc-extra"), ("new", "new-pvc")]]}
        self.assertEqual([v["metadata"]["name"] for v in cleanup.project_pods(pods, self.tokens)], ["new"])

    def test_exact_mount_and_dynamic_image_identity_do_not_assume_rbd_number(self):
        host = {"mountinfo_exact_matches": 1, "mount": {"filesystems": [{"target": self.target, "source": "/dev/rbd29", "maj:min": "252:464"}]},
                "image_devices": [{"device": "/dev/rbd29", "image_name": "csi-vol-exact", "major_minor": "252:464"}]}
        self.assertEqual(cleanup.mount_state(host, self.identity), "PRESENT")
        wrong = copy.deepcopy(host)
        wrong["mount"]["filesystems"][0]["target"] = self.target.replace("original-uid", "previous-uid")
        self.assertEqual(cleanup.mount_state(wrong, self.identity), "UNKNOWN")
        wrong = copy.deepcopy(host)
        wrong["image_devices"][0]["image_name"] = "csi-vol-exact-old"
        self.assertEqual(cleanup.mount_state(wrong, self.identity), "UNKNOWN")
        wrong = copy.deepcopy(host)
        wrong["mount"]["filesystems"][0]["maj:min"] = "252:64"
        self.assertEqual(cleanup.mount_state(wrong, self.identity), "UNKNOWN")

    def test_api_detach_cannot_hide_host_residual_or_unreadable_probe(self):
        host = {"mountinfo_exact_matches": 0, "mount": {"filesystems": []}, "image_devices": []}
        self.assertEqual(cleanup.mount_state(host, self.identity), "ABSENT")
        states = {"vmi": "ABSENT", "guest": "ABSENT", "pod_references": "ABSENT", "host": cleanup.mount_state(None, self.identity)}
        self.assertEqual(cleanup.summarize(states), "UNKNOWN")
        states["host"] = "PRESENT"
        self.assertEqual(cleanup.summarize(states), "RESIDUAL")
        states["host"] = "ABSENT"
        self.assertEqual(cleanup.summarize(states), "CLEAR")
        with self.assertRaises(KeyError):
            cleanup.project_node({}, "handle")

    def test_followup_requires_a_readable_bound_sample_not_early_api_cleanup(self):
        last = {"state": "CLEAR", "sample_started_since_terminal_seconds": 299}
        self.assertFalse(cleanup.cleanup_safe(last, 305, True))
        last["sample_started_since_terminal_seconds"] = 300
        self.assertTrue(cleanup.cleanup_safe(last, 305, True))
        self.assertFalse(cleanup.cleanup_safe(last, 305, False))
        for state in ("UNKNOWN", "RESIDUAL"):
            last["state"] = state
            self.assertFalse(cleanup.cleanup_safe(last, 305, True))

    def test_vmi_detach_is_independent_of_actual_guest_disk_state(self):
        vmi = {"metadata": {"uid": "vmi"}, "spec": {"volumes": [], "utilityVolumes": []},
               "status": {"phase": "Running", "nodeName": "node", "volumeStatus": []}}
        self.assertEqual(cleanup.project_vmi(vmi, self.tokens)["utilityVolumes"], [])
        baseline = {"disk_targets": ["sda", "vda"], "qdevs": ["cloudinit", "root"]}
        disks = "Type Device Target Source\n-----\nfile disk vda /root.qcow2\nfile disk sda /cloudinit.iso\n"
        blocks = {"return": [{"qdev": "root"}, {"qdev": "cloudinit"}]}
        named = {"return": [{"image": {"filename": "/root.qcow2"}}]}
        self.assertEqual(cleanup.guest_state(blocks, named, disks, baseline, self.tokens), "ABSENT")
        named["return"].append({"image": {"filename": "/hotplug/new-full-backup-target-pvc/disk.img"}})
        self.assertEqual(cleanup.guest_state(blocks, named, disks, baseline, self.tokens), "PRESENT")
        self.assertEqual(cleanup.guest_state(blocks, None, disks, baseline, self.tokens), "UNKNOWN")


if __name__ == "__main__":
    unittest.main()
