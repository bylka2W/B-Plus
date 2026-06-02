using System.Linq;
using System.Text;
using BPlus.Core.Ast;

namespace BPlus.Targets.Generators;

public class CppGenerator : ICodeGenerator
{
    public string GetFileExtension() => ".cpp";
    public string GetLanguageName() => "C++";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var result = new Dictionary<string, string>
        {
            { "states.h", GenHeader(program) },
            { "states.cpp", GenImpl(program) }
        };

        // Carbon ABI: bidirectional C++ interop without wrappers
        if (program.Kernels.Count > 0 || program.ExternCppFns.Count > 0)
            result["carbon_abi.h"] = GenCarbonABI(program);

        return result;
    }

    private string GenHeader(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("#ifdef __cplusplus");
        sb.AppendLine("#include <cstdint>");
        sb.AppendLine("#include <optional>");
        sb.AppendLine("#else");
        sb.AppendLine("#include <stdint.h>");
        sb.AppendLine("#include <stdbool.h>");
        sb.AppendLine("#endif");
        sb.AppendLine();

        // Enums
        foreach (var en in program.Enums)
        {
            sb.AppendLine($"enum class {en.Name} {{ {string.Join(", ", en.Members)} }};");
        }
        if (program.Enums.Count > 0) sb.AppendLine();

        // Context
        if (program.Context is { Variables.Count: > 0 })
        {
            sb.AppendLine("namespace bplus_ctx {");
            foreach (var v in program.Context.Variables)
                sb.AppendLine($"    extern {v.Type} {v.Name};");
            sb.AppendLine("}");
            sb.AppendLine();
        }

        // Zig: errdefer declarations
        sb.AppendLine("// Zig-inspired errdefer: transaction rollback support");
        sb.AppendLine("#define errdefer(cleanup) auto _bplus_rollback = [&]() { cleanup };");
        sb.AppendLine("#define defer(cleanup) auto _bplus_defer = _bplus_rollback = [&]() { cleanup };");
        sb.AppendLine();

        // Collect all event names for base class
        var allEvents = new HashSet<string>();
        void CollectEvents(StateDefNode s)
        {
            foreach (var t in s.Transitions)
                if (!t.IsAlways) allEvents.Add(t.EventName);
            foreach (var ns in s.NestedStates) CollectEvents(ns);
        }
        foreach (var st in program.States) CollectEvents(st);
        foreach (var par in program.ParallelBlocks)
            foreach (var st in par.States) CollectEvents(st);

        sb.AppendLine("namespace bplus {");
        sb.AppendLine();
        sb.AppendLine("// Runtime State base class");
        sb.AppendLine("struct State {");
        sb.AppendLine("    virtual ~State() = default;");
        sb.AppendLine("    virtual State* handleEvent(const std::string& eventName) { return nullptr; }");
        sb.AppendLine("    virtual State* always() { return nullptr; }");
        sb.AppendLine("    virtual void enter() {}");
        sb.AppendLine("    virtual void exit() {}");
        foreach (var ev in allEvents.OrderBy(e => e))
            sb.AppendLine($"    virtual State* on_{ev}() {{ return nullptr; }}");
        sb.AppendLine("};");
        sb.AppendLine();

        foreach (var par in program.ParallelBlocks)
            foreach (var st in par.States)
                EmitStateHeader(sb, st, 1);

        foreach (var st in program.States)
            EmitStateHeader(sb, st, 1);

        sb.AppendLine("} // namespace bplus");
        return sb.ToString();
    }

    private string GenImpl(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#include \"states.h\"");
        sb.AppendLine("#include <new>");
        sb.AppendLine("#include <string>");
        sb.AppendLine("#include <iostream>");
        if (HasFallibleTransitions(program))
        {
            sb.AppendLine("#include <expected>");
        }

        if (program.Context is { Variables.Count: > 0 })
        {
            sb.AppendLine("namespace bplus_ctx {");
            foreach (var v in program.Context.Variables)
                sb.AppendLine($"    {v.Type} {v.Name} = {v.DefaultValue ?? DefaultLiteral(v.Type)};");
            sb.AppendLine("}");
            sb.AppendLine();
        }

        sb.AppendLine("namespace bplus {");

        foreach (var par in program.ParallelBlocks)
            foreach (var st in par.States)
                EmitStateImpl(sb, st, 1);

        foreach (var st in program.States)
            EmitStateImpl(sb, st, 1);

        sb.AppendLine("} // namespace bplus");

        // Collect all event names for main()
        var allEvents = new HashSet<string>();
        void CollectEvents(StateDefNode s)
        {
            foreach (var t in s.Transitions)
                if (!t.IsAlways) allEvents.Add(t.EventName);
            foreach (var ns in s.NestedStates) CollectEvents(ns);
        }
        foreach (var st in program.States) CollectEvents(st);
        foreach (var par in program.ParallelBlocks)
            foreach (var st in par.States) CollectEvents(st);

        // Entry point: main() with multi-source event loop
        if (allEvents.Count > 0 && program.States.Count > 0)
        {
            bool hasTimer = allEvents.Contains("timer");
            bool hasNetwork = allEvents.Any(e => e.StartsWith("tcp_") || e.StartsWith("udp_"));
            var firstState = program.States[0].Name;
            sb.AppendLine();
            sb.AppendLine("#include <thread>");
            sb.AppendLine("#include <queue>");
            sb.AppendLine("#include <mutex>");
            sb.AppendLine("#include <condition_variable>");
            sb.AppendLine("#include <chrono>");
            if (hasNetwork)
            {
                sb.AppendLine("#ifdef _WIN32");
                sb.AppendLine("#include <winsock2.h>");
                sb.AppendLine("#pragma comment(lib, \"ws2_32.lib\")");
                sb.AppendLine("#else");
                sb.AppendLine("#include <sys/socket.h>");
                sb.AppendLine("#include <netinet/in.h>");
                sb.AppendLine("#include <unistd.h>");
                sb.AppendLine("#endif");
            }
            sb.AppendLine();
            sb.AppendLine("int main() {");
            // Emit entry body (if entry named "main" exists)
            foreach (var entry in program.Entries)
            {
                if (entry.Name == "main")
                {
                    foreach (var line in entry.BodyLines)
                    {
                        var trimmed = line.TrimStart();
                        if (trimmed.StartsWith("$$")) { sb.AppendLine($"    {trimmed[2..]}"); continue; }
                        if (trimmed == "end") continue;
                        sb.AppendLine($"    {TranslateBPlusToCpp(trimmed)};");
                    }
                }
            }
            sb.AppendLine("    using namespace bplus;");
            sb.AppendLine("    std::queue<std::string> eventQueue;");
            sb.AppendLine("    std::mutex queueMutex;");
            sb.AppendLine("    std::condition_variable queueCV;");
            sb.AppendLine();
            sb.AppendLine("    // Stdin reader");
            sb.AppendLine("    std::thread stdinThread([] {");
            sb.AppendLine("        std::string line;");
            sb.AppendLine("        while (std::getline(std::cin, line)) {");
            sb.AppendLine("            { std::lock_guard<std::mutex> lock(queueMutex); eventQueue.push(line); }");
            sb.AppendLine("            queueCV.notify_one();");
            sb.AppendLine("        }");
            sb.AppendLine("    });");
            sb.AppendLine("    stdinThread.detach();");
            if (hasTimer)
            {
                sb.AppendLine();
                sb.AppendLine("    // Timer (fires 'timer' every 1s)");
                sb.AppendLine("    std::thread timerThread([] {");
                sb.AppendLine("        while (true) {");
                sb.AppendLine("            std::this_thread::sleep_for(std::chrono::seconds(1));");
                sb.AppendLine("            { std::lock_guard<std::mutex> lock(queueMutex); eventQueue.push(\"timer\"); }");
                sb.AppendLine("            queueCV.notify_one();");
                sb.AppendLine("        }");
                sb.AppendLine("    });");
                sb.AppendLine("    timerThread.detach();");
            }
            if (hasNetwork)
            {
                sb.AppendLine();
                sb.AppendLine("    // TCP server on port 8080");
                sb.AppendLine("    std::thread tcpThread([] {");
                sb.AppendLine("#ifdef _WIN32");
                sb.AppendLine("        WSADATA wsa; WSAStartup(MAKEWORD(2,2), &wsa);");
                sb.AppendLine("        SOCKET sock = socket(AF_INET, SOCK_STREAM, 0);");
                sb.AppendLine("        sockaddr_in addr = {}; addr.sin_family = AF_INET; addr.sin_port = htons(8080); addr.sin_addr.s_addr = INADDR_ANY;");
                sb.AppendLine("        bind(sock, (sockaddr*)&addr, sizeof(addr));");
                sb.AppendLine("        listen(sock, 5);");
                sb.AppendLine("        while (true) {");
                sb.AppendLine("            SOCKET client = accept(sock, NULL, NULL);");
                sb.AppendLine("            if (client == INVALID_SOCKET) break;");
                sb.AppendLine("            { std::lock_guard<std::mutex> lock(queueMutex); eventQueue.push(\"tcp_connect\"); }");
                sb.AppendLine("            queueCV.notify_one();");
                sb.AppendLine("            char buf[4096]; int n = recv(client, buf, sizeof(buf), 0);");
                sb.AppendLine("            if (n > 0) { std::lock_guard<std::mutex> lock(queueMutex); eventQueue.push(\"tcp_data\"); queueCV.notify_one(); }");
                sb.AppendLine("            closesocket(client);");
                sb.AppendLine("            { std::lock_guard<std::mutex> lock(queueMutex); eventQueue.push(\"tcp_disconnected\"); }");
                sb.AppendLine("            queueCV.notify_one();");
                sb.AppendLine("        }");
                sb.AppendLine("        closesocket(sock); WSACleanup();");
                sb.AppendLine("#else");
                sb.AppendLine("        int sock = socket(AF_INET, SOCK_STREAM, 0);");
                sb.AppendLine("        sockaddr_in addr = {}; addr.sin_family = AF_INET; addr.sin_port = htons(8080); addr.sin_addr.s_addr = INADDR_ANY;");
                sb.AppendLine("        bind(sock, (sockaddr*)&addr, sizeof(addr));");
                sb.AppendLine("        listen(sock, 5);");
                sb.AppendLine("        while (true) {");
                sb.AppendLine("            int client = accept(sock, NULL, NULL);");
                sb.AppendLine("            if (client < 0) break;");
                sb.AppendLine("            { std::lock_guard<std::mutex> lock(queueMutex); eventQueue.push(\"tcp_connect\"); queueCV.notify_one(); }");
                sb.AppendLine("            char buf[4096]; int n = read(client, buf, sizeof(buf));");
                sb.AppendLine("            if (n > 0) { std::lock_guard<std::mutex> lock(queueMutex); eventQueue.push(\"tcp_data\"); queueCV.notify_one(); }");
                sb.AppendLine("            close(client);");
                sb.AppendLine("            { std::lock_guard<std::mutex> lock(queueMutex); eventQueue.push(\"tcp_disconnected\"); queueCV.notify_one(); }");
                sb.AppendLine("        }");
                sb.AppendLine("        close(sock);");
                sb.AppendLine("#endif");
                sb.AppendLine("    });");
                sb.AppendLine("    tcpThread.detach();");
            }
            sb.AppendLine();
            sb.AppendLine($"    State* current = new {firstState}();");
            sb.AppendLine("    while (true) {");
            sb.AppendLine("        std::string event;");
            sb.AppendLine("        {");
            sb.AppendLine("            std::unique_lock<std::mutex> lock(queueMutex);");
            sb.AppendLine("            queueCV.wait(lock, [&]{ return !eventQueue.empty(); });");
            sb.AppendLine("            event = eventQueue.front(); eventQueue.pop();");
            sb.AppendLine("        }");
            sb.AppendLine("        if (event == \"exit\") break;");
            sb.AppendLine("        State* next = current->handleEvent(event);");
            sb.AppendLine("        if (next != nullptr && next != current) {");
            sb.AppendLine("            delete current;");
            sb.AppendLine("            current = next;");
            sb.AppendLine("        }");
            sb.AppendLine("    }");
            sb.AppendLine("    delete current;");
            sb.AppendLine("    return 0;");
            sb.AppendLine("}");
        }

        return sb.ToString();
    }

    // Zig: Carbon ABI — zero-overhead C++ interop
    private string GenCarbonABI(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("// Carbon ABI: bidirectional C++ interop without wrappers");
        sb.AppendLine("// Generated by B+ Transpiler — ABI-compatible with existing C++ types");
        sb.AppendLine("#include <cstdint>");
        sb.AppendLine();

        foreach (var k in program.Kernels)
        {
            var pars = string.Join(", ", k.Parameters.Select(p => $"{MapToCppType(p.Type)} {p.Name}"));
            sb.AppendLine($"extern \"C\" void bplus_kernel_{k.Name}({pars});");
        }

        foreach (var fn in program.ExternCppFns)
        {
            var pars = string.Join(", ", fn.Parameters.Select(p => $"{MapToCppType(p.Type)} {p.Name}"));
            sb.AppendLine($"using bplus_extern_{fn.Name} = {fn.ReturnType}(*)({pars});");
        }

        sb.AppendLine();
        sb.AppendLine("// C++ ABI-compatible state pointer (no wrapper struct)");
        sb.AppendLine("using bplus_state_ptr = void*;");
        sb.AppendLine("static_assert(sizeof(bplus_state_ptr) == sizeof(void*), \"ABI mismatch\");");
        return sb.ToString();
    }

    // Zig: Error unions via std::expected
    private void EmitErrDefer(StringBuilder sb, TransitionNode t, string ind)
    {
        if (t.IsFallible)
        {
            if (t.ErrorBody != null)
            {
                sb.AppendLine($"{ind}    errdefer {{ {t.ErrorBody} }};");
            }
            if (t.ErrorTarget != null)
            {
                var errType = t.ErrorType ?? "std::string";
                sb.AppendLine($"{ind}    using result_t = std::expected<State*, {errType}>;");
            }
        }

        if (t.Body != null && t.Body.Contains("cleanup"))
        {
            sb.AppendLine($"{ind}    defer {{ {t.Body.Split("cleanup").Last().Trim()} }};");
        }
    }

    private void EmitStateHeader(StringBuilder sb, StateDefNode state, int depth)
    {
        var ind = new string(' ', depth * 4);
        var baseCls = state.BaseClass ?? "State";
        var generic = state.GenericParam != null ? $"<typename {state.GenericParam}>" : "";

        if (state.IsBaseClass)
            sb.AppendLine($"{ind}class {state.Name} : public {baseCls} {{");
        else
            sb.AppendLine($"{ind}class {state.Name}{generic} : public {baseCls} {{");
        sb.AppendLine($"{ind}public:");

        foreach (var v in state.Variables)
        {
            var qual = v.IsMutable ? "" : "const ";
            sb.AppendLine($"{ind}    {qual}{v.Type} {v.Name} = {v.DefaultValue ?? DefaultLiteral(v.Type)};");
        }
        if (state.Variables.Count > 0) sb.AppendLine();

        foreach (var a in state.Actions)
            sb.AppendLine($"{ind}    void {a.Type.ToString().ToLower()}() override;");

        // Group transitions by event name to avoid duplicate declarations
        foreach (var group in state.Transitions.Where(t => !t.IsAlways).GroupBy(t => t.EventName))
        {
            var first = group.First();
            var pars = string.Join(", ", first.Parameters.Select(p => $"{p.Type} {p.Name}"));
            if (first.IsFallible)
            {
                var errType = first.ErrorType ?? "std::string";
                sb.AppendLine($"{ind}    std::expected<State*, {errType}> on_{group.Key}({pars}) override;");
            }
            else
                sb.AppendLine($"{ind}    State* on_{group.Key}({pars}) override;");
        }
        // Always transitions
        foreach (var t in state.Transitions.Where(t => t.IsAlways))
            sb.AppendLine($"{ind}    State* always() override;");

        // Error transitions
        foreach (var et in state.ErrorTransitions)
        {
            var pars = string.Join(", ", et.Parameters.Select(p => $"{p.Type} {p.Name}"));
            var errType = et.ErrorType ?? "std::string";
            sb.AppendLine($"{ind}    std::expected<State*, {errType}> on_{et.EventName}({pars}) override;");
        }

        foreach (var timer in state.Timers)
            sb.AppendLine($"{ind}    State* after_{timer.Duration}() override;");

        foreach (var ns in state.NestedStates)
            EmitStateHeader(sb, ns, depth + 1);

        sb.AppendLine($"{ind}}};");
        sb.AppendLine();
    }

    private void EmitStateImpl(StringBuilder sb, StateDefNode state, int depth)
    {
        var ind = new string(' ', depth * 4);

        foreach (var a in state.Actions)
        {
            var n = a.Type.ToString().ToLower();
            sb.AppendLine($"{ind}void {state.Name}::{n}() {{ {a.Body.TrimEnd(';')}; }}");
        }

        // Always transitions
        foreach (var t in state.Transitions.Where(t => t.IsAlways))
            sb.AppendLine($"{ind}State* {state.Name}::always() {{ return new {t.Target}(); }}");

        // Group non-always transitions by event name
        foreach (var group in state.Transitions.Where(t => !t.IsAlways).GroupBy(t => t.EventName))
        {
            var first = group.First();
            var pars = string.Join(", ", first.Parameters.Select(p => $"{p.Type} {p.Name}"));
            var isFallible = first.IsFallible;
            var errType = first.ErrorType ?? "std::string";
            var needsFallback = group.All(t => t.Guard != null);

            if (isFallible)
                sb.AppendLine($"{ind}std::expected<State*, {errType}> {state.Name}::on_{group.Key}({pars}) {{");
            else
                sb.AppendLine($"{ind}State* {state.Name}::on_{group.Key}({pars}) {{");
            foreach (var t in group.Where(t => t.Body != null && t.Body.Contains("cleanup")))
                EmitErrDefer(sb, t, ind);
            foreach (var t in group)
            {
                foreach (var line in SplitBodyCpp(t.Body))
                    sb.AppendLine($"{ind}    {line.TrimEnd(';')};");
                if (t.Guard != null)
                {
                    if (t.Body != null)
                    {
                        sb.AppendLine($"{ind}    if ({t.Guard})");
                        sb.AppendLine($"{ind}        return new {t.Target}();");
                    }
                    else
                    {
                        sb.AppendLine($"{ind}    if ({t.Guard}) return new {t.Target}();");
                    }
                }
                else
                {
                    sb.AppendLine($"{ind}    return new {t.Target}();");
                }
            }
            if (isFallible && needsFallback)
                sb.AppendLine($"{ind}    return std::unexpected<{errType}>({errType}{{}});");
            else if (!isFallible && needsFallback)
                sb.AppendLine($"{ind}    return nullptr;");
            sb.AppendLine($"{ind}}}");
        }

        // Error transitions
        foreach (var et in state.ErrorTransitions)
        {
            var pars = string.Join(", ", et.Parameters.Select(p => $"{p.Type} {p.Name}"));
            var errType = et.ErrorType ?? "std::string";
            sb.AppendLine($"{ind}std::expected<State*, {errType}> {state.Name}::on_{et.EventName}({pars}) {{");
            if (et.OkBody != null)
                sb.AppendLine($"{ind}    {et.OkBody};");
            if (et.Guard != null)
            {
                sb.AppendLine($"{ind}    if ({et.Guard})");
                sb.AppendLine($"{ind}        return new {et.OkTarget}();");
            }
            if (et.ErrorBody != null)
                sb.AppendLine($"{ind}    errdefer {{ {et.ErrorBody} }};");
            sb.AppendLine($"{ind}    return new {et.OkTarget}();");
            sb.AppendLine($"{ind}}}");
        }

        foreach (var timer in state.Timers)
        {
            sb.AppendLine($"{ind}State* {state.Name}::after_{timer.Duration}() {{");
            if (timer.Guard != null)
            {
                sb.AppendLine($"{ind}    if ({timer.Guard})");
                sb.AppendLine($"{ind}        return new {timer.Target}();");
                sb.AppendLine($"{ind}    return nullptr;");
            }
            else
                sb.AppendLine($"{ind}    return new {timer.Target}();");
            sb.AppendLine($"{ind}}}");
        }

        // Runtime event dispatch
        var stateEventNames = state.Transitions.Where(t => !t.IsAlways).Select(t => t.EventName).Distinct().ToList();
        if (stateEventNames.Count > 0)
        {
            sb.AppendLine($"{ind}State* {state.Name}::handleEvent(const std::string& eventName) {{");
            foreach (var ev in stateEventNames)
                sb.AppendLine($"{ind}    if (eventName == \"{ev}\") return on_{ev}();");
            sb.AppendLine($"{ind}    return nullptr;");
            sb.AppendLine($"{ind}}}");
        }

        foreach (var ns in state.NestedStates)
            EmitStateImpl(sb, ns, depth + 1);
    }

    private static string[] SplitBodyCpp(string? body) =>
        body?.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries) ?? Array.Empty<string>();

    private static bool HasFallibleTransitions(ProgramNode program)
    {
        bool Check(StateDefNode s) =>
            s.Transitions.Any(t => t.IsFallible) ||
            s.ErrorTransitions.Count > 0 ||
            s.NestedStates.Any(Check);
        return program.States.Any(Check) ||
               program.ParallelBlocks.Any(pb => pb.States.Any(Check));
    }

    private static string DefaultLiteral(string type) => type.ToLower() switch
    {
        "int" or "float" or "double" or "long" => "0",
        "bool" => "false",
        "string" => "\"\"",
        string t when t.StartsWith("bigfloat") => "0.0",
        _ => "{}"
    };

    private static string MapToCppType(BPlusType type) => type switch
    {
        SimpleType s => s.Name,
        ImageType i => $"void* /*image {i.W}x{i.H}*/",
        ArrayType a => $"{MapToCppType(a.ElementType)}*",
        _ => "void*"
    };

    private static string TranslateBPlusToCpp(string line)
    {
        if (line.StartsWith("print(") && line.EndsWith(")"))
        {
            var inner = line.Substring(6, line.Length - 7);
            return $"std::cout << {inner} << std::endl";
        }
        if (line.StartsWith("return "))
            return line;
        return line;
    }
}