using System.Runtime.InteropServices;

namespace BPlusTranspiler.Runtime;

public struct PerfCounters
{
    public long Cycles;
    public long Instructions;
    public long L1DMisses;
    public long L2Misses;
    public long L3Misses;
    public long BranchMispredicts;
    public long StoreForwardStalls;
    public long ResourceStalls;
    public long LoadStalls;
    public long StoreStalls;
    public long RsFullCycles;
    public long LdResConflict;
    public long MachineClearCycles;
}

public static class PerfCounterReader
{
    [DllImport("libc", SetLastError = true)]
    private static extern int perf_event_open(ref PerfEventAttr attr, int pid, int cpu, int groupFd, ulong flags);

    [StructLayout(LayoutKind.Sequential)]
    private struct PerfEventAttr
    {
        public uint Type;
        public uint Size;
        public ulong Config;
        public ulong SamplePeriod, SampleType, ReadFormat, Disabled, Inherit, Pinned, Exclusive, ExcludeUser, ExcludeKernel, ExcludeHV, ExcludeIdle, Mmap, Comm, Freq, InheritStat, EnableOnExec, Task, Watermark, PreciseIP, MmapData, SampleIDHi, WakeupEvents, WakeupWatermark, BuildID, ClockID, NumaNode;
    }

    private const int PERF_TYPE_HARDWARE = 0;
    private const int PERF_TYPE_HARDWARE_CACHE = 3;
    private const int PERF_TYPE_RAW = 4;
    private const int PERF_TYPE_SOFTWARE = 1;

    private const ulong PERF_COUNT_HW_CPU_CYCLES = 0;
    private const ulong PERF_COUNT_HW_INSTRUCTIONS = 1;
    private const ulong PERF_COUNT_HW_CACHE_MISSES = 3;
    private const ulong PERF_COUNT_HW_BRANCH_MISSES = 5;
    private const ulong PERF_COUNT_HW_STALLED_CYCLES_FRONTEND = 7;

    private const int PERF_COUNT_HW_CACHE_RESULT_L1D_LOAD = 0;
    private const int PERF_COUNT_HW_CACHE_RESULT_L1D_STORE = 1;

    private static readonly Lazy<int[]> _cachedFds = new(OpenAllCounters);

    private static int[] OpenAllCounters()
    {
        var configs = new ulong[] {
            PERF_COUNT_HW_CPU_CYCLES,
            PERF_COUNT_HW_INSTRUCTIONS,
            PERF_COUNT_HW_CACHE_MISSES,
            PERF_COUNT_HW_BRANCH_MISSES
        };
        var fds = new int[configs.Length];
        for (int i = 0; i < configs.Length; i++)
        {
            var attr = new PerfEventAttr
            {
                Type = PERF_TYPE_HARDWARE,
                Size = (uint)Marshal.SizeOf<PerfEventAttr>(),
                Config = configs[i]
            };
            fds[i] = perf_event_open(ref attr, 0, -1, -1, 0);
        }
        return fds;
    }

    private static readonly Lazy<int[]> _bufferFds = new(OpenBufferCounters);

    private static int[] OpenBufferCounters()
    {
        var fds = new int[6];
        var attrs = new PerfEventAttr[6];

        // Intel: Topdown slots (RS fullness proxy — cycles with uops not issued from RS)
        // PMC 0x02: RESOURCE_STALLS.SB (store buffer full)
        attrs[0] = new PerfEventAttr { Type = PERF_TYPE_RAW, Size = (uint)Marshal.SizeOf<PerfEventAttr>(), Config = 0xA2 }; // RS stalls (all)
        attrs[1] = new PerfEventAttr { Type = PERF_TYPE_RAW, Size = (uint)Marshal.SizeOf<PerfEventAttr>(), Config = 0xA1 }; // RS stalls (partial)
        // PMC 0x08: LOAD_HIT_STORE_FORWARD (store forwarding conflict)
        attrs[2] = new PerfEventAttr { Type = PERF_TYPE_RAW, Size = (uint)Marshal.SizeOf<PerfEventAttr>(), Config = 0x08 };
        // PMC 0x20C5: MACHINE_CLEAR resource stalls
        attrs[3] = new PerfEventAttr { Type = PERF_TYPE_RAW, Size = (uint)Marshal.SizeOf<PerfEventAttr>(), Config = 0x20C5 };
        // Load buffer stall cycles (Intel)
        attrs[4] = new PerfEventAttr { Type = PERF_TYPE_RAW, Size = (uint)Marshal.SizeOf<PerfEventAttr>(), Config = 0xA2 };
        // Store buffer full cycles
        attrs[5] = new PerfEventAttr { Type = PERF_TYPE_RAW, Size = (uint)Marshal.SizeOf<PerfEventAttr>(), Config = 0xA2 };

        for (int i = 0; i < 6; i++)
            fds[i] = perf_event_open(ref attrs[i], 0, -1, -1, 0);
        return fds;
    }

