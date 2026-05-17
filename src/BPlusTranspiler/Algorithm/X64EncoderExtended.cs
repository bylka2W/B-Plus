using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace BPlusTranspiler.Algorithm;

public class X64Encoder
{
    private List<byte> code = new();
    private long baseAddress = 0;

    public byte[] Code => code.ToArray();
    public long BaseAddress => baseAddress;
    public int Length => code.Count;

    public void SetBaseAddress(long addr) => baseAddress = addr;

    public X64Encoder Emit(byte b)
    {
        code.Add(b);
        return this;
    }

    public X64Encoder Emit(params byte[] b)
    {
        code.AddRange(b);
        return this;
    }

    public X64Encoder EmitModRM(byte mod, byte reg, byte rm)
    {
        code.Add((byte)((mod << 6) | ((reg & 7) << 3) | (rm & 7)));
        return this;
    }

    public X64Encoder EmitSIB(byte scale, byte index, byte base_)
    {
        code.Add((byte)((scale << 6) | ((index & 7) << 3) | (base_ & 7)));
        return this;
    }

    public X64Encoder REX(bool w = false, bool r = false, bool x = false, bool b = false)
    {
        code.Add((byte)(0x40 | ((w ? 1 : 0) << 3) | ((r ? 1 : 0) << 2) | ((x ? 1 : 0) << 1) | (b ? 1 : 0)));
        return this;
    }

    public X64Encoder Imm8(byte v) { code.Add(v); return this; }
    public X64Encoder Imm16(int v) { code.AddRange(BitConverter.GetBytes((short)v)); return this; }
    public X64Encoder Imm32(int v) { code.AddRange(BitConverter.GetBytes(v)); return this; }
    public X64Encoder Imm64(long v) { code.AddRange(BitConverter.GetBytes(v)); return this; }

    public X64Encoder Add(byte reg1, byte reg2) { Emit(0x01).EmitModRM(3, reg1, reg2); return this; }
    public X64Encoder Add(byte reg, int disp, byte base_) { Emit(0x01).EmitModRM(2, reg, 4).EmitSIB(0, 0, base_).Imm32(disp); return this; }
    public X64Encoder Add(byte reg, byte base_, byte index, byte scale, int disp)
    {
        Emit(0x01).EmitModRM(1, reg, 4).EmitSIB(scale, index, base_);
        if (disp >= -128 && disp <= 127) code.Add((byte)disp);
        else Imm32(disp);
        return this;
    }

    public X64Encoder Sub(byte reg1, byte reg2) { Emit(0x29).EmitModRM(3, reg1, reg2); return this; }
    public X64Encoder Sub(byte reg, int disp, byte base_) { Emit(0x29).EmitModRM(2, reg, 4).EmitSIB(0, 0, base_).Imm32(disp); return this; }

    public X64Encoder Imul(byte reg1, byte reg2) { Emit(0x0F, 0xAF).EmitModRM(3, reg1, reg2); return this; }
    public X64Encoder Imul(byte reg, byte src, int imm) { Emit(0x6B).EmitModRM(3, reg, src); Imm8((byte)imm); return this; }
    public X64Encoder Imul(byte reg, byte src, int imm32, bool wide) { Emit(0x69).EmitModRM(3, reg, src); Imm32(imm32); return this; }

    public X64Encoder Mul(byte reg) { Emit(0xF7).EmitModRM(3, 4, reg); return this; }
    public X64Encoder Mul(byte base_, int disp) { Emit(0xF7).EmitModRM(2, 4, 4).EmitSIB(0, 0, base_).Imm32(disp); return this; }
    public X64Encoder Imul(byte base_, int disp) { Emit(0xF7).EmitModRM(2, 4, 4).EmitSIB(0, 0, base_).Imm32(disp); return this; }

    public X64Encoder Div(byte reg) { Emit(0xF7).EmitModRM(3, 6, reg); return this; }
    public X64Encoder Idiv(byte reg) { Emit(0xF7).EmitModRM(3, 7, reg); return this; }

