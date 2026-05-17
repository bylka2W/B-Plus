using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;

namespace BPlusTranspiler.AI;

public class ExecutableMemory
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr VirtualAlloc(IntPtr lpAddress, UIntPtr dwSize, uint flAllocationType, uint flProtect);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool VirtualFree(IntPtr lpAddress, UIntPtr dwSize, uint dwFreeType);

    private const uint MEM_COMMIT = 0x1000;
    private const uint MEM_RESERVE = 0x2000;
    private const uint PAGE_READWRITE = 0x04;
    private const uint PAGE_EXECUTE_READ = 0x20;
    private const uint PAGE_EXECUTE_READWRITE = 0x40;
    private const uint MEM_RELEASE = 0x8000;

    private IntPtr _mem;
    private long _size;

    public IntPtr Allocate(long size, bool executable = true)
    {
        _size = size;
        uint protect = executable ? PAGE_EXECUTE_READWRITE : PAGE_READWRITE;
        _mem = VirtualAlloc(IntPtr.Zero, (UIntPtr)size, MEM_COMMIT | MEM_RESERVE, protect);
        return _mem;
    }

    public void Free()
    {
        if (_mem != IntPtr.Zero)
        {
            VirtualFree(_mem, (UIntPtr)_size, MEM_RELEASE);
            _mem = IntPtr.Zero;
        }
    }

    public void Write(long offset, byte[] data)
    {
        if (_mem == IntPtr.Zero) return;
        Marshal.Copy(data, 0, IntPtr.Add(_mem, (int)offset), data.Length);
    }

    public void WriteByte(long offset, byte b)
    {
        if (_mem == IntPtr.Zero) return;
        Marshal.WriteByte(_mem, (int)offset, b);
    }

    public IntPtr GetBaseAddress() => _mem;

    public TDelegate GetDelegate<TDelegate>() where TDelegate : Delegate
    {
        return Marshal.GetDelegateForFunctionPointer<TDelegate>(_mem);
    }
}

public class PEBuilder
{
    private const ushort MachineX64 = 0x8664;
    private const ushort MagicPE64 = 0x20b;
    private const ushort SubsystemConsole = 3;
    private const uint BaseOfCode = 0x400000;
    private const uint SizeOfCode = 0x10000;
    private const uint SizeOfHeaders = 0x200;

    public class PEFile
    {
        public byte[] Data { get; set; } = Array.Empty<byte>();
        public long EntryPoint { get; set; }
        public string Path { get; set; } = "";
    }

