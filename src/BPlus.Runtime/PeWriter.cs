using System;
using System.Collections.Generic;
using System.Text;

namespace BPlus.Runtime;

public static class PeWriter
{
    public static byte[] Write(byte[] code, int importDirRva, int idatSize)
    {
        int codeLen = code.Length;

        int fileAlign = 0x200;
        int sectAlign = 0x1000;
        int sectionRva = 0x1000;

        int headersSize = AlignUp(0x1B0, fileAlign); // 0x200
        int rawCodeSize = AlignUp(codeLen, fileAlign);

        int imageSize = sectionRva + AlignUp(codeLen, sectAlign);

        var pe = new List<byte>();

        // ── DOS Header ──
        pe.AddRange(new byte[] { 0x4D, 0x5A }); // e_magic "MZ"
        pe.AddRange(new byte[58]); // padding
        pe.AddRange(BitConverter.GetBytes(0x80u)); // e_lfanew

        // ── DOS stub ──
        pe.AddRange(new byte[64]);

        // ── PE signature ──
        pe.AddRange(new byte[] { 0x50, 0x45, 0x00, 0x00 }); // "PE\0\0"

        // ── IMAGE_FILE_HEADER ──
        pe.AddRange(BitConverter.GetBytes((ushort)0x8664)); // Machine = AMD64
        pe.AddRange(BitConverter.GetBytes((ushort)1));      // NumberOfSections
        pe.AddRange(new byte[4]);                           // TimeDateStamp
        pe.AddRange(new byte[4]);                           // PointerToSymbolTable
        pe.AddRange(new byte[4]);                           // NumberOfSymbols
        pe.AddRange(BitConverter.GetBytes((ushort)0xF0));  // SizeOfOptionalHeader
        pe.AddRange(BitConverter.GetBytes((ushort)0x0022));// Characteristics (EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE)

        // ── IMAGE_OPTIONAL_HEADER64 ──
        pe.AddRange(BitConverter.GetBytes((ushort)0x020B));// Magic = PE32+
        pe.AddRange(new byte[2]);                           // MajorLinkerVersion, MinorLinkerVersion
        pe.AddRange(new byte[4]);                           // SizeOfCode
        pe.AddRange(new byte[4]);                           // SizeOfInitializedData
        pe.AddRange(new byte[4]);                           // SizeOfUninitializedData
        pe.AddRange(BitConverter.GetBytes((uint)(sectionRva + 0))); // AddressOfEntryPoint
        pe.AddRange(BitConverter.GetBytes((uint)sectionRva));       // BaseOfCode
        pe.AddRange(new byte[8]);                           // ImageBase (default 0x140000000)
        pe.AddRange(BitConverter.GetBytes((uint)sectAlign));// SectionAlignment
        pe.AddRange(BitConverter.GetBytes((uint)fileAlign));// FileAlignment
        pe.AddRange(new byte[2]);                           // MajorOperatingSystemVersion
        pe.AddRange(new byte[2]);                           // MinorOperatingSystemVersion
        pe.AddRange(new byte[2]);                           // MajorImageVersion
        pe.AddRange(new byte[2]);                           // MinorImageVersion
        pe.AddRange(BitConverter.GetBytes((ushort)6));     // MajorSubsystemVersion (6 = Vista+)
        pe.AddRange(new byte[2]);                           // MinorSubsystemVersion
        pe.AddRange(new byte[4]);                           // Win32VersionValue
        pe.AddRange(BitConverter.GetBytes((uint)imageSize));// SizeOfImage
        pe.AddRange(BitConverter.GetBytes((uint)headersSize)); // SizeOfHeaders
        pe.AddRange(new byte[4]);                           // CheckSum
        pe.AddRange(BitConverter.GetBytes((ushort)3));     // Subsystem = CONSOLE
        pe.AddRange(new byte[2]);                           // DllCharacteristics
        pe.AddRange(new byte[8]);                           // SizeOfStackReserve
        pe.AddRange(new byte[8]);                           // SizeOfStackCommit
        pe.AddRange(new byte[8]);                           // SizeOfHeapReserve
        pe.AddRange(new byte[8]);                           // SizeOfHeapCommit
        pe.AddRange(new byte[4]);                           // LoaderFlags
        pe.AddRange(BitConverter.GetBytes(16u));           // NumberOfRvaAndSizes

        // ── Data directories (16 entries) ──
        int importDirRvaFinal = importDirRva != 0 ? sectionRva + importDirRva : 0;
        int importDirSize = idatSize;

        // [0] Export
        pe.AddRange(new byte[8]);
        // [1] Import
        pe.AddRange(BitConverter.GetBytes((uint)importDirRvaFinal));
        pe.AddRange(BitConverter.GetBytes((uint)importDirSize));
        // [2..15] rest
        for (int i = 0; i < 14; i++)
            pe.AddRange(new byte[8]);

        // ── Section table (.text) ──
        byte[] nameBytes = Encoding.ASCII.GetBytes(".text\0\0\0");
        pe.AddRange(nameBytes);
        pe.AddRange(BitConverter.GetBytes((uint)codeLen));          // VirtualSize
        pe.AddRange(BitConverter.GetBytes((uint)sectionRva));       // VirtualAddress
        pe.AddRange(BitConverter.GetBytes((uint)rawCodeSize));      // SizeOfRawData
        pe.AddRange(BitConverter.GetBytes((uint)headersSize));      // PointerToRawData
        pe.AddRange(new byte[4]);                                   // PointerToRelocations
        pe.AddRange(new byte[4]);                                   // PointerToLinenumbers
        pe.AddRange(new byte[2]);                                   // NumberOfRelocations
        pe.AddRange(new byte[2]);                                   // NumberOfLinenumbers
        pe.AddRange(BitConverter.GetBytes(0x60000020u));            // Characteristics: CODE | EXECUTE | READ

        // ── Align headers ──
        while (pe.Count < headersSize)
            pe.Add(0);

        // ── Write code ──
        pe.AddRange(code);

        // ── Zero-pad to raw size ──
        while (pe.Count < headersSize + rawCodeSize)
            pe.Add(0);

        return pe.ToArray();
    }

    private static int AlignUp(int v, int a) => (v + a - 1) / a * a;
}
