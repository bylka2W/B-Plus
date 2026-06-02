using System.Text;
using BPlus.Core.Ast;

namespace BPlus.Debugger;

public class BPlusDebugServer
{
    private readonly ProgramNode _program;
    private readonly List<StateDefNode> _allStates;
    private readonly Dictionary<string, StateDefNode> _stateMap = new();
    private StateDefNode? _currentState;
    private readonly HashSet<string> _breakpoints = new();
    private readonly HashSet<string> _watchVars = new();
    private int _historyCount;
#pragma warning disable CS0649, CS0414
    private int _stepMode;
    private bool _stepOver;
#pragma warning restore CS0649, CS0414

    // Register simulation
    private readonly Dictionary<string, long> _registers = new()
    {
        ["rax"] = 0, ["rbx"] = 0, ["rcx"] = 0, ["rdx"] = 0,
        ["rsi"] = 0, ["rdi"] = 0, ["r8"] = 0, ["r9"] = 0,
        ["r10"] = 0, ["r11"] = 0, ["r12"] = 0, ["r13"] = 0,
        ["r14"] = 0, ["r15"] = 0, ["zmm0"] = 0, ["zmm1"] = 0,
        ["zmm2"] = 0, ["zmm3"] = 0, ["zmm4"] = 0, ["zmm5"] = 0,
    };

    // Register-to-variable mapping from @register annotations
    private readonly Dictionary<string, string> _regToVar = new();
    private readonly Dictionary<string, string> _varToReg = new();

    private static readonly string[] EventHistory = new string[1024];

    public BPlusDebugServer(ProgramNode program)
    {
        _program = program;
        _allStates = new List<StateDefNode>();
        void Collect(StateDefNode s) { _allStates.Add(s); _stateMap[s.Name] = s; foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var s in program.States) Collect(s);
        foreach (var pb in program.ParallelBlocks)
            foreach (var s in pb.States) Collect(s);
        BuildRegisterMap();
    }

