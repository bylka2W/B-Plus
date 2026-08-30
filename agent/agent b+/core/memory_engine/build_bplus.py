r"""Build the B+ knowledge pyramid from C:\B-Plus and benchmark each tier.

Excludes third-party / binary blobs (venv, .git, checkpoints, models) so the
project knowledge stays meaningful; binaries are recorded as METADATA only.
Produces a dense store + WARM/HOT indexes, then measures retrieval latency:
  HOT (exact-ID LRU) / WARM (name index) / COLD (mmap column) / SOURCE (file).
"""
import os
import sys
import time
import hashlib

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from core.memory_engine.store import MemoryStore
from core.memory_engine.extractors import extract
from core.memory_engine.index import KnowledgeIndex
from core.memory_engine.knowledge_query import KnowledgeQuery

ROOT = r"C:\B-Plus"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "store_data")

EXCLUDE_DIRS = {".git", "venv", "__pycache__", "checkpoints", "node_modules", ".hg"}
EXCLUDE_EXT = {".pt", ".bin", ".gguf", ".onnx", ".dll", ".exe", ".so", ".dylib",
               ".png", ".jpg", ".jpeg", ".gif", ".zip", ".gz", ".tar", ".wav",
               ".mp3", ".npy", ".ckpt", ".ttf", ".otf", ".pdf"}
TEXT_EXT = {".zig", ".py", ".pyi", ".json", ".toml", ".ini", ".yaml", ".yml",
            ".md", ".markdown", ".txt", ".bat", ".sh", ".b+", ".c", ".h",
            ".cpp", ".hpp", ".rs", ".js", ".ts", ".html", ".css", ".modelfile",
            ".jsonc", ".cfg", ".toml"}
MAX_TEXT = 2 * 1024 * 1024  # skip full extraction beyond 2 MB (metadata only)


def kind_of(ext):
    return {
        ".zig": "zig", ".py": "py", ".pyi": "py", ".json": "json",
        ".toml": "toml", ".ini": "ini", ".yaml": "yaml", ".yml": "yaml",
        ".md": "md", ".markdown": "md", ".txt": "txt", ".bat": "bat",
        ".sh": "sh", ".b+": "bplus", ".c": "c", ".h": "c", ".cpp": "cpp",
        ".hpp": "cpp", ".rs": "rs", ".js": "js", ".ts": "ts", ".html": "html",
        ".css": "css", ".modelfile": "modelfile", ".jsonc": "json", ".cfg": "ini",
    }.get(ext, "text")


