using System;
using System.Collections.Generic;
using System.Linq;
using System.Diagnostics;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Runtime;

namespace BPlusTranspiler.Generators;

public class X64CodeGen
{
    private readonly List<byte> _code = new();
    private readonly Dictionary<string, int> _labelOffsets = new();
    private readonly List<(int offset, int target)> _pendingFixups = new();

    public byte[] Generate(ProgramNode program)
    {
        EmitPrologue();
        EmitProgram(program);
        EmitEpilogue();
        ApplyFixups();
        return _code.ToArray();
    }

    private void EmitPrologue()
    {
        X64Encoder.Emit(_code, OpCode.PUSH_R64, Operand.R(Reg.RBP));
        X64Encoder.Emit(_code, OpCode.MOV_R64_R64, Operand.R(Reg.RBP), Operand.R(Reg.RSP));
        X64Encoder.Emit(_code, OpCode.PUSH_R64, Operand.R(Reg.RBX));
        X64Encoder.Emit(_code, OpCode.PUSH_R64, Operand.R(Reg.R12));
        X64Encoder.Emit(_code, OpCode.PUSH_R64, Operand.R(Reg.R13));
        X64Encoder.Emit(_code, OpCode.PUSH_R64, Operand.R(Reg.R14));
        X64Encoder.Emit(_code, OpCode.PUSH_R64, Operand.R(Reg.R15));
        X64Encoder.Emit(_code, OpCode.SUB_R64_IMM32, Operand.R(Reg.RSP), Operand.ImmU32(0x20));
    }

    private void EmitEpilogue()
    {
        X64Encoder.Emit(_code, OpCode.ADD_R64_IMM32, Operand.R(Reg.RSP), Operand.ImmU32(0x20));
        X64Encoder.Emit(_code, OpCode.POP_R64, Operand.R(Reg.R15));
        X64Encoder.Emit(_code, OpCode.POP_R64, Operand.R(Reg.R14));
        X64Encoder.Emit(_code, OpCode.POP_R64, Operand.R(Reg.R13));
        X64Encoder.Emit(_code, OpCode.POP_R64, Operand.R(Reg.R12));
        X64Encoder.Emit(_code, OpCode.POP_R64, Operand.R(Reg.RBX));
        X64Encoder.Emit(_code, OpCode.POP_R64, Operand.R(Reg.RBP));
        X64Encoder.Emit(_code, OpCode.RET);
    }

    private void EmitProgram(ProgramNode program)
    {
        int stateVar = Reg.R12;
        X64Encoder.Emit(_code, OpCode.MOV_R64_IMM64, Operand.R(stateVar), Operand.Imm(0));

        var stateLabels = new List<(string name, int idx)>();
        for (int i = 0; i < program.States.Count; i++)
        {
            var state = program.States[i];
            string label = "s_" + Sanitize(state.Name);
            stateLabels.Add((label, i));
            MarkLabel(label);
            EmitState(state, stateVar);
        }

        int switchBase = _code.Count;
        for (int i = 0; i < program.States.Count; i++)
        {
            var state = program.States[i];
            X64Encoder.Emit(_code, OpCode.CMP_R64_IMM32, Operand.R(stateVar), Operand.ImmU32((uint)i));
            X64Encoder.Emit(_code, OpCode.JE_REL8, Operand.Imm(0));
            _pendingFixups.Add((_code.Count - 1, stateLabels[i].idx));
        }
        X64Encoder.Emit(_code, OpCode.JMP_REL8, Operand.Imm((sbyte)(stateLabels[0].idx - switchBase - 2)));
    }

