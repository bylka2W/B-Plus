import os
import sys
import json
import hashlib
import subprocess
import tempfile
import shutil
import time
import re
import glob

try:
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "engine"))
    import compact_store
    _HAVE_COMPACT = True
except Exception:
    _HAVE_COMPACT = False
import copy
from pathlib import Path
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone

AGENT_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(AGENT_ROOT))

FORBIDDEN_ROOTS = [Path(r"C:\B-Plus\zig")]
WORKSPACE_ROOT = AGENT_ROOT / "workspace"
BACKUP_DIR = AGENT_ROOT / "workspace" / "backups"
AUDIT_DIR = AGENT_ROOT / "workspace" / "audit"


def sha256_file(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except (OSError, IOError):
        return ""


def short_id(prefix, *parts):
    h = hashlib.sha1(json.dumps(parts, default=str).encode()).hexdigest()[:16]
    return f"{prefix}-{h}"


class AuditLog:
    def __init__(self, log_dir=None):
        self.log_dir = Path(log_dir) if log_dir else AUDIT_DIR
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.entries = []

    def log(self, action, input_data, output_data, success, duration_ms=0):
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "action": action,
            "input": input_data,
            "output": {k: v for k, v in output_data.items() if k != "content"},
            "success": success,
            "duration_ms": round(duration_ms, 1),
        }
        self.entries.append(entry)
        return entry

    def save(self, goal_id):
        path = self.log_dir / f"{goal_id}_audit.json"
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.entries, f, indent=2, default=str)
        return path

    def summary(self):
        total = len(self.entries)
        ok = sum(1 for e in self.entries if e["success"])
        return {"total_actions": total, "succeeded": ok, "failed": total - ok}


class Sandbox:
    def __init__(self):
        self.backups = {}
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)

    def snapshot(self, filepath):
        fp = Path(filepath)
        if not fp.exists():
            return None
        backup_path = BACKUP_DIR / f"{sha256_file(fp)[:12]}_{fp.name}"
        shutil.copy2(fp, backup_path)
        self.backups[str(fp)] = str(backup_path)
        return str(backup_path)

    def restore(self, filepath):
        fp = str(filepath)
        if fp in self.backups:
            shutil.copy2(self.backups[fp], fp)
            return True
        return False

    def is_forbidden(self, filepath):
        fp = Path(filepath).resolve()
        for root in FORBIDDEN_ROOTS:
            try:
                fp.relative_to(root.resolve())
                return True
            except ValueError:
                pass
        return False