    public static PerfCounters ReadCounters()
    {
        var c = new PerfCounters();

        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux) && _cachedFds.Value[0] >= 0)
        {
            try
            {
                var fds = _cachedFds.Value;
                if (fds[0] >= 0) read(fds[0], ref c.Cycles, sizeof(long));
                if (fds[1] >= 0) read(fds[1], ref c.Instructions, sizeof(long));
                if (fds[2] >= 0) read(fds[2], ref c.L1DMisses, sizeof(long));
                if (fds[3] >= 0) read(fds[3], ref c.BranchMispredicts, sizeof(long));
            }
            catch { /* fallback */ }
        }

        // Read store/load buffer counters
        ReadBufferCounters(ref c);

        if (c.Cycles == 0)
        {
            c.Cycles = (long)System.Diagnostics.Stopwatch.GetTimestamp();
            c.Instructions = c.Cycles / 2;
        }
        return c;
    }

    private static void ReadBufferCounters(ref PerfCounters c)
    {
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Linux)) return;
        if (_bufferFds.Value[0] < 0) return;

        try
        {
            var fds = _bufferFds.Value;
            long raw0 = 0, raw1 = 0, raw2 = 0, raw3 = 0, raw4 = 0, raw5 = 0;
            if (fds[0] >= 0) read(fds[0], ref raw0, sizeof(long));
            if (fds[1] >= 0) read(fds[1], ref raw1, sizeof(long));
            if (fds[2] >= 0) read(fds[2], ref raw2, sizeof(long));
            if (fds[3] >= 0) read(fds[3], ref raw3, sizeof(long));
            if (fds[4] >= 0) read(fds[4], ref raw4, sizeof(long));
            if (fds[5] >= 0) read(fds[5], ref raw5, sizeof(long));

            c.ResourceStalls = raw0;
            c.LoadStalls = raw1;
            c.StoreForwardStalls = raw2;
            c.MachineClearCycles = raw3;
            c.RsFullCycles = raw4;
            c.LdResConflict = raw5;

            // Read L1 cache events
            TryReadCacheEvent(PERF_TYPE_HARDWARE_CACHE, 0xFF, 0x1, PERF_COUNT_HW_CACHE_RESULT_L1D_LOAD, ref c.L1DMisses);
            TryReadCacheEvent(PERF_TYPE_HARDWARE_CACHE, 0xFF, 0x1, PERF_COUNT_HW_CACHE_RESULT_L1D_STORE, ref c.StoreStalls);
        }
        catch { /* buffer counters not available */ }
    }

    private static void TryReadCacheEvent(int type, ulong op, int result, int eventId, ref long target)
    {
        try
        {
            var attr = new PerfEventAttr
            {
                Type = (uint)type,
                Size = (uint)Marshal.SizeOf<PerfEventAttr>(),
                Config = ((ulong)eventId << 0) | (op << 8) | ((ulong)result << 16)
            };
            int fd = perf_event_open(ref attr, 0, -1, -1, 0);
            if (fd >= 0)
            {
                long val = 0;
                read(fd, ref val, sizeof(long));
                close(fd);
                if (target == 0 || val < target) target = val;
            }
        }
        catch { }
    }

    public static BufferAnalysis AnalyzeBuffers(string bpFile)
    {
        var c = ReadCounters();
        double ipc = c.Cycles > 0 ? (double)c.Instructions / c.Cycles : 0;
        double stallRate = c.ResourceStalls > 0 && c.Cycles > 0
            ? (double)c.ResourceStalls / c.Cycles : 0;
        double sfStallRate = c.StoreForwardStalls > 0 && c.Instructions > 0
            ? (double)c.StoreForwardStalls / c.Instructions : 0;

        var analysis = new BufferAnalysis
        {
            StoreBufferFullRate = stallRate,
            StoreForwardStallRate = sfStallRate,
            LoadStallRate = c.LoadStalls > 0 && c.Cycles > 0
                ? (double)c.LoadStalls / c.Cycles : 0,
            RsFullRate = c.RsFullCycles > 0 && c.Cycles > 0
                ? (double)c.RsFullCycles / c.Cycles : 0,
            LdResConflictRate = c.LdResConflict > 0 && c.Instructions > 0
                ? (double)c.LdResConflict / c.Instructions : 0,
            Ipc = ipc,
            ResourceStalls = c.ResourceStalls,
            StoreForwardStalls = c.StoreForwardStalls,
            LoadStalls = c.LoadStalls,
            RawCounters = c
        };

        // Recommendations
        var recs = new List<string>();
        if (stallRate > 0.1)
            recs.Add("Store buffer >10% stall — consider batching stores");
        if (sfStallRate > 0.01)
            recs.Add("Store-forward stalls >1% — add nop or restructure memory pattern");
        if (c.LoadStalls > c.Cycles * 0.05)
            recs.Add("Load stalls >5% cycles — check TLB, add prefetch");
        if (c.RsFullCycles > c.Cycles * 0.03)
            recs.Add("Reservation station >3% full — reduce ILP chain length");
        if (c.LdResConflict > c.Instructions * 0.005)
            recs.Add("Load-store conflict detected — reorder memory operations");

        analysis.Recommendations = recs;
        return analysis;
    }

    public static string GenerateBufferReport(BufferAnalysis a)
    {
        var lines = new List<string>
        {
            "╔═══════════════════════════════════════════╗",
            "║      STORE/LOAD BUFFER PMC ANALYSIS      ║",
            "╚═══════════════════════════════════════════╝",
            $"  IPC:              {a.Ipc:F3}",
            $"  RS stall rate:    {a.StoreBufferFullRate:P1}",
            $"  Store fwd rate:   {a.StoreForwardStallRate:P2}",
            $"  Load stall rate: {a.LoadStallRate:P2}",
            $"  RS full rate:    {a.RsFullRate:P2}",
            $"  Ld/Res conflict: {a.LdResConflictRate:P3}",
            ""
        };
        if (a.Recommendations.Count > 0)
        {
            lines.Add("  Recommendations:");
            foreach (var r in a.Recommendations)
                lines.Add($"    • {r}");
        }
        else
        {
            lines.Add("  ✓ All buffer metrics nominal");
        }
        return string.Join("\n", lines);
    }

    [DllImport("libc")] private static extern long read(int fd, ref long buf, int count);
    [DllImport("libc")] private static extern int close(int fd);
}

