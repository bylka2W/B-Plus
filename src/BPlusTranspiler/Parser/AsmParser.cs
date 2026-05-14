using System.Text.RegularExpressions;

namespace BPlusTranspiler.Parser;

public class AsmInstruction
{
    public string Mnemonic { get; set; } = "";
    public string Operands { get; set; } = "";
    public List<string> Constraints { get; set; } = new();
    public string? Label { get; set; }
    public bool IsDirective { get; set; }
    public int LineNumber { get; set; }
}

public class AsmBlock
{
    public List<AsmInstruction> Instructions { get; set; } = new();
    public List<string> Clobbers { get; set; } = new();
    public string? Volatile { get; set; }
}

public static class AsmParser
{
    private static readonly Regex InstrRegex = new(
        @"^\s*(?:(\w+):)?\s*(?:(\.[a-z]\w*)|([a-z][a-z0-9]*))?\s*(.*?)\s*(?:#.*)?$",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private static readonly HashSet<string> RegisterNames = new()
    {
        "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp",
        "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
        "eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp",
        "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d",
        "ax", "bx", "cx", "dx", "si", "di", "bp", "sp",
        "al", "bl", "cl", "dl", "sil", "dil", "bpl", "spl",
        "ah", "bh", "ch", "dh",
        "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7",
        "xmm8", "xmm9", "xmm10", "xmm11", "xmm12", "xmm13", "xmm14", "xmm15",
        "ymm0", "ymm1", "ymm2", "ymm3", "ymm4", "ymm5", "ymm6", "ymm7",
        "ymm8", "ymm9", "ymm10", "ymm11", "ymm12", "ymm13", "ymm14", "ymm15",
        "zmm0", "zmm1", "zmm2", "zmm3", "zmm4", "zmm5", "zmm6", "zmm7",
        "zmm8", "zmm9", "zmm10", "zmm11", "zmm12", "zmm13", "zmm14", "zmm15",
        "zmm16", "zmm17", "zmm18", "zmm19", "zmm20", "zmm21", "zmm22", "zmm23",
        "zmm24", "zmm25", "zmm26", "zmm27", "zmm28", "zmm29", "zmm30", "zmm31",
        "k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7",
        "mm0", "mm1", "mm2", "mm3", "mm4", "mm5", "mm6", "mm7",
        "st", "st(0)", "st(1)", "st(2)", "st(3)", "st(4)", "st(5)", "st(6)", "st(7)",
        "cr0", "cr1", "cr2", "cr3", "cr4", "cr8",
        "dr0", "dr1", "dr2", "dr3", "dr6", "dr7",
        "rip", "eip",
    };

    public static AsmBlock Parse(string source, string? clobbers = null)
    {
        var block = new AsmBlock();
        if (clobbers != null)
            block.Clobbers.AddRange(clobbers.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries));

        var lines = source.Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            var trimmed = line.Trim();
            if (trimmed.Length == 0 || trimmed.StartsWith("#") || trimmed.StartsWith("//"))
                continue;

            var match = InstrRegex.Match(trimmed);
            if (!match.Success) continue;

            var label = match.Groups[1].Value;
            var directive = match.Groups[2].Value;
            var mnemonic = match.Groups[3].Value;
            var operands = match.Groups[4].Value.Trim();

            if (!string.IsNullOrEmpty(directive) && !string.IsNullOrEmpty(mnemonic))
            {
                block.Instructions.Add(new AsmInstruction
                {
                    Mnemonic = mnemonic,
                    Operands = operands,
                    IsDirective = false,
                    LineNumber = i + 1,
                });
                continue;
            }

            if (!string.IsNullOrEmpty(directive))
            {
                block.Instructions.Add(new AsmInstruction
                {
                    Mnemonic = directive,
                    Operands = operands,
                    IsDirective = true,
                    LineNumber = i + 1,
                });
                continue;
            }

            if (!string.IsNullOrEmpty(mnemonic))
            {
                block.Instructions.Add(new AsmInstruction
                {
                    Mnemonic = mnemonic,
                    Operands = operands,
                    Label = string.IsNullOrEmpty(label) ? null : label,
                    IsDirective = false,
                    LineNumber = i + 1,
                });
            }
        }

        return block;
    }

    public static string Generate(AsmBlock block, bool intelSyntax = true)
    {
        var lines = new List<string>();
        if (intelSyntax)
            lines.Add(".intel_syntax noprefix");

        foreach (var instr in block.Instructions)
        {
            if (instr.Label != null)
                lines.Add($"{instr.Label}:");
            if (instr.IsDirective)
                lines.Add($"\t{instr.Mnemonic} {instr.Operands}".TrimEnd());
            else
                lines.Add($"\t{instr.Mnemonic}\t{instr.Operands}".TrimEnd());
        }

        return string.Join("\n", lines);
    }

    public static string DetectSyntax(string asm)
    {
        if (asm.Contains(".intel_syntax")) return "intel";
        if (asm.Contains(",(")) return "at_and_t";
        if (asm.Contains("[") && asm.Contains("]")) return "intel";
        return "unknown";
    }
}
