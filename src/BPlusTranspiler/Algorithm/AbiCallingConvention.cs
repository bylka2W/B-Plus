using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace BPlusTranspiler.Algorithm;

public enum AbiType { Windows, SystemV, FastCall }

public class WindowsX64Abi
{
    public static readonly int[] CalleeSaved = { 3, 12, 13, 14, 15 };
    public static readonly int[] CallerSaved = { 0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11 };
    public static readonly int[] IntegerParamRegs = { 1, 2, 8, 9 };
    public static readonly int[] FloatParamRegs = { 0, 1, 2, 3 };
    public static readonly int ShadowSpace = 32;

    public string GenPrologue(int localsSize)
    {
        var sb = new StringBuilder();
        sb.AppendLine("; Prologue");
        sb.AppendLine("push rbp");
        sb.AppendLine("mov rbp, rsp");
        sb.AppendLine($"sub rsp, {localsSize + 8}");
        foreach (int r in CalleeSaved)
            sb.AppendLine($"push r{r}");
        return sb.ToString();
    }

    public string GenEpilogue(int localsSize)
    {
        var sb = new StringBuilder();
        sb.AppendLine("; Epilogue");
        foreach (int r in CalleeSaved.AsEnumerable().Reverse())
            sb.AppendLine($"pop r{r}");
        sb.AppendLine($"add rsp, {localsSize + 8}");
        sb.AppendLine("pop rbp");
        sb.AppendLine("ret");
        return sb.ToString();
    }

    public string GenCall(string funcName, List<(int reg, double? immFloat, long? immInt)> args)
    {
        var sb = new StringBuilder();
        int intIdx = 0, floatIdx = 0;

        foreach (var (reg, immFloat, immInt) in args)
        {
            if (floatIdx < FloatParamRegs.Length)
            {
                if (immFloat.HasValue)
                    sb.AppendLine($"mov xmm{floatIdx}, {immFloat.Value}");
                else
                    sb.AppendLine($"mov xmm{floatIdx}, r{reg}");
                floatIdx++;
            }
            else if (intIdx < IntegerParamRegs.Length)
            {
                if (immInt.HasValue)
                    sb.AppendLine($"mov r{intIdx}, {immInt.Value}");
                else
                    sb.AppendLine($"mov r{intIdx}, r{reg}");
                intIdx++;
            }
        }

        sb.AppendLine($"sub rsp, {ShadowSpace}");
        sb.AppendLine($"call {funcName}");
        sb.AppendLine($"add rsp, {ShadowSpace}");
        return sb.ToString();
    }
}

public class SystemVX64Abi
{
    public static readonly int[] CalleeSaved = { 12, 13, 14, 15 };
    public static readonly int[] CallerSaved = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    public static readonly int[] IntegerParamRegs = { 5, 4, 3, 2, 8, 9 };
    public static readonly int[] FloatParamRegs = { 0, 1, 2, 3, 4, 5, 6, 7 };

    public string GenPrologue(int localsSize)
    {
        var sb = new StringBuilder();
        sb.AppendLine("; Prologue");
        sb.AppendLine("push rbp");
        sb.AppendLine("mov rbp, rsp");
        sb.AppendLine($"and rsp, ~0xF");
        sb.AppendLine($"sub rsp, {localsSize + 8}");
        foreach (int r in CalleeSaved)
            sb.AppendLine($"push r{r}");
        return sb.ToString();
    }

    public string GenEpilogue(int localsSize)
    {
        var sb = new StringBuilder();
        sb.AppendLine("; Epilogue");
        foreach (int r in CalleeSaved.AsEnumerable().Reverse())
            sb.AppendLine($"pop r{r}");
        sb.AppendLine($"mov rsp, rbp");
        sb.AppendLine("pop rbp");
        sb.AppendLine("ret");
        return sb.ToString();
    }

    public string GenCall(string funcName, List<(int reg, double? immFloat, long? immInt)> args)
    {
        var sb = new StringBuilder();
        int intIdx = 0, floatIdx = 0;

        foreach (var (reg, immFloat, immInt) in args)
        {
            if (floatIdx < FloatParamRegs.Length)
            {
                if (immFloat.HasValue)
                    sb.AppendLine($"mov xmm{floatIdx}, {immFloat.Value}");
                else
                    sb.AppendLine($"mov xmm{floatIdx}, r{reg}");
                floatIdx++;
            }
            else if (intIdx < IntegerParamRegs.Length)
            {
                if (immInt.HasValue)
                    sb.AppendLine($"mov r{intIdx}, {immInt.Value}");
                else
                    sb.AppendLine($"mov r{intIdx}, r{reg}");
                intIdx++;
            }
        }

        sb.AppendLine($"call {funcName}");
        return sb.ToString();
    }
}

public class VarargsSupport
{
    public class VarargInfo
    {
        public int GPRegCount { get; set; }
        public int FPRegCount { get; set; }
        public int StackArgsCount { get; set; }
        public List<long> StackValues { get; set; } = new();
    }