    public PEFile Build(byte[] code, byte[]? data = null, byte[]? rsrc = null)
    {
        var pe = new List<byte>();

        int codeSize = (code.Length + 0xFFF) & ~0xFFF;
        int dataSize = data != null ? (data.Length + 0xFFF) & ~0xFFF : 0;
        int totalSize = 0x1000 + codeSize + dataSize;

        var dosHeader = new byte[0x80];
        dosHeader[0] = 0x4D; dosHeader[1] = 0x5A;
        Array.Copy(BitConverter.GetBytes(0x80), 0, dosHeader, 0x3C, 4);
        pe.AddRange(dosHeader);

        pe.AddRange(new byte[] { 0x50, 0x45, 0x00, 0x00 });
        pe.AddRange(BitConverter.GetBytes(MachineX64));
        pe.AddRange(BitConverter.GetBytes((ushort)1));
        pe.AddRange(new byte[] { 0, 0 });
        pe.AddRange(BitConverter.GetBytes((ushort)0));
        pe.AddRange(BitConverter.GetBytes((uint)0));
        pe.AddRange(BitConverter.GetBytes((uint)0));
        pe.AddRange(BitConverter.GetBytes((ushort)0xF0));
        pe.AddRange(BitConverter.GetBytes((ushort)0));

        int sections = 2 + (data != null ? 1 : 0);
        int optHeaderSize = 0xF0;
        int fileHeaderSize = 20 + sections * 40;

        pe.AddRange(BitConverter.GetBytes((uint)0x00000101));
        pe.AddRange(BitConverter.GetBytes((uint)0x400000));
        pe.AddRange(BitConverter.GetBytes((uint)0x1000));
        pe.AddRange(BitConverter.GetBytes((uint)0));
        pe.AddRange(BitConverter.GetBytes((uint)0));
        pe.AddRange(BitConverter.GetBytes((uint)0));
        pe.AddRange(BitConverter.GetBytes((uint)0));
        pe.AddRange(BitConverter.GetBytes((uint)0));
        pe.AddRange(BitConverter.GetBytes((uint)0x200));
        pe.AddRange(BitConverter.GetBytes((uint)0));
        pe.AddRange(BitConverter.GetBytes((uint)0));
        pe.AddRange(BitConverter.GetBytes((uint)0x140000));
        pe.AddRange(BitConverter.GetBytes((long)0));
        pe.AddRange(BitConverter.GetBytes(0L));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes((uint)0x10000));
        pe.AddRange(BitConverter.GetBytes((uint)0));
        pe.AddRange(BitConverter.GetBytes((ushort)SubsystemConsole));
        pe.AddRange(BitConverter.GetBytes((ushort)0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes((uint)0));
        pe.AddRange(BitConverter.GetBytes((ushort)0));
        pe.AddRange(BitConverter.GetBytes((ushort)0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes((uint)0x100000));
        pe.AddRange(BitConverter.GetBytes((uint)0x1000));
        pe.AddRange(BitConverter.GetBytes((uint)0));
        pe.AddRange(BitConverter.GetBytes((uint)0));
        pe.AddRange(BitConverter.GetBytes((ushort)0));
        pe.AddRange(BitConverter.GetBytes((ushort)0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes(0));
        pe.AddRange(BitConverter.GetBytes((uint)16));

        long headerSize = 0x80 + fileHeaderSize + optHeaderSize;
        while (pe.Count < headerSize) pe.Add(0);

        long textVA = 0x1000;
        long textFileOff = pe.Count;

        var textSec = new byte[40];
        byte[] name = Encoding.ASCII.GetBytes(".text");
        Array.Copy(name, 0, textSec, 0, name.Length);
        Array.Copy(BitConverter.GetBytes(code.Length), 0, textSec, 8, 4);
        Array.Copy(BitConverter.GetBytes((uint)textVA), 0, textSec, 12, 4);
        Array.Copy(BitConverter.GetBytes((uint)textFileOff), 0, textSec, 16, 4);
        Array.Copy(BitConverter.GetBytes((uint)code.Length), 0, textSec, 20, 4);
        Array.Copy(BitConverter.GetBytes(0), 0, textSec, 24, 4);
        Array.Copy(BitConverter.GetBytes(0), 0, textSec, 28, 4);
        Array.Copy(BitConverter.GetBytes(0), 0, textSec, 32, 4);
        Array.Copy(BitConverter.GetBytes(0x60000020), 0, textSec, 36, 4);
        pe.AddRange(textSec);

        long dataVA = textVA + codeSize;
        long dataFileOff = textFileOff + codeSize;

        var dataSec = new byte[40];
        byte[] dname = Encoding.ASCII.GetBytes(".data");
        Array.Copy(dname, 0, dataSec, 0, dname.Length);
        Array.Copy(BitConverter.GetBytes(data != null ? data.Length : 0), 0, dataSec, 8, 4);
        Array.Copy(BitConverter.GetBytes((uint)dataVA), 0, dataSec, 12, 4);
        Array.Copy(BitConverter.GetBytes((uint)dataFileOff), 0, dataSec, 16, 4);
        Array.Copy(BitConverter.GetBytes(data != null ? data.Length : 0), 0, dataSec, 20, 4);
        Array.Copy(BitConverter.GetBytes(0), 0, dataSec, 24, 4);
        Array.Copy(BitConverter.GetBytes(0), 0, dataSec, 28, 4);
        Array.Copy(BitConverter.GetBytes(0), 0, dataSec, 32, 4);
        Array.Copy(BitConverter.GetBytes(0xC0000040), 0, dataSec, 36, 4);
        pe.AddRange(dataSec);

        while (pe.Count < textFileOff) pe.Add(0);
        pe.AddRange(code);
        while (pe.Count < dataFileOff) pe.Add(0);
        if (data != null) pe.AddRange(data);

        return new PEFile { Data = pe.ToArray(), EntryPoint = textVA };
    }

    public void WriteFile(PEFile pe, string path)
    {
        File.WriteAllBytes(path, pe.Data);
        pe.Path = path;
    }
}

public class JITCompiler
{
    private ExecutableMemory mem = new();
    private X64Encoder enc = new();
    private PEBuilder peBuilder = new();

    public class CompileOptions
    {
        public bool GeneratePE { get; set; } = true;
        public bool GenerateELF { get; set; } = false;
        public bool GenerateMachO { get; set; } = false;
        public bool EnableOpt { get; set; } = true;
        public string OutputPath { get; set; } = "output.exe";
    }

    public class CompileOutput
    {
        public byte[] Code { get; set; } = Array.Empty<byte>();
        public byte[]? PE { get; set; }
        public long EntryPoint { get; set; }
        public Dictionary<string, long> Symbols { get; set; } = new();
        public TimeSpan CompileTime { get; set; }
        public long CodeSize { get; set; }
    }

    public CompileOutput Compile(X64Encoder code, CompileOptions opts)
    {
        var sw = Stopwatch.StartNew();
        var result = new CompileOutput();

        result.Code = code.Code;
        result.CodeSize = result.Code.Length;
        result.EntryPoint = code.BaseAddress;

        if (opts.GeneratePE)
        {
            var pe = peBuilder.Build(result.Code);
            peBuilder.WriteFile(pe, opts.OutputPath);
            result.PE = pe.Data;
        }

        sw.Stop();
        result.CompileTime = sw.Elapsed;
        return result;
    }

    public IntPtr AllocateAndExecute(byte[] code)
    {
        mem.Allocate(code.Length);
        mem.Write(0, code);
        return mem.GetBaseAddress();
    }

    public TFunc CompileAndExecute<TFunc>(X64Encoder code) where TFunc : Delegate
    {
        var ptr = AllocateAndExecute(code.Code);
        return Marshal.GetDelegateForFunctionPointer<TFunc>(ptr);
    }
}

public class SymbolResolver
{
    public Dictionary<string, long> Symbols { get; set; } = new();

    public void Add(string name, long addr)
    {
        Symbols[name] = addr;
    }

    public long? Resolve(string name)
    {
        return Symbols.GetValueOrDefault(name);
    }

    public void Relocate(PatchList patches)
    {
        patches.Apply(new byte[0], Symbols);
    }
}

public class CodeLayout
{
    public class LayoutResult
    {
        public byte[] Code { get; set; } = Array.Empty<byte>();
        public int HotPathLength { get; set; }
        public int ColdPathLength { get; set; }
        public double EstSpeedup { get; set; }
    }

    public LayoutResult Layout(byte[] code, int[] hotBlocks, int[] coldBlocks)
    {
        var hot = new List<byte>();
        var cold = new List<byte>();

        int hotSize = hotBlocks.Sum(b => b);
        int coldSize = coldBlocks.Sum(b => b);

        int pos = 0;
        for (int i = 0; i < hotBlocks.Length && pos < code.Length; i++)
        {
            int end = Math.Min(pos + hotBlocks[i], code.Length);
            for (int j = pos; j < end; j++) hot.Add(code[j]);
            pos = end;
        }

        for (int i = 0; i < coldBlocks.Length && pos < code.Length; i++)
        {
            int end = Math.Min(pos + coldBlocks[i], code.Length);
            for (int j = pos; j < end; j++) cold.Add(code[j]);
            pos = end;
        }

        hot.AddRange(cold);

        return new LayoutResult
        {
            Code = hot.ToArray(),
            HotPathLength = hot.Count,
            ColdPathLength = cold.Count,
            EstSpeedup = hotSize > 0 ? (double)(hotSize + coldSize) / hotSize : 1.0
        };
    }

    public string Analyze(byte[] code)
    {
        return $"Code size: {code.Length} bytes, Hot: {code.Length / 2}, Cold: {code.Length / 2}";
    }
}

public class ControlFlowGraph
{
    public class Block
    {
        public int Id { get; set; }
        public long Start { get; set; }
        public long End { get; set; }
        public List<int> Preds { get; set; } = new();
        public List<int> Succs { get; set; } = new();
        public int Size => (int)(End - Start);
    }

    public List<Block> Blocks { get; set; } = new();
    public int Entry { get; set; }

    public void BuildFromCode(byte[] code, int[] blockStarts)
    {
        Blocks.Clear();
        for (int i = 0; i < blockStarts.Length; i++)
        {
            var block = new Block
            {
                Id = i,
                Start = blockStarts[i],
                End = i + 1 < blockStarts.Length ? blockStarts[i + 1] : code.Length
            };

            if (i > 0) block.Preds.Add(i - 1);
            Blocks.Add(block);
        }

        Entry = 0;
    }

    public string Dump()
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("CFG:");
        foreach (var b in Blocks)
        {
            sb.AppendLine($"  B{b.Id}: [{b.Start}, {b.End}] size={b.Size}, preds={string.Join(",", b.Preds)}, succs={string.Join(",", b.Succs)}");
        }
        return sb.ToString();
    }
}

public class HotColdSplitter
{
    public class SplitResult
    {
        public byte[] Hot { get; set; } = Array.Empty<byte>();
        public byte[] Cold { get; set; } = Array.Empty<byte>();
        public int HotBlocks { get; set; }
        public int ColdBlocks { get; set; }
        public double EstSpeedup { get; set; }
    }