class KnowledgeQuery:
    def __init__(self, kb_dir):
        # Accept a single path OR a list of paths (tiers: environment + truth).
        if isinstance(kb_dir, (list, tuple)):
            self.kb_dirs = [Path(d) for d in kb_dir]
        else:
            self.kb_dirs = [Path(kb_dir)]
        self.facts = []
        self.concepts = {}
        self.concepts_by_id = {}
        self.relations = []
        self.evidence = []
        self.compact_readers = []
        self._load()
        if _HAVE_COMPACT:
            for kb_dir in self.kb_dirs:
                opened = False
                for cand in (kb_dir / "knowledge.db", kb_dir / "knowledge.db.gz"):
                    if cand.exists():
                        try:
                            self.compact_readers.append(compact_store.CompactReader(str(cand)))
                            opened = True
                            break
                        except Exception:
                            pass
                if opened:
                    continue

    def _load(self):
        file_map = {
            "facts": "facts.json",
            "concepts": "concepts.json",
            "relations": "semantic_relations.json",
            "evidence": "source_evidence.json",
        }
        for kb_dir in self.kb_dirs:
            for name, filename in file_map.items():
                path = kb_dir / filename
                if path.exists():
                    self._ingest(name, path)
            # sharded facts / relations / evidence (full_zig layer)
            for shard in sorted(glob.glob(str(kb_dir / "facts_*.json"))):
                self._ingest("facts", Path(shard))
            for shard in sorted(glob.glob(str(kb_dir / "relations_*.json"))):
                self._ingest("relations", Path(shard))
            for shard in sorted(glob.glob(str(kb_dir / "evidence_*.json"))):
                self._ingest("evidence", Path(shard))

    def _ingest(self, name, path):
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
                if name == "facts":
                    if isinstance(data, dict):
                        self.facts.extend(data.get("items", []))
                    elif isinstance(data, list):
                        self.facts.extend(data)
                elif name == "concepts":
                    if isinstance(data, dict):
                        items = data.get("items", [])
                        if isinstance(items, list):
                            self.concepts_by_id.update({item.get("concept_id", str(i)): item for i, item in enumerate(items) if isinstance(item, dict)})
                            self.concepts.update({item.get("name", item.get("concept_id", str(i))): item for i, item in enumerate(items) if isinstance(item, dict)})
                        else:
                            self.concepts.update(data)
                    elif isinstance(data, list):
                        self.concepts_by_id.update({item.get("concept_id", str(i)): item for i, item in enumerate(data) if isinstance(item, dict)})
                        self.concepts.update({item.get("name", item.get("concept_id", str(i))): item for i, item in enumerate(data)})
                elif name == "relations":
                    if isinstance(data, dict):
                        self.relations.extend(data.get("items", []))
                    elif isinstance(data, list):
                        self.relations.extend(data)
                elif name == "evidence":
                    if isinstance(data, dict):
                        self.evidence.extend(data.get("items", []))
                    elif isinstance(data, list):
                        self.evidence.extend(data)
        except (json.JSONDecodeError, OSError):
            pass

    def query_symbol(self, name):
        results = []
        for fact in self.facts:
            if isinstance(fact, dict):
                text = str(fact.get("source_file", "") or "")
                predicate = str(fact.get("predicate", "") or "")
                if name.lower() in text.lower() or name.lower() in predicate.lower():
                    results.append(fact)
        for concept_name, concept_data in self.concepts.items():
            if name.lower() in str(concept_name).lower():
                results.append({"type": "concept", "name": concept_name, **(concept_data if isinstance(concept_data, dict) else {})})
        for reader in self.compact_readers:
            for sym in reader.symbol_by_name(name):
                results.append({"type": "symbol", **sym})
            for f in reader.query_facts_text(name):
                results.append(f)
        return results

    def query_file(self, filepath):
        results = []
        for fact in self.facts:
            if isinstance(fact, dict):
                if filepath.lower() in str(fact.get("source_file", "")).lower():
                    results.append(fact)
        for reader in self.compact_readers:
            fid = reader.file_id_by_path(filepath)
            if fid is not None:
                results.extend(reader.query_facts(file_id=fid, limit=20000))
        return results

    def evidence_text(self, fact):
        """Recover real source text for a fact (compact or JSON)."""
        for reader in self.compact_readers:
            ev_id = fact.get("evidence_id")
            if isinstance(ev_id, int) and ev_id:
                rec = reader.get_evidence_text(ev_id)
                if rec:
                    return rec
        if self.evidence:
            ev_id = fact.get("evidence_id")
            for e in self.evidence:
                if isinstance(e, dict) and e.get("id") == ev_id:
                    return e.get("text", "")
        return None

    def retrieve_context(self, query, max_symbols=8, max_facts_per_symbol=40,
                         max_related=80, expand_members=True):
        """Build a compact, provable model context for a query.

        Returns symbols + their atomic facts + member symbols (methods/fields
        of containers) + resolved CALLS/USES_TYPE targets + the REAL source
        spans (evidence) — bounded to a few KB, never the whole DB.
        """
        ctx = {"query": query, "symbols": [], "related": [], "source_snippets": []}
        seen_sym = set()
        seen_snip = set()
        # 1) candidate symbols: exact first, then substring
        cands = []
        for reader in self.compact_readers:
            cands.extend(reader.symbol_by_name(query))
            cands.extend(reader.symbol_by_substr(query))
        def _def_priority(s):
            k = s.get("kind")
            sig = s.get("signature") or ""
            if k in ("struct", "enum", "union", "error", "opaque", "fn", "test"):
                return 0
            if any(t in sig for t in ("struct", "enum", "union", "error")):
                return 0
            if k == "import":
                return 2
            return 1
        cands.sort(key=lambda s: (_def_priority(s), 0 if s.get("name") == query else 1))
        container_kinds = {"struct", "enum", "union", "const", "error", "opaque"}

        def add_snippet(fact):
            rec = self.evidence_text(fact)
            if isinstance(rec, dict) and rec.get("text"):
                key = (rec.get("path"), rec.get("start"), rec.get("end"))
                if key not in seen_snip:
                    seen_snip.add(key)
                    ctx["source_snippets"].append({
                        "path": rec.get("path"), "start": rec.get("start"),
                        "end": rec.get("end"), "text": rec.get("text")})
                return True
            return False

        for sym in cands[:max_symbols]:
            sid = sym.get("symbol_id")
            if sid in seen_sym:
                continue
            seen_sym.add(sid)
            entry = dict(sym)
            facts = []
            for reader in self.compact_readers:
                facts.extend(reader.query_facts(subject_id=sid, limit=max_facts_per_symbol))
            entry["facts"] = facts
            if facts:
                add_snippet(facts[0])
            ctx["symbols"].append(entry)
            # expand container members (methods/fields) -> their facts+evidence
            if expand_members and sym.get("kind") in container_kinds:
                for reader in self.compact_readers:
                    for mem in reader.nested_symbols(sym):
                        if mem["symbol_id"] in seen_sym:
                            continue
                        seen_sym.add(mem["symbol_id"])
                        mfacts = reader.query_facts(subject_id=mem["symbol_id"],
                                                   limit=max_facts_per_symbol)
                        mentry = dict(mem)
                        mentry["facts"] = mfacts
                        if mfacts:
                            add_snippet(mfacts[0])
                        ctx["symbols"].append(mentry)
            # resolve CALLS / USES_TYPE targets -> related symbols
            for f in facts:
                if f.get("fact_type") in ("CALLS", "USES_TYPE", "FIELD_ACCESS"):
                    tgt = f.get("object_value") or f.get("object_id")
                    if not tgt:
                        continue
                    for reader in self.compact_readers:
                        for rs in reader.symbol_by_name(tgt)[:3]:
                            if rs["symbol_id"] not in seen_sym and len(ctx["related"]) < max_related:
                                seen_sym.add(rs["symbol_id"])
                                ctx["related"].append(rs)
        blob = json.dumps(ctx, ensure_ascii=False)
        ctx["_stats"] = {
            "symbols": len(ctx["symbols"]),
            "related": len(ctx["related"]),
            "facts": sum(len(s["facts"]) for s in ctx["symbols"]),
            "source_snippets": len(ctx["source_snippets"]),
            "context_chars": len(blob),
        }
        return ctx

    def format_context(self, ctx):
        """Render the retrieved context as compact human/LLM-readable text."""
        lines = [f"# Knowledge context for: {ctx['query']}", ""]
        for s in ctx["symbols"]:
            lines.append(f"## symbol {s.get('name')} ({s.get('kind')}) "
                         f"@ {s.get('source_file')}:{s.get('line_start')}")
            if s.get("signature"):
                lines.append(f"   sig: {s['signature']}")
            for f in s.get("facts", [])[:25]:
                lines.append(f"   - {f.get('fact_type')} "
                             f"{f.get('object_value') or ''} "
                             f"[{f.get('resolution_status')}]")
        if ctx.get("related"):
            lines.append("")
            lines.append("## related symbols")
            for r in ctx["related"][:25]:
                lines.append(f"   - {r.get('name')} ({r.get('kind')}) "
                             f"@ {r.get('source_file')}:{r.get('line_start')}")
        if ctx.get("source_snippets"):
            lines.append("")
            lines.append("## real source evidence")
            for sn in ctx["source_snippets"][:15]:
                lines.append(f"   # {sn.get('path')}:{sn.get('start')}-{sn.get('end')}")
                for sl in sn.get("text", "").split("\n"):
                    lines.append(f"   | {sl}")
        return "\n".join(lines)