    public VarargInfo Analyze(List<(int reg, double? immFloat, long? immInt)> args)
    {
        var info = new VarargInfo();
        int gp = 0, fp = 0;

        foreach (var (reg, immFloat, immInt) in args)
        {
            if (immFloat.HasValue)
            {
                if (fp < 4) fp++;
                else info.StackValues.Add(BitConverter.DoubleToInt64Bits(immFloat.Value));
            }
            else if (immInt.HasValue)
            {
                if (gp < 4) gp++;
                else info.StackValues.Add(immInt.Value);
            }
            else
            {
                if (gp < 4) gp++;
                else info.StackValues.Add(reg);
            }
        }

        info.GPRegCount = gp;
        info.FPRegCount = fp;
        info.StackArgsCount = info.StackValues.Count;
        return info;
    }

    public string GenerateVAStart(string listPtr)
    {
        return $"mov rax, {listPtr}\nmov [rax], 0\nmov [rax+8], 0\n";
    }

    public string GenerateVAArg(string listPtr, string type)
    {
        return $"; TODO: va_arg implementation for {type}\n";
    }
}

public class ExceptionHandling
{
    public class UnwindInfo
    {
        public int Version { get; set; } = 1;
        public int Flags { get; set; }
        public int PrologSize { get; set; }
        public int UnwindCodeCount { get; set; }
        public List<UnwindCode> Codes { get; set; } = new();
        public int ExceptionHandler { get; set; }
        public int ChainedInfo { get; set; }
    }

    public class UnwindCode
    {
        public byte CodeOffset { get; set; }
        public byte UnwindOp { get; set; }
        public byte OpInfo { get; set; }
    }

    public UnwindInfo CreateUnwindInfo(string prolog, int handlerOffset)
    {
        var info = new UnwindInfo
        {
            PrologSize = prolog.Split('\n').Length,
            ExceptionHandler = handlerOffset
        };

        int offset = 0;
        foreach (var line in prolog.Split('\n'))
        {
            if (line.Contains("push rbp")) { info.Codes.Add(new UnwindCode { CodeOffset = (byte)offset, UnwindOp = 0, OpInfo = 1 }); offset += 1; }
            else if (line.Contains("mov rbp, rsp")) { offset += 3; }
            else if (line.Contains("sub rsp")) { info.Codes.Add(new UnwindCode { CodeOffset = (byte)offset, UnwindOp = 1, OpInfo = 0 }); offset += 7; }
            else if (line.Contains("push r")) { info.Codes.Add(new UnwindCode { CodeOffset = (byte)offset, UnwindOp = 0, OpInfo = 1 }); offset += 1; }
        }

        info.UnwindCodeCount = info.Codes.Count;
        return info;
    }

    public byte[] SerializeUnwindInfo(UnwindInfo info)
    {
        var data = new List<byte>();
        byte versionFlags = (byte)((info.Version & 3) | ((info.Flags & 7) << 2));
        data.Add(versionFlags);
        data.Add((byte)((info.PrologSize & 0xFF)));
        data.Add((byte)(info.UnwindCodeCount));
        data.Add((byte)(info.ExceptionHandler));

        foreach (var c in info.Codes)
        {
            data.Add(c.CodeOffset);
            byte op = (byte)((c.UnwindOp & 0xF) | ((c.OpInfo & 0xF) << 4));
            data.Add(op);
        }

        while (data.Count % 4 != 0)
            data.Add(0);

        return data.ToArray();
    }
}

public class StackAlignment
{
    public class AlignmentResult
    {
        public int OriginalOffset { get; set; }
        public int AlignedOffset { get; set; }
        public int Alignment { get; set; }
        public int Padding { get; set; }
    }

    public AlignmentResult Align(int offset, int alignment = 16)
    {
        int mod = offset % alignment;
        int padding = mod == 0 ? 0 : alignment - mod;

        return new AlignmentResult
        {
            OriginalOffset = offset,
            AlignedOffset = offset + padding,
            Alignment = alignment,
            Padding = padding
        };
    }

    public int GetFrameSize(int localsSize, int spillCount, int alignment = 16)
    {
        int raw = localsSize + spillCount * 8 + 8;
        int mod = raw % alignment;
        return mod == 0 ? raw : raw + alignment - mod;
    }

    public string GenAlignCheck(string tempReg, int alignment = 16)
    {
        return $"test {tempReg}, {alignment - 1}\njne .unaligned\n";
    }
}

public class ImmediateEncoder
{
    public class ImmEncoding
    {
        public int Size { get; set; }
        public long Value { get; set; }
        public string Comment { get; set; } = "";
    }

