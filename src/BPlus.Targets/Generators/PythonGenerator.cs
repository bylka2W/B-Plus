using System.Text;
using BPlus.Core.Ast;
using System.Linq;

namespace BPlus.Targets.Generators;

public class PythonGenerator : ICodeGenerator
{
    public string GetFileExtension() => ".py";
    public string GetLanguageName() => "Python";

    private static HashSet<string> CollectAllEvents(ProgramNode program)
    {
        var events = new HashSet<string>();
        void Walk(StateDefNode s)
        {
            foreach (var t in s.Transitions)
                if (!t.IsAlways) events.Add(t.EventName);
            foreach (var ns in s.NestedStates) Walk(ns);
        }
        foreach (var st in program.States) Walk(st);
        foreach (var par in program.ParallelBlocks)
            foreach (var st in par.States) Walk(st);
        return events;
    }

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var sb = new StringBuilder();
        var allEvents = CollectAllEvents(program);

        // Runtime: State base class
        sb.AppendLine("from enum import Enum, auto");
        sb.AppendLine();
        sb.AppendLine();
        sb.AppendLine("class State:");
        sb.AppendLine("    def enter(self): pass");
        sb.AppendLine("    def exit(self): pass");
        sb.AppendLine("    def always(self): return None");
        sb.AppendLine("    def handle_event(self, event_name):");
        sb.AppendLine("        return None");
        sb.AppendLine();

        foreach (var imp in program.Imports)
            sb.AppendLine($"from {Path.GetFileNameWithoutExtension(imp.Path)} import *");
        if (program.Imports.Count > 0) sb.AppendLine();

        if (program.Context is { Variables.Count: > 0 })
        {
            sb.AppendLine("# Context");
            foreach (var v in program.Context.Variables)
                sb.AppendLine($"{v.Name}: {MapToPyType(v.Type)} = {NormalizePyLiteral(v.DefaultValue ?? DefaultLiteral(v.Type))}");
            sb.AppendLine();
        }

        foreach (var en in program.Enums)
        {
            sb.AppendLine($"class {en.Name}(Enum):");
            foreach (var m in en.Members)
                sb.AppendLine($"    {m} = auto()");
            sb.AppendLine();
        }

        var ctxVars = program.Context is { Variables.Count: > 0 }
            ? program.Context.Variables.Select(v => v.Name).ToHashSet()
            : new HashSet<string>();

        foreach (var par in program.ParallelBlocks)
            foreach (var st in par.States)
                EmitState(sb, st, 0, ctxVars);

        foreach (var st in program.States)
            EmitState(sb, st, 0, ctxVars);

        bool hasMain = false;

        foreach (var entry in program.Entries)
        {
            sb.AppendLine();
            sb.AppendLine();
            sb.AppendLine($"def {entry.Name}():");
            var stack = new List<string>();
            foreach (var line in entry.BodyLines)
            {
                var trimmed = line.TrimStart();
                if (trimmed == "{" || trimmed == "}") continue; // skip B+ braces
                var indent = new string(' ', 4 + stack.Count * 4);
                if (trimmed.StartsWith("$$"))
                {
                    sb.AppendLine($"{indent}{trimmed[2..]}");
                    continue;
                }
                if (trimmed == "end")
                {
                    if (stack.Count > 0) stack.RemoveAt(stack.Count - 1);
                    continue;
                }
                if (trimmed.StartsWith("while ") || trimmed.StartsWith("if ") || trimmed.StartsWith("for "))
                {
                    stack.Add("");
                    var kw = trimmed.Split(' ')[0];
                    var rest = trimmed.Substring(kw.Length).Trim().TrimEnd(';');
                    sb.AppendLine($"{indent}{kw} {rest}:");
                    continue;
                }
                sb.AppendLine($"{indent}{line.TrimEnd(';')}");
            }
            // State machine event loop
            if (allEvents.Count > 0)
            {
                var firstState = GetFirstStateName(program);
                if (firstState != null)
                {
                    EmitEventLoop(sb, allEvents, firstState ?? "");
                }
            }
            if (entry.Name == "main")
            {
                sb.AppendLine();
                sb.AppendLine("if __name__ == \"__main__\":");
                sb.AppendLine($"    {entry.Name}()");
                hasMain = true;
            }
        }

        // Auto-generate main() if none exists
        if (!hasMain && allEvents.Count > 0)
        {
            var firstState = GetFirstStateName(program);
            if (firstState != null)
            {
                sb.AppendLine();
                sb.AppendLine();
                sb.AppendLine("def main():");
                EmitEventLoop(sb, allEvents, firstState ?? "");
                sb.AppendLine();
                sb.AppendLine("if __name__ == \"__main__\":");
                sb.AppendLine("    main()");
            }
        }