class SourceIndex:
    def __init__(self, roots):
        self.roots = [Path(r) for r in roots]
        self.files = {}

    def scan(self):
        excluded = {"zig-cache", "zig-out", ".git", "node_modules", "build", "build-debug", "build-release", "CMakeFiles"}
        for root in self.roots:
            for dirpath, dirnames, filenames in os.walk(root):
                dirnames[:] = sorted(d for d in dirnames if d not in excluded and not d.startswith("."))
                for name in sorted(filenames):
                    if name.endswith(".zig"):
                        fp = os.path.join(dirpath, name)
                        rel = str(Path(fp))
                        try:
                            with open(fp, "r", encoding="utf-8", errors="replace") as f:
                                content = f.read()
                            self.files[rel] = {
                                "path": fp,
                                "root": str(root),
                                "lines": content.split("\n"),
                                "hash": hashlib.sha256(content.encode()).hexdigest(),
                            }
                        except (OSError, IOError):
                            pass

    def search(self, query, max_results=10):
        results = []
        query_lower = query.lower()
        for fp, info in self.files.items():
            score = 0
            for i, line in enumerate(info["lines"]):
                if query_lower in line.lower():
                    score += 1
            if score > 0:
                results.append({"path": fp, "score": score, "lines": info["lines"]})
        results.sort(key=lambda x: x["score"], reverse=True)
        return results[:max_results]

    def read_file(self, filepath, line_start=None, line_end=None):
        for fp, info in self.files.items():
            if fp == filepath or filepath in fp:
                lines = info["lines"]
                if line_start is not None:
                    start = max(0, line_start - 1)
                    end = line_end if line_end else len(lines)
                    return "\n".join(lines[start:end])
                return "\n".join(lines)
        return ""

    def read_file_real(self, filepath):
        try:
            with open(filepath, "r", encoding="utf-8", errors="replace") as f:
                return f.read()
        except (OSError, IOError):
            return ""