    public X64Encoder And(byte reg1, byte reg2) { Emit(0x21).EmitModRM(3, reg1, reg2); return this; }
    public X64Encoder Or(byte reg1, byte reg2) { Emit(0x09).EmitModRM(3, reg1, reg2); return this; }
    public X64Encoder Xor(byte reg1, byte reg2) { Emit(0x31).EmitModRM(3, reg1, reg2); return this; }
    public X64Encoder Xor(byte reg) { Emit(0x31).EmitModRM(3, 0, reg); return this; }
    public X64Encoder Not(byte reg) { Emit(0xF7).EmitModRM(3, 2, reg); return this; }
    public X64Encoder Neg(byte reg) { Emit(0xF7).EmitModRM(3, 3, reg); return this; }

    public X64Encoder Cmp(byte reg1, byte reg2) { Emit(0x39).EmitModRM(3, reg1, reg2); return this; }
    public X64Encoder Cmp(byte base_, int disp, byte reg) { Emit(0x39).EmitModRM(2, reg, 4).EmitSIB(0, 0, base_).Imm32(disp); return this; }
    public X64Encoder Cmp(byte base_, int disp, int imm) { Emit(0x83).EmitModRM(0, 7, 4).EmitSIB(0, 0, base_).Imm8((byte)disp); code.Add((byte)imm); return this; }
    public X64Encoder Cmp(byte reg, int imm) { Emit(0x83).EmitModRM(3, 7, reg); Imm8((byte)imm); return this; }

    public X64Encoder Test(byte reg1, byte reg2) { Emit(0x85).EmitModRM(3, reg1, reg2); return this; }
    public X64Encoder Test(byte reg, int imm) { Emit(0xF7).EmitModRM(3, 0, reg); Imm32(imm); return this; }

    public X64Encoder Mov(byte dst, byte src) { Emit(0x8B).EmitModRM(3, dst, src); return this; }
    public X64Encoder Mov(byte dst, byte base_, int disp) { Emit(0x8B).EmitModRM(2, dst, 4).EmitSIB(0, 0, base_).Imm32(disp); return this; }
    public X64Encoder Mov(byte dst, byte base_, byte index, byte scale, int disp)
    {
        Emit(0x8B).EmitModRM(1, dst, 4).EmitSIB(scale, index, base_);
        if (disp >= -128 && disp <= 127) code.Add((byte)disp);
        else Imm32(disp);
        return this;
    }
    public X64Encoder Mov(byte dst, long imm) { REX(w: true).Emit((byte)(0xB8 + (dst & 7))).Imm64(imm); return this; }
    public X64Encoder Mov(byte dst, int imm) { Emit((byte)(0xB8 + (dst & 7))); Imm32(imm); return this; }
    public X64Encoder Mov(byte base_, int disp, byte src) { Emit(0x89).EmitModRM(2, src, 4).EmitSIB(0, 0, base_).Imm32(disp); return this; }
    public X64Encoder Mov(byte base_, int disp, int imm) { Emit(0xC7).EmitModRM(0, 0, 4).EmitSIB(0, 0, base_).Imm32(disp).Imm32(imm); return this; }
    public X64Encoder Movq(byte dst, byte src) { REX(w: true).Emit(0x0F, 0x7E).EmitModRM(3, dst, src); return this; }
    public X64Encoder Movq(byte dst, byte base_, int disp) { REX(w: true).Emit(0x0F, 0x7E).EmitModRM(2, dst, 4).EmitSIB(0, 0, base_).Imm32(disp); return this; }
    public X64Encoder Movdqu(byte dst, byte src) { Emit(0xF3, 0x0F, 0x6F).EmitModRM(3, dst, src); return this; }
    public X64Encoder Movdqa(byte dst, byte src) { Emit(0x66, 0x0F, 0x6F).EmitModRM(3, dst, src); return this; }
    public X64Encoder Movups(byte dst, byte src) { Emit(0x0F, 0x10).EmitModRM(3, dst, src); return this; }
    public X64Encoder Movupd(byte dst, byte src) { Emit(0x66, 0x0F, 0x10).EmitModRM(3, dst, src); return this; }

