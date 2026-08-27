import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import (
    EVIDENCE_PATH,
    FACTS_PATH,
    GRAPH_PATH,
    INDEX_PATH,
    MEMORY_DIR,
    RELATIONS_PATH,
    SEMANTIC_RELATIONS_PATH,
    SYMBOLS_PATH,
    CONCEPTS_PATH,
    ZIG_ROOT,
    iter_zig_files,
    load_json,
    save_json,
    sha256_file,
    short_id,
)
from source_snapshot import SNAPSHOT_PATH, SourceSnapshot

CHUNK_SIZE = 10


def _extract_file_symbols(path, digest):
    import re
    FN_RX = re.compile(
        r'pub\s+fn\s+(\w+)\s*\(([^)]*)\)\s*([^{=\n]*)'
    )
    CONST_RX = re.compile(r'pub\s+const\s+(\w+)\s*[:=]')
    TYPE_ALIASE_RX = re.compile(
        r'pub\s+const\s+(\w+)\s*=\s*([\w.]+)\s*;'
    )
    VAR_RX = re.compile(r'pub\s+var\s+(\w+)\s*[:=]')
    FIELD_RX = re.compile(r'^\s+(\w+)\s*:', re.MULTILINE)
    CONTAINER_KINDS = {"struct", "enum", "union"}

    path_str = str(path)
    file_id = short_id("FI", path_str, digest)

    from common import read_lines
    lines = read_lines(path)
    text = "\n".join(lines)

    symbols = []

    def _sig(raw):
        parts = [p.strip() for p in raw.split(",") if p.strip()]
        out = []
        for p in parts:
            name_p = p.split(":")[0].strip() if ":" in p else ""
            type_p = p.split(":", 1)[1].strip() if ":" in p else ""
            out.append({"name": name_p, "type": type_p})
        return out

    for m in FN_RX.finditer(text):
        name = m.group(1)
        params = m.group(2)
        ret = m.group(3).strip()
        start = text[:m.start()].count("\n") + 1
        end = start + (m.group(0).count("\n"))
        ev_id = short_id("EV", path_str, name, start, end)
        symbols.append({
            "symbol_id": short_id("SY", path_str, name, start),
            "name": name,
            "kind": "function",
            "source_file": path_str,
            "file_id": file_id,
            "line_start": start,
            "line_end": end,
            "evidence_id": ev_id,
            "signature_raw": m.group(0).split("{")[0].strip(),
            "params": _sig(params),
            "return_type": ret or None,
        })

    for m in CONST_RX.finditer(text):
        name = m.group(1)
        start = text[:m.start()].count("\n") + 1
        end = start + (m.group(0).count("\n"))
        ev_id = short_id("EV", path_str, name, start, end)
        symbols.append({
            "symbol_id": short_id("SY", path_str, name, start),
            "name": name,
            "kind": "constant",
            "source_file": path_str,
            "file_id": file_id,
            "line_start": start,
            "line_end": end,
            "evidence_id": ev_id,
            "signature_raw": m.group(0),
            "params": [],
            "return_type": None,
        })

    for m in TYPE_ALIASE_RX.finditer(text):
        name = m.group(1)
        target = m.group(2)
        start = text[:m.start()].count("\n") + 1
        end = start + (m.group(0).count("\n"))
        ev_id = short_id("EV", path_str, name, start, end)
        symbols.append({
            "symbol_id": short_id("SY", path_str, name, start),
            "name": name,
            "kind": "type_alias",
            "source_file": path_str,
            "file_id": file_id,
            "line_start": start,
            "line_end": end,
            "evidence_id": ev_id,
            "signature_raw": m.group(0),
            "params": [],
            "return_type": target,
        })

    for m in VAR_RX.finditer(text):
        name = m.group(1)
        start = text[:m.start()].count("\n") + 1
        end = start + (m.group(0).count("\n"))
        ev_id = short_id("EV", path_str, name, start, end)
        symbols.append({
            "symbol_id": short_id("SY", path_str, name, start),
            "name": name,
            "kind": "variable",
            "source_file": path_str,
            "file_id": file_id,
            "line_start": start,
            "line_end": end,
            "evidence_id": ev_id,
            "signature_raw": m.group(0),
            "params": [],
            "return_type": None,
        })

    for m in CONTAINER_KINDS:
        pattern = re.compile(
            r'pub\s+' + m + r'\s+(\w+)\s*\{', re.MULTILINE
        )
        for cm in pattern.finditer(text):
            name = cm.group(1)
            start = text[:cm.start()].count("\n") + 1
            brace = text.find("{", cm.start())
            end = text[:brace].count("\n") + 1 if brace != -1 else start
            ev_id = short_id("EV", path_str, name, start, end)
            symbols.append({
                "symbol_id": short_id("SY", path_str, name, start),
                "name": name,
                "kind": m,
                "source_file": path_str,
                "file_id": file_id,
                "line_start": start,
                "line_end": end,
                "evidence_id": ev_id,
                "signature_raw": cm.group(0),
                "params": [],
                "return_type": None,
            })

    symbols.sort(key=lambda s: (s["line_start"], s["name"]))
    return symbols, file_id


