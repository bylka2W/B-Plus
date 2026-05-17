namespace BPlusTranspiler.Algorithm;

public class InstructionScheduler
{
    public class InstInfo
    {
        public string Inst { get; set; } = "";
        public int Latency { get; set; }
        public bool DependsOnMemory { get; set; }
        public bool IsMemoryLoad { get; set; }
        public string[] Dependencies { get; set; } = [];
    }

    public class ScheduleResult
    {
        public List<string> Scheduled { get; set; } = new();
        public int TotalCycles { get; set; }
        public int FillRate { get; set; }
        public string[] Suggestions { get; set; } = [];
    }

    private static readonly (string inst, int latency, bool mem)[] IntelLatency =
    {
        ("add", 1, false), ("sub", 1, false), ("imul", 3, false),
        ("idiv", 20, false), ("mov", 1, false), ("movzx", 1, false),
        ("load", 4, true), ("store", 1, true), ("cmp", 1, false),
        ("test", 1, false), ("call", 10, false)
    };

    public ScheduleResult Schedule(List<InstInfo> instructions, int iqSize = 64)
    {
        var result = new ScheduleResult();
        var ready = new List<InstInfo>();
        var pending = new List<InstInfo>(instructions);
        int cycle = 0;
        int slots = iqSize;

        while (pending.Count > 0 || ready.Count > 0)
        {
            foreach (var p in pending.Where(i => !i.DependsOnMemory && CanDispatch(i, ready)))
                ready.Add(p);
            pending.RemoveAll(i => ready.Contains(i));

            if (ready.Count == 0)
            {
                if (pending.Count > 0)
                {
                    result.Scheduled.Add($"    ; stall cycle {cycle}");
                    cycle++;
                    slots = iqSize;
                    continue;
                }
                break;
            }

            int dispatch = Math.Min(slots, ready.Count);
            for (int i = 0; i < dispatch; i++)
            {
                var inst = ready[i];
                result.Scheduled.Add($"    {inst.Inst} ; cycle {cycle}");
                cycle += inst.Latency;
            }
            ready.RemoveRange(0, dispatch);
            slots -= dispatch;
            if (slots <= 0) { cycle++; slots = iqSize; }
        }

        result.TotalCycles = cycle;
        result.FillRate = instructions.Count > 0 ? (result.Scheduled.Count - result.Scheduled.Count(s => s.Contains("stall"))) * 100 / result.Scheduled.Count : 0;
        result.Suggestions = GenerateSuggestions(result);

        return result;
    }

    private bool CanDispatch(InstInfo inst, List<InstInfo> ready)
    {
        if (inst.Dependencies.Length == 0) return true;
        return inst.Dependencies.All(d => ready.Any(r => r.Inst.Contains(d)));
    }

    private string[] GenerateSuggestions(ScheduleResult r)
    {
        var suggestions = new List<string>();
        if (r.FillRate < 70) suggestions.Add("Increase ILP: unroll loop 2x");
        if (r.TotalCycles > 100) suggestions.Add("Break critical path with register renaming");
        if (r.Scheduled.Any(s => s.Contains("stall"))) suggestions.Add("Add prefetch to eliminate stalls");
        return suggestions.ToArray();
    }

    public string Optimize(string asm)
    {
        var lines = asm.Split('\n').Where(l => !string.IsNullOrWhiteSpace(l)).ToArray();
        var instructions = new List<InstInfo>();

        foreach (var line in lines)
        {
            string inst = line.Trim().TrimStart('.');
            if (string.IsNullOrEmpty(inst) || inst.StartsWith(";")) continue;

            var info = ParseInstruction(inst);
            if (info != null) instructions.Add(info);
        }

        var result = Schedule(instructions);
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("; Instruction schedule (optimized)");
        foreach (var s in result.Scheduled)
            sb.AppendLine(s);
        return sb.ToString();
    }

    private InstInfo? ParseInstruction(string inst)
    {
        string lower = inst.ToLower();
        foreach (var (name, lat, mem) in IntelLatency)
        {
            if (lower.Contains(name))
            {
                return new InstInfo
                {
                    Inst = inst,
                    Latency = lat,
                    IsMemoryLoad = mem && lower.Contains("load"),
                    DependsOnMemory = mem
                };
            }
        }
        return new InstInfo { Inst = inst, Latency = 1, DependsOnMemory = false };
    }
}