    public X64Encoder Lea(byte dst, byte base_, int disp) { Emit(0x8D).EmitModRM(2, dst, 4).EmitSIB(0, 0, base_).Imm32(disp); return this; }
    public X64Encoder Lea(byte dst, byte base_, byte index, byte scale, int disp)
    {
        Emit(0x8D).EmitModRM(1, dst, 4).EmitSIB(scale, index, base_);
        if (disp >= -128 && disp <= 127) code.Add((byte)disp);
        else Imm32(disp);
        return this;
    }

    public X64Encoder Jmp(byte reg) { Emit(0xFF).EmitModRM(3, 4, reg); return this; }
    public X64Encoder Jmp(int disp) { Emit(0xE9).Imm32(disp - 5); return this; }
    public X64Encoder Jmp(byte base_, int disp) { Emit(0xFF).EmitModRM(2, 4, 4).EmitSIB(0, 0, base_).Imm32(disp); return this; }

    public X64Encoder Je(int disp) { Emit(0x0F, 0x84).Imm32(disp - 6); return this; }
    public X64Encoder Jne(int disp) { Emit(0x0F, 0x85).Imm32(disp - 6); return this; }
    public X64Encoder Jl(int disp) { Emit(0x0F, 0x8C).Imm32(disp - 6); return this; }
    public X64Encoder Jle(int disp) { Emit(0x0F, 0x8E).Imm32(disp - 6); return this; }
    public X64Encoder Jg(int disp) { Emit(0x0F, 0x8F).Imm32(disp - 6); return this; }
    public X64Encoder Jge(int disp) { Emit(0x0F, 0x8D).Imm32(disp - 6); return this; }
    public X64Encoder Ja(int disp) { Emit(0x0F, 0x87).Imm32(disp - 6); return this; }
    public X64Encoder Jb(int disp) { Emit(0x0F, 0x82).Imm32(disp - 6); return this; }
    public X64Encoder Jz(int disp) { Emit(0x0F, 0x84).Imm32(disp - 6); return this; }
    public X64Encoder Jnz(int disp) { Emit(0x0F, 0x85).Imm32(disp - 6); return this; }

    public X64Encoder Call(byte reg) { Emit(0xFF).EmitModRM(3, 2, reg); return this; }
    public X64Encoder Call(int disp) { Emit(0xE8).Imm32(disp - 5); return this; }
    public X64Encoder Call(byte base_, int disp) { Emit(0xFF).EmitModRM(2, 2, 4).EmitSIB(0, 0, base_).Imm32(disp); return this; }

    public X64Encoder Ret() { Emit(0xC3); return this; }
    public X64Encoder Ret(int imm) { Emit(0xC2).Imm16((short)imm); return this; }

    public X64Encoder Push(byte reg) { Emit((byte)(0x50 + (reg & 7))); return this; }
    public X64Encoder Push(int imm) { Emit(0x68).Imm32(imm); return this; }
    public X64Encoder Push(byte base_, int disp) { Emit(0xFF).EmitModRM(2, 6, 4).EmitSIB(0, 0, base_).Imm32(disp); return this; }

    public X64Encoder Pop(byte reg) { Emit((byte)(0x58 + (reg & 7))); return this; }
    public X64Encoder Pop(byte base_, int disp) { Emit(0x8F).EmitModRM(2, 0, 4).EmitSIB(0, 0, base_).Imm32(disp); return this; }

    public X64Encoder Inc(byte reg) { Emit((byte)(0x40 + (reg & 7))); return this; }
    public X64Encoder Dec(byte reg) { Emit((byte)(0x48 + (reg & 7))); return this; }

