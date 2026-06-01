using BPlusTranspiler.Ast;
using BPlusTranspiler.Parser;

namespace BPlusTranspiler;

public static class BPlusDiff
{
    public static int Run(string fileA, string fileB)
    {
        if (!File.Exists(fileA)) { Console.Error.WriteLine($"File not found: {fileA}"); return 1; }
        if (!File.Exists(fileB)) { Console.Error.WriteLine($"File not found: {fileB}"); return 1; }

        var progA = Parse(fileA);
        var progB = Parse(fileB);
        if (progA == null || progB == null) return 1;

        int changes = 0;

        // States
        var statesA = FlatStates(progA);
        var statesB = FlatStates(progB);
        var namesA = statesA.Keys.ToHashSet();
        var namesB = statesB.Keys.ToHashSet();

        foreach (var s in namesB.Except(namesA))
        {
            Console.WriteLine($"+ Added state: {s}");
            changes++;
        }

        foreach (var s in namesA.Except(namesB))
        {
            Console.WriteLine($"- Removed state: {s}");
            changes++;
        }

        foreach (var s in namesA.Intersect(namesB).OrderBy(x => x))
        {
            var sa = statesA[s];
            var sb = statesB[s];
            var items = DiffState(sa, sb);
            if (items.Count > 0)
            {
                Console.WriteLine($"~ Modified state: {s}");
                foreach (var item in items)
                    Console.WriteLine($"  {item}");
                changes += items.Count;
            }
        }

        // Context
        var ctxA = progA.Context?.Variables ?? new List<VariableNode>();
        var ctxB = progB.Context?.Variables ?? new List<VariableNode>();
        var ctxNamesA = ctxA.Select(v => v.Name).ToHashSet();
        var ctxNamesB = ctxB.Select(v => v.Name).ToHashSet();

        foreach (var v in ctxB)
        {
            if (!ctxNamesA.Contains(v.Name))
            {
                var def = v.DefaultValue != null ? $" = {v.DefaultValue}" : "";
                Console.WriteLine($"+ context `{v.Name}`: `{v.Type}`{def}");
                changes++;
            }
        }

        foreach (var v in ctxA)
        {
            if (!ctxNamesB.Contains(v.Name))
            {
                Console.WriteLine($"- context `{v.Name}`: `{v.Type}`");
                changes++;
            }
        }

        foreach (var vb in ctxB)
        {
            var va = ctxA.FirstOrDefault(v => v.Name == vb.Name);
            if (va == null) continue;
            if (va.Type != vb.Type || va.DefaultValue != vb.DefaultValue)
            {
                var oldDef = va.DefaultValue != null ? $" = {va.DefaultValue}" : "";
                var newDef = vb.DefaultValue != null ? $" = {vb.DefaultValue}" : "";
                Console.WriteLine($"~ context `{vb.Name}`: `{va.Type}`{oldDef} → `{vb.Type}`{newDef}");
                changes++;
            }
        }

        // Entries
        var entryA = progA.Entries.ToDictionary(e => e.Name);
        var entryB = progB.Entries.ToDictionary(e => e.Name);

        foreach (var e in progB.Entries)
        {
            if (!entryA.ContainsKey(e.Name))
            {
                Console.WriteLine($"+ entry `{e.Name}()`");
                changes++;
            }
        }

        foreach (var e in progA.Entries)
        {
            if (!entryB.ContainsKey(e.Name))
            {
                Console.WriteLine($"- entry `{e.Name}()`");
                changes++;
            }
        }

        foreach (var eb in progB.Entries)
        {
            if (!entryA.TryGetValue(eb.Name, out var ea)) continue;
            var oldBody = ea.Body ?? string.Join("\n", ea.BodyLines);
            var newBody = eb.Body ?? string.Join("\n", eb.BodyLines);
            if (oldBody != newBody)
            {
                Console.WriteLine($"~ entry `{eb.Name}()` body changed");
                changes++;
            }
        }

        // Enums
        var enumA = progA.Enums.Select(e => e.Name).ToHashSet();
        var enumB = progB.Enums.Select(e => e.Name).ToHashSet();
        foreach (var e in enumB.Except(enumA))
        {
            Console.WriteLine($"+ enum `{e}`");
            changes++;
        }
        foreach (var e in enumA.Except(enumB))
        {
            Console.WriteLine($"- enum `{e}`");
            changes++;
        }

        if (changes == 0)
            Console.WriteLine("No differences found.");

        return changes;
    }

    static List<string> DiffState(StateDefNode old, StateDefNode n)
    {
        var items = new List<string>();

        var oldT = old.Transitions.ToDictionary(t => TransitionKey(t));
        var newT = n.Transitions.ToDictionary(t => TransitionKey(t));

        foreach (var (k, nt) in newT)
        {
            if (!oldT.ContainsKey(k))
            {
                var ev = nt.IsAlways ? "always" : nt.IsEnterAuto ? "enter" : nt.EventName;
                var tgt = string.IsNullOrEmpty(nt.Target) ? "(stay)" : nt.Target;
                var guard = nt.Guard != null ? $" [{nt.Guard}]" : "";
                items.Add($"+ {ev} -> {tgt}{guard}");
            }
        }

        foreach (var (k, ot) in oldT)
        {
            if (!newT.ContainsKey(k))
            {
                var ev = ot.IsAlways ? "always" : ot.IsEnterAuto ? "enter" : ot.EventName;
                var tgt = string.IsNullOrEmpty(ot.Target) ? "(stay)" : ot.Target;
                items.Add($"- {ev} -> {tgt}");
            }
        }

        var oldVars = old.Variables.ToDictionary(v => v.Name);
        var newVars = n.Variables.ToDictionary(v => v.Name);

        foreach (var v in n.Variables)
        {
            if (!oldVars.ContainsKey(v.Name))
            {
                var def = v.DefaultValue != null ? $" = {v.DefaultValue}" : "";
                items.Add($"+ var `{v.Name}`: `{v.Type}`{def}");
            }
        }

        foreach (var v in old.Variables)
        {
            if (!newVars.ContainsKey(v.Name))
            {
                items.Add($"- var `{v.Name}`: `{v.Type}`");
            }
        }

        var oldAct = string.Join("\n", old.Actions.Select(a => $"{a.Type}:{a.Body}"));
        var newAct = string.Join("\n", n.Actions.Select(a => $"{a.Type}:{a.Body}"));
        if (oldAct != newAct)
            items.Add("~ actions changed");

        return items;
    }

    static ProgramNode? Parse(string file)
    {
        try
        {
            return new BPlusParser().Parse(File.ReadAllText(file));
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Parse error {file}: {ex.Message}");
            return null;
        }
    }

    static Dictionary<string, StateDefNode> FlatStates(ProgramNode prog)
    {
        var map = new Dictionary<string, StateDefNode>();
        void Collect(StateDefNode s) { map[s.Name] = s; foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var s in prog.States) Collect(s);
        foreach (var pb in prog.ParallelBlocks)
            foreach (var s in pb.States) Collect(s);
        return map;
    }

    static string TransitionKey(TransitionNode t) =>
        $"{(t.IsAlways ? "always" : t.IsEnterAuto ? "enter" : t.EventName)}->{t.Target ?? ""}|{t.Guard ?? ""}";
}