    public SplitResult Split(byte[] code, Dictionary<int, long> profile)
    {
        var hot = new List<byte>();
        var cold = new List<byte>();

        var sorted = profile.OrderByDescending(p => p.Value).Take(profile.Count / 2).Select(p => p.Key).ToHashSet();

        int pos = 0;
        int blockId = 0;
        int blockSize = 64;

        while (pos < code.Length)
        {
            int end = Math.Min(pos + blockSize, code.Length);
            if (sorted.Contains(blockId))
            {
                for (int i = pos; i < end; i++) hot.Add(code[i]);
            }
            else
            {
                for (int i = pos; i < end; i++) cold.Add(code[i]);
            }
            pos = end;
            blockId++;
        }

        return new SplitResult
        {
            Hot = hot.ToArray(),
            Cold = cold.ToArray(),
            HotBlocks = sorted.Count,
            ColdBlocks = profile.Count - sorted.Count,
            EstSpeedup = hot.Count > 0 ? (double)(hot.Count + cold.Count) / hot.Count : 1.0
        };
    }
}

public class DWARFDebugInfo
{
    public class DebugLine
    {
        public List<(long addr, string file, int line, string op)> Entries { get; set; } = new();
    }

    private List<DebugLine> lines = new();

    public void AddLine(long addr, string file, int line, string op = "")
    {
        if (lines.Count == 0) lines.Add(new DebugLine());
        lines[0].Entries.Add((addr, file, line, op));
    }

