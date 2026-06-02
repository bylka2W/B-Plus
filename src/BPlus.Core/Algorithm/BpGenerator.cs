using System.Text;

namespace BPlus.Core.Algorithm;

public class BpGenerator
{
    private static readonly ThreadLocal<Random> _rng = new(() => new Random());

    public static string GenerateProgram(int? seed = null)
    {
        var r = seed.HasValue ? new Random(seed.Value) : _rng.Value!;
        int stateCount = r.Next(3, 20);
        int maxVarsPerState = r.Next(0, 10);
        int maxTransitionsPerState = r.Next(1, 8);
        int maxEnterLines = r.Next(0, 20);

        var stateNames = new List<string>();
        for (int i = 0; i < stateCount; i++)
            stateNames.Add($"State_{i + 1}");

        var sb = new StringBuilder();
        sb.AppendLine("// Auto-generated B+ program for AI training");
        sb.AppendLine();

        if (r.NextDouble() < 0.3)
        {
            int pCount = r.Next(2, 5);
            sb.AppendLine("parallel {");
            for (int p = 0; p < pCount; p++)
            {
                sb.AppendLine("    [");
                int innerStates = r.Next(1, 4);
                for (int i = 0; i < innerStates; i++)
                {
                    string name = $"Par{p}_S{i}";
                    stateNames.Add(name);
                    EmitState(sb, name, stateNames, r, maxVarsPerState, maxTransitionsPerState, maxEnterLines);
                }
                sb.AppendLine("    ]");
            }
            sb.AppendLine("}");
            sb.AppendLine();
        }

        foreach (var name in stateNames)
        {
            if (name.StartsWith("Par")) continue;
            EmitState(sb, name, stateNames, r, maxVarsPerState, maxTransitionsPerState, maxEnterLines);
        }

        if (r.NextDouble() < 0.5)
        {
            sb.AppendLine();
            int kernelCount = r.Next(1, 4);
            for (int k = 0; k < kernelCount; k++)
            {
                sb.AppendLine($"kernel kernel_{k + 1}(id: i32) -> (result: f32) {{");
                int ops = r.Next(3, 15);
                for (int o = 0; o < ops; o++)
                    sb.AppendLine($"    t{o} = id + {r.Next(1, 100)};");
                sb.AppendLine($"    return t{ops - 1};");
                sb.AppendLine("}");
            }
        }

        return sb.ToString();
    }

    private static void EmitState(StringBuilder sb, string name, List<string> allStates,
        Random r, int maxVars, int maxTrans, int maxEnter)
    {
        if (r.NextDouble() < 0.1) return;

        var annotations = new List<string>();
        if (r.NextDouble() < 0.3) annotations.Add("@hot");
        else if (r.NextDouble() < 0.3) annotations.Add("@cold");
        if (r.NextDouble() < 0.2) annotations.Add("@parallel");
        if (r.NextDouble() < 0.15) annotations.Add("@fast_path");

        foreach (var ann in annotations)
            sb.AppendLine($"    {ann}");

        sb.AppendLine($"state {name} {{");

        int varCount = r.Next(0, maxVars + 1);
        var varNames = new List<string>();
        for (int v = 0; v < varCount; v++)
        {
            string vn = $"v_{v}";
            varNames.Add(vn);
            string type = r.Next(4) switch { 0 => "i32", 1 => "f32", 2 => "bool", _ => "i64" };
            sb.AppendLine($"    {type} {vn} = {r.Next(0, 100)};");
        }

        int enterLines = r.Next(0, maxEnter + 1);
        if (enterLines > 0)
        {
            sb.AppendLine("    enter {");
            for (int l = 0; l < enterLines; l++)
            {
                var op = r.Next(5);
                if (varNames.Count == 0) op = 0;
                switch (op)
                {
                    case 0: sb.AppendLine($"        {varNames[r.Next(varNames.Count)]} = {varNames[r.Next(varNames.Count)]} + {r.Next(1, 20)};"); break;
                    case 1: sb.AppendLine($"        {varNames[r.Next(varNames.Count)]} = {varNames[r.Next(varNames.Count)]} * {r.Next(1, 10)};"); break;
                    case 2: if (varNames.Count >= 2) sb.AppendLine($"        if ({varNames[0]} > {varNames[1]}) {{}}"); break;
                    case 3: sb.AppendLine($"        for i in 0..{r.Next(1, 20)} {{}}"); break;
                    default: sb.AppendLine($"        {varNames[r.Next(varNames.Count)]} = {r.Next(0, 1000)};"); break;
                }
            }
            sb.AppendLine("    }");
        }

        int transCount = r.Next(1, maxTrans + 1);
        for (int t = 0; t < transCount; t++)
        {
            var target = allStates[r.Next(allStates.Count)];
            if (r.NextDouble() < 0.3)
            {
                sb.AppendLine($"    always -> {target};");
            }
            else
            {
                string ev = r.Next(4) switch { 0 => "ev_a", 1 => "ev_b", 2 => "ev_c", _ => "ev_d" };
                if (varNames.Count > 0 && r.NextDouble() < 0.4)
                    sb.AppendLine($"    on {ev} when {varNames[r.Next(varNames.Count)]} > {r.Next(0, 50)} -> {target};");
                else
                    sb.AppendLine($"    on {ev} -> {target};");
            }
        }

        if (r.NextDouble() < 0.1)
        {
            sb.AppendLine($"    after {r.Next(1, 100)} -> {allStates[r.Next(allStates.Count)]};");
        }

        sb.AppendLine("}");
        sb.AppendLine();
    }

    public static void GenerateDataset(string outputDir, int count = 50, int? seed = null)
    {
        Directory.CreateDirectory(outputDir);
        for (int i = 0; i < count; i++)
        {
            int s = seed.HasValue ? seed.Value + i : i;
            string src = GenerateProgram(s);
            string path = Path.Combine(outputDir, $"gen_{i:D4}.bp");
            File.WriteAllText(path, src);
        }
    }
}