class ZigRunner:
    def __init__(self, zig_exe=None):
        self.zig_exe = zig_exe or self._find_zig()

    def _find_zig(self):
        candidates = [
            Path(r"C:\tools\zig\zig-windows-x86_64-0.14.0\zig.exe"),
            Path(r"C:\Users\Local\zig\zig.exe"),
        ]
        for c in candidates:
            if c.exists():
                return str(c)
        return "zig"

    def _run(self, args, timeout=30, cwd=None):
        t0 = time.monotonic()
        try:
            result = subprocess.run(
                args, capture_output=True, text=True, timeout=timeout,
                encoding="utf-8", errors="replace", cwd=cwd,
            )
            duration = (time.monotonic() - t0) * 1000
            return result.returncode, result.stdout, result.stderr, duration
        except subprocess.TimeoutExpired:
            return -1, "", "TIMEOUT", timeout * 1000
        except FileNotFoundError:
            return -2, "", "ZIG_NOT_FOUND", 0

    def syntax_check_file(self, filepath):
        code, out, err, dur = self._run([self.zig_exe, "ast-check", filepath])
        return code == 0, err.strip() or out.strip(), dur

    def syntax_check_code(self, code):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".zig", delete=False) as f:
            f.write(code)
            path = f.name
        try:
            ok, msg, dur = self.syntax_check_file(path)
            return ok, msg, dur
        finally:
            os.unlink(path)

    def format_check_file(self, filepath):
        code, out, err, dur = self._run([self.zig_exe, "fmt", "--check", filepath])
        return code == 0, err.strip() or out.strip(), dur

    def fmt_file(self, filepath):
        code, out, err, dur = self._run([self.zig_exe, "fmt", filepath])
        return code == 0, err.strip(), dur

    def build_file(self, filepath, timeout=60):
        cache_dir = tempfile.mkdtemp()
        try:
            code, out, err, dur = self._run(
                [self.zig_exe, "build-exe", filepath, "--cache-dir", cache_dir],
                timeout=timeout, cwd=str(Path(filepath).parent),
            )
            return code == 0, err.strip() or out.strip(), dur
        finally:
            shutil.rmtree(cache_dir, ignore_errors=True)

    def run_file(self, filepath, timeout=15):
        exe_path = str(Path(filepath).with_suffix(".exe"))
        code, out, err, dur = self._run([exe_path], timeout=timeout)
        return code == 0, f"stdout:\n{out[:2000]}\nstderr:\n{err[:2000]}", dur

    def test_file(self, filepath, timeout=30):
        cache_dir = tempfile.mkdtemp()
        try:
            code, out, err, dur = self._run(
                [self.zig_exe, "test", filepath, "--cache-dir", cache_dir],
                timeout=timeout, cwd=str(Path(filepath).parent),
            )
            return code == 0, err.strip() or out.strip(), dur
        finally:
            shutil.rmtree(cache_dir, ignore_errors=True)


@dataclass
class AgentStep:
    action: str
    input_data: dict
    output_data: dict
    success: bool
    error: str = ""
    duration_ms: float = 0.0
    step_index: int = 0


