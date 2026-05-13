using System.Text;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Optimizer;

namespace BPlusTranspiler.Generators;

public static class LinkerScriptGenerator
{
    public static string Generate(ProgramNode program, List<TierResult> tiers, List<DataSection> dataSections)
    {
        var sb = new StringBuilder();
        sb.AppendLine("/* B+ v3.0.4L BETA Metal — Linker Script */");
        sb.AppendLine();
        sb.AppendLine("ENTRY(_start)");
        sb.AppendLine();
        sb.AppendLine("PHDRS {");
        sb.AppendLine("  L0_UCACHE PT_LOAD;");
        sb.AppendLine("  L1_ICACHE PT_LOAD;");
        sb.AppendLine("  L1_DCACHE PT_LOAD;");
        sb.AppendLine("  L2_CACHE  PT_LOAD;");
        sb.AppendLine("  L3_CACHE  PT_LOAD;");
        sb.AppendLine("  RAM       PT_LOAD;");
        sb.AppendLine("}");
        sb.AppendLine();

        sb.AppendLine("SECTIONS {");
        sb.AppendLine("  . = 0x1000000;  /* load base */");
        sb.AppendLine();

        // L0 — µop cache resident (within 16 bytes per bundle)
        sb.AppendLine("  .text.hot.L0 : ALIGN(16) {");
        sb.AppendLine("    *(.text.hot.L0*)");
        sb.AppendLine("  } : L0_UCACHE");
        sb.AppendLine();

        // L1-I — 32 KB code
        sb.AppendLine("  .text.hot.L1 : ALIGN(32) {");
        sb.AppendLine("    . = ALIGN(32);");
        bool hasL1 = false;
        foreach (var t in tiers)
        {
            if (t.Section == ".text.hot.L1")
            {
                sb.AppendLine($"    *(.text.hot.L1.{t.StateName})");
                hasL1 = true;
            }
        }
        if (!hasL1)
            sb.AppendLine("    *(.text.hot.L1*)");
        sb.AppendLine("  } : L1_ICACHE");
        sb.AppendLine();

        // L1-D — 32 KB data
        sb.AppendLine("  .data.hot.L1 : ALIGN(64) {");
        var l1Data = dataSections.Find(s => s.Section == ".data.hot.L1");
        if (l1Data != null && l1Data.Fields.Count > 0)
        {
            foreach (var f in l1Data.Fields)
                sb.AppendLine($"    {f.Name} = .;  /* offset {f.Offset}, size {f.Size} */");
            sb.AppendLine($"    . = ALIGN(64);");
        }
        else
        {
            sb.AppendLine("    . += 32768;  /* reserve 32 KB */");
        }
        sb.AppendLine("  } : L1_DCACHE");
        sb.AppendLine();

        // L2 — 256 KB
        sb.AppendLine("  .text.warm.L2 : ALIGN(64) {");
        foreach (var t in tiers)
        {
            if (t.Section == ".text.warm.L2")
                sb.AppendLine($"    *(.text.warm.L2.{t.StateName})");
        }
        sb.AppendLine("  } : L2_CACHE");
        sb.AppendLine();

        sb.AppendLine("  .data.warm.L2 : ALIGN(128) {");
        var l2Data = dataSections.Find(s => s.Section == ".data.warm.L2");
        if (l2Data != null && l2Data.Fields.Count > 0)
        {
            foreach (var f in l2Data.Fields)
                sb.AppendLine($"    {f.Name} = .;");
        }
        sb.AppendLine("  } : L2_CACHE");
        sb.AppendLine();

        // L3 — 2 MB
        sb.AppendLine("  .text.cold.L3 : ALIGN(128) {");
        foreach (var t in tiers)
        {
            if (t.Section == ".text.cold.L3")
                sb.AppendLine($"    *(.text.cold.L3.{t.StateName})");
        }
        sb.AppendLine("  } : L3_CACHE");
        sb.AppendLine();

        sb.AppendLine("  .data.cold.L3 : ALIGN(256) {");
        sb.AppendLine("  } : L3_CACHE");
        sb.AppendLine();

        // RAM — everything else
        sb.AppendLine("  .text : ALIGN(16) {");
        sb.AppendLine("    *(.text*)");
        sb.AppendLine("  } : RAM");
        sb.AppendLine();

        sb.AppendLine("  .data : ALIGN(16) {");
        sb.AppendLine("    *(.data*)");
        sb.AppendLine("  } : RAM");
        sb.AppendLine();

        sb.AppendLine("  .bss : ALIGN(16) {");
        sb.AppendLine("    *(.bss*)");
        sb.AppendLine("  } : RAM");
        sb.AppendLine();

        sb.AppendLine("  /DISCARD/ : { *(.comment) *(.note*) }");
        sb.AppendLine("}");

        return sb.ToString();
    }
}
