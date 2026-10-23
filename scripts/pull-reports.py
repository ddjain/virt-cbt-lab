#!/usr/bin/env python3
"""Pull report-only snapshots without changing the execution host."""

import argparse
import datetime
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


class PullError(Exception):
    pass


SCENARIOS = PurePosixPath("cbt-chaos/scenarios_v2")
DENIED_DIRS = {".git", ".kube", ".ssh", "keys", "__pycache__"}
DENIED_FILES = (
    ".env", ".env.*", "*kubeconfig*", "id_rsa*", "id_ed25519*",
    "*.pem", "*.key", "*.p12", "*.pfx", "*windows*password*",
    ".DS_Store", "*.iso", "*.qcow2", "*.raw", "*.img",
)
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]


def component(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", value):
        raise PullError("Invalid scenario/lifecycle ID: {!r}".format(value))
    return value


def relative_report_path(value):
    if not isinstance(value, str) or not value or any(c in value for c in "\x00\r\n\\"):
        raise PullError("Invalid report path: {!r}".format(value))
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or str(path) != value:
        raise PullError("Unsafe report path: {!r}".format(value))
    parts = path.parts
    allowed = False
    if len(parts) >= 2 and parts[0] == "runs":
        allowed = True
    elif len(parts) >= 3 and parts[0] == "artifacts":
        component(parts[1])
        allowed = True
    elif len(parts) >= 4 and parts[:2] == SCENARIOS.parts:
        component(parts[2])
        allowed = (len(parts) >= 5 and parts[3] in ("bugs", "runs")) or (
            len(parts) == 4 and parts[3] in (
                "consolidated-report.md", "approval.json", "jira-issue.md"
            )
        )
    if not allowed:
        raise PullError("Path is not a report artifact: {}".format(value))
    if excluded(path):
        raise PullError("Credential/image paths are not report payload: {}".format(value))
    return path


def excluded(path):
    return any(part in DENIED_DIRS for part in path.parts) or any(
        fnmatch.fnmatch(path.name.lower(), pattern) for pattern in DENIED_FILES
    )


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_destination(root, relative):
    root = Path(root).absolute()
    if root.is_symlink() or not root.is_dir():
        raise PullError("Local checkout must be an existing, non-symlink directory")
    path = relative_report_path(relative)
    current = root
    for index, part in enumerate(path.parts):
        current = current / part
        if current.is_symlink():
            raise PullError("Refusing local symlink: {}".format(relative))
        if current.exists():
            last = index == len(path.parts) - 1
            if (last and not current.is_file()) or (not last and not current.is_dir()):
                raise PullError("Local file/directory conflict: {}".format(relative))
    return current


def proposal_path(value):
    path = relative_report_path(value)
    if len(path.parts) != 4 or path.parts[:2] != SCENARIOS.parts or path.name != "jira-issue.md":
        raise PullError("Proposal must be a repository-relative scenario jira-issue.md: {!r}".format(value))
    return path


def proposed_document(path):
    status = re.compile(
        r"(?:status:\s*)?proposed\s*[-–—]\s*unexecuted\s*[-–—]\s*pending\s+human\s+review",
        re.IGNORECASE,
    )
    return any(
        status.fullmatch(line.replace("*", "").replace("_", "").strip(" \t#>"))
        for line in path.read_text(encoding="utf-8").splitlines()
    )


def inventory(root, scenario=""):
    root = Path(root)
    if root.is_symlink():
        raise PullError("Refusing symlinked remote checkout")
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise PullError("Remote checkout is not a directory")

    def source_symlink(path):
        while path != root:
            if path.is_symlink():
                return True
            path = path.parent
        return False

    base = root / str(SCENARIOS)
    if scenario:
        component(scenario)
        selected = base / scenario
        if source_symlink(selected) or not selected.is_dir():
            raise PullError("Scenario does not exist as a regular directory: {}".format(scenario))
        scenarios = [scenario]
    else:
        if source_symlink(base):
            raise PullError("Refusing symlinked scenario root")
        scenarios = sorted(
            component(path.name) for path in base.iterdir()
            if path.is_dir() and not path.is_symlink() and not path.name.startswith(".")
        ) if base.is_dir() else []
    result = {"files": {}, "missing_lifecycles": [], "scenarios": scenarios, "excluded": 0}
    lifecycles = set()
    proposals = set()

    def collect(path):
        if source_symlink(path) or excluded(path.relative_to(root)):
            result["excluded"] += 1
            return
        if not path.exists():
            return
        if path.is_dir():
            for directory, dirs, files in os.walk(path, followlinks=False):
                parent = Path(directory)
                keep = []
                for name in sorted(dirs):
                    child = parent / name
                    if child.is_symlink() or excluded(child.relative_to(root)):
                        result["excluded"] += 1
                    else:
                        keep.append(name)
                dirs[:] = keep
                for name in sorted(files):
                    collect(parent / name)
        elif path.is_file():
            relative = path.relative_to(root).as_posix()
            relative_report_path(relative)
            result["files"][relative] = sha256_file(path)
        else:
            result["excluded"] += 1

    def metadata(path):
        if not path.exists() or source_symlink(path):
            return
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (ValueError, UnicodeError) as exc:
            raise PullError("Malformed metadata {}: {}".format(path.relative_to(root), exc)) from exc
        if not isinstance(record, dict):
            raise PullError("Metadata must be an object: {}".format(path.relative_to(root)))
        ids = record.get("lifecycle_ids")
        if ids is None:
            ids = []
        if not isinstance(ids, list):
            raise PullError("lifecycle_ids must be an array: {}".format(path.relative_to(root)))
        ids = list(ids)
        if record.get("lifecycle_id") is not None:
            ids.append(record["lifecycle_id"])
        lifecycles.update(component(value) for value in ids)
        references = record.get("proposed_scenarios")
        if references is None:
            references = []
        if not isinstance(references, list):
            raise PullError("proposed_scenarios must be an array: {}".format(path.relative_to(root)))
        proposals.update(proposal_path(value) for value in references)

    for name in scenarios:
        directory = base / name
        for child in ("bugs", "runs", "consolidated-report.md", "approval.json"):
            collect(directory / child)
        attempts = directory / "runs"
        if attempts.is_dir() and not attempts.is_symlink():
            for attempt in sorted(attempts.iterdir()):
                if attempt.is_dir() and not attempt.is_symlink():
                    metadata(attempt / "run.json")
                    metadata(attempt / "analysis.json")
        collect(root / "artifacts" / name)
        jira = directory / "jira-issue.md"
        if jira.is_file() and not jira.is_symlink() and proposed_document(jira):
            proposals.add(PurePosixPath(jira.relative_to(root).as_posix()))
    for lifecycle in sorted(lifecycles):
        path = root / "runs" / lifecycle
        if source_symlink(path):
            raise PullError("Refusing symlinked lifecycle: {}".format(lifecycle))
        if not path.is_dir():
            result["missing_lifecycles"].append(lifecycle)
        elif scenario:
            collect(path)
    if not scenario:
        collect(root / "runs")
    for relative in sorted(proposals):
        path = root / str(relative)
        # Validate every parent too: a proposal link must not escape the checkout.
        if source_symlink(path):
            raise PullError("Refusing symlinked proposal: {}".format(relative))
        if not path.is_file() or not proposed_document(path):
            raise PullError("Claimed proposal missing or lacking PROPOSED — UNEXECUTED — PENDING HUMAN REVIEW status: {}".format(relative))
        collect(path)
    result["files"] = dict(sorted(result["files"].items()))
    return result


def changed_files(root, files):
    changed = []
    for relative, digest in sorted(files.items()):
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise PullError("Invalid SHA-256 for {}".format(relative))
        path = safe_destination(root, relative)
        if not path.is_file() or sha256_file(path) != digest:
            changed.append(relative)
    return changed


def verify_files(root, files):
    mismatches = changed_files(root, files)
    if mismatches:
        raise PullError("SHA-256 verification failed: {}".format(", ".join(mismatches[:8])))


def remote_inventory(host, directory, scenario):
    command = "python3 - --inventory {} {}".format(shlex.quote(directory), shlex.quote(scenario))
    completed = subprocess.run(
        SSH + [host, command], input=Path(__file__).read_bytes(),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300,
    )
    if completed.returncode:
        raise PullError("Remote inventory failed: {}".format(completed.stderr.decode(errors="replace").strip()))
    try:
        snapshot = json.loads(completed.stdout)
    except (ValueError, UnicodeError) as exc:
        raise PullError("Remote inventory did not return valid JSON") from exc
    if not isinstance(snapshot, dict) or not isinstance(snapshot.get("files"), dict):
        raise PullError("Invalid remote report inventory")
    return snapshot


def pull(root, host, directory, scenario=""):
    if not host or host.startswith("-") or any(c.isspace() for c in host):
        raise PullError("REMOTE_HOST must be an SSH host or alias, not options")
    if not directory or any(c in directory for c in "\x00\r\n"):
        raise PullError("REMOTE_DIR is required and must not contain control characters")
    root = Path(root).absolute()
    if root.is_symlink():
        raise PullError("Refusing symlinked local checkout")
    root = root.resolve(strict=True)
    if scenario:
        component(scenario)
    for command in ("ssh", "rsync"):
        if shutil.which(command) is None:
            raise PullError("Required command not found: {}".format(command))
    before = remote_inventory(host, directory, scenario)
    files = before["files"]
    if not files:
        raise PullError("No report artifacts found for the selected scope")
    changed = changed_files(root, files)
    conflicts = [relative for relative in changed if safe_destination(root, relative).exists()]
    backup = None
    if conflicts:
        backup_parent = safe_destination(root, "artifacts/sync-backups/placeholder").parent
        backup_parent.mkdir(parents=True, exist_ok=True)
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
        backup = Path(tempfile.mkdtemp(prefix=stamp, dir=backup_parent))
        # Keep backup paths out of the remote rsync argv: openrsync does not
        # quote its forwarded --backup-dir when a local checkout has spaces.
        for relative in conflicts:
            destination = backup / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(safe_destination(root, relative), destination)
    if changed:
        with tempfile.TemporaryDirectory(prefix="cbt-report-pull-") as temporary:
            listing = Path(temporary) / "files"
            listing.write_bytes(b"".join(path.encode("utf-8") + b"\0" for path in changed))
            command = [
                "rsync", "-ptR", "--ignore-times", "--from0", "--files-from=" + str(listing),
                "-e", shlex.join(SSH),
            ]
            command += [host + ":" + shlex.quote(directory.rstrip("/") + "/"), str(root) + "/"]
            subprocess.run(command, check=True, timeout=600)
    verify_files(root, files)
    if remote_inventory(host, directory, scenario) != before:
        raise PullError("Remote reports changed during pull; local snapshot is not verified current. Rerun after remote writers finish.")
    print("Verified {} report files with SHA-256; transferred {} changed files.".format(len(files), len(changed)))
    print("Scope: {}".format(scenario or "all v2 scenarios and all root lifecycle runs"))
    for lifecycle in before.get("missing_lifecycles", []):
        print("Referenced lifecycle absent on remote (not fabricated): {}".format(lifecycle))
    if before.get("excluded"):
        print("Excluded {} credential/image/symlink or special entries.".format(before["excluded"]))
    if backup is not None:
        print("Preserved {} local conflicts in {}".format(len(conflicts), backup.relative_to(root)))
    print("Local reports: {}".format(root))


def main():
    if sys.argv[1:2] == ["--inventory"]:
        if len(sys.argv) != 4:
            raise PullError("Internal inventory requires ROOT and SCENARIO")
        print(json.dumps(inventory(Path(sys.argv[2]), sys.argv[3]), sort_keys=True))
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--remote-host", required=True)
    parser.add_argument("--remote-dir", required=True)
    parser.add_argument("--local-root", type=Path, required=True)
    parser.add_argument("--scenario", default="")
    args = parser.parse_args()
    pull(args.local_root, args.remote_host, args.remote_dir, args.scenario)


if __name__ == "__main__":
    try:
        main()
    except (PullError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("Report pull failed: {}".format(error), file=sys.stderr)
        sys.exit(1)
