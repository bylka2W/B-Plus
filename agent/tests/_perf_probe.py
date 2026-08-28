import ctypes
import json
import sys


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


STAGES = {
    "mem_base": "",
    "mem_imports": ("import common, source_store, graph, search, "
                    "query, context, answer, router, verify, "
                    "knowledge"),
    "mem_store": ("from source_store import SourceStore; "
                  "KEEP.append(SourceStore.load())"),
    "mem_graph": ("from graph import KnowledgeGraph; "
                  "KEEP.append(KnowledgeGraph.load())"),
    "mem_knowledge": ("from knowledge import Knowledge; "
                      "KEEP.append(Knowledge.load())"),
    "mem_full_suite_style": ("from knowledge import Knowledge; "
                             "from verify import VerifyEngine; "
                             "KEEP.append(Knowledge.load()); "
                             "KEEP.append(VerifyEngine.load())"),
}


def measure():
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


def main():
    stage = sys.argv[1]
    if stage not in STAGES:
        raise SystemExit("unknown stage")
    sys.path.insert(0, r"C:\B-Plus\agent\engine")
    ns = {"KEEP": []}
    exec(compile(STAGES[stage], "<stage:%s>" % stage, "exec"), ns)
    out = measure()
    out["objects_kept"] = len(ns["KEEP"])
    print(json.dumps(out))
    sys.exit(0)


if __name__ == "__main__":
    main()
