import ctypes
import json
import os
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.join(os.path.dirname(HERE), "engine")
MEMORY = os.path.join(os.path.dirname(HERE), "memory")
BASELINE_PATH = os.path.join(MEMORY, "perf_baseline.json")
PROBE_PATH = os.path.join(HERE, "_perf_probe.py")
sys.path.insert(0, ENGINE)

INTENTS = [
    ("DEFINITION", "Где определён foldConstantOp?", "foldConstantOp"),
    ("CALLERS", "Кто вызывает foldConstantOp?", "foldConstantOp"),
    ("CALLEES", "Что вызывает foldConstantOp?", "foldConstantOp"),
    ("REFERENCES", "Где используется AstVisitor?", "AstVisitor"),
    ("USES_TYPE", "Какие типы использует foldConstantOp?",
     "foldConstantOp"),
    ("TYPE_USERS", "Кто использует тип Arena?", "Arena"),
    ("CONTAINS", "Что содержит AccumulationConstants?",
     "AccumulationConstants"),
    ("DEPENDENCIES", "От чего зависит x64gen.zig?", "x64gen.zig"),
    ("DEPENDENTS", "Кто зависит от x64gen.zig?", "x64gen.zig"),
    ("MODULE", "Модуль x64gen.zig", "x64gen.zig"),
    ("FILE", r"Файл C:\B-Plus\zig\build.zig",
     r"C:\B-Plus\zig\build.zig"),
]

BOOT = "import sys; sys.path.insert(0, r'%s')" % ENGINE
COLD_STAGES = {
    "python_boot": "pass",
    "imports": BOOT + ("; import common, source_store, graph, search, "
                       "query, context, answer, router, verify, "
                       "knowledge"),
    "store": BOOT + ("; from source_store import SourceStore; "
                     "SourceStore.load()"),
    "graph": BOOT + ("; from graph import KnowledgeGraph; "
                     "KnowledgeGraph.load()"),
    "search": BOOT + "; from search import Search; Search.load()",
    "query": BOOT + ("; from query import QueryEngine; "
                     "QueryEngine.load()"),
    "knowledge": BOOT + ("; from knowledge import Knowledge; "
                         "Knowledge.load()"),
    "verify": BOOT + ("; from verify import VerifyEngine; "
                      "VerifyEngine.load()"),
    "full_suite_style": BOOT + ("; from knowledge import Knowledge; "
                                "from verify import VerifyEngine; "
                                "Knowledge.load(); VerifyEngine.load()"),
}
MEM_STAGES = ["mem_base", "mem_imports", "mem_store", "mem_graph",
              "mem_knowledge", "mem_full_suite_style"]


class PMC(ctypes.Structure):
    _fields_ = [
        ("cb", ctypes.c_ulong),
        ("PageFaultCount", ctypes.c_ulong),
        ("PeakWorkingSetSize", ctypes.c_size_t),
        ("WorkingSetSize", ctypes.c_size_t),
        ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
        ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
        ("PagefileUsage", ctypes.c_size_t),
        ("PeakPagefileUsage", ctypes.c_size_t),
    ]


def rss_mb():
    pmc = PMC()
    pmc.cb = ctypes.sizeof(PMC)
    kernel32 = ctypes.WinDLL("kernel32")
    psapi = ctypes.WinDLL("psapi")
    kernel32.GetCurrentProcess.restype = ctypes.c_void_p
    psapi.GetProcessMemoryInfo.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(PMC), ctypes.c_ulong]
    handle = kernel32.GetCurrentProcess()
    if not psapi.GetProcessMemoryInfo(handle, ctypes.byref(pmc), pmc.cb):
        raise OSError("GetProcessMemoryInfo failed")
    return {"rss_mb": round(pmc.WorkingSetSize / (1024 * 1024), 1),
            "peak_rss_mb": round(pmc.PeakWorkingSetSize / (1024 * 1024),
                                 1)}


def pct(samples, q):
    s = sorted(samples)
    return s[min(len(s) - 1, int(q * (len(s) - 1)))]


def stats(samples):
    return {"p50": round(pct(samples, 0.50), 3),
            "p95": round(pct(samples, 0.95), 3),
            "p99": round(pct(samples, 0.99), 3),
            "mean": round(statistics.fmean(samples), 3)}