def main():
    store = MemoryStore()
    name_to_syms = {}            # global name -> [sid]
    file_syms = []               # (fid, [(sid, name, l0, l1)])
    file_calls = []              # (fid, [(lineno, callee)])
    file_imports = []            # (fid, [target_path])

    n_files = n_bin = 0
    t_build = time.monotonic()
    for dirpath, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
        for fn in files:
            ext = os.path.splitext(fn)[1].lower()
            full = os.path.join(dirpath, fn)
            try:
                stt = os.stat(full)
            except Exception:
                continue
            if ext in EXCLUDE_EXT or stt.st_size > MAX_TEXT and ext not in TEXT_EXT:
                # binary / oversized -> metadata only
                if ext in EXCLUDE_EXT or stt.st_size > MAX_TEXT:
                    fid = store.add_file(full, "binary", _h(str(stt.st_size)), stt.st_size, int(stt.st_mtime_ns), 0)
                    n_bin += 1
                    continue
            if ext not in TEXT_EXT:
                # unknown text-ish: record as text metadata if small enough
                if stt.st_size > MAX_TEXT:
                    store.add_file(full, "binary", _h(str(stt.st_size)), stt.st_size, int(stt.st_mtime_ns), 0)
                    n_bin += 1
                    continue
            try:
                with open(full, "rb") as f:
                    raw = f.read()
            except Exception:
                continue
            text = raw.decode("utf-8", "replace")
            ftype = kind_of(ext)
            fid = store.add_file(full, ftype, _h(raw[:1024]), stt.st_size, int(stt.st_mtime_ns), text.count("\n") + 1)
            # line-offset index: byte offset of each line start (for O(1) SOURCE spans)
            offsets = [0]
            for i in range(len(raw)):
                if raw[i] == 10:  # '\n'
                    offsets.append(i + 1)
            store.add_line_offsets(fid, offsets)
            n_files += 1
            rec = extract(full, text, ext)
            f_syms = []
            for (name, kind, l0, l1) in rec["symbols"]:
                sid = store.add_symbol(fid, name, kind, l0, l1)
                name_to_syms.setdefault(name, []).append(sid)
                f_syms.append((sid, name, l0, l1))
                store.add_evidence(fid, sid, "DEFINITION", l0, l1, _h(f"{name}@{l0}"))
            file_syms.append((fid, f_syms))
            file_calls.append((fid, rec["calls"]))
            file_imports.append((fid, [t for (_, t) in rec["imports"]]))
    # relations
    n_decl = n_call = n_imp = 0
    for fid, f_syms in file_syms:
        for (sid, name, l0, l1) in f_syms:
            store.add_relation("DECLARES", 1, fid, 0, sid)
            n_decl += 1
    for fid, calls in file_calls:
        # resolve enclosing symbol per call
        spans = [s for (f, ss) in file_syms if f == fid for s in ss]
        for (lineno, callee) in calls:
            caller = _enclosing(spans, lineno)
            targets = name_to_syms.get(callee)
            if caller is not None and targets:
                store.add_relation("CALLS", 0, caller[0], 0, targets[0])
                n_call += 1
    for fid, imps in file_imports:
        for tgt in imps:
            tfid = store.file_id(tgt)
            if tfid is not None:
                store.add_relation("IMPORTS", 1, fid, 1, tfid)
                n_imp += 1
    print(f"[build] files(text)={n_files} binaries={n_bin} symbols={len(store.s_file)} "
          f"relations={n_decl + n_call + n_imp} evidence={len(store.e_sym)} "
          f"in {round(time.monotonic() - t_build, 1)}s")
    store.save(OUT)

    # ---- index + hot ----
    idx = KnowledgeIndex(store)
    idx.seed_hot_by_degree(top_k=5000)
    kq = KnowledgeQuery(idx)

    # ---- benchmark tiers ----
    print("\n=== LATENCY BENCHMARK (per tier) ===")
    # HOT: query a name that is in HOT
    hot_name = next(iter(idx.hot.data)) if idx.hot.data else None
    if hot_name:
        _warm(kq, hot_name)
        t = _avg(lambda: _warm(kq, hot_name))
        print(f"HOT     exact-ID LRU   : {t*1000:.3f} ms  (query='{hot_name}')")
    # WARM: a random symbol name not necessarily hot
    import random
    rname = random.choice(list(idx.name_to_syms.keys()))
    t = _avg(lambda: _warm(kq, rname))
    print(f"WARM    name index      : {t*1000:.3f} ms  (query='{rname}')")
    # COLD: mmap column random read
    cold = MemoryStore.mmap_open(OUT)
    sid = random.randrange(len(cold.s_file))
    t = _avg(lambda: (cold.s_name[sid], cold.s_line0[sid]))
    print(f"COLD    mmap column     : {t*1000:.3f} ms  (symbol#{sid})")
    # SOURCE: file line read for an evidence span
    eid = random.randrange(len(cold.e_sym))
    fid = cold.e_file[eid]; l0 = cold.e_line0[eid]; l1 = cold.e_line1[eid]
    t = _avg(lambda: kq._read_source(fid, l0, l1))
    print(f"SOURCE  file line read  : {t*1000:.3f} ms  (file#{fid}:{l0}-{l1})")
    # end-to-end
    for q in ("allocator", "GPUScheduler", "Model", "config", "test", "KnowledgeQuery"):
        r = kq.retrieve(q)
        print(f"QUERY   '{q}' -> {len(r['matches'])} matches, total {r['total_ms']:.3f} ms "
              f"(hot {r['tiers_ms']['hot']*1000:.3f}, warm {r['tiers_ms']['warm']*1000:.3f}, "
              f"source {r['tiers_ms']['source']*1000:.3f})")


def _h(s):
    if isinstance(s, str):
        s = s.encode("utf-8", "replace")
    return hashlib.md5(s).hexdigest()[:16]


def _enclosing(spans, lineno):
    best = None
    for (sid, name, l0, l1) in spans:
        if l0 <= lineno <= l1:
            return (sid, name, l0, l1)
        if l0 <= lineno and (best is None or l0 > best[2]):
            best = (sid, name, l0, l1)
    return best


def _warm(kq, name):
    return kq.retrieve(name, with_source=False)


def _avg(fn, n=200):
    # one cold run, then n timed
    fn()
    t0 = time.perf_counter()
    for _ in range(n):
        fn()
    return (time.perf_counter() - t0) / n


if __name__ == "__main__":
    main()
