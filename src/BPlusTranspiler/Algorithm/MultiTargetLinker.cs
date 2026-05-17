using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace BPlusTranspiler.Algorithm;

public enum ExecutableFormat { PE, ELF, MachO }

public class Relocation
{
    public long Offset { get; set; }
    public RelocType Type { get; set; }
    public string? SymbolName { get; set; }
    public long Addend { get; set; }

    public enum RelocType
    {
        Absolute64,
        Relative64,
        Relative32,
        Absolute32,
        Relative16,
        Absolute16
    }
}

public class Symbol
{
    public string Name { get; set; } = "";
    public long Value { get; set; }
    public int Size { get; set; }
    public SymbolType Type { get; set; }
    public SymbolBinding Binding { get; set; }
    public int SectionIndex { get; set; }
    public bool IsDefined => SectionIndex >= 0;

    public enum SymbolType { NoType, Object, Function, File, Common, Section }
    public enum SymbolBinding { Local, Global, Weak }
}

public class Section
{
    public string Name { get; set; } = "";
    public byte[] Data { get; set; } = Array.Empty<byte>();
    public SectionFlags Flags { get; set; }
    public int Alignment { get; set; } = 1;
    public List<Relocation> Relocations { get; set; } = new();
    public long VirtualAddress { get; set; }
    public long FileOffset { get; set; }
    public long VirtualSize { get; set; }

    [Flags]
    public enum SectionFlags
    {
        None = 0,
        Executable = 1,
        Writable = 2,
        Readable = 4,
        Alloc = 8,
        Initialize = 16,
        NonHeap = 32,
        Shareable = 64
    }
}

public class ObjectFile
{
    public List<Section> Sections { get; set; } = new();
    public Dictionary<string, Symbol> Symbols { get; set; } = new();
    public List<Relocation> Relocations { get; set; } = new();
}

public class PELinker
{
    private const ushort MachineX64 = 0x8664;
    private const ushort MagicPE64 = 0x20b;

    public byte[] BuildPe(ObjectFile obj, List<ObjectFile> libs)
    {
        var sections = new List<Section>();
        foreach (var s in obj.Sections)
            sections.Add(s);

        foreach (var lib in libs)
            foreach (var s in lib.Sections)
                sections.Add(s);

        long textSize = sections.Sum(s => s.Data.Length);
        long totalSize = textSize + sections.Count * 256 + 0x1000;

        var pe = new List<byte>();

        var dosHeader = new byte[0x80];
        dosHeader[0] = 0x4D; dosHeader[1] = 0x5A;
        Array.Copy(BitConverter.GetBytes(0x80), 0, dosHeader, 0x3C, 4);
        pe.AddRange(dosHeader);

        pe.AddRange(new byte[] { 0x50, 0x45, 0x00, 0x00 });
        pe.AddRange(BitConverter.GetBytes((ushort)MagicPE64));
        pe.AddRange(BitConverter.GetBytes((ushort)1));
        pe.AddRange(new byte[] { 0, 0 });
        pe.AddRange(BitConverter.GetBytes((uint)0));
        pe.AddRange(BitConverter.GetBytes((uint)0));
        pe.AddRange(BitConverter.GetBytes((ushort)0xF0));
        pe.AddRange(BitConverter.GetBytes((ushort)0));

        int sectionCount = sections.Count;
        int optHeaderSize = 0xF0;
        int fileHeaderSize = 20 + sectionCount * 40;
        long headerSize = 0x80 + fileHeaderSize + optHeaderSize;

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

        long offset = headerSize;
        foreach (var sec in sections)
        {
            int paddedSize = (sec.Data.Length + 0xFFF) & ~0xFFF;
            offset += paddedSize;
        }

        var sectionHeaders = new List<byte[]>();
        long textOffset = headerSize;
        long va = 0x1000;
        foreach (var sec in sections)
        {
            var sh = new byte[40];
            byte[] nameBytes = sec.Name.Length > 8
                ? Encoding.ASCII.GetBytes(sec.Name[..8])
                : Encoding.ASCII.GetBytes(sec.Name);
            Array.Copy(nameBytes, 0, sh, 0, nameBytes.Length);
            Array.Copy(BitConverter.GetBytes(sec.Data.Length), 0, sh, 8, 4);
            Array.Copy(BitConverter.GetBytes((uint)va), 0, sh, 12, 4);
            Array.Copy(BitConverter.GetBytes((uint)textOffset), 0, sh, 16, 4);
            Array.Copy(BitConverter.GetBytes((uint)sec.Data.Length), 0, sh, 20, 4);
            Array.Copy(BitConverter.GetBytes(0), 0, sh, 24, 4);
            Array.Copy(BitConverter.GetBytes(0), 0, sh, 28, 4);
            Array.Copy(BitConverter.GetBytes(0), 0, sh, 32, 4);
            Array.Copy(BitConverter.GetBytes(0), 0, sh, 36, 4);

            uint flags = 0;
            if (sec.Name == ".text") flags = 0x60000020;
            else if (sec.Name == ".data") flags = 0xC0000040;
            else if (sec.Name == ".rdata") flags = 0x40000040;
            else if (sec.Name == ".reloc") flags = 0x42000040;
            Array.Copy(BitConverter.GetBytes(flags), 0, sh, 36, 4);

            sectionHeaders.Add(sh);
            textOffset += (sec.Data.Length + 0xFFF) & ~0xFFF;
            va += (sec.Data.Length + 0xFFF) & ~0xFFF;
        }

        foreach (var sh in sectionHeaders)
            pe.AddRange(sh);

        pe.AlignTo(0x200);

        foreach (var sec in sections)
        {
            pe.AddRange(sec.Data);
            pe.AlignTo(0x200);
        }

        return pe.ToArray();
    }
}

