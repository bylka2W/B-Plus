using System.Text;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Debugger;

public class BPlusDebugServer
{
    private readonly ProgramNode _program;
    private readonly List<StateDefNode> _allStates;
    private readonly Dictionary<string, StateDefNode> _stateMap = new();
    private StateDefNode? _currentState;
    private readonly HashSet<string> _breakpoints = new();
    private int _historyCount;

    private static readonly string[] EventHistory = new string[256];

    public BPlusDebugServer(ProgramNode program)
    {
        _program = program;
        _allStates = new List<StateDefNode>();
        void Collect(StateDefNode s) { _allStates.Add(s); _stateMap[s.Name] = s; foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var s in program.States) Collect(s);
        foreach (var pb in program.ParallelBlocks)
            foreach (var s in pb.States) Collect(s);
    }

    public void Run()
    {
        _currentState = _program.States.FirstOrDefault();
        if (_currentState == null)
        {
            Console.WriteLine("No states defined.");
            return;
        }

        Console.WriteLine();
        Console.WriteLine("╔══════════════════════════════════════════════╗");
        Console.WriteLine("║     B+ State Machine Debugger v2.0         ║");
        Console.WriteLine("╚══════════════════════════════════════════════╝");
        Console.WriteLine();
        PrintState();

        Console.WriteLine("Commands:");
        Console.WriteLine("  <event> [args]  — fire event");
        Console.WriteLine("  step            — step (execute next available)");
        Console.WriteLine("  bp <state>      — toggle breakpoint on state");
        Console.WriteLine("  state           — show current state info");
        Console.WriteLine("  vars            — show variables");
        Console.WriteLine("  events          — list available events");
        Console.WriteLine("  history         — event history");
        Console.WriteLine("  help            — this help");
        Console.WriteLine("  quit            — exit");
        Console.WriteLine();

        while (true)
        {
            Console.Write($"[{_currentState.Name}]> ");
            var input = Console.ReadLine();
            if (input == null) break;

            var parts = input.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            if (parts.Length == 0) continue;

            var cmd = parts[0].ToLower();

            switch (cmd)
            {
                case "quit" or "exit" or "q":
                    return;

                case "help" or "h" or "?":
                    Console.WriteLine("  <event>     — fire an event to trigger a transition");
                    Console.WriteLine("  step        — step one line / event");
                    Console.WriteLine("  bp <state>  — toggle breakpoint on entering <state>");
                    Console.WriteLine("  state       — show current state details");
                    Console.WriteLine("  vars        — list current state variables");
                    Console.WriteLine("  events      — list events the current state handles");
                    Console.WriteLine("  history     — show transition history");
                    Console.WriteLine("  quit        — exit debugger");
                    break;

                case "step" or "s":
                    Console.WriteLine("Step mode: enter an event name to fire it manually.");
                    break;

                case "bp" or "breakpoint":
                    if (parts.Length < 2) { Console.WriteLine("Usage: bp <state>"); break; }
                    var bpName = string.Join(" ", parts[1..]);
                    if (!_stateMap.ContainsKey(bpName))
                    {
                        // Try case-insensitive
                        var match = _stateMap.Keys.FirstOrDefault(k =>
                            k.Equals(bpName, StringComparison.OrdinalIgnoreCase));
                        if (match == null) { Console.WriteLine($"Unknown state: {bpName}"); break; }
                        bpName = match;
                    }
                    if (_breakpoints.Add(bpName))
                        Console.WriteLine($"Breakpoint set on state '{bpName}'");
                    else
                    {
                        _breakpoints.Remove(bpName);
                        Console.WriteLine($"Breakpoint removed from state '{bpName}'");
                    }
                    break;

                case "state":
                    PrintState();
                    break;

                case "vars" or "variables":
                    PrintVars();
                    break;

                case "events":
                    PrintEvents();
                    break;

                case "history" or "log":
                    PrintHistory();
                    break;

                default:
                    // Try to fire an event
                    var eventName = cmd;
                    var argsArr = parts.Length > 1 ? parts[1..] : Array.Empty<string>();
                    FireEvent(eventName, argsArr);
                    break;
            }
        }
    }