    public ImmEncoding Encode(long value)
    {
        if (value >= -128 && value <= 127)
            return new ImmEncoding { Size = 1, Value = value, Comment = "imm8" };

        if (value >= -32768 && value <= 32767)
            return new ImmEncoding { Size = 2, Value = value, Comment = "imm16" };

        if (value >= -2147483648 && value <= 2147483647)
            return new ImmEncoding { Size = 4, Value = value, Comment = "imm32" };

        return new ImmEncoding { Size = 8, Value = value, Comment = "imm64" };
    }

    public ImmEncoding EncodeFloat(double value)
    {
        long bits = BitConverter.DoubleToInt64Bits(value);
        return Encode(bits);
    }

    public byte[] EncodeModRM(byte mod, byte reg, byte rm)
    {
        byte modRM = (byte)((mod << 6) | ((reg & 7) << 3) | (rm & 7));
        return new[] { modRM };
    }

    public byte[] EncodeSIB(byte scale, byte index, byte base_)
    {
        return new[] { (byte)((scale << 6) | ((index & 7) << 3) | (base_ & 7)) };
    }

    public byte[] EncodeREX(byte w, byte r, byte x, byte b)
    {
        byte rex = (byte)(0x40 | ((w & 1) << 3) | ((r & 1) << 2) | ((x & 1) << 1) | (b & 1));
        return new[] { rex };
    }
}

public class ConstantPool
{
    private List<byte> pool = new();
    private int poolOffset = 0;
    private int alignment = 4;

    public long AddFloat(double value)
    {
        long offset = poolOffset;
        byte[] bits = BitConverter.GetBytes(value);
        pool.AddRange(bits);
        poolOffset += 8;
        return offset;
    }

    public long AddInt64(long value)
    {
        long offset = poolOffset;
        byte[] bits = BitConverter.GetBytes(value);
        pool.AddRange(bits);
        poolOffset += 8;
        return offset;
    }

    public long AddInt32(int value)
    {
        long offset = poolOffset;
        byte[] bits = BitConverter.GetBytes(value);
        pool.AddRange(bits);
        poolOffset += 4;
        return offset;
    }

    public long AddString(string str)
    {
        long offset = poolOffset;
        byte[] bytes = Encoding.UTF8.GetBytes(str + '\0');
        pool.AddRange(bytes);
        poolOffset += bytes.Length;
        return offset;
    }

    public byte[] Build()
    {
        var result = new List<byte>();
        while (result.Count % alignment != 0)
            result.Add(0);
        result.AddRange(pool);
        return result.ToArray();
    }

    public void Align(int align)
    {
        alignment = align;
        while (poolOffset % align != 0)
        {
            pool.Add(0);
            poolOffset++;
        }
    }

    public int Count => poolOffset;
}

public class PatchList
{
    public class Patch
    {
        public long Offset { get; set; }
        public PatchType Type { get; set; }
        public string? Symbol { get; set; }
        public long? TargetOffset { get; set; }
    }

    public enum PatchType { Relative32, Absolute64, Relative16, Absolute32, Call }

    public List<Patch> Patches { get; set; } = new();

    public void Add(long offset, PatchType type, string? symbol = null, long? target = null)
    {
        Patches.Add(new Patch { Offset = offset, Type = type, Symbol = symbol, TargetOffset = target });
    }

    public void Apply(byte[] code, Dictionary<string, long> symbols)
    {
        foreach (var p in Patches)
        {
            long target = p.TargetOffset ?? (symbols.GetValueOrDefault(p.Symbol ?? "") + p.Offset + 4);
            long offset = p.Offset;

            switch (p.Type)
            {
                case PatchType.Relative32:
                    long rel32 = target - (offset + 4);
                    BitConverter.GetBytes((int)rel32).CopyTo(code, (int)offset);
                    break;
                case PatchType.Absolute64:
                    BitConverter.GetBytes(target).CopyTo(code, (int)offset);
                    break;
                case PatchType.Relative16:
                    BitConverter.GetBytes((short)(target - (offset + 2))).CopyTo(code, (int)offset);
                    break;
                case PatchType.Absolute32:
                    BitConverter.GetBytes((int)target).CopyTo(code, (int)offset);
                    break;
            }
        }
    }
}

public class AbiDispatcher
{
    public string GenDispatch(AbiType abi)
    {
        return abi switch
        {
            AbiType.Windows => new WindowsX64Abi().GenPrologue(0),
            AbiType.SystemV => new SystemVX64Abi().GenPrologue(0),
            _ => "; Unknown ABI\n"
        };
    }

    public string GenerateFullFunction(string name, string body, AbiType abi, int localsSize = 0)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"; Function: {name} ({abi})");
        sb.AppendLine($"{name}:");

        if (abi == AbiType.Windows)
            sb.Append(new WindowsX64Abi().GenPrologue(localsSize));
        else
            sb.Append(new SystemVX64Abi().GenPrologue(localsSize));

        sb.Append(body);

        if (abi == AbiType.Windows)
            sb.Append(new WindowsX64Abi().GenEpilogue(localsSize));
        else
            sb.Append(new SystemVX64Abi().GenEpilogue(localsSize));

        return sb.ToString();
    }
}
