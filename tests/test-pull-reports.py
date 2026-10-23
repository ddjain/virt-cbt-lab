#!/usr/bin/env python3
"""Offline report-pull regressions using real files, hashes and local rsync.

The SSH adapter only replaces transport: it executes the helper's actual remote
Python program and rsync server. Nothing connects to a host or cluster.
"""
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/pull-reports.py"
spec = importlib.util.spec_from_file_location("pull_reports", HELPER)
pull = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = pull
spec.loader.exec_module(pull)
RSYNC = shutil.which("rsync")
SCENARIO = "CBT-A-01"
OTHER = "CBT-B-02"
BASE = f"cbt-chaos/scenarios_v2/{SCENARIO}"
PROPOSAL = "cbt-chaos/scenarios_v2/CBT-P-03/jira-issue.md"


def put(root, relative, content):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def put_json(root, relative, value):
    return put(root, relative, json.dumps(value))


def digest(content):
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


def regular_contents(root):
    return {str(path.relative_to(root)): path.read_bytes()
            for path in root.rglob("*") if path.is_file() and not path.is_symlink()}


class ReportFixture(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="report pull tests ")
        self.addCleanup(temporary.cleanup)
        self.work = pathlib.Path(temporary.name)
        self.remote = self.work / "remote checkout with spaces"
        self.local = self.work / "local checkout with spaces"
        self.remote.mkdir()
        self.local.mkdir()

    def fixture(self):
        files = {
            f"{BASE}/runs/attempt one/run.json": json.dumps({
                "lifecycle_id": "life-one", "lifecycle_ids": ["life-two", "planned-only"],
                "proposed_scenarios": [PROPOSAL]}),
            f"{BASE}/runs/attempt one/analysis.json": json.dumps({
                "lifecycle_ids": ["life-one"], "proposed_scenarios": [PROPOSAL]}),
            f"{BASE}/runs/attempt one/run-report.md": "primary report\n",
            f"{BASE}/bugs/reported defect.md": "observed defect\n",
            f"{BASE}/approval.json": '{"approved": false}\n',
            f"{BASE}/consolidated-report.md": "consolidated findings\n",
            "runs/life-one/report.md": "linked lifecycle one\n",
            "runs/life-two/report.md": "linked lifecycle two\n",
            f"artifacts/{SCENARIO}/diagnosis with spaces.log": "diagnostic output\n",
            PROPOSAL: "# Linked proposal\n\n**PROPOSED — UNEXECUTED — PENDING HUMAN REVIEW**\n",
        }
        for name, content in files.items():
            put(self.remote, name, content)
        others = {
            "runs/index.md": "aggregate lifecycle report\n",
            "runs/unrelated/report.md": "unrelated lifecycle\n",
            f"cbt-chaos/scenarios_v2/{OTHER}/runs/attempt/run.json": "{}",
            f"cbt-chaos/scenarios_v2/{OTHER}/runs/attempt/analysis.json": "{}",
            f"cbt-chaos/scenarios_v2/{OTHER}/bugs/other.md": "other defect\n",
            f"artifacts/{OTHER}/diagnosis.log": "other diagnostics\n",
        }
        for name, content in others.items():
            put(self.remote, name, content)
        # These are source, not report outputs, even when adjacent to reports.
        for name in (f"{BASE}/jira-issue.md", f"{BASE}/scenario.yaml",
                     f"{BASE}/driver.sh", f"{BASE}/agents/lead.md",
                     "cbt-chaos/scenarios_v2/CBT-P-03/driver.sh"):
            put(self.remote, name, "remote source must stay remote\n")
        return files, others