    private void PrintState()
    {
        if (_currentState == null) return;
        Console.WriteLine($"Current state: {_currentState.Name}");
        if (_currentState.BaseClass != null)
            Console.WriteLine($"  Base class: {_currentState.BaseClass}");
        if (_currentState.Variables.Count > 0)
            Console.WriteLine($"  Variables: {_currentState.Variables.Count}");
        if (_currentState.Transitions.Count > 0)
            Console.WriteLine($"  Transitions: {_currentState.Transitions.Count}");
        if (_currentState.Timers.Count > 0)
            Console.WriteLine($"  Timers: {_currentState.Timers.Count}");
        if (_currentState.NestedStates.Count > 0)
            Console.WriteLine($"  Nested states: {string.Join(", ", _currentState.NestedStates.Select(s => s.Name))}");
        Console.WriteLine();
    }

    private void PrintVars()
    {
        if (_currentState == null) return;
        if (_currentState.Variables.Count == 0)
        {
            Console.WriteLine("No variables.");
            return;
        }
        Console.WriteLine($"Variables of {_currentState.Name}:");
        foreach (var v in _currentState.Variables)
        {
            var val = v.DefaultValue ?? DefaultForType(v.Type);
            Console.WriteLine($"  {v.Name}: {v.Type} = {val}");
        }
        Console.WriteLine();
    }

    private void PrintEvents()
    {
        if (_currentState == null) return;
        if (_currentState.Transitions.Count == 0)
        {
            Console.WriteLine("No transitions defined.");
            return;
        }
        Console.WriteLine($"Available events in {_currentState.Name}:");
        foreach (var t in _currentState.Transitions)
        {
            var ev = t.IsAlways ? "always" : t.IsEnterAuto ? "enter" : t.EventName;
            var par = t.Parameters.Count > 0 ? $"({string.Join(", ", t.Parameters.Select(p => $"{p.Name}: {p.Type}"))})" : "";
            var guard = t.Guard != null ? $" [{t.Guard}]" : "";
            var body = t.Body != null ? " {body}" : "";
            Console.WriteLine($"  {ev}{par}{guard} → {t.Target}{body}");
        }
        Console.WriteLine();
    }

    private void PrintHistory()
    {
        var count = Math.Min(_historyCount, EventHistory.Length);
        if (count == 0)
        {
            Console.WriteLine("No transitions yet.");
            return;
        }
        Console.WriteLine($"Last {count} transitions:");
        for (int i = 0; i < count; i++)
        {
            var idx = (_historyCount - count + i) % EventHistory.Length;
            Console.WriteLine($"  {i + 1}. {EventHistory[idx]}");
        }
        Console.WriteLine();
    }

    private void FireEvent(string eventName, string[] args)
    {
        if (_currentState == null) return;

        // Find matching transition
        var transitions = _currentState.Transitions
            .Where(t => t.EventName.Equals(eventName, StringComparison.OrdinalIgnoreCase)
                || (t.IsAlways && eventName == "always"))
            .ToList();

        if (transitions.Count == 0)
        {
            Console.WriteLine($"Event '{eventName}' not handled by {_currentState.Name}.");
            return;
        }

        foreach (var t in transitions)
        {
            // Evaluate guard
            if (t.Guard != null)
            {
                Console.Write($"  Guard [{t.Guard}] — true? [Y/n] ");
                var answer = Console.ReadLine()?.Trim().ToLower();
                if (answer == "n" || answer == "no")
                {
                    Console.WriteLine($"  Guard rejected, skipping transition to {t.Target}");
                    continue;
                }
            }

            // Execute transition
            var log = $"{_currentState.Name} --[{t.EventName}]--> {t.Target}";
            EventHistory[_historyCount % EventHistory.Length] = log;
            _historyCount++;

            // Show action body
            if (t.Body != null)
                Console.WriteLine($"  [action] {t.Body}");

            // Check if actions on current state
            foreach (var a in _currentState.Actions.Where(a => a.Type == ActionType.Exit))
                Console.WriteLine($"  [exit] {a.Body}");

            // Move to target state
            var targetName = t.Target;
            if (_stateMap.TryGetValue(targetName, out var targetState))
            {
                _currentState = targetState;

                foreach (var a in _currentState.Actions.Where(a => a.Type == ActionType.Enter))
                    Console.WriteLine($"  [enter] {a.Body}");

                Console.WriteLine($"  ✓ {log}");

                // Check breakpoints
                if (_breakpoints.Contains(_currentState.Name))
                    Console.WriteLine($"  ** Breakpoint hit: '{_currentState.Name}' **");

                PrintState();
            }
            else
            {
                Console.WriteLine($"  ✓ {log} (external state '{targetName}')");
            }

            return;
        }
    }

    private static string DefaultForType(string type) => type.ToLower() switch
    {
        "int" or "long" or "float" or "double" => "0",
        "bool" => "false",
        "string" => "\"\"",
        _ => "null"
    };
}