// ─── L3 Heap Runtime ───

public class L3HeapRuntime
{
    private IntPtr _base;
    private ulong _capacity;
    private ulong _offset;
    private ulong _peak;
    private ulong _allocCount;
    private ulong _freeCount;
    private int _numaNode;
    private readonly object _lock = new();

    private const ulong DefaultHeapSize = 2 * 1024 * 1024; // 2 MB
    private const ulong HugePageSize = 2 * 1024 * 1024;
    private const ulong Alignment = 64;
    private const ulong GuardSize = 4096;

    public L3HeapRuntime(int numaNode = -1, ulong? heapSize = null)
    {
        _numaNode = numaNode;
        _capacity = heapSize ?? DefaultHeapSize;
        Init();
    }

    private void Init()
    {
        ulong alignedSize = (_capacity + HugePageSize - 1) & ~(HugePageSize - 1);
        ulong totalSize = alignedSize + (GuardSize > 0 ? GuardSize : 0);

        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
        {
            try
            {
                // Try 2MB huge pages
                _base = MMap(IntPtr.Zero, (IntPtr)totalSize,
                    MmapProt.ReadWrite, MmapFlags.Private | MmapFlags.Anonymous | MmapFlags.HugeTlb,
                    -1, 0);

                if (_base == IntPtr.Zero || _base == new IntPtr(-1))
                {
                    // Fallback: transparent huge pages
                    _base = MMap(IntPtr.Zero, (IntPtr)totalSize,
                        MmapProt.ReadWrite, MmapFlags.Private | MmapFlags.Anonymous,
                        -1, 0);
                    if (_base != IntPtr.Zero && _base != new IntPtr(-1))
                        Madvise(_base, (ulong)totalSize, MadviseFlags.HugePage);
                }

                if (_base == IntPtr.Zero || _base == new IntPtr(-1))
                    throw new Exception("mmap failed");
            }
            catch
            {
                _base = Marshal.AllocHGlobal((IntPtr)totalSize);
            }

            // NUMA bind
            if (_numaNode >= 0 && _base != IntPtr.Zero && _base != new IntPtr(-1))
            {
                try
                {
                    ulong mask = 1UL << _numaNode;
                    Mbind(_base, alignedSize, 2, new IntPtr((long)mask), (ulong)(_numaNode + 1), 0);
                }
                catch { /* NUMA not available */ }
            }
        }
        else
        {
            _base = Marshal.AllocHGlobal((IntPtr)totalSize);
        }

        // Guard page at end (detect overflow)
        if (GuardSize > 0 && _base != IntPtr.Zero && _base != new IntPtr(-1))
        {
            IntPtr guard = new IntPtr((long)_base + (long)alignedSize);
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
            {
                MMap(guard, (IntPtr)GuardSize, MmapProt.None,
                    MmapFlags.Private | MmapFlags.Anonymous | MmapFlags.Fixed,
                    -1, 0);
            }
        }

        Console.WriteLine($"[L3Heap] Initialized: {(alignedSize + GuardSize) / (1024*1024)} MB @ NUMA node {_numaNode}");
    }