    public X64Encoder Shl(byte reg, byte imm) { Emit(0xC1).EmitModRM(3, 4, reg); Imm8(imm); return this; }
    public X64Encoder Shr(byte reg, byte imm) { Emit(0xC1).EmitModRM(3, 5, reg); Imm8(imm); return this; }
    public X64Encoder Sar(byte reg, byte imm) { Emit(0xC1).EmitModRM(3, 7, reg); Imm8(imm); return this; }

    public X64Encoder Cqo() { Emit(0x99); return this; }

    public X64Encoder Setcc(byte reg, byte cond) { Emit(0x0F).Emit((byte)(0x90 + (cond & 0xF))).EmitModRM(0, 0, reg); return this; }

    public X64Encoder Cmpxchg(byte dst, byte src) { Emit(0x0F, 0xB1).EmitModRM(3, src, dst); return this; }
    public X64Encoder Xadd(byte dst, byte src) { Emit(0x0F, 0xC1).EmitModRM(3, src, dst); return this; }
    public X64Encoder Xchg(byte reg1, byte reg2) { Emit(0x87).EmitModRM(3, reg1, reg2); return this; }

    public X64Encoder Cvtsi2ss(byte dst, byte src) { Emit(0xF3, 0x0F, 0x2A).EmitModRM(3, dst, src); return this; }
    public X64Encoder Cvtsi2sd(byte dst, byte src) { Emit(0xF2, 0x0F, 0x2A).EmitModRM(3, dst, src); return this; }
    public X64Encoder Cvttss2si(byte dst, byte src) { Emit(0xF3, 0x0F, 0x2C).EmitModRM(3, dst, src); return this; }
    public X64Encoder Cvttsd2si(byte dst, byte src) { Emit(0xF2, 0x0F, 0x2D).EmitModRM(3, dst, src); return this; }
    public X64Encoder Cvtss2sd(byte dst, byte src) { Emit(0xF3, 0x0F, 0x5A).EmitModRM(3, dst, src); return this; }
    public X64Encoder Cvtsd2ss(byte dst, byte src) { Emit(0xF2, 0x0F, 0x5A).EmitModRM(3, dst, src); return this; }

    public X64Encoder Addps(byte dst, byte src) { Emit(0x0F, 0x58).EmitModRM(3, dst, src); return this; }
    public X64Encoder Addpd(byte dst, byte src) { Emit(0x66, 0x0F, 0x58).EmitModRM(3, dst, src); return this; }
    public X64Encoder Subps(byte dst, byte src) { Emit(0x0F, 0x5C).EmitModRM(3, dst, src); return this; }
    public X64Encoder Mulps(byte dst, byte src) { Emit(0x0F, 0x59).EmitModRM(3, dst, src); return this; }
    public X64Encoder Divps(byte dst, byte src) { Emit(0x0F, 0x5E).EmitModRM(3, dst, src); return this; }
    public X64Encoder Sqrtps(byte dst, byte src) { Emit(0x0F, 0x51).EmitModRM(3, dst, src); return this; }
    public X64Encoder Rsqrtps(byte dst, byte src) { Emit(0x0F, 0x52).EmitModRM(3, dst, src); return this; }
    public X64Encoder RcPSS(byte dst, byte src) { Emit(0x0F, 0x53).EmitModRM(3, dst, src); return this; }

    public X64Encoder MULps(byte dst, byte src) { Emit(0x0F, 0x59).EmitModRM(3, dst, src); return this; }
    public X64Encoder ADDSUBpd(byte dst, byte src) { Emit(0x66, 0x0F, 0xD0).EmitModRM(3, dst, src); return this; }
    public X64Encoder HADDpd(byte dst, byte src) { Emit(0x66, 0x0F, 0x7C).EmitModRM(3, dst, src); return this; }
    public X64Encoder HADDps(byte dst, byte src) { Emit(0xF2, 0x0F, 0x7C).EmitModRM(3, dst, src); return this; }

