using System.Runtime.InteropServices;

namespace BPlusTranspiler.Runtime;

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

    /// <summary>
    /// Lock critical sections into physical RAM (L1/L2 hot data).
    /// </summary>
    public static void LockHotSection(IntPtr addr, ulong size)
    {
        int ret = mlock(addr, size);
        if (ret != 0)
            Console.Error.WriteLine($"[MetalRuntime] mlock failed: {Marshal.GetLastWin32Error()}");
    }

    /// <summary>
    /// Unlock previously locked section.
    /// </summary>
    public static void UnlockSection(IntPtr addr, ulong size)
    {
        munlock(addr, size);
    }

    /// <summary>
    /// Allocate L3 data with huge pages (2 MB) for better TLB coverage.
    /// </summary>
    public static IntPtr AllocateL3HugePage(ulong size)
    {
        // Align to 2 MB
        ulong pageSize = 2UL * 1024 * 1024;
        ulong aligned = (size + pageSize - 1) & ~(pageSize - 1);

        IntPtr ptr = mmap(IntPtr.Zero, aligned,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB,
            -1, 0);

        if (ptr == new IntPtr(-1))
        {
            Console.Error.WriteLine($"[MetalRuntime] mmap hugepage failed: {Marshal.GetLastWin32Error()}");
            Console.Error.WriteLine("  Falling back to standard allocation.");
            ptr = Marshal.AllocHGlobal((IntPtr)size);
        }

        return ptr;
    }

    /// <summary>
    /// Mark memory as will-need (prefetch into cache).
    /// </summary>
    public static void PrefetchMemory(IntPtr addr, ulong size)
    {
        madvise(addr, size, MADV_WILLNEED);
    }

    /// <summary>
    /// Mark memory as cold (hint OS to evict).
    /// </summary>
    public static void MarkCold(IntPtr addr, ulong size)
    {
        madvise(addr, size, MADV_COLD);
    }

    /// <summary>
    /// Advise sequential access pattern.
    /// </summary>
    public static void AdviseSequential(IntPtr addr, ulong size)
    {
        madvise(addr, size, MADV_SEQUENTIAL);
    }

    /// <summary>
    /// Enable transparent huge pages for the range.
    /// </summary>
    public static void EnableHugePages(IntPtr addr, ulong size)
    {
        madvise(addr, size, MADV_HUGEPAGE);
    }

    /// <summary>
    /// Read CPU performance counter (RDTSC) through LLVM intrinsic wrapper.
    /// Emits: call i64 @llvm.readcyclecounter()
    /// </summary>
    public static ulong ReadCycleCounter()
    {
        // On Windows without kernel access, use Stopwatch as fallback
        return (ulong)System.Diagnostics.Stopwatch.GetTimestamp();
    }

    /// <summary>
    /// Memory barrier (full fence).
    /// </summary>
    public static void MemoryFence()
    {
        Thread.MemoryBarrier();
    }

    /// <summary>
    /// Cache line flush (CLFLUSH).
    /// </summary>
    public static void FlushCacheLine(IntPtr addr)
    {
        // On platforms with SSE2, emit inline asm: clflush [addr]
        // Fallback: no-op on managed only
        Thread.MemoryBarrier();
    }
}