    public byte[] Generate()
    {
        var data = new List<byte>();
        data.AddRange(new byte[] { 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x00 });
        return data.ToArray();
    }
}

public class AIPerfCounters
{
    [DllImport("kernel32.dll")]
    private static extern bool QueryPerformanceCounter(out long lpPerformanceCount);

    [DllImport("kernel32.dll")]
    private static extern bool QueryPerformanceFrequency(out long lpFrequency);

    public class AIBenchmark
    {
        public string Name { get; set; } = "";
        public long Count { get; set; }
        public double Ms { get; set; }
    }

    public List<AIBenchmark> Benchmarks { get; set; } = new();
    private long start;

    public void Start() => QueryPerformanceCounter(out start);

    public long Stop()
    {
        QueryPerformanceCounter(out long end);
        QueryPerformanceFrequency(out long freq);
        double ms = (end - start) * 1000.0 / freq;
        Benchmarks.Add(new AIBenchmark { Name = "default", Count = end - start, Ms = ms });
        return end - start;
    }

    public void Add(string name, long count, double ms)
    {
        Benchmarks.Add(new AIBenchmark { Name = name, Count = count, Ms = ms });
    }

    public string Print()
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("Performance Benchmarks:");
        foreach (var c in Benchmarks)
        {
            sb.AppendLine($"  {c.Name}: {c.Count} ticks, {c.Ms:F3} ms");
        }
        return sb.ToString();
    }
}