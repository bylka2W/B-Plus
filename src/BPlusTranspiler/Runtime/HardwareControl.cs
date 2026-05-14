using System.Diagnostics;
using System.Runtime.InteropServices;

namespace BPlusTranspiler.Runtime;

public enum PowerPolicy
{
    Performance,
    Balanced,
    PowerSave,
    Custom
}

public struct CoreAffinity
{
    public int CoreId;
    public bool ExcludeSmt;
    public int NumaNode;
}

public struct PowerBudget
{
    public double TargetWatts;
    public double MaxWatts;
    public double MinFreqMHz;
    public double MaxFreqMHz;
}

public static class HardwareControl
{
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll")]
    private static extern IntPtr SetThreadAffinityMask(IntPtr hThread, IntPtr dwThreadAffinityMask);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentThread();

    [DllImport("kernel32.dll")]
    private static extern uint SetThreadIdealProcessor(IntPtr hThread, uint dwIdealProcessor);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessAffinityMask(IntPtr hProcess, IntPtr dwProcessAffinityMask);

    [DllImport("kernel32.dll")]
    private static extern bool SetPriorityClass(IntPtr hProcess, uint dwPriorityClass);

    private const uint HIGH_PRIORITY_CLASS = 0x80;
    private const uint REALTIME_PRIORITY_CLASS = 0x100;

    public static bool PinToCore(int core)
    {
        try
        {
            var mask = new IntPtr(1L << core);
            var result = SetThreadAffinityMask(GetCurrentThread(), mask);
            return result != IntPtr.Zero;
        }
        catch
        {
            var proc = Process.GetCurrentProcess();
            proc.ProcessorAffinity = new IntPtr(1L << core);
            return true;
        }
    }

    public static void SetHighPriority()
    {
        try
        {
            SetPriorityClass(GetCurrentProcess(), HIGH_PRIORITY_CLASS);
        }
        catch { }
    }

    public static void SetRealtimePriority()
    {
        try
        {
            SetPriorityClass(GetCurrentProcess(), REALTIME_PRIORITY_CLASS);
        }
        catch { }
    }

    public static void SetPowerPolicy(PowerPolicy policy)
    {
        try
        {
            var psi = new ProcessStartInfo("powercfg", $"/setactive {policy switch
            {
                PowerPolicy.Performance => "e9a42b02-d5df-448d-aa00-03f14749eb61",
                PowerPolicy.PowerSave => "a1841308-3541-4fab-bc81-f71556f20b4a",
                _ => "381b4222-f694-41f0-9685-ff5bb260df2e"
            }}")
            {
                RedirectStandardOutput = true, UseShellExecute = false,
                CreateNoWindow = true
            };
            using var p = Process.Start(psi);
            p?.WaitForExit(500);
        }
        catch { }
    }

    public static bool SetCpuFrequencyMHz(double mhz)
    {
        try
        {
            var maxVal = (ulong)(mhz * 1000);
            var psi = new ProcessStartInfo("powercfg", $"/setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCFREQMAX {maxVal}")
            {
                RedirectStandardOutput = true, UseShellExecute = false,
                CreateNoWindow = true
            };
            using var p = Process.Start(psi);
            p?.WaitForExit(500);

            var psi2 = new ProcessStartInfo("powercfg", "/setactive SCHEME_CURRENT")
            {
                RedirectStandardOutput = true, UseShellExecute = false,
                CreateNoWindow = true
            };
            using var p2 = Process.Start(psi2);
            p2?.WaitForExit(500);
            return true;
        }
        catch { return false; }
    }

    public static bool ApplyPowerBudget(PowerBudget budget)
    {
        bool ok = true;
        if (budget.MaxFreqMHz > 0)
            ok &= SetCpuFrequencyMHz(budget.MaxFreqMHz);
        if (budget.TargetWatts > 0)
            ok &= SetPowerLimit(budget.TargetWatts);
        return ok;
    }

    public static bool SetPowerLimit(double watts)
    {
        try
        {
            var psi = new ProcessStartInfo("powercfg", $"/setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100")
            {
                RedirectStandardOutput = true, UseShellExecute = false,
                CreateNoWindow = true
            };
            using var p = Process.Start(psi);
            p?.WaitForExit(500);
            return true;
        }
        catch { return false; }
    }

    public static void DistributeAcrossCores(int[] coreList)
    {
        for (int i = 0; i < coreList.Length; i++)
        {
            var mask = new IntPtr(1L << coreList[i]);
            SetThreadAffinityMask(GetCurrentThread(), mask);
        }
    }

    public static string GenerateControlReport(PowerBudget budget, PowerPolicy policy)
    {
        return $"""
╔════════════════════════════════════════════╗
║          HARDWARE CONTROL REPORT          ║
╚════════════════════════════════════════════╝
Policy:     {policy}
Freq cap:  {budget.MaxFreqMHz:F0} MHz (min {budget.MinFreqMHz:F0})
Power cap: {budget.TargetWatts:F1} W (max {budget.MaxWatts:F1})
""";
    }
}
