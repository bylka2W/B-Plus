using System;
using System.IO;
using System.Text;

var path = @"C:\B+ v1.0\gen_x64\test_dispatch6.exe";
var buf = File.ReadAllBytes(path);
var dos = BitConverter.ToUInt32(buf, 0x3C);
int peOff = (int)dos;
Console.WriteLine($"PE offset: 0x{peOff:X}");
ushort numSections = BitConverter.ToUInt16(buf, peOff + 6);
int sectionsOff = peOff + 0xF8;
Console.WriteLine($"Sections: {numSections}");

for (int i = 0; i < numSections; i++)
{
    int secOff = sectionsOff + i * 40;
    string name = Encoding.ASCII.GetString(buf, secOff, 8).TrimEnd('\0');
    uint vsize = BitConverter.ToUInt32(buf, secOff + 8);
    uint vaddr = BitConverter.ToUInt32(buf, secOff + 12);
    uint rawSize = BitConverter.ToUInt32(buf, secOff + 16);
    uint rawOff = BitConverter.ToUInt32(buf, secOff + 20);
    Console.WriteLine($"Section {name}: VA=0x{vaddr:X4}, VSize={vsize}, RawOff=0x{rawOff:X4}, RawSize={rawSize}");
    if (name == ".text") 
    {
        Console.WriteLine("\n.text dump:");
        var text = new byte[rawSize];
        Array.Copy(buf, rawOff, text, 0, rawSize);
        for (int j = 0; j < rawSize; j++)
        {
            Console.Write($"{text[j]:X2} ");
            if ((j + 1) % 16 == 0) Console.WriteLine();
        }
        Console.WriteLine($"\n\nTotal: {rawSize} bytes");
    }
}