    public X64Encoder Ptest(byte dst, byte src) { Emit(0x66, 0x0F, 0x38, 0x17).EmitModRM(3, dst, src); return this; }
    public X64Encoder Pcmpeqd(byte dst, byte src) { Emit(0x0F, 0x76).EmitModRM(3, dst, src); return this; }
    public X64Encoder Pcmpeqb(byte dst, byte src) { Emit(0x0F, 0x74).EmitModRM(3, dst, src); return this; }
    public X64Encoder Pcmpeqw(byte dst, byte src) { Emit(0x0F, 0x75).EmitModRM(3, dst, src); return this; }
    public X64Encoder Pcmpgtb(byte dst, byte src) { Emit(0x0F, 0x64).EmitModRM(3, dst, src); return this; }
    public X64Encoder Pcmpgtd(byte dst, byte src) { Emit(0x0F, 0x66).EmitModRM(3, dst, src); return this; }
    public X64Encoder Pcmpgtw(byte dst, byte src) { Emit(0x0F, 0x65).EmitModRM(3, dst, src); return this; }

    public X64Encoder Vxorps(byte dst, byte src1, byte src2) { Emit(0x0F, 0x57).EmitModRM(3, src1, src2); return this; }
    public X64Encoder Vxorpd(byte dst, byte src1, byte src2) { Emit(0x66, 0x0F, 0x57).EmitModRM(3, src1, src2); return this; }
    public X64Encoder Vaddps(byte dst, byte src1, byte src2) { Emit(0x0F, 0x58).EmitModRM(3, src1, src2); return this; }
    public X64Encoder Vaddpd(byte dst, byte src1, byte src2) { Emit(0x66, 0x0F, 0x58).EmitModRM(3, src1, src2); return this; }
    public X64Encoder Vsubps(byte dst, byte src1, byte src2) { Emit(0x0F, 0x5C).EmitModRM(3, src1, src2); return this; }
    public X64Encoder Vmulps(byte dst, byte src1, byte src2) { Emit(0x0F, 0x59).EmitModRM(3, src1, src2); return this; }
    public X64Encoder Vdivps(byte dst, byte src1, byte src2) { Emit(0x0F, 0x5E).EmitModRM(3, src1, src2); return this; }
    public X64Encoder Vsqrtps(byte dst, byte src) { Emit(0x0F, 0x51).EmitModRM(3, dst, src); return this; }
    public X64Encoder Vrcpps(byte dst, byte src) { Emit(0x0F, 0x53).EmitModRM(3, dst, src); return this; }
    public X64Encoder Vrsqrtps(byte dst, byte src) { Emit(0x0F, 0x52).EmitModRM(3, dst, src); return this; }

    public X64Encoder Vfmadd132ps(byte dst, byte src1, byte src2) { Emit(0x66, 0x0F, 0x38, 0x98).EmitModRM(3, src1, src2); return this; }
    public X64Encoder Vfmadd213ps(byte dst, byte src1, byte src2) { Emit(0x66, 0x0F, 0x38, 0xA8).EmitModRM(3, src1, src2); return this; }
    public X64Encoder Vfmadd231ps(byte dst, byte src1, byte src2) { Emit(0x66, 0x0F, 0x38, 0xB8).EmitModRM(3, src1, src2); return this; }

    public X64Encoder Prefetch0(byte base_, int disp) { Emit(0x0F, 0x18, 0x00).EmitModRM(0, 0, 4).EmitSIB(0, 0, base_).Imm32(disp); return this; }
    public X64Encoder Prefetch1(byte base_, int disp) { Emit(0x0F, 0x18, 0x01).EmitModRM(0, 0, 4).EmitSIB(0, 0, base_).Imm32(disp); return this; }
    public X64Encoder Prefetch2(byte base_, int disp) { Emit(0x0F, 0x18, 0x02).EmitModRM(0, 0, 4).EmitSIB(0, 0, base_).Imm32(disp); return this; }

    public X64Encoder Cpuid() { Emit(0x0F, 0xA2); return this; }
    public X64Encoder Rdtsc() { Emit(0x0F, 0x31); return this; }
    public X64Encoder Rdtscp() { Emit(0x0F, 0x01, 0xF9); return this; }
    public X64Encoder Rdpmc() { Emit(0x0F, 0x33); return this; }