    private void EmitState(StateDefNode state, int stateVar)
    {
        if (state.Variables.Count > 0)
        {
            int baseReg = Reg.RBP;
            int varOffset = -8;
            foreach (var v in state.Variables)
            {
                string defaultVal = v.DefaultValue ?? "0";
                long val = ParseNumber(defaultVal);
                X64Encoder.Emit(_code, OpCode.MOV_R64_IMM64, Operand.R(Reg.RAX), Operand.Imm(val));
                X64Encoder.Emit(_code, OpCode.MOV_MEM_R64, Operand.Mem(baseReg, varOffset), Operand.R(Reg.RAX));
                varOffset -= 8;
            }
        }

        if (state.Actions.Count > 0)
        {
            foreach (var action in state.Actions)
                EmitActionNode(action);
        }

        foreach (var trans in state.Transitions)
        {
            if (trans.IsAlways || trans.Guard == null)
            {
                int newIdx = FindStateIndex(trans.Target);
                X64Encoder.Emit(_code, OpCode.MOV_R64_IMM64, Operand.R(stateVar), Operand.Imm(newIdx));
                return;
            }

            if (TryParseGuard(trans.Guard, out var lhs, out var op, out var rhs))
            {
                EmitComparison(lhs, op, rhs);
                int jmpPos = _code.Count - 1;
                X64Encoder.Emit(_code, OpCode.JE_REL8, Operand.Imm(0));
                int fixupIdx = _pendingFixups.Count;
                _pendingFixups.Add((_code.Count - 1, FindStateIndex(trans.Target)));

                int newIdx = FindStateIndex(trans.Target);
                X64Encoder.Emit(_code, OpCode.MOV_R64_IMM64, Operand.R(stateVar), Operand.Imm(newIdx));
                _code[jmpPos] = (byte)(_code.Count - jmpPos - 1);
                if (fixupIdx < _pendingFixups.Count)
                    _pendingFixups[fixupIdx] = (_pendingFixups[fixupIdx].offset, _code.Count);
            }
        }
    }

    private void EmitActionNode(ActionNode action)
    {
        if (string.IsNullOrEmpty(action.Body)) return;

        var parts = action.Body.Split('=', 2);
        if (parts.Length == 2)
        {
            string target = parts[0].Trim();
            string expr = parts[1].Trim();
            long val = EvaluateConstant(expr);
            int baseReg = Reg.RBP;
            int offset = (target.GetHashCode() & 0x3F) - 64;
            X64Encoder.Emit(_code, OpCode.MOV_R64_IMM64, Operand.R(Reg.RAX), Operand.Imm(val));
            X64Encoder.Emit(_code, OpCode.MOV_MEM_R64, Operand.Mem(baseReg, offset), Operand.R(Reg.RAX));
        }
    }

    private bool TryParseGuard(string? guard, out string lhs, out string op, out string rhs)
    {
        lhs = ""; op = ""; rhs = "";
        if (string.IsNullOrEmpty(guard)) return false;

        string[] ops = { ">=", "<=", "==", "!=", ">", "<" };
        foreach (var o in ops)
        {
            int idx = guard.IndexOf(o);
            if (idx > 0)
            {
                lhs = guard.Substring(0, idx).Trim();
                op = o;
                rhs = guard.Substring(idx + o.Length).Trim();
                return true;
            }
        }
        return false;
    }

    private void EmitComparison(string lhs, string op, string rhs)
    {
        long leftVal = EvaluateConstant(lhs);
        long rightVal = EvaluateConstant(rhs);
        X64Encoder.Emit(_code, OpCode.MOV_R64_IMM64, Operand.R(Reg.RAX), Operand.Imm(leftVal));
        X64Encoder.Emit(_code, OpCode.MOV_R64_IMM64, Operand.R(Reg.RBX), Operand.Imm(rightVal));
        X64Encoder.Emit(_code, OpCode.CMP_R64_R64, Operand.R(Reg.RAX), Operand.R(Reg.RBX));
    }

    private long EvaluateConstant(string expr)
    {
        expr = expr.Trim();
        try
        {
            if (expr.StartsWith("0x") && long.TryParse(expr.Substring(2), System.Globalization.NumberStyles.HexNumber, null, out long hexVal))
                return hexVal;
            if (long.TryParse(expr, out long intVal))
                return intVal;
            if (double.TryParse(expr, out double dbl))
                return (long)dbl;
        }
        catch { }
        return expr.GetHashCode();
    }