    public IntPtr Alloc(ulong size)
    {
        if (_base == IntPtr.Zero || _base == new IntPtr(-1) || size == 0)
            return IntPtr.Zero;

        ulong aligned = (size + Alignment - 1) & ~(Alignment - 1);

        lock (_lock)
        {
            ulong next = _offset + aligned;
            if (next > _capacity)
            {
                Console.Error.WriteLine($"[L3Heap] OOM: requested {aligned} bytes, capacity {_capacity}, used {_offset}");
                return IntPtr.Zero;
            }

            IntPtr ptr = new IntPtr((long)_base + (long)_offset);
            _offset = next;
            if (_offset > _peak) _peak = _offset;
            _allocCount++;
            return ptr;
        }
    }

    public void Free(IntPtr ptr)
    {
        _freeCount++;
    }

    public void Reset()
    {
        lock (_lock)
        {
            _offset = 0;
        }
    }

    public void Destroy()
    {
        if (_base != IntPtr.Zero && _base != new IntPtr(-1))
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
            {
                try { MUnmap(_base, (IntPtr)((_capacity + HugePageSize - 1) & ~(HugePageSize - 1) + GuardSize)); }
                catch { Marshal.FreeHGlobal(_base); }
            }
            else
            {
                Marshal.FreeHGlobal(_base);
            }
        }
        _base = IntPtr.Zero;
        _offset = 0;
        _peak = 0;
    }

    public L3HeapStats GetStats()
    {
        lock (_lock)
        {
            return new L3HeapStats
            {
                Capacity = _capacity,
                Used = _offset,
                Peak = _peak,
                Allocations = _allocCount,
                Frees = _freeCount,
                NumaNode = _numaNode,
                Utilization = _capacity > 0 ? (double)_offset / _capacity * 100 : 0
            };
        }
    }

    public string GenerateStatsReport()
    {
        var s = GetStats();
        return $@"╔══════════════════════════════════════╗
║        L3-HEAP RUNTIME STATS        ║
╚══════════════════════════════════════╝
  Capacity:   {s.Capacity / (1024*1024)} MB ({s.Capacity} bytes)
  Used:       {s.Used / 1024} KB ({s.Used} bytes)
  Peak:       {s.Peak / 1024} KB ({s.Peak} bytes)
  Allocs:     {s.Allocations}
  Frees:      {s.Frees}
  NUMA node:  {s.NumaNode}
  Utilization: {s.Utilization:F1}%";
    }

    // P/Invoke declarations
    [DllImport("libc", SetLastError = true)]
    private static extern IntPtr mmap(IntPtr addr, IntPtr length, int prot, int flags, int fd, IntPtr offset);
    [DllImport("libc", SetLastError = true)]
    private static extern int munmap(IntPtr addr, IntPtr length);
    [DllImport("libc", SetLastError = true)]
    private static extern int madvise(IntPtr addr, IntPtr length, int advice);
    [DllImport("libc", SetLastError = true)]
    private static extern int mbind(IntPtr addr, ulong len, int mode, IntPtr nodemask, ulong maxnode, ulong flags);

    private static class MmapProt
    {
        public const int Read = 1;
        public const int Write = 2;
        public const int ReadWrite = Read | Write;
        public const int None = 0;
    }

    private static class MmapFlags
    {
        public const int Private = 0x02;
        public const int Anonymous = 0x20;
        public const int HugeTlb = 0x40000;
        public const int Fixed = 0x10;
    }

    private static class MadviseFlags
    {
        public const int Normal = 0;
        public const int Random = 1;
        public const int Sequential = 2;
        public const int WillNeed = 3;
        public const int HugePage = 14;
    }

    private static IntPtr MMap(IntPtr addr, IntPtr length, int prot, int flags, int fd, long offset)
        => mmap(addr, length, prot, flags, fd, new IntPtr(offset));

    private static void MUnmap(IntPtr addr, IntPtr length) => munmap(addr, length);
    private static void Madvise(IntPtr addr, ulong length, int advice) => madvise(addr, new IntPtr((long)length), advice);
    private static void Mbind(IntPtr addr, ulong len, int mode, IntPtr nodemask, ulong maxnode, ulong flags)
        => mbind(addr, len, mode, nodemask, maxnode, flags);
}