def _extract_file_evidence(path, lines):
    evidence = []
    chunk_size = CHUNK_SIZE
    for i in range(0, len(lines), chunk_size):
        chunk_lines = lines[i:i + chunk_size]
        ls = i + 1
        le = min(i + chunk_size, len(lines))
        ev_id = short_id("EV", str(path), ls, le)
        evidence.append({
            "id": ev_id,
            "source_file": str(path),
            "line_start": ls,
            "line_end": le,
            "text": "\n".join(chunk_lines),
            "sha256": sha256_file(path),
        })
    return evidence


def _rebuild_source_layer(root, dirty_paths, old_index_doc):
    new_entries = []
    existing_by_path = {e["path"]: e for e in old_index_doc["files"]}
    files_needed = iter_zig_files(root)
    path_set = {str(p) for p in files_needed}
    for fp in files_needed:
        fp_str = str(fp)
        if fp_str in dirty_paths:
            from common import IMPORT_RE, read_lines
            digest = sha256_file(fp)
            lines = read_lines(fp)
            import os as _os
            st = _os.stat(fp)
            text = "\n".join(lines)
            new_entries.append({
                "id": short_id("FI", fp_str, digest),
                "path": fp_str,
                "language": "zig",
                "type": "module",
                "size": st.st_size,
                "sha256": digest,
                "line_count": len(lines),
                "non_empty_lines": sum(1 for l in lines if l.strip()),
                "imports": IMPORT_RE.findall(text),
            })
        else:
            existing = existing_by_path.get(fp_str)
            if existing:
                new_entries.append(existing)
    new_entries.sort(key=lambda e: e["path"])
    new_index_doc = {
        "schema": "source_index",
        "version": 1,
        "root": str(root),
        "file_count": len(new_entries),
        "files": new_entries,
    }
    return new_index_doc


def _rebuild_symbols_layer(root, dirty_paths, old_symbols_doc):
    existing_syms = old_symbols_doc["items"]
    syms_by_file = {}
    for s in existing_syms:
        syms_by_file.setdefault(s["source_file"], []).append(s)
    new_syms = []
    for fp in iter_zig_files(root):
        fp_str = str(fp)
        if fp_str in dirty_paths:
            from common import sha256_file as _sha
            digest = _sha(fp)
            file_syms, _ = _extract_file_symbols(fp, digest)
            new_syms.extend(file_syms)
        else:
            new_syms.extend(syms_by_file.get(fp_str, []))
    new_syms.sort(key=lambda s: (s["source_file"], s["line_start"], s["name"]))
    return {
        "schema": "source_symbols",
        "version": 1,
        "root": str(root),
        "symbol_count": len(new_syms),
        "items": new_syms,
    }