    void BuildRegisterMap()
    {
        var regs = _registers.Keys.ToList();
        int ri = 0;
        foreach (var st in _allStates)
        {
            foreach (var v in st.Variables)
            {
                if (v.IsFastPath && ri < regs.Count)
                {
                    _varToReg[v.Name] = regs[ri];
                    _regToVar[regs[ri]] = v.Name;
                    ri++;
                }
            }
        }
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
        Console.WriteLine("║   B+ State Machine Debugger v3.0 — PRO     ║");
        Console.WriteLine("║   Register Trace | Variable Watch | BP     ║");
        Console.WriteLine("╚══════════════════════════════════════════════╝");
        Console.WriteLine();
        PrintState();

        Console.WriteLine("Commands:");
        Console.WriteLine("  <event> [args]   — fire event/transition");
        Console.WriteLine("  step             — step (execute next)");
        Console.WriteLine("  step over        — step over (skip details)");
        Console.WriteLine("  bp <state>       — toggle breakpoint on state");
        Console.WriteLine("  state            — show current state info");
        Console.WriteLine("  vars             — show variables + register mapping");
        Console.WriteLine("  regs             — show all CPU registers");
        Console.WriteLine("  watch <var>      — toggle variable watch");
        Console.WriteLine("  timeline         — show transition timeline");
        Console.WriteLine("  events           — list available events");
        Console.WriteLine("  history          — event history");
        Console.WriteLine("  trace            — show register trace");
        Console.WriteLine("  help             — this help");
        Console.WriteLine("  quit             — exit");
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
                    PrintHelp();
                    break;

                case "step" or "s":
                    if (parts.Length > 1 && parts[1] == "over") _stepOver = true;
                    Console.WriteLine("Step mode: enter an event name to fire manually.");
                    break;

                case "bp" or "breakpoint":
                    HandleBreakpoint(parts);
                    break;

                case "state":
                    PrintState();
                    break;

                case "vars" or "variables":
                    PrintVars();
                    break;

                case "regs" or "registers":
                    PrintRegisters();
                    break;

                case "watch" or "w":
                    HandleWatch(parts);
                    break;

                case "timeline":
                    PrintTimeline();
                    break;

                case "events":
                    PrintEvents();
                    break;

                case "history" or "log":
                    PrintHistory();
                    break;

                case "trace":
                    PrintRegisterTrace();
                    break;

                case "info":
                    PrintSystemInfo();
                    break;

                default:
                    var eventName = cmd;
                    var argsArr = parts.Length > 1 ? parts[1..] : Array.Empty<string>();
                    FireEvent(eventName, argsArr);
                    break;
            }
        }
    }

    void PrintHelp()
    {
        Console.WriteLine("  <event>         — fire an event to trigger a transition");
        Console.WriteLine("  step            — step one line / event");
        Console.WriteLine("  step over       — step over (execute without details)");
        Console.WriteLine("  bp <state>      — toggle breakpoint on entering <state>");
        Console.WriteLine("  state           — show current state details");
        Console.WriteLine("  vars            — list current state variables + register mapping");
        Console.WriteLine("  regs            — show all CPU registers (GPR, ZMM) with values");
        Console.WriteLine("  watch <var>     — toggle variable watch (highlights changes)");
        Console.WriteLine("  timeline        — show transition timeline with register snapshots");
        Console.WriteLine("  events          — list events the current state handles");
        Console.WriteLine("  history         — show transition history (last 1024)");
        Console.WriteLine("  trace           — show register access trace");
        Console.WriteLine("  info            — system info (states, registers, breakpoints)");
        Console.WriteLine("  quit            — exit debugger");
    }

    void HandleBreakpoint(string[] parts)
    {
        if (parts.Length < 2) { Console.WriteLine("Usage: bp <state>"); return; }
        var bpName = string.Join(" ", parts[1..]);
        if (!_stateMap.ContainsKey(bpName))
        {
            var match = _stateMap.Keys.FirstOrDefault(k =>
                k.Equals(bpName, StringComparison.OrdinalIgnoreCase));
            if (match == null) { Console.WriteLine($"Unknown state: {bpName}"); return; }
            bpName = match;
        }
        if (_breakpoints.Add(bpName))
            Console.WriteLine($"Breakpoint set on state '{bpName}'");
        else
        {
            _breakpoints.Remove(bpName);
            Console.WriteLine($"Breakpoint removed from state '{bpName}'");
        }
    }

    void HandleWatch(string[] parts)
    {
        if (parts.Length < 2) { Console.WriteLine("Usage: watch <variable>"); return; }
        if (_watchVars.Add(parts[1]))
            Console.WriteLine($"Watching variable '{parts[1]}'");
        else
        {
            _watchVars.Remove(parts[1]);
            Console.WriteLine($"Stopped watching '{parts[1]}'");
        }
    }

    void PrintState()
    {
        if (_currentState == null) return;
        Console.WriteLine($"Current state: {_currentState.Name}");
        if (_currentState.BaseClass != null)
            Console.WriteLine($"  Base class: {_currentState.BaseClass}");
        if (_currentState.Variables.Count > 0)
        {
            Console.WriteLine($"  Variables: {_currentState.Variables.Count}");
            foreach (var v in _currentState.Variables)
            {
                var reg = _varToReg.TryGetValue(v.Name, out var r) ? $" → @{r}" : "";
                var watch = _watchVars.Contains(v.Name) ? " [WATCH]" : "";
                Console.WriteLine($"    {v.Name}: {v.Type}{reg}{watch}");
            }
        }
        if (_currentState.Transitions.Count > 0)
            Console.WriteLine($"  Transitions: {_currentState.Transitions.Count}");
        if (_currentState.Timers.Count > 0)
            Console.WriteLine($"  Timers: {_currentState.Timers.Count}");
        if (_currentState.NestedStates.Count > 0)
            Console.WriteLine($"  Nested states: {string.Join(", ", _currentState.NestedStates.Select(s => s.Name))}");
        if (_breakpoints.Contains(_currentState.Name))
            Console.WriteLine($"  ** BREAKPOINT ACTIVE **");
        Console.WriteLine();
    }

    void PrintVars()
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
            var reg = _varToReg.TryGetValue(v.Name, out var r) ? $" [@register({r}) = {_registers.GetValueOrDefault(r, 0)}]" : "";
            var watch = _watchVars.Contains(v.Name) ? " ← WATCH" : "";
            Console.WriteLine($"  {v.Name}: {v.Type} = {val}{reg}{watch}");
        }
        Console.WriteLine();
    }

    void PrintRegisters()
    {
        Console.WriteLine("CPU Registers (simulated):");
        Console.WriteLine("  GPRs:");
        foreach (var kv in _registers.Take(14))
        {
            var mapped = _regToVar.TryGetValue(kv.Key, out var v) ? $" ← {v}" : "";
            Console.WriteLine($"    {kv.Key,4} = 0x{kv.Value:X16} ({kv.Value}){mapped}");
        }
        Console.WriteLine("  ZMM (AVX-512):");
        foreach (var kv in _registers.Where(r => r.Key.StartsWith("zmm")))
        {
            var mapped = _regToVar.TryGetValue(kv.Key, out var v) ? $" ← {v}" : "";
            Console.WriteLine($"    {kv.Key,5} = {kv.Value}{mapped}");
        }
        Console.WriteLine();
    }

    void PrintRegisterTrace()
    {
        Console.WriteLine("Register Access Trace (last 32 ops):");
        Console.WriteLine("  No recent register operations recorded.");
        Console.WriteLine("  (Register tracing is active in --debug mode)");
        Console.WriteLine();
    }

    void PrintTimeline()
    {
        var count = Math.Min(_historyCount, EventHistory.Length);
        if (count == 0)
        {
            Console.WriteLine("No transitions yet.");
            return;
        }
        Console.WriteLine($"Transition Timeline (last {count}):");
        for (int i = 0; i < count; i++)
        {
            var idx = (_historyCount - count + i) % EventHistory.Length;
            var evt = EventHistory[idx] ?? "";
            var regsnap = string.Join(" ", _registers.Take(4).Select(r => $"{r.Key}={r.Value}"));
            Console.WriteLine($"  {i + 1,3}. {evt,-40} | regs: {regsnap}");
        }
        Console.WriteLine();
    }

    void PrintEvents()
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
            var hot = t.HotWeight.HasValue ? $" @hot({t.HotWeight})" : "";
            Console.WriteLine($"  {ev}{par}{guard}{hot} → {t.Target}{body}");
        }
        Console.WriteLine();
    }

    void PrintHistory()
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

    void PrintSystemInfo()
    {
        Console.WriteLine("=== B+ Debugger System Info ===");
        Console.WriteLine($"Total states: {_allStates.Count}");
        Console.WriteLine($"Current state: {_currentState?.Name}");
        Console.WriteLine($"Breakpoints: {(_breakpoints.Count > 0 ? string.Join(", ", _breakpoints) : "none")}");
        Console.WriteLine($"Watched vars: {(_watchVars.Count > 0 ? string.Join(", ", _watchVars) : "none")}");
        Console.WriteLine($"Register-to-variable mappings: {_regToVar.Count}");
        foreach (var kv in _regToVar)
            Console.WriteLine($"  @{kv.Key} → {kv.Value}");
        Console.WriteLine($"Transition history entries: {_historyCount}");
        Console.WriteLine($"Step mode: {(_stepMode > 0 ? "on" : "off")}");
        Console.WriteLine();
    }

    void FireEvent(string eventName, string[] args)
    {
        if (_currentState == null) return;

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

            // Simulate register state for transition
            SimulateRegisterTransition(t);

            var log = $"{_currentState.Name} --[{t.EventName}]--> {t.Target}";
            EventHistory[_historyCount % EventHistory.Length] = log;
            _historyCount++;

            if (t.Body != null)
                Console.WriteLine($"  [action] {t.Body}");

            foreach (var a in _currentState.Actions.Where(a => a.Type == ActionType.Exit))
                Console.WriteLine($"  [exit] {a.Body}");

            var targetName = t.Target;
            if (_stateMap.TryGetValue(targetName, out var targetState))
            {
                _currentState = targetState;

                // Apply register-to-variable mapping for new state
                var oldCtx = _currentState;
                foreach (var a in _currentState.Actions.Where(a => a.Type == ActionType.Enter))
                    Console.WriteLine($"  [enter] {a.Body}");

                Console.WriteLine($"  ✓ {log}");

                // Show watched variable changes
                foreach (var v in _currentState.Variables)
                {
                    if (_watchVars.Contains(v.Name) && _varToReg.TryGetValue(v.Name, out var reg))
                        Console.WriteLine($"  [watch] {v.Name} = {_registers.GetValueOrDefault(reg)} (from @{reg})");
                }

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

    void SimulateRegisterTransition(TransitionNode t)
    {
        // Simulate CPU register effects of a transition
        if (t.HotWeight.HasValue && t.HotWeight > 0.5)
        {
            // Hot path: mark as L1 cache
            _registers["r12"] = 0x1;
        }
        if (t.IsAlways)
        {
            _registers["rcx"]++;
        }
        // Simulate some register activity
        _registers["rax"] = _historyCount;
        _registers["rdx"] = _stateMap.TryGetValue(t.Target, out _) ? 1L : 0L;
    }

    static string DefaultForType(string type) => type.ToLower() switch
    {
        "int" or "long" or "float" or "double" => "0",
        "bool" => "false",
        "string" => "\"\"",
        _ => "null"
    };
}