class InventoryTests(ReportFixture):
    def test_scoped_selection_contains_exact_linked_outputs_not_unrelated_runs(self):
        files, _ = self.fixture()
        before = regular_contents(self.remote)
        result = pull.inventory(self.remote, SCENARIO)
        self.assertEqual(result["files"], {name: digest(content) for name, content in files.items()})
        self.assertEqual(set(result["missing_lifecycles"]), {"planned-only"})
        self.assertIn(SCENARIO, result["scenarios"])
        self.assertFalse((self.remote / "runs/planned-only").exists())
        self.assertEqual(regular_contents(self.remote), before)

    def test_full_selection_retains_all_root_runs_and_all_scenario_outputs(self):
        files, others = self.fixture()
        result = pull.inventory(self.remote)
        self.assertEqual(result["files"], {
            name: digest(content) for name, content in {**files, **others}.items()})
        self.assertEqual(set(result["missing_lifecycles"]), {"planned-only"})

    def test_analysis_metadata_can_supply_lifecycle_and_proposal_links(self):
        self.fixture()
        put_json(self.remote, f"{BASE}/runs/attempt one/run.json", {})
        put_json(self.remote, f"{BASE}/runs/attempt one/analysis.json", {
            "lifecycle_id": "life-two", "proposed_scenarios": [PROPOSAL]})
        selected = pull.inventory(self.remote, SCENARIO)["files"]
        self.assertIn("runs/life-two/report.md", selected)
        self.assertIn(PROPOSAL, selected)
        self.assertNotIn("runs/life-one/report.md", selected)

    def test_malformed_and_wrong_typed_metadata_fail(self):
        self.fixture()
        metadata = f"{BASE}/runs/attempt one/run.json"
        cases = ["{broken", "[]", "null", json.dumps({"lifecycle_ids": "life-one"}),
                 json.dumps({"lifecycle_ids": [7]}), json.dumps({"lifecycle_id": ["life-one"]}),
                 json.dumps({"proposed_scenarios": PROPOSAL}),
                 json.dumps({"proposed_scenarios": [False]})]
        for value in cases:
            with self.subTest(metadata=value):
                put(self.remote, metadata, value)
                with self.assertRaises(pull.PullError):
                    pull.inventory(self.remote, SCENARIO)

    def test_standalone_proposed_unexecuted_docs_are_full_only_outputs(self):
        self.fixture()
        standalone = "cbt-chaos/scenarios_v2/CBT-P-04/jira-issue.md"
        content = "# New specialist proposal\n\n**PROPOSED — UNEXECUTED — PENDING HUMAN REVIEW**\n"
        put(self.remote, standalone, content)
        put(self.remote, "cbt-chaos/scenarios_v2/CBT-P-04/driver.sh", "not a report")
        proposed_only = "cbt-chaos/scenarios_v2/CBT-P-05/jira-issue.md"
        put(self.remote, proposed_only, "# PROPOSED\nAlready executed.\n")
        self.assertEqual(pull.inventory(self.remote)["files"][standalone], digest(content))
        self.assertNotIn(standalone, pull.inventory(self.remote, SCENARIO)["files"])
        self.assertNotIn(proposed_only, pull.inventory(self.remote)["files"])
        self.assertNotIn("cbt-chaos/scenarios_v2/CBT-P-04/driver.sh",
                         pull.inventory(self.remote)["files"])

    def test_partial_attempt_accepts_whichever_metadata_exists(self):
        self.fixture()
        run_path = self.remote / BASE / "runs/attempt one/run.json"
        run_path.unlink()
        result = pull.inventory(self.remote, SCENARIO)
        self.assertIn("runs/life-one/report.md", result["files"])
        self.assertIn(PROPOSAL, result["files"])
        self.assertNotIn("runs/life-two/report.md", result["files"])
        (self.remote / BASE / "runs/attempt one/analysis.json").unlink()
        result = pull.inventory(self.remote, SCENARIO)
        self.assertIn(f"{BASE}/runs/attempt one/run-report.md", result["files"])
        self.assertFalse(any(name.startswith("runs/") for name in result["files"]))
        self.assertEqual(result["missing_lifecycles"], [])
        put_json(self.remote, f"{BASE}/runs/attempt one/run.json", {"lifecycle_id": "life-two"})
        result = pull.inventory(self.remote, SCENARIO)
        self.assertIn("runs/life-two/report.md", result["files"])
        self.assertNotIn("runs/life-one/report.md", result["files"])


    def test_malformed_analysis_is_not_hidden_by_valid_run_metadata(self):
        self.fixture()
        put(self.remote, f"{BASE}/runs/attempt one/analysis.json", "not json")
        with self.assertRaises(pull.PullError):
            pull.inventory(self.remote, SCENARIO)

    def test_unsafe_lifecycle_and_proposal_references_fail(self):
        self.fixture()
        metadata = f"{BASE}/runs/attempt one/run.json"
        cases = [{"lifecycle_id": name} for name in ("../outside", "/absolute", "a/b", ".", "..")]
        cases += [{"proposed_scenarios": [name]} for name in (
            "../jira-issue.md", "/tmp/jira-issue.md", f"{BASE}/driver.sh",
            "cbt-chaos/scenarios_v2/../jira-issue.md", "runs/life-one/jira-issue.md")]
        for value in cases:
            with self.subTest(metadata=value):
                put_json(self.remote, metadata, value)
                with self.assertRaises(pull.PullError):
                    pull.inventory(self.remote, SCENARIO)

    def test_missing_claimed_created_proposal_fails(self):
        self.fixture()
        (self.remote / PROPOSAL).unlink()
        with self.assertRaises(pull.PullError):
            pull.inventory(self.remote, SCENARIO)

    def test_invalid_scenario_components_fail(self):
        self.fixture()
        for value in ("..", ".", "../CBT-A-01", "/tmp/scenario", "a/b"):
            with self.subTest(scenario=value), self.assertRaises(pull.PullError):
                pull.inventory(self.remote, value)

    def test_credentials_disks_symlinks_and_special_files_are_not_payload(self):
        files, _ = self.fixture()
        excluded = [".env", ".env.production", "kubeconfig", "admin.kubeconfig",
                    ".kube/config", ".ssh/config", "keys/signing", "id_rsa",
                    "private.pem", "private.key", "windows-password.txt",
                    "disk.qcow2", "disk.img", "disk.raw"]
        for name in excluded:
            put(self.remote, f"{BASE}/runs/attempt one/{name}", "must not transfer")
        outside = put(self.work, "outside/secret.md", "outside secret")
        (self.remote / BASE / "bugs/link.md").symlink_to(outside)
        (self.remote / BASE / "runs/linked-directory").symlink_to(outside.parent, target_is_directory=True)
        os.mkfifo(self.remote / BASE / "runs/attempt one/special.pipe")
        selected = pull.inventory(self.remote, SCENARIO)
        self.assertEqual(set(selected["files"]), set(files))
        self.assertGreater(selected["excluded"], 0)

    def test_link_to_ordinary_source_jira_is_not_a_proposal(self):
        self.fixture()
        put(self.remote, PROPOSAL, "# Ordinary executed scenario source\n"
            "This source mentions a proposed, unexecuted follow-up but is not a draft.\n")
        with self.assertRaises(pull.PullError):
            pull.inventory(self.remote, SCENARIO)



