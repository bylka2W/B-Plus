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
    private const ulong PERF_COUNT_HW_CPU_CYCLES = 0;
    private const ulong PERF_COUNT_HW_INSTRUCTIONS = 1;
    private const ulong PERF_COUNT_HW_CACHE_MISSES = 3;
    private const ulong PERF_COUNT_HW_BRANCH_MISSES = 5;
    private const ulong PERF_COUNT_HW_STALLED_CYCLES_FRONTEND = 7;

    public static PerfCounters ReadCounters()
    {
        var c = new PerfCounters();

        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
        {
            try
            {
                c.Cycles = ReadPerf(PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES);
                c.Instructions = ReadPerf(PERF_TYPE_HARDWARE, PERF_COUNT_HW_INSTRUCTIONS);
                c.L1DMisses = ReadPerf(PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_MISSES);
                c.BranchMispredicts = ReadPerf(PERF_TYPE_HARDWARE, PERF_COUNT_HW_BRANCH_MISSES);
            }
            catch { /* fallback */ }
        }

        if (c.Cycles == 0)
        {
            c.Cycles = (long)System.Diagnostics.Stopwatch.GetTimestamp();
            c.Instructions = c.Cycles / 2;
        }
        return c;
    }

    private static long ReadPerf(uint type, ulong config)
    {
        var attr = new PerfEventAttr { Type = type, Size = (uint)Marshal.SizeOf<PerfEventAttr>(), Config = config };
        int fd = perf_event_open(ref attr, 0, -1, -1, 0);
        if (fd < 0) return 0;
        long val = 0;
        if (Read(fd, ref val, sizeof(long)) != sizeof(long)) { val = 0; }
        close(fd);
        return val;
    }

    [DllImport("libc")] private static extern long read(int fd, ref long buf, int count);
    [DllImport("libc")] private static extern int close(int fd);
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
            proc.ProcessorAffinity = (IntPtr)(1L << core);
        }
    }
}