public class ELFLinker
{
    private const byte ELFCLASS64 = 2;
    private const byte ELFDATA2LSB = 1;
    private const byte ETEXEC = 2;
    private const byte EMX86_64 = 62;

    public byte[] BuildElf(ObjectFile obj, List<ObjectFile> libs)
    {
        var sections = new List<Section>();
        foreach (var s in obj.Sections)
            sections.Add(s);
        foreach (var lib in libs)
            foreach (var s in lib.Sections)
                sections.Add(s);

        int shstrtabIdx = sections.Count + 1;
        int symtabIdx = sections.Count + 2;
        int strtabIdx = sections.Count + 3;
        int relIdx = sections.Count + 4;

        int eShEntSize = 64;
        int eShNum = sections.Count + 5;

        long ehdrSize = 64;
        long shdrOffset = ehdrSize;
        long dataOffset = 0;

        foreach (var sec in sections)
            dataOffset += (sec.Data.Length + sec.Alignment - 1) & ~(sec.Alignment - 1);
        long shstrtabOffset = dataOffset;
        long symtabOffset = shstrtabOffset + 256;
        long strtabOffset = symtabOffset + (obj.Symbols.Count + 1) * 24;
        long relOffset = strtabOffset + 256;
        long shdrStart = relOffset + obj.Relocations.Count * 24;

        var elf = new List<byte>();

        elf.AddRange(new byte[] { 0x7F, 0x45, 0x4C, 0x46 });
        elf.Add(ELFCLASS64);
        elf.Add(ELFDATA2LSB);
        elf.Add(1);
        elf.Add(0);
        elf.AddRange(new byte[] { 0, 0, 0, 0, 0, 0 });

        elf.AddRange(BitConverter.GetBytes((ushort)ETEXEC));
        elf.AddRange(BitConverter.GetBytes((ushort)EMX86_64));
        elf.AddRange(BitConverter.GetBytes(1));
        elf.AddRange(BitConverter.GetBytes((ulong)0x400000));
        elf.AddRange(BitConverter.GetBytes((ulong)ehdrSize));
        elf.AddRange(BitConverter.GetBytes((ulong)0));
        elf.AddRange(BitConverter.GetBytes((ulong)0));
        elf.AddRange(BitConverter.GetBytes(0));
        elf.AddRange(BitConverter.GetBytes((uint)64));
        elf.AddRange(BitConverter.GetBytes((ushort)eShEntSize));
        elf.AddRange(BitConverter.GetBytes((ushort)eShNum));
        elf.AddRange(BitConverter.GetBytes((ushort)shstrtabIdx));

        elf.AlignTo(8);
        long pos = elf.Count;

        foreach (var sec in sections)
        {
            elf.AddRange(sec.Data);
            elf.AlignTo(sec.Alignment);
        }

        var shstrtab = new StringBuilder();
        shstrtab.Append('\0');
        foreach (var sec in sections)
        {
            sec.Name = shstrtab.ToString();
            shstrtab.Append(sec.Name + '\0');
        }
        shstrtab.Append(".shstrtab\0").Append(".symtab\0").Append(".strtab\0").Append(".rel.text\0");
        elf.AddRange(Encoding.ASCII.GetBytes(shstrtab.ToString()));
        elf.AlignTo(8);

        foreach (var sym in obj.Symbols.Values)
        {
            int nameIdx = 0;
            elf.AddRange(BitConverter.GetBytes((uint)nameIdx));
            elf.Add((byte)(sym.Binding == Symbol.SymbolBinding.Global ? 0x12 : 0x11));
            elf.Add(0);
            elf.AddRange(BitConverter.GetBytes((ushort)0));
            elf.AddRange(BitConverter.GetBytes((ulong)sym.Value));
            elf.AddRange(BitConverter.GetBytes((ulong)sym.Size));
        }
        elf.AddRange(new byte[24]);

        foreach (var rel in obj.Relocations)
        {
            elf.AddRange(BitConverter.GetBytes((ulong)rel.Offset));
            elf.AddRange(BitConverter.GetBytes(8));
            elf.AddRange(BitConverter.GetBytes((uint)4));
        }

        elf.AlignTo(8);

        long currPos = elf.Count;
        while (currPos < shdrStart)
        {
            elf.Add(0);
            currPos++;
        }

        foreach (var sec in sections)
        {
            elf.AddRange(new byte[64]);
        }
        elf.AddRange(new byte[64]);
        elf.AddRange(new byte[64]);
        elf.AddRange(new byte[64]);
        elf.AddRange(new byte[64]);

        return elf.ToArray();
    }
}

