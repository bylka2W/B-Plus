using System.Text;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Optimizer;

namespace BPlusTranspiler.Generators;

// Profile data for BOLT/Propeller-style function layout optimization.
// Each entry records a function's execution count (from perf) and optional
// fall-through weight to guide cache-line placement.
public class ProfileEntry
{
    public string FunctionName { get; set; } = "";
    public ulong HotCount { get; set; }
    public ulong FallthroughWeight { get; set; }
}

public class ProfileData
{
    public List<ProfileEntry> Entries { get; } = new();

    // Default threshold: top 20% of functions by HotCount → hot partition
    public double HotThreshold { get; set; } = 0.2;

    // Compute which function names are in the hot partition
    public HashSet<string> GetHotFunctions()
    {
        if (Entries.Count == 0) return new HashSet<string>();

        var sorted = Entries.OrderByDescending(e => e.HotCount).ToList();
        var total = sorted.Sum(e => (double)e.HotCount);
        var hotSet = new HashSet<string>();
        double cumulative = 0;

        foreach (var e in sorted)
        {
            cumulative += e.HotCount;
            hotSet.Add(e.FunctionName);
            if (total > 0 && cumulative / total >= HotThreshold)
                break;
        }

        return hotSet;
    }

    // Detect cache-line conflicts between hot functions: group functions that
    // should occupy the same cache line (fall-through pairs)
    public List<List<string>> GetCacheLineGroups()
    {
        var groups = new List<List<string>>();
        var used = new HashSet<string>();

        const ulong fallthroughThreshold = 1000;

        foreach (var e in Entries.OrderByDescending(e => e.FallthroughWeight))
        {
            if (used.Contains(e.FunctionName) || e.FallthroughWeight < fallthroughThreshold)
                continue;
            used.Add(e.FunctionName);

            var group = new List<string> { e.FunctionName };
            var partner = Entries.FirstOrDefault(x =>
                !used.Contains(x.FunctionName) &&
                x.FunctionName != e.FunctionName &&
                x.FallthroughWeight >= fallthroughThreshold);
            if (partner != null)
            {
                used.Add(partner.FunctionName);
                group.Add(partner.FunctionName);
            }
            groups.Add(group);
        }

        return groups;
    }
}

public static class LinkerScriptGenerator
{
    public static string Generate(ProgramNode program, List<TierResult> tiers, List<DataSection> dataSections, ProfileData? profile = null)
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
        if (profile != null)
        {
            sb.AppendLine("  BOLT_TEXT PT_LOAD;");
            sb.AppendLine("  PROPELLER_TEXT PT_LOAD;");
        }
        sb.AppendLine("}");
        sb.AppendLine();

        sb.AppendLine("SECTIONS {");
        sb.AppendLine("  . = 0x1000000;  /* load base */");
        sb.AppendLine();

        // ── BOLT / Propeller layout sections (when profile data is present) ──
        HashSet<string>? hotFunctions = null;
        if (profile != null)
        {
            hotFunctions = profile.GetHotFunctions();
            var cacheLineGroups = profile.GetCacheLineGroups();
            var groupedFns = cacheLineGroups.SelectMany(g => g).ToHashSet();

            // BOLT-style: hot functions grouped in __bolt_text_hot
            sb.AppendLine("  /* BOLT profile-guided layout */");
            sb.AppendLine("  __bolt_text_hot : ALIGN(64) {");
            sb.AppendLine("    __bolt_hot_start = .;");
            foreach (var group in cacheLineGroups)
            {
                sb.Append("    KEEP(*(");
                sb.Append(string.Join(" ", group.Select(f => $".bolt.hot.{f}")));
                sb.AppendLine("))");
            }
            foreach (var fn in hotFunctions.Where(f => !groupedFns.Contains(f)))
                sb.AppendLine($"    *(.bolt.hot.{fn})");
            sb.AppendLine("    __bolt_hot_end = .;");
            sb.AppendLine("  } : BOLT_TEXT");
            sb.AppendLine();

            // Propeller-style: sorted-by-name sub-sections for cold functions
            sb.AppendLine("  /* Propeller SORT_BY_NAME layout */");
            sb.AppendLine("  __propeller_text_cold : ALIGN(64) {");
            sb.AppendLine("    __propeller_cold_start = .;");
            foreach (var t in tiers)
            {
                if (!hotFunctions.Contains(t.StateName))
                    sb.AppendLine($"    *(.propeller.cold.{t.StateName})");
            }
            sb.AppendLine("    __propeller_cold_end = .;");
            sb.AppendLine("  } : PROPELLER_TEXT");
            sb.AppendLine();
        }

        bool IsHot(string stateName) => hotFunctions == null || hotFunctions.Contains(stateName);

        // L0 — µop cache resident (within 16 bytes per bundle)
        sb.AppendLine("  .text.hot.L0 : ALIGN(16) {");
        bool hasL0 = false;
        foreach (var t in tiers)
        {
            if (IsHot(t.StateName) && t.Section == ".text.hot.L0")
            {
                sb.AppendLine($"    *(.text.hot.L0.{t.StateName})");
                hasL0 = true;
            }
        }
        if (!hasL0)
            sb.AppendLine("    *(.text.hot.L0*)");
        sb.AppendLine("  } : L0_UCACHE");
        sb.AppendLine();

        // L1-I — 32 KB code
        sb.AppendLine("  .text.hot.L1 : ALIGN(32) {");
        sb.AppendLine("    . = ALIGN(32);");
        bool hasL1 = false;
        foreach (var t in tiers)
        {
            if (IsHot(t.StateName) && t.Section == ".text.hot.L1")
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
            if (IsHot(t.StateName) && t.Section == ".text.warm.L2")
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
            if (IsHot(t.StateName) && t.Section == ".text.cold.L3")
                sb.AppendLine($"    *(.text.cold.L3.{t.StateName})");
        }
        sb.AppendLine("  } : L3_CACHE");
        sb.AppendLine();

        sb.AppendLine("  .data.cold.L3 : ALIGN(256) {");
        sb.AppendLine("  } : L3_CACHE");
        sb.AppendLine();

        // RAM — everything else
        sb.AppendLine("  .text : ALIGN(16) {");
        if (hotFunctions != null)
        {
            foreach (var t in tiers)
            {
                if (!hotFunctions.Contains(t.StateName))
                    sb.AppendLine($"    *(.text.cold.{t.StateName})");
            }
        }
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