def run_cold(repeats=3):
    out = {}
    for name, code in COLD_STAGES.items():
        times = []
        for _ in range(repeats):
            t0 = time.perf_counter()
            subprocess.run([sys.executable, "-X", "utf8", "-c", code],
                           check=True,
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
            times.append((time.perf_counter() - t0) * 1000)
        out[name] = stats(times)
    boot = out["python_boot"]["p50"]
    net = {name: {k: max(0.0, round(v - boot, 3)) for k, v in st.items()}
           for name, st in out.items()}
    return {"wall": out, "net_of_interpreter": net,
            "interpreter_boot_p50_ms": boot}


def run_memory():
    out = {}
    for stage in MEM_STAGES:
        r = subprocess.run(
            [sys.executable, "-X", "utf8", PROBE_PATH, stage],
            capture_output=True, text=True, check=True)
        out[stage] = json.loads(r.stdout.strip().splitlines()[-1])
    return out


def artifact_sizes():
    sizes = {}
    for fn in sorted(os.listdir(MEMORY)):
        p = os.path.join(MEMORY, fn)
        if os.path.isfile(p):
            sizes[fn] = os.path.getsize(p)
    return sizes


def run_warm(iters=100):
    from knowledge import Knowledge
    from verify import VerifyEngine
    k = Knowledge.load()
    ve = VerifyEngine.load()
    qe = k.ae.cb.qe
    micro_samples = {
        "find_symbol": [], "find_module": [], "find_file": [],
        "evidence_get": [], "fact_get": [],
    }
    eid = next(iter(ve.cb.store.evidence_by_id))
    fid = next(iter(ve.cb.facts))
    for _ in range(max(iters, 500)):
        for name, fn_args in (
                ("find_symbol", (qe.search.find_symbol,
                                 "foldConstantOp")),
                ("find_module", (qe.search.find_module, "x64gen.zig")),
                ("find_file", (qe.search.find_file,
                               r"C:\B-Plus\zig\build.zig"))):
            fn, arg = fn_args
            t0 = time.perf_counter()
            fn(arg)
            micro_samples[name].append((time.perf_counter() - t0) * 1000)
        t0 = time.perf_counter()
        ve.cb.store.evidence_by_id.get(eid)
        micro_samples["evidence_get"].append(
            (time.perf_counter() - t0) * 1000)
        t0 = time.perf_counter()
        ve.cb.facts.get(fid)
        micro_samples["fact_get"].append((time.perf_counter() - t0) * 1000)
    micro = {name: stats(s) for name, s in micro_samples.items()}

    res = {}
    for intent, question, entity in INTENTS:
        route_s, query_s, answer_s, verify_s, ask_s = ([] for _ in range(5))
        for i in range(iters):
            t0 = time.perf_counter()
            d = k.route(question)
            route_s.append((time.perf_counter() - t0) * 1000)
            assert d["status"] == "ROUTED"
            t0 = time.perf_counter()
            qe.query(intent, entity)
            query_s.append((time.perf_counter() - t0) * 1000)
            t0 = time.perf_counter()
            model = k.ae.answer(intent, entity, question=question)
            answer_s.append((time.perf_counter() - t0) * 1000)
            t0 = time.perf_counter()
            vres = ve.verify_answer(model)
            verify_s.append((time.perf_counter() - t0) * 1000)
            assert vres["overall"] == "VERIFIED", intent
            t0 = time.perf_counter()
            k.ask(question)
            ask_s.append((time.perf_counter() - t0) * 1000)
        res[intent] = {
            "route": stats(route_s),
            "query": stats(query_s),
            "answer": stats(answer_s),
            "verify": stats(verify_s),
            "ask_end_to_end": stats(ask_s),
        }
    return res, micro


def main():
    report = {
        "schema": "performance_baseline",
        "version": 1,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "source_root": r"C:\B-Plus\zig",
        "iterations_warm": 100,
        "cold": run_cold(),
        "memory_rss_mb": run_memory(),
        "artifact_bytes": artifact_sizes(),
    }
    warm, micro = run_warm(100)
    report["warm"] = warm
    report["micro"] = micro
    with open(BASELINE_PATH, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=1)
    c = report["cold"]["net_of_interpreter"]
    m = report["memory_rss_mb"]
    print("=== COLD net of interpreter %.0f ms" %
          report["cold"]["interpreter_boot_p50_ms"])
    for name in ("imports", "store", "graph", "search", "query",
                 "knowledge", "verify", "full_suite_style"):
        print("%18s p50=%9.1f ms p95=%9.1f ms" %
              (name, c[name]["p50"], c[name]["p95"]))
    print("=== MEMORY RSS / PEAK MB")
    for name in MEM_STAGES:
        v = m[name]
        print("%22s %9.1f %9.1f" % (name, v["rss_mb"],
                                    v["peak_rss_mb"]))
    ab = report["artifact_bytes"]
    print("=== ARTIFACTS %.1f MB total" % (sum(ab.values()) / 1048576))
    for name, b in sorted(ab.items(), key=lambda kv: -kv[1])[:8]:
        print("%38s %8.2f MB" % (name, b / 1048576))
    print("=== WARM p95 ms")
    print("%-14s %8s %8s %8s %8s %8s" %
          ("intent", "route", "query", "answer", "verify", "ask"))
    for intent, _q, _e in INTENTS:
        w = report["warm"][intent]
        print("%-14s %8.2f %8.2f %8.2f %8.2f %8.2f" %
              (intent[:14], w["route"]["p95"], w["query"]["p95"],
               w["answer"]["p95"], w["verify"]["p95"],
               w["ask_end_to_end"]["p95"]))
    print("=== MICRO p50/p95 ms")
    for name, st in micro.items():
        print("%16s %.4f / %.4f" % (name, st["p50"], st["p95"]))
    print("BASELINE_SAVED:", BASELINE_PATH)
    sys.exit(0)


if __name__ == "__main__":
    main()
