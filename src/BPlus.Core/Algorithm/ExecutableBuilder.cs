using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;

namespace BPlus.Core.Algorithm;

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
    private const ushort MagicPE32p = 0x20b;
    private const ushort SubsystemConsole = 3;

    public class PEFile
    {
        public byte[] Data { get; set; } = Array.Empty<byte>();
        public long EntryPoint { get; set; }
        public string Path { get; set; } = "";
    }

    public PEFile Build(byte[] code, byte[]? data = null, byte[]? rsrc = null,
        int importDirRva = 0, int importDirSize = 0)
    {
        uint fileAlign = 0x200;
        uint sectAlign = 0x1000;
        int codeRnd = (code.Length + (int)fileAlign - 1) & ~((int)fileAlign - 1);
        int dataRnd = data != null ? (data.Length + (int)fileAlign - 1) & ~((int)fileAlign - 1) : 0;
        int numSections = data != null ? 2 : 1;
        ushort optHdrSize = 240;
        ulong imageBase = 0x140000000;
        uint entryRva = 0x1000;

        // Pre-compute header size with file alignment
        uint hdrRaw = (uint)(0x40 + 4 + 20 + optHdrSize + 16 * 8 + (uint)numSections * 40);
        uint hdrSize = (hdrRaw + fileAlign - 1) & ~(fileAlign - 1);

        uint textRva = entryRva;
        uint textFileOff = hdrSize;
        uint codeRvaRnd = (uint)((code.Length + (int)sectAlign - 1) & ~((int)sectAlign - 1));
        uint dataRva = data != null ? textRva + codeRvaRnd : 0;

        uint sizeOfImage = data != null
            ? (dataRva + (uint)data.Length + sectAlign - 1) & ~(sectAlign - 1)
            : (textRva + codeRvaRnd + sectAlign - 1) & ~(sectAlign - 1);

        var ms = new MemoryStream();
        var bw = new BinaryWriter(ms);

        // ── DOS Header (64 bytes) ──
        bw.Write(new byte[0x40]);             // zeros
        ms.Seek(0, SeekOrigin.Begin);
        bw.Write((byte)0x4D); bw.Write((byte)0x5A);  // MZ
        ms.Seek(0x3C, SeekOrigin.Begin);
        bw.Write(0x40u);                      // e_lfanew
        ms.Seek(0x40, SeekOrigin.Begin);

        // ── PE Signature ──
        bw.Write("PE\0\0"u8);

        // ── COFF Header (20 bytes) ──
        bw.Write(MachineX64);
        bw.Write((ushort)numSections);
        bw.Write(0u);                         // TimeDateStamp
        bw.Write(0u);                         // PointerToSymbolTable
        bw.Write(0u);                         // NumberOfSymbols
        bw.Write(optHdrSize);
        bw.Write((ushort)0x22);               // Characteristics

        // ── Optional Header PE32+ (240 bytes) ──
        bw.Write(MagicPE32p);
        bw.Write((byte)0); bw.Write((byte)0); // Linker version
        bw.Write((uint)codeRnd);              // SizeOfCode
        bw.Write(data != null ? (uint)dataRnd : 0u);
        bw.Write(0u);                         // SizeOfUninitializedData
        bw.Write(entryRva);                   // AddressOfEntryPoint
        bw.Write(0x1000u);                    // BaseOfCode
        bw.Write(imageBase);                  // ImageBase
        bw.Write(sectAlign);                  // SectionAlignment
        bw.Write(fileAlign);                  // FileAlignment
        bw.Write((ushort)6);                  // MajorOSVersion
        bw.Write((ushort)0);                  // MinorOSVersion
        bw.Write((ushort)0);                  // MajorImageVersion
        bw.Write((ushort)0);                  // MinorImageVersion
        bw.Write((ushort)6);                  // MajorSubsystemVersion
        bw.Write((ushort)0);                  // MinorSubsystemVersion
        bw.Write(0u);                         // Win32VersionValue
        bw.Write(sizeOfImage);                // SizeOfImage
        bw.Write(hdrSize);                    // SizeOfHeaders
        bw.Write(0u);                         // CheckSum
        bw.Write(SubsystemConsole);
        bw.Write((ushort)0x8160);             // DllCharacteristics
        bw.Write(0x100000UL);                 // SizeOfStackReserve
        bw.Write(0x1000UL);                   // SizeOfStackCommit
        bw.Write(0x100000UL);                 // SizeOfHeapReserve
        bw.Write(0x1000UL);                   // SizeOfHeapCommit
        bw.Write(0u);                         // LoaderFlags
        bw.Write(16u);                        // NumberOfRvaAndSizes
        // Data directories (8 bytes each: RVA + Size)
        for (int i = 0; i < 16; i++)
        {
            if (i == 1) // IMAGE_DIRECTORY_ENTRY_IMPORT
            {
                bw.Write(importDirRva > 0 ? (uint)(textRva + importDirRva) : 0u);
                bw.Write(importDirSize > 0 ? (uint)importDirSize : 0u);
            }
            else
            {
                bw.Write(0L);
            }
        }

        // ── Section headers ──
        // .text
        bw.Write(".text\0\0\0"u8);            // Name
        bw.Write((uint)code.Length);           // VirtualSize
        bw.Write(textRva);                     // VirtualAddress
        bw.Write((uint)codeRnd);               // SizeOfRawData
        bw.Write(textFileOff);                 // PointerToRawData
        bw.Write(0u);                          // PointerToRelocations
        bw.Write(0u);                          // PointerToLineNumbers
        bw.Write((ushort)0);                   // NumberOfRelocations
        bw.Write((ushort)0);                   // NumberOfLinenumbers
        bw.Write(0xE0000020u);                 // Characteristics (code+execute+read+write for IAT)

        uint dataFileOff = data != null ? textFileOff + (uint)codeRnd : 0;

        if (data != null)
        {
            bw.Write(".data\0\0\0"u8);        // Name
            bw.Write((uint)data.Length);       // VirtualSize
            bw.Write(dataRva);                 // VirtualAddress
            bw.Write((uint)dataRnd);           // SizeOfRawData
            bw.Write(dataFileOff);             // PointerToRawData
            bw.Write(0u);                      // PointerToRelocations
            bw.Write(0u);                      // PointerToLineNumbers
            bw.Write((ushort)0);               // NumberOfRelocations
            bw.Write((ushort)0);               // NumberOfLinenumbers
            bw.Write(0xC0000040u);             // Characteristics
        }

        // ── Pad to hdrSize ──
        while (ms.Position < hdrSize)
            bw.Write((byte)0);

        // ── .text code ──
        bw.Write(code);
        while (ms.Position < textFileOff + (uint)codeRnd)
            bw.Write((byte)0);

        // ── .data ──
        if (data != null)
        {
            while (ms.Position < dataFileOff)
                bw.Write((byte)0);
            bw.Write(data);
            while (ms.Position < dataFileOff + (uint)dataRnd)
                bw.Write((byte)0);
        }

        bw.Flush();
        var pe = ms.ToArray();

        return new PEFile { Data = pe, EntryPoint = textRva };
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