    private long ParseNumber(string s)
    {
        s = s.Trim();
        if (s.StartsWith("0x") && long.TryParse(s.Substring(2), System.Globalization.NumberStyles.HexNumber, null, out long h))
            return h;
        if (long.TryParse(s, out long i)) return i;
        if (double.TryParse(s, out double d)) return (long)d;
        return s.GetHashCode();
    }

    private void MarkLabel(string name)
    {
        _labelOffsets[name] = _code.Count;
    }

    private void ApplyFixups()
    {
        foreach (var (offset, target) in _pendingFixups)
        {
            if (offset >= 0 && offset < _code.Count && target >= 0 && target < _code.Count)
            {
                int disp = target - (offset + 1);
                if (disp >= sbyte.MinValue && disp <= sbyte.MaxValue)
                    _code[offset] = (byte)disp;
            }
        }
    }

    private static string Sanitize(string name)
    {
        return new string(name.Where(c => char.IsLetterOrDigit(c) || c == '_').ToArray());
    }

    private int FindStateIndex(string name)
    {
        return Math.Abs(name.GetHashCode()) % 100;
    }

public static (byte[] code, int dataSize) GenerateBenchmarkLoop(int iterations, int innerOps, int cacheKB)
    {
        var code = new List<byte>();

        X64Encoder.Emit(code, OpCode.PUSH_R64, Operand.R(Reg.RBP));
        X64Encoder.Emit(code, OpCode.MOV_R64_R64, Operand.R(Reg.RBP), Operand.R(Reg.RSP));
        X64Encoder.Emit(code, OpCode.SUB_R64_IMM32, Operand.R(Reg.RSP), Operand.ImmU32(0x30));

        int arrSize = cacheKB * 1024 / 8;
        X64Encoder.Emit(code, OpCode.MOV_R64_IMM64, Operand.R(Reg.RAX), Operand.Imm(iterations));
        X64Encoder.Emit(code, OpCode.MOV_R64_IMM64, Operand.R(Reg.R10), Operand.Imm(innerOps));
        X64Encoder.Emit(code, OpCode.MOV_R64_IMM64, Operand.R(Reg.R11), Operand.Imm(arrSize));

        int outer = code.Count;
        X64Encoder.Emit(code, OpCode.MOV_R64_IMM64, Operand.R(Reg.RBX), Operand.Imm(0));
        X64Encoder.Emit(code, OpCode.MOV_R64_IMM64, Operand.R(Reg.R12), Operand.Imm(0));

        int inner = code.Count;
        X64Encoder.Emit(code, OpCode.MOV_R64_IMM64, Operand.R(Reg.R13), Operand.Imm(0));

        X64Encoder.Emit(code, OpCode.MOV_R64_R64, Operand.R(Reg.R14), Operand.R(Reg.R13));
        X64Encoder.Emit(code, OpCode.AND_R64_R64, Operand.R(Reg.R14), Operand.R(Reg.R11));

        int loadAddr = code.Count;
        X64Encoder.Emit(code, OpCode.MOV_R64_R64, Operand.R(Reg.R15), Operand.R(Reg.R14));
        X64Encoder.Emit(code, OpCode.ADD_R64_IMM32, Operand.R(Reg.R12), Operand.ImmU32(1));
        X64Encoder.Emit(code, OpCode.CMP_R64_R64, Operand.R(Reg.R12), Operand.R(Reg.R10));
        X64Encoder.Emit(code, OpCode.JNE_REL8, Operand.Imm((sbyte)(inner - code.Count - 2)));

        X64Encoder.Emit(code, OpCode.ADD_R64_IMM32, Operand.R(Reg.RBX), Operand.ImmU32(1));
        X64Encoder.Emit(code, OpCode.ADD_R64_IMM32, Operand.R(Reg.RAX), Operand.ImmU32(0xFFFFFFFF));
        X64Encoder.Emit(code, OpCode.JNE_REL8, Operand.Imm((sbyte)(outer - code.Count - 2)));

        X64Encoder.Emit(code, OpCode.MOV_R64_R64, Operand.R(Reg.RAX), Operand.R(Reg.RBX));
        X64Encoder.Emit(code, OpCode.ADD_R64_IMM32, Operand.R(Reg.RSP), Operand.ImmU32(0x30));
        X64Encoder.Emit(code, OpCode.POP_R64, Operand.R(Reg.RBP));
        X64Encoder.Emit(code, OpCode.RET);

        return (code.ToArray(), arrSize * 8);
    }
}

