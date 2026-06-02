using System.Text;
using System.Text.RegularExpressions;

namespace BPlus.Targets.Generators;

// Peephole pass: replaces equivalent but larger instructions with shorter/faster ones.
// Inspired by GAS -O2 peephole optimizer.
public static class PeepholePass
{
    private struct PeepholeRule
    {
        public Regex Pattern;
        public MatchEvaluator Evaluator;
    }

    private static readonly PeepholeRule[] PeepholeRules =
    {
        // mov reg,0 → xor reg,reg (shorter, breaks dependency)
        new PeepholeRule { Pattern = new Regex(@"\bmov\s+(r[a-z0-9]+),\s*0\b", RegexOptions.IgnoreCase), Evaluator = m => $"xor {m.Groups[1].Value}, {m.Groups[1].Value}" },
        new PeepholeRule { Pattern = new Regex(@"\bmov\s+(e[a-z0-9]+),\s*0\b", RegexOptions.IgnoreCase), Evaluator = m => $"xor {m.Groups[1].Value}, {m.Groups[1].Value}" },

        // andq %reg,%reg → testq %reg,%reg (shorter, same flags)
        new PeepholeRule { Pattern = new Regex(@"\bandq\s+%(r[a-z0-9]+),\s*%\1\b", RegexOptions.IgnoreCase), Evaluator = m => $"testq %{m.Groups[1].Value}, %{m.Groups[1].Value}" },
        new PeepholeRule { Pattern = new Regex(@"\bandl\s+%(e[a-z0-9]+),\s*%\1\b", RegexOptions.IgnoreCase), Evaluator = m => $"testl %{m.Groups[1].Value}, %{m.Groups[1].Value}" },

        // andq $imm31,%reg → andl $imm31,%reg (removes REX.W byte when imm fits in 32-bit)
        new PeepholeRule { Pattern = new Regex(@"\bandq\s+\$(\d+),\s*%(r[a-z0-9]+)\b", RegexOptions.IgnoreCase), Evaluator = m =>
        {
            if (long.TryParse(m.Groups[1].Value, out var imm) && imm <= int.MaxValue && imm >= 0)
                return $"andl ${imm}, %{m.Groups[2].Value.Replace("r", "e")}";
            return m.Value;
        } },

        // sub reg,reg → nop (no-op)
        new PeepholeRule { Pattern = new Regex(@"\bsub[ql]?\s+%(r[a-z0-9]+),\s*%\1\b", RegexOptions.IgnoreCase), Evaluator = _ => "; peephole: removed sub (no-op)" },

        // lea reg,[reg+0] → nop
        new PeepholeRule { Pattern = new Regex(@"\blea\s+(r[a-z0-9]+),\s*\[\1\]\b", RegexOptions.IgnoreCase), Evaluator = _ => "; peephole: removed lea (no-op)" },

        // cmp reg,0 → test reg,reg (shorter)
        new PeepholeRule { Pattern = new Regex(@"\bcmp[ql]?\s+%(r[a-z0-9]+),\s*\$0\b", RegexOptions.IgnoreCase), Evaluator = m => $"testq %{m.Groups[1].Value}, %{m.Groups[1].Value}" },
    };

    public static string Apply(string asm)
    {
        var lines = asm.Split('\n');
        var result = new StringBuilder();

        foreach (var line in lines)
        {
            var trimmed = line.Trim();
            if (string.IsNullOrEmpty(trimmed) || trimmed.StartsWith(';') || trimmed.StartsWith('.'))
            {
                result.AppendLine(line);
                continue;
            }

            string updated = trimmed;
            foreach (var rule in PeepholeRules)
            {
                updated = rule.Pattern.Replace(updated, rule.Evaluator);
            }

            // Preserve original indentation
            var indent = line.Length - line.TrimStart().Length;
            result.AppendLine(new string(' ', indent) + updated);
        }

        return result.ToString();
    }
}