class ValidationTests(ReportFixture):
    def test_sha_comparison_detects_same_size_same_mtime_difference(self):
        name = "runs/life/report.md"
        source = put(self.remote, name, "remote")
        local = put(self.local, name, "locals")
        timestamp = 1_700_000_000_000_000_000
        os.utime(source, ns=(timestamp, timestamp))
        os.utime(local, ns=(timestamp, timestamp))
        files = {name: digest("remote")}
        self.assertEqual(pull.sha256_file(source), files[name])
        self.assertEqual(pull.changed_files(self.local, files), [name])
        with self.assertRaises(pull.PullError):
            pull.verify_files(self.local, files)
        local.write_bytes(source.read_bytes())
        self.assertEqual(pull.changed_files(self.local, files), [])
        pull.verify_files(self.local, files)

    def test_missing_selected_file_is_changed_and_fails_verification(self):
        files = {"runs/life/missing.md": digest("missing")}
        self.assertEqual(pull.changed_files(self.local, files), list(files))
        with self.assertRaises(pull.PullError):
            pull.verify_files(self.local, files)

    def test_destination_rejects_traversal_absolute_and_nonreport_paths(self):
        for name in ("../escape", "/tmp/escape", "runs/../../escape", "runs/./life/file",
                     f"{BASE}/driver.sh", "README.md"):
            with self.subTest(path=name), self.assertRaises(pull.PullError):
                pull.safe_destination(self.local, name)
        name = "runs/life/report with spaces.md"
        self.assertEqual(pull.safe_destination(self.local, name), self.local / name)

    def test_destination_symlink_ancestors_and_leaf_are_rejected(self):
        outside = self.work / "outside"
        outside.mkdir()
        (self.local / "runs").symlink_to(outside, target_is_directory=True)
        files = {"runs/life/report.md": digest("report")}
        for operation in (pull.changed_files, pull.verify_files):
            with self.subTest(operation=operation.__name__), self.assertRaises(pull.PullError):
                operation(self.local, files)
        with self.assertRaises(pull.PullError):
            pull.safe_destination(self.local, next(iter(files)))
        self.assertEqual(list(outside.iterdir()), [])
        (self.local / "runs").unlink()
        target = put(outside, "target.md", "report")
        leaf = self.local / "runs/life/report.md"
        leaf.parent.mkdir(parents=True)
        leaf.symlink_to(target)
        for operation in (pull.changed_files, pull.verify_files):
            with self.subTest(operation=operation.__name__), self.assertRaises(pull.PullError):
                operation(self.local, files)

    def test_file_directory_collisions_fail_before_transfer(self):
        put(self.local, "runs/life", "not a directory")
        with self.assertRaises(pull.PullError):
            pull.changed_files(self.local, {"runs/life/report.md": digest("report")})
        (self.local / "runs/life").unlink()
        (self.local / "runs/life/report.md").mkdir(parents=True)
        with self.assertRaises(pull.PullError):
            pull.changed_files(self.local, {"runs/life/report.md": digest("report")})