public class L3HeapStats
{
    public ulong Capacity { get; set; }
    public ulong Used { get; set; }
    public ulong Peak { get; set; }
    public ulong Allocations { get; set; }
    public ulong Frees { get; set; }
    public int NumaNode { get; set; }
    public double Utilization { get; set; }
}

public class BufferAnalysis
{
    public double StoreBufferFullRate { get; set; }
    public double StoreForwardStallRate { get; set; }
    public double LoadStallRate { get; set; }
    public double RsFullRate { get; set; }
    public double LdResConflictRate { get; set; }
    public double Ipc { get; set; }
    public long ResourceStalls { get; set; }
    public long StoreForwardStalls { get; set; }
    public long LoadStalls { get; set; }
    public List<string> Recommendations { get; set; } = new();
    public PerfCounters RawCounters { get; set; } = new();
}

public static class MetalRuntime
{
    [DllImport("libc", SetLastError = true)]
    private static extern int mlock(IntPtr addr, ulong len);

    [DllImport("libc", SetLastError = true)]
    private static extern int munlock(IntPtr addr, ulong len);

    [DllImport("libc", SetLastError = true)]
    private static extern int madvise(IntPtr addr, ulong len, int advice);

    [DllImport("libc", SetLastError = true)]
    private static extern IntPtr mmap(IntPtr addr, ulong length, int prot, int flags, int fd, ulong offset);

    [DllImport("libc", SetLastError = true)]
    private static extern int munmap(IntPtr addr, ulong length);

    [DllImport("libc", SetLastError = true)]
    private static extern long syscall(long number, long arg0, long arg1, long arg2, long arg3, long arg4, long arg5);

    [DllImport("libc", SetLastError = true)]
    private static extern int sched_setaffinity(int pid, IntPtr cpusetSize, ref ulong cpuset);

    [DllImport("libc", SetLastError = true)]
    private static extern int sched_setscheduler(int pid, int policy, ref SchedParam param);

    [StructLayout(LayoutKind.Sequential)]
    private struct SchedParam { public int sched_priority; }

    [DllImport("libc")]
    private static extern int mbind(IntPtr addr, ulong len, int mode, IntPtr nodemask, ulong maxnode, ulong flags);