def _rebuild_evidence_layer(root, dirty_paths, old_evidence_doc):
    existing_ev = old_evidence_doc["items"]
    ev_by_file = {}
    for e in existing_ev:
        ev_by_file.setdefault(e["source_file"], []).append(e)
    new_ev = []
    from common import read_lines as _rl
    for fp in iter_zig_files(root):
        fp_str = str(fp)
        if fp_str in dirty_paths:
            lines = _rl(fp)
            new_ev.extend(_extract_file_evidence(fp, lines))
        else:
            new_ev.extend(ev_by_file.get(fp_str, []))
    new_ev.sort(key=lambda e: (e["source_file"], e["line_start"]))
    return {
        "schema": "source_evidence",
        "version": 1,
        "root": str(root),
        "chunk_count": len(new_ev),
        "items": new_ev,
    }


class IncrementalPipeline:
    def __init__(self, root=None, memory_dir=None, snapshot_path=None):
        self.root = str(root or ZIG_ROOT)
        self.memory_dir = Path(memory_dir) if memory_dir else MEMORY_DIR
        self.snapshot_path = Path(snapshot_path) if snapshot_path else SNAPSHOT_PATH

    def run(self):
        t0 = time.time()
        old_snap = SourceSnapshot.load(self.snapshot_path)
        new_snap = SourceSnapshot.build(self.root)
        diff = old_snap.compare(new_snap) if old_snap else {
            "added": list(new_snap.files.keys()),
            "removed": [],
            "modified": [],
            "unchanged": [],
            "renamed": [],
            "dirty": True,
            "dirty_count": len(new_snap.files),
            "total": len(new_snap.files),
        }
        t_snapshot = time.time() - t0
        if not diff["dirty"]:
            return {
                "status": "unchanged",
                "files_changed": 0,
                "total_files": diff["total"],
                "time_snapshot": round(t_snapshot, 3),
                "time_rebuild": 0,
                "time_total": round(t_snapshot, 3),
                "old_tree_sha": diff["old_tree_sha"],
                "new_tree_sha": diff["new_tree_sha"],
                "artifacts": {},
            }
        dirty_rel = set(diff["added"] + diff["removed"] + diff["modified"])
        dirty_paths = {os.path.normpath(os.path.join(self.root, p)) for p in dirty_rel}
        t1 = time.time()
        old_index = load_json(self.memory_dir / "source_index.json")
        old_symbols = load_json(self.memory_dir / "source_symbols.json")
        old_evidence = load_json(self.memory_dir / "source_evidence.json")
        t_load = time.time() - t1
        t2 = time.time()
        new_index = _rebuild_source_layer(self.root, dirty_paths, old_index)
        save_json(self.memory_dir / "source_index.json", new_index)
        t_index = time.time() - t2
        t3 = time.time()
        new_symbols = _rebuild_symbols_layer(self.root, dirty_paths, old_symbols)
        save_json(self.memory_dir / "source_symbols.json", new_symbols)
        t_symbols = time.time() - t3
        t4 = time.time()
        new_evidence = _rebuild_evidence_layer(self.root, dirty_paths, old_evidence)
        save_json(self.memory_dir / "source_evidence.json", new_evidence)
        t_evidence = time.time() - t4
        t5 = time.time()
        self._rebuild_downstream()
        t_downstream = time.time() - t5
        t6 = time.time()
        self._validate()
        t_validate = time.time() - t6
        new_snap.save(self.snapshot_path)
        t_total = time.time() - t0
        return {
            "status": "updated",
            "files_changed": diff["dirty_count"],
            "total_files": diff["total"],
            "added": list(diff["added"]),
            "removed": list(diff["removed"]),
            "modified": list(diff["modified"]),
            "renamed": diff["renamed"],
            "time_snapshot": round(t_snapshot, 3),
            "time_load": round(t_load, 3),
            "time_index": round(t_index, 3),
            "time_symbols": round(t_symbols, 3),
            "time_evidence": round(t_evidence, 3),
            "time_downstream": round(t_downstream, 3),
            "time_validate": round(t_validate, 3),
            "time_total": round(t_total, 3),
            "old_tree_sha": diff.get("old_tree_sha", ""),
            "new_tree_sha": diff["new_tree_sha"],
            "artifacts": {
                "index": new_index["file_count"],
                "symbols": new_symbols["symbol_count"],
                "evidence": new_evidence["chunk_count"],
            },
        }

    def _rebuild_downstream(self):
        from source_store import SourceStore
        import facts as facts_mod
        import concepts as concepts_mod
        import relations as rels_mod
        import graph as graph_mod

        store = SourceStore.load(self.memory_dir)
        errs = store.validate(deep=True)
        if errs:
            raise RuntimeError(f"source layer integrity error: {len(errs)} errors")

        src_dir = os.path.dirname(os.path.abspath(__file__))
        import subprocess
        result = subprocess.run(
            [sys.executable, os.path.join(src_dir, "source_relations.py")],
            capture_output=True, text=True, cwd=src_dir,
            timeout=120,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"source_relations rebuild failed: {result.stderr[:300]}"
            )

        store2 = SourceStore.load(self.memory_dir)

        items = facts_mod.build_facts(store2)
        facts_doc = {
            "schema": "facts",
            "version": 1,
            "root": store2.index_doc["root"],
            "fact_count": len(items),
            "items": items,
        }
        save_json(self.memory_dir / "facts.json", facts_doc)

        concepts_items = concepts_mod.build_concepts(store2, facts_doc)
        concepts_doc = {
            "schema": "concepts",
            "version": 1,
            "root": store2.index_doc["root"],
            "concept_count": len(concepts_items),
            "items": concepts_items,
        }
        save_json(self.memory_dir / "concepts.json", concepts_doc)

        rels_items, rels_meta = rels_mod.build_relations(store2, facts_doc, concepts_doc)
        rels_doc = {
            "schema": "semantic_relations",
            "version": 1,
            "root": store2.index_doc["root"],
            "relation_count": len(rels_items),
            "items": rels_items,
        }
        save_json(self.memory_dir / "semantic_relations.json", rels_doc)

        graph_built = graph_mod.build_graph(
            facts_doc, concepts_doc, rels_doc,
            files=store2.files_by_path,
        )
        graph_doc = {
            "schema": "knowledge_graph",
            "version": 1,
            "root": store2.index_doc["root"],
            "concept_count": concepts_doc["concept_count"],
            "relation_count": rels_doc["relation_count"],
            "indexes": graph_built["indexes"],
        }
        save_json(self.memory_dir / "graph.json", graph_doc)

    def _validate(self):
        from source_store import SourceStore
        store = SourceStore.load(self.memory_dir)
        errs = store.validate(deep=True)
        if errs:
            raise RuntimeError(
                f"post-incremental validation failed: {len(errs)} errors: "
                + "; ".join(errs[:5])
            )


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--full", action="store_true")
    args = parser.parse_args()
    if args.full:
        from pathlib import Path
        snap = SourceSnapshot.build()
        snap.save()
        print("FULL_SNAPSHOT:", len(snap.files))
        sys.exit(0)
    pipe = IncrementalPipeline()
    result = pipe.run()
    print("STATUS:", result["status"])
    print("FILES_CHANGED:", result["files_changed"])
    print("TOTAL_FILES:", result["total_files"])
    print("TIME_TOTAL:", result["time_total"])
    if result["status"] == "updated":
        print("ADDED:", result["added"])
        print("REMOVED:", result["removed"])
        print("MODIFIED:", result["modified"])
        print("RENAMED:", result["renamed"])
    sys.exit(0)


if __name__ == "__main__":
    main()