    public X64Encoder Pause() { Emit(0xF3, 0x90); return this; }
    public X64Encoder Nop() { Emit(0x90); return this; }
    public X64Encoder Nop(int count)
    {
        for (int i = 0; i < count; i++) Emit(0x90);
        return this;
    }

    public X64Encoder Int3() { Emit(0xCC); return this; }
    public X64Encoder Hlt() { Emit(0xF4); return this; }
}

public class AgnerFogTables
{
public class InstructionLatency
    {
        public string Name { get; set; } = "";
        public int Latency { get; set; }
        public int Throughput { get; set; }
        public int Port { get; set; }
        public string Arch { get; set; } = "";
    }

    private static readonly Dictionary<string, InstructionLatency[]> LatencyTable = new()
    {
        ["add"] = new[] {
            new InstructionLatency { Name = "add r, r", Latency = 1, Throughput = 1, Port = 0, Arch = "Skylake" },
            new InstructionLatency { Name = "add r, m", Latency = 3, Throughput = 1, Port = 2, Arch = "Skylake" }
        },
        ["mul"] = new[] {
            new InstructionLatency { Name = "mul r", Latency = 3, Throughput = 1, Port = 1, Arch = "Skylake" },
            new InstructionLatency { Name = "imul r", Latency = 3, Throughput = 1, Port = 1, Arch = "Skylake" }
        },
        ["div"] = new[] {
            new InstructionLatency { Name = "div r", Latency = 10, Throughput = 4, Port = 1, Arch = "Skylake" }
        },
        ["load"] = new[] {
            new InstructionLatency { Name = "mov r, [m]", Latency = 4, Throughput = 2, Port = 2, Arch = "Skylake" }
        },
        ["store"] = new[] {
            new InstructionLatency { Name = "mov [m], r", Latency = 4, Throughput = 2, Port = 2, Arch = "Skylake" }
        },
        ["fmadd"] = new[] {
            new InstructionLatency { Name = "vfmaddps", Latency = 4, Throughput = 2, Port = 0, Arch = "Skylake" }
        },
        ["vec_add"] = new[] {
            new InstructionLatency { Name = "vaddps", Latency = 4, Throughput = 2, Port = 1, Arch = "Skylake" }
        }
    };

    public InstructionLatency? GetLatency(string op, string variant = "r, r")
    {
        if (!LatencyTable.TryGetValue(op, out var entries))
            return null;

        foreach (var e in entries)
        {
            if (e.Name.Contains(variant))
                return e;
        }

        return entries.FirstOrDefault();
    }

    public int GetOptimalChoice(string[] ops, string arch = "Skylake")
    {
        int bestIdx = 0;
        int bestScore = int.MaxValue;

        for (int i = 0; i < ops.Length; i++)
        {
            var lat = GetLatency(ops[i]);
            int score = lat?.Latency ?? 1;
            if (score < bestScore)
            {
                bestScore = score;
                bestIdx = i;
            }
        }

        return bestIdx;
    }

    public string GetScheduleAdvice(string op, string arch = "Skylake")
    {
        var lat = GetLatency(op);
        if (lat == null) return "Use default scheduling";

        return $"Op: {lat.Name}, Latency: {lat.Latency}, Throughput: {lat.Throughput}, Port: {lat.Port}";
    }
}

public class InstructionSelector
{
    private AgnerFogTables agner = new();
    private List<string> schedule = new();

    public void SelectForTarget(string[] ops, string targetArch, out string[] selected, out string[] scheduleOrder)
    {
        var chosen = new List<string>();
        schedule.Clear();

        foreach (var op in ops)
        {
            string best = op;
            var alternatives = GetAlternatives(op);

            if (alternatives.Length > 1)
            {
                int idx = agner.GetOptimalChoice(alternatives, targetArch);
                best = alternatives[idx];
            }

            chosen.Add(best);
            schedule.Add($"{best}: {agner.GetScheduleAdvice(best, targetArch)}");
        }

        selected = chosen.ToArray();
        scheduleOrder = schedule.ToArray();
    }