@unittest.skipUnless(RSYNC, "real rsync is required only for transport tests")
class TransferTests(ReportFixture):
    def setUp(self):
        super().setUp()
        self.bin = self.work / "transport bin"
        self.bin.mkdir()
        self.transport_log = self.work / "transport.jsonl"
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ.get("PATH", ""),
                        REPORT_TEST_RSYNC=RSYNC, REPORT_TEST_LOG=str(self.transport_log),
                        REPORT_TEST_LOCAL=str(self.local), REPORT_TEST_REMOTE=str(self.remote))
        for name in ("SCENARIO", "RSYNC_RSH", "RSYNC_PROXY",
                     "REPORT_TEST_AFTER_COPY", "REPORT_TEST_TARGET"):
            self.env.pop(name, None)
        ssh = put(self.bin, "ssh", "#!" + sys.executable + "\n" + textwrap.dedent('''\
            import json, os, subprocess, sys
            args = sys.argv[1:]
            host = args.index("report-test-host")
            command = " ".join(args[host + 1:])
            with open(os.environ["REPORT_TEST_LOG"], "a") as stream:
                stream.write(json.dumps({"transport": "ssh", "command": command}) + "\\n")
            sys.exit(subprocess.call(["/bin/sh", "-c", command]))
            '''))
        ssh.chmod(0o755)
        rsync = put(self.bin, "rsync", "#!" + sys.executable + "\n" + textwrap.dedent('''\
            import json, os, pathlib, subprocess, sys
            args = sys.argv[1:]
            if "--server" in args:
                os.execv(os.environ["REPORT_TEST_RSYNC"], [os.environ["REPORT_TEST_RSYNC"], *args])
            with open(os.environ["REPORT_TEST_LOG"], "a") as stream:
                stream.write(json.dumps({"transport": "rsync", "args": args}) + "\\n")
            status = subprocess.call([os.environ["REPORT_TEST_RSYNC"], *args])
            if status == 0:
                action = os.environ.get("REPORT_TEST_AFTER_COPY", "")
                relative = os.environ.get("REPORT_TEST_TARGET", "")
                if action in ("corrupt", "change-source"):
                    root = "REPORT_TEST_LOCAL" if action == "corrupt" else "REPORT_TEST_REMOTE"
                    path = pathlib.Path(os.environ[root]) / relative
                    path.write_text("changed after real transfer\\n", encoding="utf-8")
                elif action == "add-source":
                    path = pathlib.Path(os.environ["REPORT_TEST_REMOTE"]) / relative
                    path.write_text("new report after real transfer\\n", encoding="utf-8")
            sys.exit(status)
            '''))
        rsync.chmod(0o755)

    def run_pull(self, scenario=SCENARIO):
        command = [sys.executable, str(HELPER), "--remote-host", "report-test-host",
                   "--remote-dir", str(self.remote), "--local-root", str(self.local)]
        if scenario:
            command += ["--scenario", scenario]
        return subprocess.run(command, env=self.env, capture_output=True, text=True, timeout=45)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def log_entries(self):
        if not self.transport_log.exists():
            return []
        return [json.loads(line) for line in self.transport_log.read_text().splitlines()]

    def test_scoped_cli_transfer_preserves_source_local_drafts_and_exact_backups(self):
        files, _ = self.fixture()
        conflicts = {f"{BASE}/approval.json": "local approval draft\n",
                     f"{BASE}/consolidated-report.md": "local consolidation draft\n",
                     f"{BASE}/runs/attempt one/run-report.md": "local report draft\n"}
        for name, content in conflicts.items():
            put(self.local, name, content)
        preserved = {f"{BASE}/jira-issue.md": "local source\n",
                     f"{BASE}/bugs/human-review.md": "local review only\n",
                     "runs/local-only/report.md": "local-only lifecycle\n",
                     f"artifacts/{OTHER}/local.log": "unrelated local diagnostics\n"}
        for name, content in preserved.items():
            put(self.local, name, content)
        # Same length and mtime as remote must still replace different local bytes.
        name = f"{BASE}/runs/attempt one/run-report.md"
        remote_path = self.remote / name
        conflicts[name] = "x" * len(files[name])
        (self.local / name).write_text(conflicts[name])
        timestamp = 1_700_000_000_000_000_000
        for path in (remote_path, self.local / name):
            os.utime(path, ns=(timestamp, timestamp))
        before = regular_contents(self.remote)
        self.assert_success(self.run_pull())
        for name, content in {**files, **preserved}.items():
            self.assertEqual((self.local / name).read_text(), content, name)
        self.assertFalse((self.local / "runs/unrelated").exists())
        self.assertFalse((self.local / "runs/planned-only").exists())
        backups = self.local / "artifacts/sync-backups"
        generations = [path for path in backups.iterdir() if path.is_dir()]
        self.assertEqual(len(generations), 1)
        self.assertEqual(regular_contents(generations[0]), {
            name: content.encode() for name, content in conflicts.items()})
        self.assertEqual(regular_contents(self.remote), before)
        local_before_repeat = regular_contents(self.local)
        self.assert_success(self.run_pull())
        self.assertEqual(regular_contents(self.local), local_before_repeat)
        self.assertEqual(regular_contents(self.remote), before)
        # Verification still fetches real inventories on a no-change rerun.
        self.assertGreaterEqual(sum(entry["transport"] == "ssh" for entry in self.log_entries()), 4)

    def test_full_cli_transfer_includes_unrelated_root_lifecycles(self):
        files, others = self.fixture()
        before = regular_contents(self.remote)
        self.assert_success(self.run_pull(scenario=""))
        for name, content in {**files, **others}.items():
            self.assertEqual((self.local / name).read_text(), content)
        self.assertFalse((self.local / BASE / "driver.sh").exists())
        self.assertEqual(regular_contents(self.remote), before)

    def test_shell_scenario_option_uses_verified_pull_in_temporary_checkout(self):
        files, _ = self.fixture()
        for relative in ("sync.sh", "scripts/dotenv.sh", "scripts/pull-reports.py"):
            destination = self.local / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)
        env = dict(self.env, REMOTE_HOST="report-test-host", REMOTE_DIR=str(self.remote))
        result = subprocess.run(
            ["bash", str(self.local / "sync.sh"), "--pull-reports", "--scenario", SCENARIO],
            env=env, capture_output=True, text=True, timeout=45)
        self.assert_success(result)
        for name, content in files.items():
            self.assertEqual((self.local / name).read_text(), content)
        self.assertFalse((self.local / "runs/unrelated").exists())


    def test_corrupt_copy_fails_final_sha_verification(self):
        self.fixture()
        name = f"{BASE}/runs/attempt one/run-report.md"
        self.env.update(REPORT_TEST_AFTER_COPY="corrupt", REPORT_TEST_TARGET=name)
        before = regular_contents(self.remote)
        result = self.run_pull()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.local / name).read_text(), "changed after real transfer\n")
        self.assertEqual(regular_contents(self.remote), before)

    def test_source_change_after_transfer_fails_second_inventory_verification(self):
        files, _ = self.fixture()
        name = f"{BASE}/runs/attempt one/run-report.md"
        self.env.update(REPORT_TEST_AFTER_COPY="change-source", REPORT_TEST_TARGET=name)
        result = self.run_pull()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.local / name).read_text(), files[name])
        self.assertEqual((self.remote / name).read_text(), "changed after real transfer\n")

    def test_new_source_selection_after_transfer_also_fails_verification(self):
        self.fixture()
        name = f"{BASE}/bugs/created-during-pull.md"
        self.env.update(REPORT_TEST_AFTER_COPY="add-source", REPORT_TEST_TARGET=name)
        result = self.run_pull()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.remote / name).is_file())
        self.assertFalse((self.local / name).exists())


    def test_empty_selection_fails_instead_of_claiming_success(self):
        result = self.run_pull()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(regular_contents(self.local), {})

    def test_destination_symlink_cannot_write_outside_local_checkout(self):
        self.fixture()
        outside = self.work / "outside local"
        outside.mkdir()
        (self.local / "runs").symlink_to(outside, target_is_directory=True)
        result = self.run_pull()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(regular_contents(outside), {})
        self.assertFalse(any(entry["transport"] == "rsync" for entry in self.log_entries()))


if __name__ == "__main__":
    unittest.main()
