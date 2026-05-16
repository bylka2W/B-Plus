namespace BPlusTranspiler.AI;

public class CycleScheduler
{
    private static readonly (string inst, int latency, double throughput)[] IntelTable =
    {
        ("add", 1, 1.0), ("sub", 1, 1.0), ("imul", 3, 1.0), ("idiv", 20, 1.0),
        ("mov", 1, 1.0), ("movzx", 1, 1.0), ("load", 4, 1.0), ("store", 1, 1.0),
        ("cmp", 1, 1.0), ("test", 1, 1.0), ("and", 1, 1.0), ("or", 1, 1.0),
        ("shl", 1, 1.0), ("shr", 1, 1.0), ("call", 10, 1.0), ("ret", 4, 1.0),
        ("vaddps", 4, 0.5), ("vmulps", 4, 0.5), ("vfmadd", 4, 0.5)
    };

    public class ScheduleEntry
    {
        public string Inst { get; set; } = "";
        public int Cycle { get; set; }
        public int Port { get; set; }
        public bool IsBottleneck { get; set; }
    }

    public class ScheduleResult
    {
        public List<ScheduleEntry> Schedule { get; set; } = new();
        public int TotalCycles { get; set; }
        public double Ipc { get; set; }
        public string Bottleneck { get; set; } = "";
    }

    public ScheduleResult ScheduleCycle(string[] instructions, int iqSize = 64)
    {
        var result = new ScheduleResult();
        int cycle = 0;
        int portsUsed = 0;
        int[] portCount = { 0, 0, 0, 0, 0, 0 };

        foreach (var inst in instructions)
        {
            var info = GetInstInfo(inst);
if (info == null) continue;

            int lat = info.Value.latency;
            double tp = info.Value.throughput;
            int port = cycle % 6;
            result.Schedule.Add(new ScheduleEntry
            {
                Inst = inst,
                Cycle = cycle,
                Port = port,
                IsBottleneck = tp < 1.0
            });

            cycle += lat;
            portsUsed++;
            portCount[port]++;
        }

        result.TotalCycles = cycle;
        result.Ipc = instructions.Length / Math.Max(1, cycle);

        int maxPort = 0;
        for (int i = 1; i < 6; i++)
            if (portCount[i] > portCount[maxPort]) maxPort = i;

        string[] portNames = { "P015", "P1", "P2", "P3", "P4", "P5" };
        result.Bottleneck = portCount[maxPort] > instructions.Length / 4
            ? $"Port {portNames[maxPort]} ({portCount[maxPort]} instructions)"
            : "No bottleneck detected";

        return result;
    }

    private (int latency, double throughput)? GetInstInfo(string inst)
    {
        string lower = inst.ToLower();
        foreach (var entry in IntelTable)
        {
            if (lower.Contains(entry.inst))
            {
                var result = (entry.latency, entry.throughput);
                return result;
            }
        }
        return (1, 1.0);
    }

    public string GenerateHeader(ScheduleResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Cycle scheduler");
        sb.AppendLine($"#define BPLUS_SCHEDULE_CYCLES {r.TotalCycles}");
        sb.AppendLine($"#define BPLUS_SCHEDULE_IPC {r.Ipc:F2}");
        sb.AppendLine($"// Bottleneck: {r.Bottleneck}");
        sb.AppendLine();
        sb.AppendLine("// Port mappings:");
        sb.AppendLine("// P015: ALU, load, store");
        sb.AppendLine("// P1: ALU, FMA");
        sb.AppendLine("// P2/P3: Store address/data");
        sb.AppendLine("// P4/P5: Branch, ALU");
        return sb.ToString();
    }

    public string OptimizeBottleneck(string[] instructions, string bottleneck)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("; Cycle schedule optimized for " + bottleneck);

        if (bottleneck.Contains("P1"))
        {
            sb.AppendLine("; P1 bottleneck detected: use P015 for ALU ops");
            foreach (var inst in instructions)
            {
                if (inst.ToLower().Contains("imul") || inst.ToLower().Contains("vfmadd"))
                    sb.AppendLine(inst + " ; schedule on P015");
                else
                    sb.AppendLine(inst);
            }
        }
        else
        {
            foreach (var inst in instructions)
                sb.AppendLine(inst);
        }

        return sb.ToString();
    }
}