@dataclass
class AgentGoal:
    goal: str
    goal_id: str = ""
    steps: list = field(default_factory=list)
    result: str = ""
    success: bool = False
    verified: bool = False
    audit_summary: dict = field(default_factory=dict)

    def __post_init__(self):
        if not self.goal_id:
            self.goal_id = short_id("GOAL", self.goal, time.time())


class AgentRuntime:
    MAX_STEPS = 30
    MAX_RETRIES = 2

    def __init__(self, model, tokenizer, knowledge, source_index, zig_runner):
        self.model = model
        self.tokenizer = tokenizer
        self.knowledge = knowledge
        self.source_index = source_index
        self.zig_runner = zig_runner
        self.sandbox = Sandbox()
        self.audit = AuditLog()

    def plan(self, goal):
        steps = []
        goal_lower = goal.lower()

        steps.append({"action": "search_knowledge", "params": {"query": goal}})
        steps.append({"action": "search_source", "params": {"query": goal}})

        if "fix" in goal_lower or "error" in goal_lower or "bug" in goal_lower:
            steps.extend([
                {"action": "read_file", "params": {"file": "auto"}},
                {"action": "backup_file", "params": {}},
                {"action": "generate_fix", "params": {"goal": goal}},
                {"action": "syntax_check", "params": {}},
                {"action": "apply_patch", "params": {}},
                {"action": "syntax_check_file", "params": {}},
                {"action": "fmt_file", "params": {}},
                {"action": "build_file", "params": {}},
                {"action": "test_file", "params": {}},
                {"action": "verify", "params": {"goal": goal}},
            ])
        elif "create" in goal_lower or "write" in goal_lower or "implement" in goal_lower:
            steps.extend([
                {"action": "generate_code", "params": {"goal": goal}},
                {"action": "syntax_check", "params": {}},
                {"action": "write_file", "params": {}},
                {"action": "syntax_check_file", "params": {}},
                {"action": "fmt_file", "params": {}},
                {"action": "build_file", "params": {}},
                {"action": "test_file", "params": {}},
                {"action": "verify", "params": {"goal": goal}},
            ])
        elif "explain" in goal_lower or "find" in goal_lower or "search" in goal_lower:
            steps.extend([
                {"action": "read_file", "params": {"file": "auto"}},
                {"action": "summarize", "params": {"goal": goal}},
            ])
        else:
            steps.extend([
                {"action": "generate_response", "params": {"goal": goal}},
            ])
        return steps

    def execute(self, goal_text):
        goal = AgentGoal(goal=goal_text)
        goal.steps = self.plan(goal_text)
        self.audit = AuditLog()

        context = {"goal": goal.goal, "files_read": {}, "files_written": [], "target_file": None}

        for i, step_def in enumerate(goal.steps):
            if i >= self.MAX_STEPS:
                goal.result = f"MAX_STEPS ({self.MAX_STEPS}) exceeded"
                break

            action = step_def["action"]
            params = step_def["params"]
            params["_context"] = context

            t0 = time.monotonic()
            step_result = self._run_action(action, params, context, goal)
            step_result.duration_ms = (time.monotonic() - t0) * 1000
            step_result.step_index = i
            goal.steps[i] = step_result

            self.audit.log(action, params, step_result.output_data, step_result.success, step_result.duration_ms)

            if not step_result.success:
                should_retry = action in ("syntax_check", "build_file", "test_file", "fmt_file")
                retried = False
                for retry in range(self.MAX_RETRIES if should_retry else 0):
                    retry_params = dict(params)
                    retry_params["_retry"] = retry + 1
                    t0 = time.monotonic()
                    step_result = self._run_action(action, retry_params, context, goal)
                    step_result.duration_ms = (time.monotonic() - t0) * 1000
                    step_result.step_index = i
                    retried = True
                    if step_result.success:
                        break

                if not step_result.success:
                    if action == "apply_patch" and context.get("target_file"):
                        self.sandbox.restore(context["target_file"])
                    goal.result = f"FAILED at step {i}: {action}: {step_result.error}"
                    goal.audit_summary = self.audit.summary()
                    self.audit.save(goal.goal_id)
                    return goal

        goal.verified = self._verify(goal, context)
        goal.success = True
        goal.result = self._summarize(goal)
        goal.audit_summary = self.audit.summary()
        self.audit.save(goal.goal_id)
        return goal

    def _run_action(self, action, params, context, goal):
        try:
            if action == "search_knowledge":
                results = self.knowledge.query_symbol(params.get("query", ""))
                return AgentStep(action=action, input_data=params, output_data={"count": len(results), "results": results[:5]}, success=True)

            elif action == "search_source":
                results = self.source_index.search(params.get("query", ""))
                return AgentStep(action=action, input_data=params, output_data={"count": len(results), "paths": [r["path"] for r in results[:5]]}, success=True)

            elif action == "read_file":
                file_path = params.get("file", "")
                if file_path == "auto":
                    search_results = context.get("_search_results", [])
                    if search_results:
                        file_path = search_results[0]
                    elif context.get("target_file"):
                        file_path = context["target_file"]
                    else:
                        for s in goal.steps:
                            if isinstance(s, AgentStep) and s.action == "search_source" and s.output_data.get("paths"):
                                file_path = s.output_data["paths"][0]
                                break
                if not file_path:
                    return AgentStep(action=action, input_data=params, output_data={}, success=False, error="no file path")
                content = self.source_index.read_file_real(file_path)
                if not content:
                    return AgentStep(action=action, input_data=params, output_data={}, success=False, error=f"cannot read: {file_path}")
                context["files_read"][file_path] = content
                context["target_file"] = file_path
                return AgentStep(action=action, input_data={"file": file_path}, output_data={"file": file_path, "lines": content.count("\n") + 1, "bytes": len(content)}, success=True)

            elif action == "backup_file":
                file_path = context.get("target_file")
                if not file_path:
                    return AgentStep(action=action, input_data=params, output_data={}, success=False, error="no target file")
                backup_path = self.sandbox.snapshot(file_path)
                if backup_path is None:
                    return AgentStep(action=action, input_data=params, output_data={}, success=False, error=f"backup failed: {file_path}")
                return AgentStep(action=action, input_data={"file": file_path}, output_data={"backup": backup_path}, success=True)

            elif action == "generate_fix" or action == "generate_code":
                code = self._generate(goal.goal)
                return AgentStep(action=action, input_data=params, output_data={"code": code, "chars": len(code)}, success=True)

            elif action == "generate_response":
                response = self._generate(goal.goal)
                return AgentStep(action=action, input_data=params, output_data={"response": response, "chars": len(response)}, success=True)

            elif action == "syntax_check":
                code = self._extract_code(goal)
                if not code:
                    return AgentStep(action=action, input_data=params, output_data={}, success=False, error="no code to check")
                ok, msg, dur = self.zig_runner.syntax_check_code(code)
                return AgentStep(action=action, input_data=params, output_data={"valid": ok, "msg": msg, "duration_ms": dur}, success=ok, error="" if ok else msg)

            elif action == "apply_patch":
                code = self._extract_code(goal)
                target = context.get("target_file")
                if not target:
                    return AgentStep(action=action, input_data=params, output_data={}, success=False, error="no target file")
                if self.sandbox.is_forbidden(target):
                    return AgentStep(action=action, input_data=params, output_data={}, success=False, error=f"FORBIDDEN: {target}")
                try:
                    with open(target, "w", encoding="utf-8", newline="\n") as f:
                        f.write(code)
                    return AgentStep(action=action, input_data={"file": target}, output_data={"file": target, "bytes": len(code)}, success=True)
                except (OSError, IOError) as e:
                    return AgentStep(action=action, input_data={"file": target}, output_data={}, success=False, error=str(e))

            elif action == "write_file":
                code = self._extract_code(goal)
                target = context.get("target_file")
                if not target:
                    return AgentStep(action=action, input_data=params, output_data={}, success=False, error="no target file")
                if self.sandbox.is_forbidden(target):
                    return AgentStep(action=action, input_data=params, output_data={}, success=False, error=f"FORBIDDEN: {target}")
                try:
                    with open(target, "w", encoding="utf-8", newline="\n") as f:
                        f.write(code)
                    context["files_written"].append(target)
                    return AgentStep(action=action, input_data={"file": target}, output_data={"file": target, "bytes": len(code)}, success=True)
                except (OSError, IOError) as e:
                    return AgentStep(action=action, input_data={"file": target}, output_data={}, success=False, error=str(e))

            elif action == "syntax_check_file":
                target = context.get("target_file")
                if not target:
                    return AgentStep(action=action, input_data=params, output_data={}, success=False, error="no target file")
                ok, msg, dur = self.zig_runner.syntax_check_file(target)
                return AgentStep(action=action, input_data={"file": target}, output_data={"valid": ok, "msg": msg, "duration_ms": dur}, success=ok, error="" if ok else msg)

            elif action == "fmt_file":
                target = context.get("target_file")
                if not target:
                    return AgentStep(action=action, input_data=params, output_data={}, success=False, error="no target file")
                ok, msg, dur = self.zig_runner.fmt_file(target)
                return AgentStep(action=action, input_data={"file": target}, output_data={"formatted": ok, "msg": msg, "duration_ms": dur}, success=True)

            elif action == "build_file":
                target = context.get("target_file")
                if not target:
                    return AgentStep(action=action, input_data=params, output_data={}, success=False, error="no target file")
                ok, msg, dur = self.zig_runner.build_file(target)
                return AgentStep(action=action, input_data={"file": target}, output_data={"built": ok, "msg": msg, "duration_ms": dur}, success=ok, error="" if ok else msg)

            elif action == "test_file":
                target = context.get("target_file")
                if not target:
                    return AgentStep(action=action, input_data=params, output_data={}, success=False, error="no target file")
                ok, msg, dur = self.zig_runner.test_file(target)
                return AgentStep(action=action, input_data={"file": target}, output_data={"tested": ok, "msg": msg, "duration_ms": dur}, success=ok, error="" if ok else msg)

            elif action == "verify":
                checks = {"goal": params.get("goal", "")}
                verify_passed = True
                for s in goal.steps:
                    if isinstance(s, AgentStep):
                        if s.action == "syntax_check" or s.action == "syntax_check_file":
                            checks["syntax_valid"] = s.output_data.get("valid", False)
                            if not s.output_data.get("valid"):
                                verify_passed = False
                        elif s.action == "build_file":
                            checks["build_valid"] = s.output_data.get("built", False)
                            if not s.output_data.get("built"):
                                verify_passed = False
                        elif s.action == "test_file":
                            checks["test_valid"] = s.output_data.get("tested", False)
                return AgentStep(action=action, input_data=params, output_data={"checks": checks, "passed": verify_passed}, success=verify_passed)

            elif action == "summarize":
                summary = self._summarize(goal)
                return AgentStep(action=action, input_data=params, output_data={"summary": summary}, success=True)

            else:
                return AgentStep(action=action, input_data=params, output_data={}, success=False, error=f"unknown action: {action}")

        except Exception as e:
            return AgentStep(action=action, input_data=params, output_data={}, success=False, error=str(e))

    def _extract_code(self, goal):
        for s in goal.steps:
            if isinstance(s, AgentStep) and "code" in s.output_data:
                return s.output_data["code"]
        return ""

    def _generate(self, prompt):
        import torch
        device = "cuda" if torch.cuda.is_available() else "cpu"
        ids = self.tokenizer.encode(prompt)
        if not ids:
            return ""
        x = torch.tensor([ids], dtype=torch.long, device=device)
        self.model.eval()
        with torch.no_grad():
            output = self.model.generate(x, max_new_tokens=256, temperature=0.2)
        return self.tokenizer.decode(output[0].tolist())

    def _verify(self, goal, context):
        syntax_ok = True
        build_ok = True
        test_ok = True
        for s in goal.steps:
            if isinstance(s, AgentStep):
                if s.action in ("syntax_check", "syntax_check_file") and not s.output_data.get("valid"):
                    syntax_ok = False
                elif s.action == "build_file" and not s.output_data.get("built"):
                    build_ok = False
                elif s.action == "test_file" and not s.output_data.get("tested"):
                    test_ok = False
        return syntax_ok and build_ok and test_ok

    def _summarize(self, goal):
        parts = []
        for s in goal.steps:
            if isinstance(s, AgentStep):
                if s.action == "search_knowledge" and s.output_data.get("count", 0) > 0:
                    parts.append(f"KB: {s.output_data['count']} facts")
                elif s.action == "search_source" and s.output_data.get("count", 0) > 0:
                    parts.append(f"Source: {s.output_data['count']} files")
                elif s.action == "read_file" and s.output_data.get("file"):
                    parts.append(f"Read: {s.output_data['file']} ({s.output_data.get('lines', '?')} lines)")
                elif s.action == "backup_file" and s.success:
                    parts.append("Backup: OK")
                elif s.action in ("generate_fix", "generate_code"):
                    parts.append(f"Generated: {s.output_data.get('chars', 0)} chars")
                elif s.action == "syntax_check" or s.action == "syntax_check_file":
                    parts.append(f"Syntax: {'PASS' if s.output_data.get('valid') else 'FAIL'}")
                elif s.action == "apply_patch":
                    parts.append(f"Patched: {s.output_data.get('file', '?')}")
                elif s.action == "write_file":
                    parts.append(f"Written: {s.output_data.get('file', '?')}")
                elif s.action == "fmt_file":
                    parts.append(f"Fmt: OK")
                elif s.action == "build_file":
                    parts.append(f"Build: {'PASS' if s.output_data.get('built') else 'FAIL'}")
                elif s.action == "test_file":
                    parts.append(f"Test: {'PASS' if s.output_data.get('tested') else 'FAIL'}")
                elif s.action == "verify":
                    parts.append(f"Verify: {'PASS' if s.output_data.get('passed') else 'FAIL'}")
        return "; ".join(parts) if parts else "No actions completed"