// Multipass jump shrink: converts 5-byte rel32 jumps to 2-byte rel8 when target
// is within ±127 bytes. Loops until no more shrinks possible (FASM-style).
public static class JumpShrinker
{
    public static string Shrink(string asm)
    {
        bool changed;
        int pass = 0;

        do
        {
            changed = false;
            pass++;

            var lines = asm.Split('\n');
            var labels = new Dictionary<string, int>();
            var jumps = new List<(int LineIndex, string Label, bool IsShort, string Instr, int InstSize)>();

            // First pass: collect label positions and jump sizes
            int byteOffset = 0;
            for (int i = 0; i < lines.Length; i++)
            {
                var line = lines[i].Trim();
                if (string.IsNullOrEmpty(line)) { byteOffset++; continue; }

                // Label definition (ends with ':') — allow .L_ local labels
                if (line.EndsWith(':') && !line.StartsWith(';') && !line.StartsWith("section") && !line.StartsWith("align"))
                {
                    var labelName = line.TrimEnd(':');
                    labelName = labelName.Trim();
                    // Strip leading dot for local labels to match jump references
                    var lookupName = labelName.StartsWith('.') ? labelName.Substring(1) : labelName;
                    if (!labels.ContainsKey(lookupName))
                        labels[lookupName] = byteOffset;
                    byteOffset++;
                    continue;
                }

                // CFI directives (skip but count minimal)
                if (line.StartsWith(".cfi_"))
                {
                    byteOffset += 2;
                    continue;
                }

                // Section/align directives
                if (line.StartsWith("section") || line.StartsWith("align"))
                {
                    byteOffset += 2;
                    continue;
                }

                // Other dot-directives (not .cfi_ and not labels) — skip
                if (line.StartsWith('.') || line.StartsWith(';'))
                {
                    byteOffset++;
                    continue;
                }

                // Check for jumps
                var jmpMatch = Regex.Match(line, @"\b(jmp|je|jne|jb|jae|jl|jge|ja|jbe|jo|jno|js|jns|jp|jnp)\b", RegexOptions.IgnoreCase);
                if (jmpMatch.Success)
                {
                    var instr = jmpMatch.Groups[1].Value.ToLower();
                    bool isShort = line.Contains("short ", StringComparison.OrdinalIgnoreCase);
                    int size = isShort ? 2 : (instr == "jmp" ? 5 : 6);

                    // Extract label from jump — strip leading dot if present
                    var labelMatch = Regex.Match(line, @"[.]([a-zA-Z_][a-zA-Z0-9_.]*)\s*$");
                    var label = labelMatch.Success ? labelMatch.Groups[1].Value : "";
                    jumps.Add((i, label, isShort, instr, size));
                    byteOffset += size;
                    continue;
                }

                int instSize = EstimateInstructionSize(line);
                byteOffset += instSize;
            }

            // Second pass: shrink jumps where possible
            for (int j = 0; j < jumps.Count; j++)
            {
                var (lineIdx, label, isShort, instr, origSize) = jumps[j];

                if (isShort) continue;
                if (!labels.TryGetValue(label, out var labelPos)) continue;

                // Recalculate byte offset up to this line
                int currentOffset = 0;
                for (int i = 0; i < lineIdx; i++)
                {
                    var l = lines[i].Trim();
                    if (string.IsNullOrEmpty(l) || l.StartsWith(';') || l.StartsWith(".cfi_") ||
                        l.StartsWith("section") || l.StartsWith("align"))
                    { currentOffset++; continue; }
                    if (l.EndsWith(':') && !l.StartsWith(';') && !l.StartsWith("section") && !l.StartsWith("align"))
                    { currentOffset++; continue; }
                    // Other dot-directives, but NOT .L_ local labels (those are instruction labels)
                    if (l.StartsWith('.') && !l.StartsWith(".L"))
                    { currentOffset++; continue; }

                    var jmpCheck = Regex.Match(l, @"\b(jmp|je|jne)\b", RegexOptions.IgnoreCase);
                    if (jmpCheck.Success)
                    {
                        bool isShortJump = l.Contains("short ", StringComparison.OrdinalIgnoreCase);
                        currentOffset += isShortJump ? 2 : (jmpCheck.Groups[1].Value.ToLower() == "jmp" ? 5 : 6);
                        continue;
                    }

                    currentOffset += EstimateInstructionSize(l);
                }

                int rel32Distance = labelPos - (currentOffset + origSize);
                int rel8Distance = labelPos - (currentOffset + 2);

                bool canShorten = rel8Distance >= -128 && rel8Distance <= 127;
                if (!canShorten) continue;

                // Replace with short jump
                var indent = lines[lineIdx].Length - lines[lineIdx].TrimStart().Length;
                lines[lineIdx] = new string(' ', indent) + $"    {instr} short .{label}";
                changed = true;
                jumps[j] = (lineIdx, label, true, instr, 2);
            }

            if (changed)
                asm = string.Join("\n", lines);

        } while (changed && pass < 10);

        return asm;
    }

    private static int EstimateInstructionSize(string line)
    {
        var trimmed = line.Trim();

        if (trimmed.StartsWith(';') || trimmed.EndsWith(':') || trimmed.StartsWith('.') ||
            trimmed.StartsWith("section") || trimmed.StartsWith("align") || trimmed.StartsWith("section"))
            return 1;

        if (Regex.IsMatch(trimmed, @"\b(push|pop)\b", RegexOptions.IgnoreCase))
            return 2;

        if (Regex.IsMatch(trimmed, @"\b(ret|nop|syscall|int3)\b", RegexOptions.IgnoreCase))
            return 1;

        if (Regex.IsMatch(trimmed, @"\b(vpermq|kortest|prefetcht0|prefetchnta)\b", RegexOptions.IgnoreCase))
            return 5;

        if (Regex.IsMatch(trimmed, @"\b(mov|test|and|or|xor|add|sub|cmp|lea)\b", RegexOptions.IgnoreCase))
            return 4;

        return 3;
    }
}

// ABI manager: tracks callee-saved register usage and emits push/pop in prologue/epilogue.
// Inspired by PeachPy's automatic ABI management.
public static class AbiManager
{
    private static readonly HashSet<string> CalleeSavedGpr = new()
    { "rbx", "rbp", "r12", "r13", "r14", "r15" };

