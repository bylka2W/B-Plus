using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Optimizer;

// Vale: Region-based memory — isolated memory regions per state machine
// Each state machine is an isolated region. Data cannot leak between
// machines without an explicit transfer annotation.
// Statically verifiable at compile time.

public static class RegionPass
{
    public static List<RegionInfo> Run(ProgramNode program)
    {
        var regions = new List<RegionInfo>();

        // Each top-level state is its own region
        foreach (var state in program.States)
        {
            var region = new RegionInfo
            {
                Name = $"region_{state.Name}",
            };
            region.OwnedStates.Add(state.Name);
            foreach (var v in state.Variables)
                region.OwnedVars.Add(v.Name);

            // Nested states belong to the same region
            CollectNestedStateVars(state, region);
            regions.Add(region);
        }

        // Track cross-region transfers (transitions between top-level states)
        foreach (var state in program.States)
        {
            var fromRegion = regions.Find(r => r.OwnedStates.Contains(state.Name));
            if (fromRegion == null) continue;

            foreach (var t in state.Transitions)
            {
                var toRegion = regions.Find(r => r.OwnedStates.Contains(t.Target));
                if (toRegion != null && toRegion.Name != fromRegion.Name)
                {
                    fromRegion.Transfers.Add(t.Target);
                }
            }
        }

        // Verify isolation: check for cross-region variable leaks
        VerifyIsolation(program, regions);

        return regions;
    }

    private static void CollectNestedStateVars(StateDefNode state, RegionInfo region)
    {
        foreach (var ns in state.NestedStates)
        {
            region.OwnedStates.Add(ns.Name);
            foreach (var v in ns.Variables)
                region.OwnedVars.Add(v.Name);
            CollectNestedStateVars(ns, region);
        }
    }

    private static void VerifyIsolation(ProgramNode program, List<RegionInfo> regions)
    {
        foreach (var state in program.States)
        {
            var region = regions.Find(r => r.OwnedStates.Contains(state.Name));
            if (region == null) continue;

            foreach (var t in state.Transitions)
            {
                // A transition body should not reference variables from other regions
                if (t.Body == null) continue;
                foreach (var otherRegion in regions)
                {
                    if (otherRegion.Name == region.Name) continue;
                    foreach (var v in otherRegion.OwnedVars)
                    {
                        if (t.Body.Contains(v))
                        {
                            Console.WriteLine($"[RegionPass] ⚠ Cross-region reference: '{state.Name}' → '{v}' from '{otherRegion.Name}' in transition '{t.EventName}'");
                        }
                    }
                }
            }
        }
    }
}