public class MachOLinker
{
    private const uint MH_MAGIC_64 = 0xFEEDFACF;

    public byte[] BuildMachO(ObjectFile obj, List<ObjectFile> libs)
    {
        var sections = new List<Section>();
        foreach (var s in obj.Sections)
            sections.Add(s);
        foreach (var lib in libs)
            foreach (var s in lib.Sections)
                sections.Add(s);

        long headerSize = 32 + sections.Count * 80;
        var macho = new List<byte>();

        macho.AddRange(BitConverter.GetBytes(MH_MAGIC_64));
        macho.AddRange(BitConverter.GetBytes((uint)0x01000007));
        macho.AddRange(BitConverter.GetBytes((uint)0));
        macho.AddRange(BitConverter.GetBytes((uint)sections.Count + 2));
        macho.AddRange(BitConverter.GetBytes((uint)0));
        macho.AddRange(BitConverter.GetBytes((uint)0x02000000));
        macho.AddRange(BitConverter.GetBytes((uint)0));
        macho.AddRange(BitConverter.GetBytes((uint)0));
        macho.AddRange(BitConverter.GetBytes((uint)0));

        long dataOffset = headerSize;
        long textStart = 0x1000;

        foreach (var sec in sections)
        {
            var seg = new List<byte>();
            seg.AddRange(new byte[16]);
            seg.AddRange(new byte[24]);
            seg.AddRange(BitConverter.GetBytes((ulong)textStart));
            seg.AddRange(BitConverter.GetBytes((ulong)sec.Data.LongLength));
            seg.AddRange(BitConverter.GetBytes((ulong)dataOffset));
            seg.AddRange(BitConverter.GetBytes((ulong)sec.Data.LongLength));
            seg.AddRange(BitConverter.GetBytes((uint)7));
            seg.AddRange(BitConverter.GetBytes((uint)0));
            macho.AddRange(seg);
        }

        macho.AddRange(new byte[80]);
        macho.AddRange(new byte[80]);

        macho.AlignTo(0x1000);
        dataOffset = macho.Count;

        foreach (var sec in sections)
        {
            macho.AddRange(sec.Data);
            macho.AlignTo(0x1000);
        }

        return macho.ToArray();
    }
}

public class MultiTargetLinker
{
    public byte[] Link(ObjectFile obj, ExecutableFormat format, List<ObjectFile> libs)
    {
        return format switch
        {
            ExecutableFormat.PE => new PELinker().BuildPe(obj, libs),
            ExecutableFormat.ELF => new ELFLinker().BuildElf(obj, libs),
            ExecutableFormat.MachO => new MachOLinker().BuildMachO(obj, libs),
            _ => throw new ArgumentException($"Unsupported format: {format}")
        };
    }

    public void WriteFile(byte[] data, string path)
    {
        File.WriteAllBytes(path, data);
    }

    public ObjectFile CreateObject(string name)
    {
        return new ObjectFile
        {
            Sections = new List<Section>
            {
                new Section
                {
                    Name = ".text",
                    Flags = Section.SectionFlags.Executable | Section.SectionFlags.Alloc,
                    Alignment = 16
                },
                new Section
                {
                    Name = ".data",
                    Flags = Section.SectionFlags.Writable | Section.SectionFlags.Alloc,
                    Alignment = 8
                }
            }
        };
    }

    public void AddSection(ObjectFile obj, Section sec)
    {
        obj.Sections.Add(sec);
    }

    public void AddSymbol(ObjectFile obj, Symbol sym)
    {
        obj.Symbols[sym.Name] = sym;
    }

    public void AddRelocation(ObjectFile obj, Relocation rel)
    {
        obj.Relocations.Add(rel);
    }
}

internal static class ListExtensions
{
    public static void AlignTo(this List<byte> list, int alignment)
    {
        while (list.Count % alignment != 0)
            list.Add(0);
    }
}
