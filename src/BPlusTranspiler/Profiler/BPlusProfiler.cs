using System.Diagnostics;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Profiler;

public class BPlusProfiler
{
    private readonly ProgramNode _program;
    private readonly Dictionary<string, StateDefNode> _stateMap = new();
    private readonly Dictionary<string, ProfileData> _stateStats = new();
    private readonly Dictionary<string, ProfileData> _transStats = new();
    private readonly Random _rng = new();

    public BPlusProfiler(ProgramNode program)
    {
        _program = program;
        void Collect(StateDefNode s)
        {
            _stateMap[s.Name] = s;
            _stateStats[s.Name] = new ProfileData();
            foreach (var t in s.Transitions)
            {
                var key = $"{s.Name}--{t.EventName}-->";
                if (!_transStats.ContainsKey(key))
                    _transStats[key] = new ProfileData();
            }
            foreach (var ns in s.NestedStates) Collect(ns);
        }
        foreach (var s in program.States) Collect(s);
        foreach (var pb in program.ParallelBlocks)
            foreach (var s in pb.States) Collect(s);
    }

    public void Run(int iterations = 100_000)
    {
        Console.WriteLine($"Profiling {Path.GetFileNameWithoutExtension(_program.Imports.FirstOrDefault()?.Path ?? "state machine")}...");
        Console.WriteLine($"  Simulating {iterations:N0} random transitions...");
        Console.WriteLine();

        var sw = Stopwatch.StartNew();
        var current = _program.States.FirstOrDefault()?.Name;

        for (int i = 0; i < iterations && current != null; i++)
        {
            if (!_stateMap.TryGetValue(current, out var state))
                break;

            _stateStats[current].Count++;

            var transitions = state.Transitions
                .Where(t => string.IsNullOrEmpty(t.Guard) || SimulateGuard(t.Guard))
                .ToList();

            if (transitions.Count == 0)
            {
                // Can't transition, stay in same state
                continue;
            }

            var chosen = transitions[_rng.Next(transitions.Count)];
            var transKey = $"{current}--{chosen.EventName}-->";
            if (_transStats.ContainsKey(transKey))
                _transStats[transKey].Count++;

            current = chosen.Target;
        }

        sw.Stop();

        // Report
        Console.WriteLine($"Completed in {sw.Elapsed.TotalMilliseconds:F1}ms");
        Console.WriteLine();

        // State statistics
        var maxNameLen = _stateStats.Keys.Max(n => n.Length);
        Console.WriteLine($"{"State".PadRight(maxNameLen)} | {"Entries".PadLeft(10)} | {"%".PadLeft(7)} | Avg Time");
        Console.WriteLine(new string('-', maxNameLen + 38));
        var total = _stateStats.Values.Sum(d => d.Count);
        foreach (var (name, data) in _stateStats.OrderByDescending(x => x.Value.Count))
        {
            var pct = total > 0 ? (double)data.Count / total * 100 : 0;
            Console.WriteLine($"{name.PadRight(maxNameLen)} | {data.Count,10:N0} | {pct,6:F1}% | -");
        }
        Console.WriteLine();

        // Transition statistics
        Console.WriteLine($"{"Transition".PadRight(maxNameLen + 16)} | {"Hits".PadLeft(10)} | {"%".PadLeft(7)}");
        Console.WriteLine(new string('-', maxNameLen + 40));
        var transTotal = _transStats.Values.Sum(d => d.Count);
        foreach (var (key, data) in _transStats.OrderByDescending(x => x.Value.Count))
        {
            var pct = transTotal > 0 ? (double)data.Count / transTotal * 100 : 0;
            var displayKey = key.Length > maxNameLen + 14 ? key[..(maxNameLen + 11)] + "..." : key;
            Console.WriteLine($"{displayKey.PadRight(maxNameLen + 16)} | {data.Count,10:N0} | {pct,6:F1}%");
        }
    }

    private bool SimulateGuard(string guard)
    {
        // Simple guard simulation: 70% chance true for most guards
        if (guard.Contains(">") || guard.Contains("<"))
            return _rng.NextDouble() < 0.5;
        if (guard.Contains("==") || guard.Contains("!="))
            return _rng.NextDouble() < 0.3;
        return _rng.NextDouble() < 0.7;
    }

    private class ProfileData
    {
        public long Count;
    }

    public static Dictionary<string, string> GenerateProfileReport(ProgramNode program, int iterations = 100_000)
    {
        var profiler = new BPlusProfiler(program);
        var oldOut = Console.Out;
        var writer = new StringWriter();
        Console.SetOut(writer);
        profiler.Run(iterations);
        Console.SetOut(oldOut);
        return new Dictionary<string, string>
        {
            { "profile_report.txt", writer.ToString() }
        };
    }
}
