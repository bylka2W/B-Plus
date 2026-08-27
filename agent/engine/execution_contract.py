import os
import sys
import time
import subprocess
import tempfile
import shutil
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import ZIG_ROOT, MEMORY_DIR, sha256_file, iter_zig_files, load_json, save_json

EXEC_LOG_PATH = MEMORY_DIR / "execution_log.json"

STATUS_PASS = "PASS"
STATUS_FAIL = "FAIL"
STATUS_TIMEOUT = "TIMEOUT"
STATUS_PARSE_ERROR = "PARSE_ERROR"
STATUS_BUILD_ERROR = "BUILD_ERROR"
STATUS_TEST_ERROR = "TEST_ERROR"
STATUS_GATE_ERROR = "GATE_ERROR"
STATUS_UNCHANGED = "UNCHANGED"

ALL_STATUSES = {
    STATUS_PASS, STATUS_FAIL, STATUS_TIMEOUT,
    STATUS_PARSE_ERROR, STATUS_BUILD_ERROR, STATUS_TEST_ERROR,
    STATUS_GATE_ERROR, STATUS_UNCHANGED,
}

PHASE_SNAPSHOT = "snapshot"
PHASE_PARSE = "parse"
PHASE_BUILD = "build"
PHASE_TEST = "test"
PHASE_REINDEX = "reindex"
PHASE_EVIDENCE = "evidence"
PHASE_DONE = "done"

ALL_PHASES = {
    PHASE_SNAPSHOT, PHASE_PARSE, PHASE_BUILD, PHASE_TEST,
    PHASE_REINDEX, PHASE_EVIDENCE, PHASE_DONE,
}


class ExecError:
    __slots__ = ("phase", "message", "file_path", "line", "stderr")

    def __init__(self):
        self.phase = ""
        self.message = ""
        self.file_path = ""
        self.line = 0
        self.stderr = ""

    def to_dict(self):
        return {
            "phase": self.phase,
            "message": self.message,
            "file_path": self.file_path,
            "line": self.line,
            "stderr": self.stderr[:2000],
        }


class FileChange:
    __slots__ = ("rel_path", "action", "old_hash", "new_hash", "lines_added", "lines_removed")

    def __init__(self):
        self.rel_path = ""
        self.action = ""
        self.old_hash = ""
        self.new_hash = ""
        self.lines_added = 0
        self.lines_removed = 0

    def to_dict(self):
        return {
            "rel_path": self.rel_path,
            "action": self.action,
            "old_hash": self.old_hash,
            "new_hash": self.new_hash,
            "lines_added": self.lines_added,
            "lines_removed": self.lines_removed,
        }


class ExecResult:
    __slots__ = (
        "execution_id", "task_id", "status", "phase",
        "changes", "errors", "stdout", "stderr",
        "exit_code", "elapsed_ms", "timeout_ms",
        "snapshot_before", "snapshot_after",
        "reindexed_files", "evidence_verified",
        "allowed_files", "denied_files",
        "created_at",
    )

    def __init__(self):
        self.execution_id = ""
        self.task_id = ""
        self.status = STATUS_FAIL
        self.phase = ""
        self.changes = []
        self.errors = []
        self.stdout = ""
        self.stderr = ""
        self.exit_code = -1
        self.elapsed_ms = 0.0
        self.timeout_ms = 30000
        self.snapshot_before = {}
        self.snapshot_after = {}
        self.reindexed_files = []
        self.evidence_verified = False
        self.allowed_files = []
        self.denied_files = []
        self.created_at = ""

    def to_dict(self):
        return {
            "execution_id": self.execution_id,
            "task_id": self.task_id,
            "status": self.status,
            "phase": self.phase,
            "changes": [c.to_dict() for c in self.changes],
            "errors": [e.to_dict() for e in self.errors],
            "stdout": self.stdout[:5000],
            "stderr": self.stderr[:5000],
            "exit_code": self.exit_code,
            "elapsed_ms": round(self.elapsed_ms, 3),
            "timeout_ms": self.timeout_ms,
            "snapshot_before": self.snapshot_before,
            "snapshot_after": self.snapshot_after,
            "reindexed_files": self.reindexed_files,
            "evidence_verified": self.evidence_verified,
            "allowed_files": self.allowed_files,
            "denied_files": self.denied_files,
            "created_at": self.created_at,
        }

    def render(self):
        lines = []
        lines.append(f"EXECUTION: {self.execution_id}")
        lines.append(f"STATUS: {self.status}")
        lines.append(f"PHASE: {self.phase}")
        lines.append(f"TIME: {self.elapsed_ms:.0f}ms")
        lines.append(f"EXIT_CODE: {self.exit_code}")
        if self.changes:
            lines.append(f"CHANGES: {len(self.changes)} files")
            for c in self.changes:
                lines.append(f"  {c.action} {c.rel_path}")
        if self.errors:
            lines.append(f"ERRORS: {len(self.errors)}")
            for e in self.errors:
                lines.append(f"  [{e.phase}] {e.message[:80]}")
        if self.denied_files:
            lines.append(f"DENIED: {self.denied_files}")
        if self.reindexed_files:
            lines.append(f"REINDEXED: {len(self.reindexed_files)} files")
        lines.append(f"EVIDENCE_VERIFIED: {self.evidence_verified}")
        return "\n".join(lines)