def main():
    print("C.7 AGENT RUNTIME — REAL EXECUTION")
    print("=" * 60)

    kb_path = AGENT_ROOT.parent / "memory"
    full_zig_path = kb_path / "full_zig"
    # Load BOTH knowledge blocks: B+ environment (memory/) and the full Zig
    # compiler source of truth (memory/full_zig/). The runtime retrieves the
    # full raw file from disk on demand (never copied into memory).
    kb_dirs = [kb_path, full_zig_path] if full_zig_path.exists() else [kb_path]
    knowledge = KnowledgeQuery(kb_dirs)
    print(f"Knowledge: facts={len(knowledge.facts)} concepts={len(knowledge.concepts)} relations={len(knowledge.relations)}")

    source_index = SourceIndex([Path(r"C:\Users\Local\zig"), Path(r"C:\B-Plus\zig")])
    print("Scanning source...")
    source_index.scan()
    print(f"Source: {len(source_index.files)} files")

    zig_runner = ZigRunner()
    print(f"Zig: {zig_runner.zig_exe}")

    print("\n--- Sandbox test ---")
    sandbox = Sandbox()
    test_file = WORKSPACE_ROOT / "test_sandbox.zig"
    WORKSPACE_ROOT.mkdir(parents=True, exist_ok=True)
    test_file.write_text("pub fn main() void {}", encoding="utf-8")
    backup = sandbox.snapshot(str(test_file))
    print(f"  snapshot: {backup}")
    test_file.write_text("pub fn main() void {}", encoding="utf-8")
    sandbox.restore(str(test_file))
    print(f"  restore: OK")
    print(f"  forbidden(C:\\B-Plus\\zig\\x.zig): {sandbox.is_forbidden('C:\\B-Plus\\zig\\x.zig')}")
    print(f"  forbidden(workspace\\x.zig): {sandbox.is_forbidden(str(WORKSPACE_ROOT / 'x.zig'))}")

    print("\n--- Zig toolchain test ---")
    code = 'const std = @import("std");\npub fn main() void { std.debug.print("hello\\n", .{}); }'
    ok, msg, dur = zig_runner.syntax_check_code(code)
    print(f"  syntax_check_code: {ok} ({dur:.0f}ms)")
    ok, msg, dur = zig_runner.syntax_check_code("pub fn broken(")
    print(f"  syntax_check_code(broken): {ok} {msg[:60]}")

    print("\n--- Audit log test ---")
    audit = AuditLog()
    audit.log("test_action", {"x": 1}, {"y": 2}, True, 42.5)
    audit.log("fail_action", {"x": 1}, {}, False, 1.0)
    print(f"  summary: {audit.summary()}")

    print("\n--- Runtime ready ---")
    print("Integration: load model checkpoint, then execute goals")


if __name__ == "__main__":
    main()
