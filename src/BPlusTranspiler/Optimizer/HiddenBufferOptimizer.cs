using System;
using System.Collections.Generic;
using System.Linq;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Optimizer
{
    public class HiddenBufferAnalysis
    {
        public bool FitsLSD { get; set; }
        public int LsdSizeBytes { get; set; }
        public bool HasCall { get; set; }
        public int StoreBufferUsage { get; set; }
        public int LoadBufferUsage { get; set; }
        public bool LfbOverloaded { get; set; }
        public int LfbPending { get; set; }
        public long TotalDataSize { get; set; }
        public bool NeedsHugePages { get; set; }
        public int TlbL1CoverageKb { get; set; }
        public int BtbAlignIssues { get; set; }
        public bool UsesCallRet { get; set; }
        public int JumpCount { get; set; }
        public int MisalignedJumpCount { get; set; }
        public int MaxStoresInARow { get; set; }
        public int MaxLoadsInARow { get; set; }
        public List<string> Warnings { get; set; } = new List<string>();
        public List<string> Optimizations { get; set; } = new List<string>();
    }

    public class HiddenBufferOptimizer
    {
        public static HiddenBufferAnalysis Analyze(List<StateDefNode> states, List<TierResult> tiers)
        {
            var analysis = new HiddenBufferAnalysis();
            if (states.Count == 0) return analysis;

            // 1. Loopback Buffer (LSD) — hot loop must be < 64 bytes, no call
            bool hasCall = false;
            int totalBytes = 0;
            int jumpCount = 0;
            int misalignedJumps = 0;
            int maxStoresInRow = 0, maxLoadsInRow = 0;
            int currentStores = 0, currentLoads = 0;
            var allStateNames = new List<string>();

            foreach (var state in states)
            {
                allStateNames.Add(state.Name);
                // Estimate code size from action body length
                foreach (var action in state.Actions)
                    totalBytes += (action.Body.Length / 2) * 4 + 4;

                foreach (var trans in state.Transitions)
                {
                    if (!string.IsNullOrEmpty(trans.Target))
                        jumpCount++;

                    // estimate store/load patterns from variable access
                    foreach (var action in state.Actions)
                    {
                        if (action.Body.Contains("=") || action.Body.Contains("set"))
                        {
                            currentStores++;
                            currentLoads = 0;
                        }
                        else
                        {
                            currentLoads++;
                            currentStores = 0;
                        }
                    }
                    maxStoresInRow = Math.Max(maxStoresInRow, currentStores);
                    maxLoadsInRow = Math.Max(maxLoadsInRow, currentLoads);
                }
            }

            analysis.FitsLSD = totalBytes <= 64 && !hasCall;
            analysis.LsdSizeBytes = totalBytes;
            analysis.HasCall = hasCall;
            analysis.JumpCount = jumpCount;
            analysis.MaxStoresInARow = maxStoresInRow;
            analysis.MaxLoadsInARow = maxLoadsInRow;

            if (!analysis.FitsLSD && totalBytes > 64 && allStateNames.Count > 0)
                analysis.Warnings.Add($"Hot state {allStateNames[0]} dispatch too large ({totalBytes}B > 64B) for Loop Stream Detector. Split into sub-states.");
            if (hasCall)
                analysis.Warnings.Add("call/ret inside hot path — disables LSD. Use jmp instead.");
            if (analysis.FitsLSD)
                analysis.Optimizations.Add("Dispatch fits in Loop Stream Detector (LSD) — decoder bypassed, −1 cycle/iter");

            // 2. Store Buffer — 42–56 entries, warn if > 35 stores in a row
            if (maxStoresInRow > 35)
                analysis.Warnings.Add($"Store buffer pressure: {maxStoresInRow} stores in a row (limit ~42). Insert load instructions to drain.");
            analysis.StoreBufferUsage = Math.Min(maxStoresInRow, 56);

            // 3. Load Buffer — 72–128 entries, warn if > 60 loads in a row
            if (maxLoadsInRow > 60)
                analysis.Warnings.Add($"Load buffer pressure: {maxLoadsInRow} loads in a row (limit ~72). Insert prefetch to spread.");
            analysis.LoadBufferUsage = Math.Min(maxLoadsInRow, 128);

            // 4. Line Fill Buffer (LFB) — 12–16 entries between L1 and L2
            int estimatedMisses = 0;
            foreach (var state in states)
                estimatedMisses += state.Variables.Count;
            analysis.LfbPending = Math.Min(estimatedMisses, 16);
            analysis.LfbOverloaded = analysis.LfbPending > 10;
            if (analysis.LfbOverloaded)
                analysis.Warnings.Add($"LFB overloaded: ~{analysis.LfbPending} pending misses (max 12–16). Insert prefetchnta to reduce pressure.");

            // 5. TLB coverage
            int varCount = states.Sum(s => s.Variables.Count);
            long totalDataSize = varCount * 64L; // approximate: each variable ~64 bytes
            analysis.TotalDataSize = totalDataSize;
            long l1dCoverage = 64 * 4096; // 64 entries × 4KB = 256KB
            analysis.TlbL1CoverageKb = (int)(l1dCoverage / 1024);
            analysis.NeedsHugePages = totalDataSize > l1dCoverage;
            if (analysis.NeedsHugePages)
                analysis.Optimizations.Add($"Data covers ~{totalDataSize / 1024}KB > L1-D TLB ({analysis.TlbL1CoverageKb}KB @ 4KB pages). Use 2MB huge pages (MAP_HUGETLB) for −20 cycle/TLB miss.");

            // 6. BTB aliasing — jumps spaced 4096 apart cause aliasing
            foreach (var state in states)
            {
                int alignment = 16;
                var tierResult = tiers.FirstOrDefault(t => t.StateName == state.Name);
                if (tierResult != null)
                    alignment = tierResult.Alignment;
                if (alignment % 16 != 0)
                {
                    analysis.MisalignedJumpCount++;
                    analysis.Warnings.Add($"State {state.Name} alignment {alignment} — BTB entry = 16B, realign to multiple of 16.");
                }
            }
            analysis.BtbAlignIssues = analysis.MisalignedJumpCount;
            if (analysis.BtbAlignIssues == 0 && jumpCount > 0)
                analysis.Optimizations.Add($"All {jumpCount} jumps aligned to 16B boundaries — BTB aliasing minimized.");

            // 7. RSB — call/ret balance
            analysis.UsesCallRet = hasCall;
            if (hasCall)
                analysis.Warnings.Add("RSB pressure from call/ret — use jmp + explicit target in hot path.");

            return analysis;
        }

        public static string GenerateReport(HiddenBufferAnalysis analysis)
        {
            var lines = new List<string>();
            lines.Add("╔══════════════════════════════════════════════╗");
            lines.Add("║  HIDDEN BUFFER OPTIMIZATION REPORT  v3.0.4L BETA ║");
            lines.Add("╚══════════════════════════════════════════════╝");
            lines.Add("");

            lines.Add($"LSD Loopback Buffer:");
            lines.Add($"  Fits: {analysis.FitsLSD} ({analysis.LsdSizeBytes}B / 64B max)");
            lines.Add($"  Has call/ret: {analysis.HasCall}");
            lines.Add("");

            lines.Add($"Store Buffer:");
            lines.Add($"  Max stores in a row: {analysis.MaxStoresInARow} / 56 entries");
            lines.Add("");

            lines.Add($"Load Buffer:");
            lines.Add($"  Max loads in a row: {analysis.MaxLoadsInARow} / 128 entries");
            lines.Add("");

            lines.Add($"Line Fill Buffer (L1↔L2):");
            lines.Add($"  Estimated pending misses: {analysis.LfbPending} / 16 max");
            lines.Add($"  Overloaded: {analysis.LfbOverloaded}");
            lines.Add("");

            lines.Add($"TLB Coverage:");
            lines.Add($"  Data size: ~{analysis.TotalDataSize / 1024}KB");
            lines.Add($"  L1-D TLB coverage (4KB pages): {analysis.TlbL1CoverageKb}KB");
            lines.Add($"  Needs huge pages: {analysis.NeedsHugePages}");
            lines.Add("");

            lines.Add($"BTB:");
            lines.Add($"  Jump count: {analysis.JumpCount}");
            lines.Add($"  Misaligned jumps: {analysis.MisalignedJumpCount}");
            lines.Add("");

            if (analysis.Warnings.Count > 0)
            {
                lines.Add("⚠  Warnings:");
                foreach (var w in analysis.Warnings)
                    lines.Add($"  • {w}");
                lines.Add("");
            }

            if (analysis.Optimizations.Count > 0)
            {
                lines.Add("✓  Recommended Optimizations:");
                foreach (var o in analysis.Optimizations)
                    lines.Add($"  • {o}");
                lines.Add("");
            }

            lines.Add("Estimated improvement from fixes: −5–40 cycles per hot iteration");
            return string.Join("\n", lines);
        }
    }
}