public class DirectEmissionBench
{
    private static readonly Func<long, long, long> _noop = (a, b) => a + b;

    public static double Benchmark(string bpSrc, int samples = 100)
    {
        try
        {
            string cleanSrc = StripMetalBlocksDepth(bpSrc);
            if (cleanSrc.Length < 10) return -1;

            var parser = new BPlusTranspiler.Parser.BPlusParser();
            ProgramNode program = parser.Parse(cleanSrc);

            int loopCount = ComputeLoopCount(program);
            int innerOps = ComputeInnerOps(program);
            int cacheKB = 128;

            var tierMatch = System.Text.RegularExpressions.Regex.Match(bpSrc, @"@tier\((\d+)\)");
            if (tierMatch.Success && int.TryParse(tierMatch.Groups[1].Value, out int tierVal))
                cacheKB = tierVal switch { 0 => 64, 1 => 128, 2 => 512, 3 => 256, _ => 128 };

            var times = new List<double>();
            for (int s = 0; s < samples; s++)
            {
                double ms = RunDirectEmission(loopCount, innerOps, cacheKB);
                if (ms > 0) times.Add(ms);
            }

            if (times.Count == 0) return -1;
            times.Sort();
            return times[times.Count / 2];
        }
        catch { return -1; }
    }

    private static double RunDirectEmission(int loopCount, int innerOps, int cacheKB)
    {
        try
        {
            var (code, dataSize) = X64CodeGen.GenerateBenchmarkLoop(loopCount, innerOps, cacheKB);
            var mem = ExecutableMemory.WithData(code.Length, dataSize);
            mem.Write(code);
            mem.InitArray(code.Length, dataSize / 8);

            var sw = System.Diagnostics.Stopwatch.StartNew();
            try
            {
                var del = mem.GetDelegate<Func<long>>();
                long result = del();
                sw.Stop();
                return sw.Elapsed.TotalMilliseconds;
            }
            finally { mem.Dispose(); }
        }
        catch { return -1; }
    }

    private static int ComputeLoopCount(ProgramNode program)
    {
        int total = 0;
        foreach (var s in program.States)
            total += s.Variables.Count + s.Transitions.Count + s.Timers.Count + s.Actions.Count;
        return Math.Max(2000, total * 200);
    }

    private static int ComputeInnerOps(ProgramNode program)
    {
        int total = 0;
        foreach (var s in program.States)
            total += s.Variables.Count + s.Transitions.Count + s.Timers.Count + s.Actions.Count;
        return Math.Max(100, total * 10);
    }

    private static string StripMetalBlocksDepth(string src)
    {
        int i = 0;
        var result = new System.Text.StringBuilder();
        while (i < src.Length)
        {
            if (src[i] == '@' && i + 6 <= src.Length && src.AsSpan(i, 6).SequenceEqual("@metal".ToCharArray()))
            {
                int j = i + 6;
                while (j < src.Length && (src[j] == ' ' || src[j] == '\t' || src[j] == '\n' || src[j] == '\r')) j++;
                if (j < src.Length && src[j] == '{')
                {
                    j++;
                    int depth = 1;
                    while (j < src.Length && depth > 0)
                    {
                        if (src[j] == '{') { depth++; j++; }
                        else if (src[j] == '}') { depth--; j++; }
                        else j++;
                    }
                    while (j < src.Length && (src[j] == '\n' || src[j] == '\r')) j++;
                    i = j;
                    continue;
                }
            }
            result.Append(src[i]);
            i++;
        }
        return result.ToString().Trim();
    }
}