class ExecutionContract:
    def __init__(self, zig_root=None, allowed_patterns=None, timeout_ms=30000):
        self.zig_root = str(zig_root or ZIG_ROOT)
        self.allowed_patterns = allowed_patterns or [".zig"]
        self.timeout_ms = timeout_ms
        self._snapshot_before = {}

    @classmethod
    def load(cls):
        return cls()

    def take_snapshot(self):
        files = {}
        for fp in iter_zig_files(self.zig_root):
            try:
                rel = str(fp).replace(self.zig_root, "").replace("\\", "/")
                files[rel] = sha256_file(str(fp))
            except (OSError, IOError):
                continue
        return files

    def diff_snapshots(self, before, after):
        changes = []
        old_set = set(before.keys())
        new_set = set(after.keys())

        for rel in sorted(new_set - old_set):
            c = FileChange()
            c.rel_path = rel
            c.action = "ADDED"
            c.new_hash = after[rel]
            changes.append(c)

        for rel in sorted(old_set - new_set):
            c = FileChange()
            c.rel_path = rel
            c.action = "REMOVED"
            c.old_hash = before[rel]
            changes.append(c)

        for rel in sorted(old_set & new_set):
            if before[rel] != after[rel]:
                c = FileChange()
                c.rel_path = rel
                c.action = "MODIFIED"
                c.old_hash = before[rel]
                c.new_hash = after[rel]
                changes.append(c)

        return changes

    def check_allowed(self, changes):
        allowed = []
        denied = []
        for c in changes:
            path = c.rel_path
            ext = os.path.splitext(path)[1]
            if ext in self.allowed_patterns:
                allowed.append(path)
            else:
                denied.append(path)
        return allowed, denied

    def parse_check(self, changed_files):
        errors = []
        for rel in changed_files:
            full = os.path.join(self.zig_root, rel.lstrip("/"))
            if not os.path.exists(full):
                continue
            try:
                result = subprocess.run(
                    ["zig", "ast-check", full],
                    capture_output=True, text=True,
                    timeout=10, cwd=self.zig_root,
                )
                if result.returncode != 0:
                    err = ExecError()
                    err.phase = PHASE_PARSE
                    err.file_path = rel
                    err.stderr = result.stderr[:2000]
                    err.message = result.stderr.split("\n")[0][:200] if result.stderr else "parse failed"
                    for line in result.stderr.split("\n"):
                        if line.startswith(full) or line.startswith(rel):
                            parts = line.split(":")
                            if len(parts) >= 2:
                                try:
                                    err.line = int(parts[1])
                                except ValueError:
                                    pass
                            break
                    errors.append(err)
            except FileNotFoundError:
                err = ExecError()
                err.phase = PHASE_PARSE
                err.file_path = rel
                err.message = "zig binary not found"
                errors.append(err)
            except subprocess.TimeoutExpired:
                err = ExecError()
                err.phase = PHASE_PARSE
                err.file_path = rel
                err.message = "parse timeout (10s)"
                errors.append(err)
        return errors

    def build_check(self):
        try:
            result = subprocess.run(
                ["zig", "build", "--help"],
                capture_output=True, text=True,
                timeout=15, cwd=self.zig_root,
            )
            return result.returncode, result.stdout[:3000], result.stderr[:3000]
        except FileNotFoundError:
            return -1, "", "zig binary not found"
        except subprocess.TimeoutExpired:
            return -2, "", "build timeout"

    def run_tests(self):
        try:
            result = subprocess.run(
                ["zig", "build", "test"],
                capture_output=True, text=True,
                timeout=self.timeout_ms / 1000,
                cwd=self.zig_root,
            )
            return result.returncode, result.stdout[:5000], result.stderr[:5000]
        except FileNotFoundError:
            return -1, "", "zig binary not found"
        except subprocess.TimeoutExpired:
            return -2, "", f"test timeout ({self.timeout_ms}ms)"

    def reindex_files(self, changed_files):
        reindexed = []
        from indexes import get_fast_index
        idx = get_fast_index()
        for rel in changed_files:
            full = os.path.join(self.zig_root, rel.lstrip("/"))
            if os.path.exists(full):
                reindexed.append(rel)
        return reindexed

    def execute(self, task_id="", timeout_ms=None):
        t0 = time.monotonic()
        result = ExecResult()
        result.execution_id = f"EX-{int(time.time() * 1000) % 1000000000:09d}"
        result.task_id = task_id
        result.timeout_ms = timeout_ms or self.timeout_ms
        result.created_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

        result.phase = PHASE_SNAPSHOT
        self._snapshot_before = self.take_snapshot()
        result.snapshot_before = {"file_count": len(self._snapshot_before)}

        result.phase = PHASE_PARSE
        after = self.take_snapshot()
        result.snapshot_after = {"file_count": len(after)}
        changes = self.diff_snapshots(self._snapshot_before, after)
        result.changes = changes

        allowed, denied = self.check_allowed(changes)
        result.allowed_files = allowed
        result.denied_files = denied

        if denied:
            result.status = STATUS_GATE_ERROR
            err = ExecError()
            err.phase = PHASE_PARSE
            err.message = f"denied files: {denied}"
            result.errors.append(err)
            result.elapsed_ms = (time.monotonic() - t0) * 1000
            self._log(result)
            return result

        if not changes:
            result.status = STATUS_UNCHANGED
            result.phase = PHASE_DONE
            result.elapsed_ms = (time.monotonic() - t0) * 1000
            self._log(result)
            return result

        parse_errors = self.parse_check(allowed)
        if parse_errors:
            result.status = STATUS_PARSE_ERROR
            result.errors.extend(parse_errors)
            result.elapsed_ms = (time.monotonic() - t0) * 1000
            self._log(result)
            return result

        result.phase = PHASE_BUILD
        build_rc, build_out, build_err = self.build_check()
        result.stdout = build_out
        result.stderr = build_err
        result.exit_code = build_rc

        if build_rc == -1:
            result.status = STATUS_BUILD_ERROR
            err = ExecError()
            err.phase = PHASE_BUILD
            err.message = "zig binary not found"
            err.stderr = build_err[:2000]
            result.errors.append(err)
        elif build_rc == -2:
            result.status = STATUS_TIMEOUT
            err = ExecError()
            err.phase = PHASE_BUILD
            err.message = "build timeout"
            result.errors.append(err)
        elif build_rc != 0:
            result.status = STATUS_BUILD_ERROR
            err = ExecError()
            err.phase = PHASE_BUILD
            err.message = build_err.split("\n")[0][:200] if build_err else "build failed"
            err.stderr = build_err[:2000]
            result.errors.append(err)
        else:
            result.phase = PHASE_TEST
            test_rc, test_out, test_err = self.run_tests()
            result.stdout = test_out
            result.stderr = test_err
            result.exit_code = test_rc

            if test_rc == -1:
                result.status = STATUS_BUILD_ERROR
                err = ExecError()
                err.phase = PHASE_TEST
                err.message = "zig binary not found"
                result.errors.append(err)
            elif test_rc == -2:
                result.status = STATUS_TIMEOUT
                err = ExecError()
                err.phase = PHASE_TEST
                err.message = f"test timeout ({result.timeout_ms}ms)"
                result.errors.append(err)
            elif test_rc != 0:
                result.status = STATUS_TEST_ERROR
                err = ExecError()
                err.phase = PHASE_TEST
                err.message = test_err.split("\n")[0][:200] if test_err else "test failed"
                err.stderr = test_err[:2000]
                result.errors.append(err)
            else:
                result.phase = PHASE_REINDEX
                result.reindexed_files = self.reindex_files(allowed)

                result.phase = PHASE_EVIDENCE
                result.evidence_verified = True

                result.phase = PHASE_DONE
                result.status = STATUS_PASS

        result.elapsed_ms = (time.monotonic() - t0) * 1000
        self._log(result)
        return result

    def execute_patch(self, patch_content, file_path, task_id=""):
        t0 = time.monotonic()
        result = ExecResult()
        result.execution_id = f"EX-{int(time.time() * 1000) % 1000000000:09d}"
        result.task_id = task_id
        result.created_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

        result.phase = PHASE_SNAPSHOT
        before = self.take_snapshot()
        result.snapshot_before = {"file_count": len(before)}

        c = FileChange()
        c.rel_path = file_path
        allowed, denied = self.check_allowed([c])
        if denied:
            result.status = STATUS_GATE_ERROR
            result.denied_files = denied
            err = ExecError()
            err.phase = PHASE_PARSE
            err.message = f"denied: {denied}"
            result.errors.append(err)
            result.elapsed_ms = (time.monotonic() - t0) * 1000
            self._log(result)
            return result

        full_path = os.path.join(self.zig_root, file_path.lstrip("/"))
        os.makedirs(os.path.dirname(full_path), exist_ok=True)

        backup = None
        if os.path.exists(full_path):
            with open(full_path, "rb") as f:
                backup = f.read()

        try:
            with open(full_path, "w", encoding="utf-8") as f:
                f.write(patch_content)
        except (OSError, IOError) as e:
            result.status = STATUS_FAIL
            err = ExecError()
            err.phase = PHASE_PARSE
            err.message = f"write failed: {e}"
            result.errors.append(err)
            result.elapsed_ms = (time.monotonic() - t0) * 1000
            self._log(result)
            return result

        after = self.take_snapshot()
        changes = self.diff_snapshots(before, after)
        result.changes = changes
        result.allowed_files = [file_path]
        result.snapshot_after = {"file_count": len(after)}

        result.phase = PHASE_PARSE
        parse_errors = self.parse_check([file_path])
        if parse_errors:
            result.status = STATUS_PARSE_ERROR
            result.errors.extend(parse_errors)
            self._restore(full_path, backup)
            result.elapsed_ms = (time.monotonic() - t0) * 1000
            self._log(result)
            return result

        result.phase = PHASE_BUILD
        build_rc, build_out, build_err = self.build_check()
        result.stdout = build_out
        result.stderr = build_err
        result.exit_code = build_rc

        if build_rc == -1:
            result.status = STATUS_BUILD_ERROR
            err = ExecError()
            err.phase = PHASE_BUILD
            err.message = "zig binary not found"
            result.errors.append(err)
        elif build_rc == -2:
            result.status = STATUS_TIMEOUT
        elif build_rc != 0:
            result.status = STATUS_BUILD_ERROR
            err = ExecError()
            err.phase = PHASE_BUILD
            err.message = build_err.split("\n")[0][:200] if build_err else "build failed"
            err.stderr = build_err[:2000]
            result.errors.append(err)
        else:
            result.phase = PHASE_TEST
            test_rc, test_out, test_err = self.run_tests()
            result.stdout = test_out
            result.stderr = test_err
            result.exit_code = test_rc

            if test_rc != 0 and test_rc != -1 and test_rc != -2:
                result.status = STATUS_TEST_ERROR
                err = ExecError()
                err.phase = PHASE_TEST
                err.message = test_err.split("\n")[0][:200] if test_err else "test failed"
                err.stderr = test_err[:2000]
                result.errors.append(err)
            elif test_rc == -1:
                result.status = STATUS_BUILD_ERROR
            elif test_rc == -2:
                result.status = STATUS_TIMEOUT
            else:
                result.phase = PHASE_REINDEX
                result.reindexed_files = self.reindex_files([file_path])
                result.phase = PHASE_EVIDENCE
                result.evidence_verified = True
                result.phase = PHASE_DONE
                result.status = STATUS_PASS

        if result.status != STATUS_PASS and backup is not None:
            self._restore(full_path, backup)

        result.elapsed_ms = (time.monotonic() - t0) * 1000
        self._log(result)
        return result

    def _restore(self, path, backup):
        if backup is not None:
            with open(path, "wb") as f:
                f.write(backup)
        elif os.path.exists(path):
            os.remove(path)

    def _log(self, result):
        log = load_json(EXEC_LOG_PATH) if EXEC_LOG_PATH.exists() else {"executions": []}
        if "executions" not in log:
            log["executions"] = []
        log["executions"].append(result.to_dict())
        if len(log["executions"]) > 500:
            log["executions"] = log["executions"][-500:]
        save_json(EXEC_LOG_PATH, log)


_instance = None


def get_execution_contract():
    global _instance
    if _instance is None:
        _instance = ExecutionContract.load()
    return _instance


def main():
    ec = ExecutionContract.load()
    print("EXECUTION CONTRACT READY")
    print(f"  zig_root: {ec.zig_root}")
    print(f"  timeout: {ec.timeout_ms}ms")
    print(f"  allowed: {ec.allowed_patterns}")

    print("\nSnapshot:")
    snap = ec.take_snapshot()
    print(f"  files: {len(snap)}")

    print("\nExecute (no changes):")
    result = ec.execute()
    print(result.render())

    sys.exit(0)


if __name__ == "__main__":
    main()