        return new Dictionary<string, string> { { "generated" + GetFileExtension(), sb.ToString() } };
    }

    private bool IsContextVarAssigned(string body, string varName)
    {
        if (body == null) return false;
        return body.Contains(varName + " =") ||
               body.Contains(varName + " +=") ||
               body.Contains(varName + "+=") ||
               body.Contains(varName + " -=") ||
               body.Contains(varName + "-=") ||
               body.Contains(varName + "++") ||
               body.Contains(varName + "--");
    }

    private void EmitState(StringBuilder sb, StateDefNode state, int depth, HashSet<string> ctxVars)
    {
        var indent = new string(' ', depth * 4);
        var baseCls = state.BaseClass ?? "State";
        sb.AppendLine($"{indent}class {state.Name}({baseCls}):");

        foreach (var v in state.Variables)
        {
            var def = NormalizePyLiteral(v.DefaultValue ?? DefaultLiteral(v.Type));
            sb.AppendLine($"{indent}    {v.Name}: {MapToPyType(v.Type)} = {def}");
        }

        if (state.Variables.Count > 0)
        {
            var initParams = string.Join(", ", state.Variables.Select(v => $"{v.Name}: {MapToPyType(v.Type)} = {NormalizePyLiteral(v.DefaultValue ?? DefaultLiteral(v.Type))}"));
            sb.AppendLine();
            sb.AppendLine($"{indent}    def __init__(self, {initParams}):");
            foreach (var v in state.Variables)
                sb.AppendLine($"{indent}        self.{v.Name} = {v.Name}");
        }

        foreach (var a in state.Actions)
        {
            sb.AppendLine();
            sb.AppendLine($"{indent}    def {a.Type.ToString().ToLower()}(self):");
            sb.AppendLine($"{indent}        {a.Body.TrimEnd(';')}");
        }

        // Group transitions by event name
        foreach (var group in state.Transitions.Where(t => !t.IsAlways).GroupBy(t => t.EventName))
        {
            sb.AppendLine();
            var pars = string.Join(", ", group.First().Parameters.Select(p => $"{p.Name}: {p.Type}"));
            sb.AppendLine($"{indent}    def on_{group.Key}(self{(pars != "" ? ", " + pars : "")}):");

            // Emit 'global' for context variables assigned in this method
            var assignedCtxVars = ctxVars.Where(v =>
                group.Any(t => IsContextVarAssigned(t.Body ?? "", v) || IsContextVarAssigned(t.Guard ?? "", v))
            ).ToList();
            if (assignedCtxVars.Count > 0)
                sb.AppendLine($"{indent}        global {string.Join(", ", assignedCtxVars)}");

            var needsFallback = group.All(t => t.Guard != null);
            foreach (var t in group)
            {
                if (t.Body != null)
                    sb.AppendLine($"{indent}        {t.Body.TrimEnd(';')}");
                if (t.Guard != null)
                {
                    sb.AppendLine($"{indent}        if {t.Guard}:");
                    sb.AppendLine($"{indent}            return {t.Target}()");
                }
                else
                {
                    sb.AppendLine($"{indent}        return {t.Target}()");
                }
            }
            if (needsFallback)
                sb.AppendLine($"{indent}        return None");
        }
        // Always transitions
        foreach (var t in state.Transitions.Where(t => t.IsAlways))
        {
            sb.AppendLine();
            sb.AppendLine($"{indent}    def always(self):");
            sb.AppendLine($"{indent}        return {t.Target}()");
        }

        // Runtime event dispatch
        var eventNames = state.Transitions.Where(t => !t.IsAlways).Select(t => t.EventName).Distinct().ToList();
        if (eventNames.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine($"{indent}    def handle_event(self, event_name):");
            foreach (var ev in eventNames)
            {
                var methodParams = state.Transitions.First(t => t.EventName == ev).Parameters;
                if (methodParams.Count > 0)
                {
                    sb.AppendLine($"{indent}        if event_name == \"{ev}\":");
                    sb.AppendLine($"{indent}            return self.on_{ev}({string.Join(", ", methodParams.Select(p => p.Name))})");
                }
                else
                {
                    sb.AppendLine($"{indent}        if event_name == \"{ev}\":");
                    sb.AppendLine($"{indent}            return self.on_{ev}()");
                }
            }
            sb.AppendLine($"{indent}        return None");
        }

        foreach (var timer in state.Timers)
        {
            sb.AppendLine();
            sb.AppendLine($"{indent}    def after_{timer.Duration}(self):");
            if (timer.Guard != null)
            {
                sb.AppendLine($"{indent}        if {timer.Guard}:");
                sb.AppendLine($"{indent}            return {timer.Target}");
            }
            else
            {
                sb.AppendLine($"{indent}        return {timer.Target}");
            }
        }

        foreach (var ns in state.NestedStates)
        {
            sb.AppendLine();
            EmitState(sb, ns, depth + 1, ctxVars);
        }

        if (state.Variables.Count == 0 && state.Actions.Count == 0 && state.Transitions.Count == 0 && state.NestedStates.Count == 0)
            sb.AppendLine($"{indent}    pass");

        sb.AppendLine();
    }

    private static string DefaultLiteral(string type) => type.ToLower() switch
    {
        "int" or "float" or "double" or "long" => "0",
        "bool" => "False",
        "string" => "\"\"",
        string t when t.StartsWith("bigfloat") => "0.0",
        _ => "None"
    };

    private static string NormalizePyLiteral(string lit)
    {
        if (lit == "true") return "True";
        if (lit == "false") return "False";
        return lit;
    }

    private static string MapToPyType(string type)
    {
        var lower = type.ToLower();
        if (lower.StartsWith("bigfloat")) return "float";
        return type;
    }

    static string? GetFirstStateName(ProgramNode program)
    {
        if (program.States.Count > 0)
            return program.States[0].Name;
        if (program.ParallelBlocks.Count > 0 && program.ParallelBlocks[0].States.Count > 0)
            return program.ParallelBlocks[0].States[0].Name;
        return null;
    }

    static void EmitEventLoop(StringBuilder sb, HashSet<string> events, string firstState)
    {
        bool hasTimer = events.Contains("timer");
        bool hasNetwork = events.Any(e => e.StartsWith("tcp_") || e.StartsWith("udp_"));
        // Use 4-space indent (1 level inside def)
        sb.AppendLine("    # State machine runtime (multi-source event loop)");
        sb.AppendLine("    import threading");
        sb.AppendLine("    import sys");
        sb.AppendLine("    from queue import Queue, Empty");
        sb.AppendLine();
        sb.AppendLine("    _queue = Queue()");
        sb.AppendLine("    _stop = threading.Event()");
        sb.AppendLine();
        sb.AppendLine("    def _stdin_source():");
        sb.AppendLine("        while not _stop.is_set():");
        sb.AppendLine("            line = sys.stdin.readline()");
        sb.AppendLine("            if not line:");
        sb.AppendLine("                break");
        sb.AppendLine("            event = line.strip()");
        sb.AppendLine("            _queue.put(event)");
        sb.AppendLine("            if event == \"exit\":");
        sb.AppendLine("                break");
        sb.AppendLine("        _stop.set()");
        sb.AppendLine();
        sb.AppendLine("    threading.Thread(target=_stdin_source, daemon=True).start()");
        if (hasTimer)
        {
            sb.AppendLine();
            sb.AppendLine("    # Timer event source (fires 'timer' every 1s)");
            sb.AppendLine("    def _timer_source():");
            sb.AppendLine("        while not _stop.is_set():");
            sb.AppendLine("            _stop.wait(1.0)");
            sb.AppendLine("            if not _stop.is_set():");
            sb.AppendLine("                _queue.put(\"timer\")");
            sb.AppendLine();
            sb.AppendLine("    threading.Thread(target=_timer_source, daemon=True).start()");
        }
        if (hasNetwork)
        {
            sb.AppendLine();
            sb.AppendLine("    # TCP server (port 8080)");
            sb.AppendLine("    def _tcp_source():");
            sb.AppendLine("        try:");
            sb.AppendLine("            import socket");
            sb.AppendLine("            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)");
            sb.AppendLine("            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)");
            sb.AppendLine("            sock.bind(('0.0.0.0', 8080))");
            sb.AppendLine("            sock.listen(5)");
            sb.AppendLine("            sock.settimeout(0.5)");
            sb.AppendLine("            while not _stop.is_set():");
            sb.AppendLine("                try:");
            sb.AppendLine("                    conn, addr = sock.accept()");
            sb.AppendLine("                    _queue.put(\"tcp_connect\")");
            sb.AppendLine("                    data = conn.recv(4096)");
            sb.AppendLine("                    if data:");
            sb.AppendLine("                        _queue.put(\"tcp_data\")");
            sb.AppendLine("                    conn.close()");
            sb.AppendLine("                    _queue.put(\"tcp_disconnected\")");
            sb.AppendLine("                except socket.timeout:");
            sb.AppendLine("                    pass");
            sb.AppendLine("        except:");
            sb.AppendLine("            pass");
            sb.AppendLine();
            sb.AppendLine("    threading.Thread(target=_tcp_source, daemon=True).start()");
        }
        sb.AppendLine();
        sb.AppendLine($"    current_state = {firstState}()");
        sb.AppendLine("    current_state.enter()");
        sb.AppendLine("    try:");
        sb.AppendLine("        while not _stop.is_set():");
        sb.AppendLine("            try:");
        sb.AppendLine("                event = _queue.get(timeout=0.2)");
        sb.AppendLine("                if event == \"exit\":");
        sb.AppendLine("                    current_state.exit()");
        sb.AppendLine("                    break");
        sb.AppendLine("                next_state = current_state.handle_event(event)");
        sb.AppendLine("                if next_state is not None:");
        sb.AppendLine("                    current_state.exit()");
        sb.AppendLine("                    current_state = next_state");
        sb.AppendLine("                    current_state.enter()");
        sb.AppendLine("            except Empty:");
        sb.AppendLine("                pass");
        sb.AppendLine("    except (EOFError, KeyboardInterrupt):");
        sb.AppendLine("        current_state.exit()");
        sb.AppendLine("        pass");
    }
}