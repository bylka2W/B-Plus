using BPlusTranspiler.Ast;
using BPlusTranspiler.Parser;

namespace BPlusTranspiler;

public static class BPlusDiff
{
    public static int Run(string fileA, string fileB)
    {
        if (!File.Exists(fileA)) { Console.Error.WriteLine($"Файл не найден: {fileA}"); return 1; }
        if (!File.Exists(fileB)) { Console.Error.WriteLine($"Файл не найден: {fileB}"); return 1; }

        var progA = Parse(fileA);
        var progB = Parse(fileB);

        if (progA == null || progB == null) return 1;

        var changes = new List<string>();

        // States: added / removed / changed
        var statesA = FlatStates(progA);
        var statesB = FlatStates(progB);
        var namesA = statesA.Keys.ToHashSet();
        var namesB = statesB.Keys.ToHashSet();

        foreach (var added in namesB.Except(namesA))
            changes.Add($"[+] состояние '{added}'");

        foreach (var removed in namesA.Except(namesB))
            changes.Add($"[-] состояние '{removed}'");

        foreach (var common in namesA.Intersect(namesB))
        {
            var sa = statesA[common];
            var sb = statesB[common];

            // Variables
            var va = sa.Variables.Select(v => $"{v.Type} {v.Name}").ToHashSet();
            var vb = sb.Variables.Select(v => $"{v.Type} {v.Name}").ToHashSet();
            foreach (var a in vb.Except(va))
                changes.Add($"[~] {common}: добавлена переменная '{a}'");
            foreach (var r in va.Except(vb))
                changes.Add($"[~] {common}: удалена переменная '{r}'");

            // Transitions
            var ta = sa.Transitions.Select(t => TransitionKey(t)).ToHashSet();
            var tb = sb.Transitions.Select(t => TransitionKey(t)).ToHashSet();
            foreach (var a in tb.Except(ta))
                changes.Add($"[~] {common}: добавлен переход '{a}'");
            foreach (var r in ta.Except(tb))
                changes.Add($"[~] {common}: удалён переход '{r}'");

            // Timers
            var tia = sa.Timers.Select(t => TimerKey(t)).ToHashSet();
            var tib = sb.Timers.Select(t => TimerKey(t)).ToHashSet();
            foreach (var a in tib.Except(tia))
                changes.Add($"[~] {common}: добавлен таймер '{a}'");
            foreach (var r in tia.Except(tib))
                changes.Add($"[~] {common}: удалён таймер '{r}'");

            // Actions
            var aa = sa.Actions.Select(a => $"{a.Type}: {a.Body}").ToHashSet();
            var ab = sb.Actions.Select(a => $"{a.Type}: {a.Body}").ToHashSet();
            foreach (var a in ab.Except(aa))
                changes.Add($"[~] {common}: изменён action '{a}'");
        }

        // Enums
        var enumsA = progA.Enums.Select(e => e.Name).ToHashSet();
        var enumsB = progB.Enums.Select(e => e.Name).ToHashSet();
        foreach (var a in enumsB.Except(enumsA))
            changes.Add($"[+] перечисление '{a}'");
        foreach (var r in enumsA.Except(enumsB))
            changes.Add($"[-] перечисление '{r}'");

        // Context
        if ((progA.Context is { Variables.Count: > 0 }) != (progB.Context is { Variables.Count: > 0 }))
            changes.Add("[~] контекст: добавлен/удалён");
        else if (progA.Context != null && progB.Context != null)
        {
            var cva = progA.Context.Variables.Select(v => $"{v.Type} {v.Name}").ToHashSet();
            var cvb = progB.Context.Variables.Select(v => $"{v.Type} {v.Name}").ToHashSet();
            foreach (var a in cvb.Except(cva))
                changes.Add($"[~] контекст: добавлена переменная '{a}'");
            foreach (var r in cva.Except(cvb))
                changes.Add($"[~] контекст: удалена переменная '{r}'");
        }

        if (changes.Count == 0)
        {
            Console.WriteLine("✅ Файлы семантически идентичны");
            return 0;
        }

        Console.WriteLine($"📊 Семантических изменений: {changes.Count}");
        Console.WriteLine();
        foreach (var c in changes)
            Console.WriteLine($"  {c}");
        Console.WriteLine();
        Console.WriteLine($"  {Path.GetFileName(fileA)} → {Path.GetFileName(fileB)}");

        return changes.Any(c => c.StartsWith("[-]") || c.StartsWith("[+]")) ? 2 : 0;
    }

    private static ProgramNode? Parse(string file)
    {
        try
        {
            var src = File.ReadAllText(file);
            return new BPlusParser().Parse(src);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Ошибка парсинга {file}: {ex.Message}");
            return null;
        }
    }

    private static Dictionary<string, StateDefNode> FlatStates(ProgramNode prog)
    {
        var map = new Dictionary<string, StateDefNode>();
        void Collect(StateDefNode s) { map[s.Name] = s; foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var s in prog.States) Collect(s);
        foreach (var pb in prog.ParallelBlocks)
            foreach (var s in pb.States) Collect(s);
        return map;
    }

    private static string TransitionKey(TransitionNode t) =>
        $"on {t.EventName}{(t.Guard != null ? $" [{t.Guard}]" : "")} -> {t.Target}";

    private static string TimerKey(TimerNode t) =>
        $"after {t.Duration}{(t.Guard != null ? $" [{t.Guard}]" : "")} -> {t.Target}";
}
