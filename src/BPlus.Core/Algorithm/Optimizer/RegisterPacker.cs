using System;
using System.Collections.Generic;
using System.Linq;
using BPlus.Core.Ast;
using BPlus.Core.Algorithm;

namespace BPlus.Core.Algorithm.Optimizer
{
    public class RegisterPacker
    {
        public class PackedRegister
        {
            public string Register { get; set; } = "";
            public List<PackedField> Fields { get; set; } = new List<PackedField>();
            public int TotalBits => Fields.Sum(f => f.Bits);
        }

        public class PackedField
        {
            public string Name { get; set; } = "";
            public int Offset { get; set; }
            public int Bits { get; set; }
            public string ExtractionPattern { get; set; } = "";
            public int AccessCycle { get; set; }
            public List<string> DependsOn { get; set; } = new List<string>();
        }

        /// <summary>Dependency edge: src variable must be computed before dst.</summary>
        public class DepEdge
        {
            public string Src { get; set; } = "";
            public string Dst { get; set; } = "";
            public int Cycle { get; set; }
        }

        private Dictionary<string, List<AccessInfo>> accessPatterns = new Dictionary<string, List<AccessInfo>>();
        private List<DepEdge> depGraph = new List<DepEdge>();
        private UnpackPredictor? predictor;

        public class AccessInfo
        {
            public string VarName { get; set; } = "";
            public int Cycle { get; set; }
            public int BitWidth { get; set; }
        }

        public void AnalyzeAccessPatterns(List<StateDefNode> states)
        {
            accessPatterns.Clear();
            depGraph.Clear();

            foreach (var state in states)
            {
                var list = new List<AccessInfo>();
                int cycle = 0;
                string? lastWritten = null;

                foreach (var action in state.Actions)
                {
                    string body = action.Body;

                    // Detect variable writes: "var = expr" or "set var"
                    string? written = null;
                    if (body.Contains("="))
                    {
                        written = body.Split('=')[0].Trim();
                        var parts = body.Split('=');
                        if (parts.Length > 1)
                        {
                            // Read vars = everything after '=' that's a variable name
                            var readVars = ExtractVarNames(parts[1]);
                            foreach (var rv in readVars)
                            {
                                if (rv != written)
                                    depGraph.Add(new DepEdge { Src = rv, Dst = written, Cycle = cycle });
                            }
                        }
                    }

                    if (written != null)
                    {
                        list.Add(new AccessInfo { VarName = written, Cycle = cycle++, BitWidth = 64 });
                        lastWritten = written;
                    }
                }
                accessPatterns[state.Name] = list;
            }
        }