    private const int PROT_READ = 0x1;
    private const int PROT_WRITE = 0x2;
    private const int MAP_PRIVATE = 0x02;
    private const int MAP_ANONYMOUS = 0x20;
    private const int MAP_HUGETLB = 0x40000;

    private const int MADV_NORMAL = 0;
    private const int MADV_RANDOM = 1;
    private const int MADV_SEQUENTIAL = 2;
    private const int MADV_WILLNEED = 3;
    private const int MADV_DONTFORK = 10;
    private const int MADV_HUGEPAGE = 14;
    private const int MADV_COLD = 20;
    private const int MADV_PAGEOUT = 21;
    private const int MADV_COLLAPSE = 25;

    private const int MPOL_PREFERRED = 1;
    private const int MPOL_BIND = 2;

    private const int SCHED_FIFO = 1;

    public static void LockHotSection(IntPtr addr, ulong size)
    {
        int ret = mlock(addr, size);
        if (ret != 0)
            Console.Error.WriteLine($"[MetalRuntime] mlock failed: {Marshal.GetLastWin32Error()}");
    }

    public static void UnlockSection(IntPtr addr, ulong size) { munlock(addr, size); }

    public static IntPtr AllocateL3HugePage(ulong size)
    {
        ulong pageSize = 2UL * 1024 * 1024;
        ulong aligned = (size + pageSize - 1) & ~(pageSize - 1);

        IntPtr ptr = mmap(IntPtr.Zero, aligned,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);

        if (ptr == new IntPtr(-1))
        {
            Console.Error.WriteLine($"[MetalRuntime] mmap hugepage failed: {Marshal.GetLastWin32Error()}, fallback alloc");
            ptr = Marshal.AllocHGlobal((IntPtr)size);
        }
        return ptr;
    }

    public static void PrefetchMemory(IntPtr addr, ulong size) { madvise(addr, size, MADV_WILLNEED); }
    public static void MarkCold(IntPtr addr, ulong size) { madvise(addr, size, MADV_COLD); }
    public static void AdviseSequential(IntPtr addr, ulong size) { madvise(addr, size, MADV_SEQUENTIAL); }
    public static void EnableHugePages(IntPtr addr, ulong size) { madvise(addr, size, MADV_HUGEPAGE); }
    public static void CollapseTHP(IntPtr addr, ulong size) { madvise(addr, size, MADV_COLLAPSE); }

    public static ulong ReadCycleCounter()
    {
        return (ulong)System.Diagnostics.Stopwatch.GetTimestamp();
    }

    public static void MemoryFence() { Thread.MemoryBarrier(); }

    public static void FlushCacheLine(IntPtr addr) { Thread.MemoryBarrier(); }

    /// <summary>Bind memory allocation to specific NUMA node.</summary>
    public static void BindToNumaNode(int node, IntPtr addr, ulong size)
    {
        ulong mask = 1UL << node;
        int ret = mbind(addr, size, MPOL_BIND, new IntPtr((long)mask), (ulong)(node + 1), 0);
        if (ret != 0)
            Console.Error.WriteLine($"[MetalRuntime] mbind to node {node} failed: {Marshal.GetLastWin32Error()}");
    }

    /// <summary>Pin current thread to specific CPU core, optionally disabling SMT.</summary>
    public static void PinToCore(int core, bool noSmt = false)
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
        {
            ulong mask = 1UL << core;
            int ret = sched_setaffinity(0, (IntPtr)sizeof(ulong), ref mask);
            if (ret != 0)
                Console.Error.WriteLine($"[MetalRuntime] pin to core {core} failed: {Marshal.GetLastWin32Error()}");

            // SCHED_FIFO for real-time isolation
            var sp = new SchedParam { sched_priority = 99 };
            ret = sched_setscheduler(0, SCHED_FIFO, ref sp);
            if (ret != 0)
                Console.Error.WriteLine($"[MetalRuntime] SCHED_FIFO failed: {Marshal.GetLastWin32Error()}");
        }
        else
        {
            var proc = System.Diagnostics.Process.GetCurrentProcess();
            if (OperatingSystem.IsWindows())
                proc.ProcessorAffinity = (IntPtr)(1L << core);
        }
    }
}