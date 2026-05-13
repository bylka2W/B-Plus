using System;
using System.Collections.Generic;
using System.Linq;
using BPlusTranspiler.Ast;
using BPlusTranspiler.AI;

namespace BPlusTranspiler.Optimizer
{
    public class RegisterPacker
    {
        public class PackedRegister
        {
            public string Register { get; set; }
            public List<PackedField> Fields { get; set; } = new List<PackedField>();
            public int TotalBits => Fields.Sum(f => f.Bits);
        }

        public class PackedField
        {
            public string Name { get; set; }
            public int Offset { get; set; }
            public int Bits { get; set; }
            public string ExtractionPattern { get; set; }
            public int AccessCycle { get; set; }
        }

        private Dictionary<string, List<AccessInfo>> accessPatterns = new Dictionary<string, List<AccessInfo>>();
        private UnpackPredictor predictor;

        public class AccessInfo
        {
            public string VarName { get; set; }
            public int Cycle { get; set; }
            public int BitWidth { get; set; }
        }

        public void AnalyzeAccessPatterns(List<StateDefNode> states)
        {
            accessPatterns.Clear();
            foreach (var state in states)
            {
                var list = new List<AccessInfo>();
                int cycle = 0;
                foreach (var action in state.Actions)
                {
                    if (action.Body.Contains("=") || action.Body.Contains("set"))
                    {
                        list.Add(new AccessInfo { VarName = $"var_{cycle}", Cycle = cycle++, BitWidth = 64 });
                    }
                }
                accessPatterns[state.Name] = list;
            }
        }

        public List<PackedRegister> PackRegisters(List<StateDefNode> states, string targetReg = "rax")
        {
            var packed = new List<PackedRegister>();
            var pr = new PackedRegister { Register = targetReg };

            int currentOffset = 0;
            foreach (var state in states)
            {
                if (!accessPatterns.ContainsKey(state.Name)) continue;
                var accesses = accessPatterns[state.Name]
                    .OrderBy(a => a.Cycle).ToList();

                foreach (var acc in accesses)
                {
                    int bits = Math.Min(acc.BitWidth, 64 - currentOffset);
                    var field = new PackedField
                    {
                        Name = acc.VarName,
                        Offset = currentOffset,
                        Bits = bits,
                        AccessCycle = acc.Cycle,
                        ExtractionPattern = PredictExtraction(acc.Cycle, bits, currentOffset)
                    };
                    pr.Fields.Add(field);
                    currentOffset += bits;
                    if (currentOffset >= 64) break;
                }
                if (currentOffset >= 64) break;
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