        /// <summary>Extract variable names from an expression body.</summary>
        private static List<string> ExtractVarNames(string expr)
        {
            var vars = new List<string>();
            var words = expr.Split(new[] { ' ', '+', '-', '*', '/', '(', ')', ',', ';', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            foreach (var w in words)
                if (w.Length > 0 && char.IsLetter(w[0]) && !char.IsUpper(w[0]))
                    vars.Add(w);
            return vars;
        }

        /// <summary>Check if two variables have a dependency conflict.</summary>
        private bool HasDepConflict(string a, string b)
        {
            return depGraph.Any(d =>
                (d.Src == a && d.Dst == b) ||  // a must be before b
                (d.Src == b && d.Dst == a) ||  // b must be before a
                (d.Src == a && d.Src == b)     // both depend on same src
            );
        }

        public List<PackedRegister> PackRegisters(List<StateDefNode> states, string targetReg = "rax")
        {
            var packed = new List<PackedRegister>();
            var pr = new PackedRegister { Register = targetReg };

            int currentOffset = 0;
            var allAccesses = new List<(AccessInfo acc, string stateName)>();

            foreach (var state in states)
            {
                if (!accessPatterns.ContainsKey(state.Name)) continue;
                var accesses = accessPatterns[state.Name]
                    .OrderBy(a => a.Cycle).ToList();

                // Check dependencies BEFORE packing
                var safeAccesses = new List<AccessInfo>();
                foreach (var acc in accesses)
                {
                    bool hasConflict = safeAccesses.Any(existing =>
                        HasDepConflict(existing.VarName, acc.VarName));

                    if (!hasConflict)
                    {
                        safeAccesses.Add(acc);
                    }
                    else
                    {
                        Console.WriteLine($"  [dep] {acc.VarName} depends on {safeAccesses.Last().VarName} → separate register");
                    }
                }

                foreach (var acc in safeAccesses)
                {
                    int bits = Math.Min(acc.BitWidth, 64 - currentOffset);
                    if (bits <= 0) break;

                    var deps = depGraph
                        .Where(d => d.Dst == acc.VarName)
                        .Select(d => d.Src)
                        .ToList();

                    var field = new PackedField
                    {
                        Name = acc.VarName,
                        Offset = currentOffset,
                        Bits = bits,
                        AccessCycle = acc.Cycle,
                        ExtractionPattern = PredictExtraction(acc.Cycle, bits, currentOffset),
                        DependsOn = deps
                    };
                    pr.Fields.Add(field);
                    currentOffset += bits;
                }
            }

            // Check for serialization stalls in the packed register
            for (int i = 0; i < pr.Fields.Count; i++)
            {
                for (int j = i + 1; j < pr.Fields.Count; j++)
                {
                    if (pr.Fields[j].DependsOn.Contains(pr.Fields[i].Name))
                    {
                        Console.WriteLine($"  ⚠ serialization stall: {pr.Fields[j].Name} depends on {pr.Fields[i].Name} in same {targetReg}");
                        Console.WriteLine($"    → insert 2+ independent instructions between them or split to separate register");
                    }
                }
            }

            packed.Add(pr);
            return packed;
        }

        public string PredictExtraction(int cycle, int bits, int offset)
        {
            if (predictor == null && System.IO.File.Exists("ai_models/unpack.nn"))
            {
                try { predictor = UnpackPredictor.Load("ai_models/unpack.nn"); }
                catch { predictor = null; }
            }
            if (predictor != null)
            {
                var x = new double[] { cycle / 10.0, bits / 64.0, offset / 64.0, bits > 32 ? 1 : 0,
                    bits % 8 == 0 ? 1 : 0, bits % 16 == 0 ? 1 : 0, bits % 32 == 0 ? 1 : 0,
                    cycle < 3 ? 1 : 0, 1, 64, 0, offset % 8 == 0 ? 1 : 0 };
                var pred = predictor.Forward(x);
                int best = 0;
                for (int i = 1; i < 4; i++)
                    if (pred[i] > pred[best]) best = i;
                return best switch
                {
                    0 => "movzx",
                    1 => "shr",
                    2 => "vpermq",
                    3 => "vextract",
                    _ => "mov"
                };
            }
            if (offset < 8 && bits <= 8) return "movzx";
            if (cycle < 3) return "mov";
            return "shr";
        }

        public string GenerateUnpackCode(PackedRegister reg)
        {
            var code = new List<string>();
            foreach (var field in reg.Fields.OrderBy(f => f.AccessCycle))
            {
                var instr = field.ExtractionPattern switch
                {
                    "movzx" => $"movzx {field.Name}, {reg.Register}",
                    "shr" => $"shr {reg.Register}, {field.Offset}",
                    "vpermq" => $"vpermq {field.Name}, {reg.Register}",
                    "vextract" => $"vextractf64x4 {field.Name}, {reg.Register}, 0",
                    _ => $"mov {field.Name}, {reg.Register}"
                };
                code.Add($"    {instr}");
            }
            return string.Join("\n", code);
        }

        public string GeneratePackCode(PackedRegister reg)
        {
            var code = new List<string>();
            int offset = 0;
            foreach (var field in reg.Fields.OrderBy(f => f.AccessCycle))
            {
                if (offset == 0)
                    code.Add($"    mov {reg.Register}, {field.Name}");
                else
                    code.Add($"    shl {field.Name}, {offset}");
                offset += field.Bits;
            }
            return string.Join("\n", code);
        }
    }
}