    // Detect which callee-saved registers are used in the assembly
    public static HashSet<string> FindUsedCalleeSaved(string asm)
    {
        var used = new HashSet<string>();
        var lines = asm.Split('\n');

        foreach (var line in lines)
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith(';') || trimmed.StartsWith('.') || trimmed.EndsWith(':'))
                continue;

            foreach (var reg in CalleeSavedGpr)
            {
                if (Regex.IsMatch(trimmed, $@"%{reg}\b", RegexOptions.IgnoreCase) ||
                    Regex.IsMatch(trimmed, $@"\b{reg}\b", RegexOptions.IgnoreCase))
                {
                    used.Add(reg);
                }
            }
        }

        return used;
    }

    // Wrap assembly with push/pop for used callee-saved registers
    public static string WrapWithPrologueEpilogue(string asm, HashSet<string> usedRegs)
    {
        if (usedRegs.Count == 0) return asm;

        var lines = asm.Split('\n');
        var result = new StringBuilder();
        bool inFunction = false;

        for (int i = 0; i < lines.Length; i++)
        {
            var trimmed = lines[i].Trim();

            // Detect function entry: state_Name: at column 0 (no indent)
            if (trimmed.EndsWith(':') && !trimmed.StartsWith('.') && !trimmed.StartsWith(';') &&
                !trimmed.StartsWith("section") && !trimmed.StartsWith("align"))
            {
                // If we were in a function, emit epilogue before the next one
                if (inFunction)
                {
                    foreach (var reg in usedRegs.Reverse())
                        result.AppendLine($"    pop {reg}");
                    inFunction = false;
                }

                result.AppendLine(lines[i]);
                inFunction = true;

                // Prologue: push all used callee-saved registers
                foreach (var reg in usedRegs)
                    result.AppendLine($"    push {reg}");
                continue;
            }

            // Check for ret — insert epilogue before it
            if (inFunction && trimmed.StartsWith("ret", StringComparison.OrdinalIgnoreCase))
            {
                foreach (var reg in usedRegs.Reverse())
                    result.AppendLine($"    pop {reg}");
                result.AppendLine(lines[i]);
                inFunction = false;
                continue;
            }

            result.AppendLine(lines[i]);
        }

        // Close last function if needed
        if (inFunction)
        {
            foreach (var reg in usedRegs.Reverse())
                result.AppendLine($"    pop {reg}");
            result.AppendLine("    ret");
        }

        return result.ToString();
    }
}

// CFI emitter: adds DWARF CFI directives for stack unwinding.
// Required for perf profiling, gdb debugging, and C++ exception compatibility.
public static class CfiEmitter
{
    public static string AddCfi(string asm)
    {
        var lines = asm.Split('\n');
        var result = new StringBuilder();
        bool inFunction = false;
        bool hadCfi = false;
        int cfaOffset = 8;

        foreach (var line in lines)
        {
            var trimmed = line.Trim();

            // Check if CFI already present
            if (trimmed.StartsWith(".cfi_"))
            {
                hadCfi = true;
                result.AppendLine(line);
                continue;
            }

            // State entry point
            if (trimmed.EndsWith(':') && !trimmed.StartsWith('.') && !trimmed.StartsWith(';') &&
                !trimmed.StartsWith("section") && !trimmed.StartsWith("align"))
            {
                if (inFunction)
                    result.AppendLine("    .cfi_endproc");

                result.AppendLine(line);
                result.AppendLine("    .cfi_startproc");
                result.AppendLine($"    .cfi_def_cfa_offset {cfaOffset}");
                inFunction = true;
                continue;
            }

            if (inFunction && !hadCfi)
            {
                // Track push for CFA offset
                var pushMatch = Regex.Match(trimmed, @"^\s*push\s+(r[a-z0-9]+)", RegexOptions.IgnoreCase);
                if (pushMatch.Success)
                {
                    cfaOffset += 8;
                    result.AppendLine(line);
                    result.AppendLine($"    .cfi_adjust_cfa_offset 8");
                    result.AppendLine($"    .cfi_rel_offset {pushMatch.Groups[1].Value}, 0");
                    continue;
                }

                // Track pop for CFA offset
                var popMatch = Regex.Match(trimmed, @"^\s*pop\s+(r[a-z0-9]+)", RegexOptions.IgnoreCase);
                if (popMatch.Success)
                {
                    cfaOffset -= 8;
                    result.AppendLine(line);
                    result.AppendLine($"    .cfi_adjust_cfa_offset -8");
                    result.AppendLine($"    .cfi_restore {popMatch.Groups[1].Value}");
                    continue;
                }

                // ret — close function
                if (trimmed.StartsWith("ret", StringComparison.OrdinalIgnoreCase))
                {
                    result.AppendLine(line);
                    result.AppendLine("    .cfi_endproc");
                    inFunction = false;
                    cfaOffset = 8;
                    continue;
                }
            }

            result.AppendLine(line);
        }

        // Close last function
        if (inFunction && !hadCfi)
        {
            result.AppendLine("    .cfi_endproc");
        }

        return result.ToString();
    }
}