    private string[] GetAlternatives(string op)
    {
        return op.ToLower() switch
        {
            "add" => new[] { "add", "lea" },
            "mul" => new[] { "mul", "lea" },
            "add_i" => new[] { "add", "sub" },
            "shift" => new[] { "shl", "sar", "shr" },
            "compare" => new[] { "cmp", "test" },
            "branch" => new[] { "jmp", "je", "jne" },
            _ => new[] { op }
        };
    }

    public string PrintSchedule()
    {
        return string.Join("\n", schedule);
    }
}

public class MicroOpFusion
{
    public class FusionPair
    {
        public string First { get; set; } = "";
        public string Second { get; set; } = "";
        public bool CanFuse { get; set; }
        public string FusedOp { get; set; } = "";
    }

    private static readonly Dictionary<(string, string), FusionPair> FusionRules = new()
    {
        [("cmp", "jne")] = new FusionPair { First = "cmp", Second = "jne", CanFuse = true, FusedOp = "cmovne" },
        [("add", "jno")] = new FusionPair { First = "add", Second = "jno", CanFuse = true, FusedOp = "cmovo" },
        [("test", "je")] = new FusionPair { First = "test", Second = "je", CanFuse = true, FusedOp = "cmove" },
        [("inc", "jmp")] = new FusionPair { First = "inc", Second = "jmp", CanFuse = false, FusedOp = "" },
        [("shl", "jnc")] = new FusionPair { First = "shl", Second = "jnc", CanFuse = true, FusedOp = "setnc" }
    };

    public FusionPair? CanFuse(string first, string second)
    {
        if (FusionRules.TryGetValue((first.ToLower(), second.ToLower()), out var pair))
            return pair;
        return null;
    }

    public string[] FuseSequence(string[] ops)
    {
        var result = new List<string>();
        int i = 0;

        while (i < ops.Length)
        {
            if (i + 1 < ops.Length)
            {
                var fuse = CanFuse(ops[i], ops[i + 1]);
                if (fuse?.CanFuse == true)
                {
                    result.Add(fuse.FusedOp);
                    i += 2;
                    continue;
                }
            }
            result.Add(ops[i]);
            i++;
        }

        return result.ToArray();
    }

    public string PrintFusions(string[] ops)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < ops.Length - 1; i++)
        {
            var fuse = CanFuse(ops[i], ops[i + 1]);
            sb.AppendLine($"{ops[i]} + {ops[i + 1]} -> {(fuse?.CanFuse == true ? fuse.FusedOp : "N/A")}");
        }
        return sb.ToString();
    }
}

public class LatencyEstimator
{
    private AgnerFogTables agner = new();
    private Dictionary<string, int> cache = new();

    public int EstimateLatency(string[] ops)
    {
        int total = 0;
        foreach (var op in ops)
        {
            var lat = agner.GetLatency(op);
            total += lat?.Latency ?? 1;
        }
        return total;
    }

    public double EstimateThroughput(string[] ops, int parallelism = 4)
    {
        int total = 0;
        foreach (var op in ops)
        {
            var lat = agner.GetLatency(op);
            total += lat != null ? lat.Throughput : 1;
        }
        return (double)total / parallelism;
    }

    public string Analyze(string[] ops)
    {
        var sb = new StringBuilder();
        sb.AppendLine("Latency Analysis:");
        sb.AppendLine($"Total ops: {ops.Length}");
        sb.AppendLine($"Est latency: {EstimateLatency(ops)} cycles");

        foreach (var op in ops.Distinct())
        {
            var lat = agner.GetLatency(op);
            sb.AppendLine($"  {op}: latency={lat?.Latency ?? 1}, throughput={lat?.Throughput ?? 1}");
        }

        return sb.ToString();
    }
}
