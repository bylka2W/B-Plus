using System.Text;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

public class CGenerator : ICodeGenerator
{
    public string GetFileExtension() => ".c";
    public string GetLanguageName() => "C";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        return new Dictionary<string, string>
        {
            { "states.h", GenHeader(program) },
            { "states.c", GenImpl(program) }
        };
    }

    private string GenHeader(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("#include <stdbool.h>");
        sb.AppendLine("#include <stdint.h>");
        sb.AppendLine("#include <string.h>");
        sb.AppendLine();

        // Enums
        foreach (var en in program.Enums)
        {
            sb.AppendLine($"typedef enum {{ {string.Join(", ", en.Members.Select((m, i) => $"{en.Name}_{m}"))} }} {en.Name};");
        }
        if (program.Enums.Count > 0) sb.AppendLine();

        // Gather all states (including nested)
        var allStates = new List<StateDefNode>();
        void Collect(StateDefNode s) { allStates.Add(s); foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var st in program.States) Collect(st);
        foreach (var par in program.ParallelBlocks)
            foreach (var st in par.States) Collect(st);

        // Forward decls
        foreach (var s in allStates)
            sb.AppendLine($"typedef struct {s.Name} {s.Name};");
        sb.AppendLine();

        sb.AppendLine("typedef struct State State;");

        bool hasMembers = false;
        var stateMembers = new List<string>();

        // Group transitions by (state, event) to avoid duplicate struct fields
        foreach (var s in allStates)
        {
            foreach (var group in s.Transitions.GroupBy(t => t.EventName))
            {
                stateMembers.Add($"    State* (*{Lower(s.Name)}_on_{group.Key})(void);");
                hasMembers = true;
            }
            foreach (var timer in s.Timers)
            {
                stateMembers.Add($"    State* (*{Lower(s.Name)}_after_{timer.Duration})(void);");
                hasMembers = true;
            }
        }

        if (hasMembers)
        {
            sb.AppendLine("struct State {");
            sb.AppendLine("    int state_id;");
            foreach (var m in stateMembers)
                sb.AppendLine(m);
            sb.AppendLine("};");
        }
        else
        {
            sb.AppendLine("struct State { int state_id; int __dummy; };");
        }
        sb.AppendLine();

        foreach (var s in allStates)
            sb.AppendLine($"extern State {Lower(s.Name)}_state;");
        sb.AppendLine();

        if (program.Context is { Variables.Count: > 0 })
        {
            foreach (var v in program.Context.Variables)
                sb.AppendLine($"extern {v.Type} {v.Name};");
            sb.AppendLine();
        }

        foreach (var s in allStates)
        {
            foreach (var a in s.Actions)
                sb.AppendLine($"void {Lower(s.Name)}_{a.Type.ToString().ToLower()}(void);");
            foreach (var group in s.Transitions.GroupBy(t => t.EventName))
                sb.AppendLine($"State* {Lower(s.Name)}_on_{group.Key}(void);");
            foreach (var timer in s.Timers)
                sb.AppendLine($"State* {Lower(s.Name)}_after_{timer.Duration}(void);");
        }

        sb.AppendLine();
        sb.AppendLine("// Generic dispatch: route event to current state's handler");
        sb.AppendLine("State* dispatch_event(State* current, const char* event);");

        return sb.ToString();
    }

    private string GenImpl(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#include \"states.h\"");
        sb.AppendLine("#include <stdio.h>");
        sb.AppendLine("#include <stdlib.h>");
        sb.AppendLine("#include <string.h>");
        sb.AppendLine("#ifdef _WIN32");
        sb.AppendLine("#include <winsock2.h>");
        sb.AppendLine("#include <windows.h>");
        sb.AppendLine("#else");
        sb.AppendLine("#include <pthread.h>");
        sb.AppendLine("#include <unistd.h>");
        sb.AppendLine("#include <sys/socket.h>");
        sb.AppendLine("#include <netinet/in.h>");
        sb.AppendLine("#endif");
        sb.AppendLine();

        // Context
        if (program.Context is { Variables.Count: > 0 })
        {
            foreach (var v in program.Context.Variables)
                sb.AppendLine($"{v.Type} {v.Name} = {v.DefaultValue ?? DefaultLiteral(v.Type)};");
            sb.AppendLine();
        }

        // Gather all states
        var allStates = new List<StateDefNode>();
        void Collect(StateDefNode s) { allStates.Add(s); foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var st in program.States) Collect(st);
        foreach (var par in program.ParallelBlocks)
            foreach (var st in par.States) Collect(st);

        foreach (var s in allStates)
        {
            foreach (var a in s.Actions)
                sb.AppendLine($"void {Lower(s.Name)}_{a.Type.ToString().ToLower()}(void) {{ {a.Body.TrimEnd(';')}; }}");

            foreach (var group in s.Transitions.GroupBy(t => t.EventName))
            {
                var fn = $"{Lower(s.Name)}_on_{group.Key}";
                var needsFallback = group.All(t => t.Guard != null);
                sb.AppendLine($"State* {fn}(void) {{");
                foreach (var t in group)
                {
                    foreach (var line in SplitBodyCGen(t.Body))
                        sb.AppendLine($"    {line.TrimEnd(';')};");
                    if (t.Guard != null)
                    {
                        sb.AppendLine($"    if ({t.Guard}) return &{Lower(t.Target)}_state;");
                    }
                    else
                    {
                        sb.AppendLine($"    return &{Lower(t.Target)}_state;");
                    }
                }
                if (needsFallback)
                    sb.AppendLine($"    return NULL;");
                sb.AppendLine("}");
            }

            foreach (var timer in s.Timers)
            {
                var fn = $"{Lower(s.Name)}_after_{timer.Duration}";
                if (timer.Guard != null)
                {
                    sb.AppendLine($"State* {fn}(void) {{");
                    sb.AppendLine($"    if ({timer.Guard}) return &{Lower(timer.Target)}_state;");
                    sb.AppendLine($"    return NULL;");
                    sb.AppendLine("}");
                }
                else
                {
                    sb.AppendLine($"State* {fn}(void) {{ return &{Lower(timer.Target)}_state; }}");
                }
            }
        }

        sb.AppendLine();

        // State instance definitions
        int sid = 0;
        foreach (var s in allStates)
        {
            sb.AppendLine($"State {Lower(s.Name)}_state = {{");
            sb.AppendLine($"    .state_id = {sid},");

            foreach (var a in s.Actions)
                sb.AppendLine($"    .{a.Type.ToString().ToLower()} = {Lower(s.Name)}_{a.Type.ToString().ToLower()},");

            foreach (var group in s.Transitions.GroupBy(t => t.EventName))
                sb.AppendLine($"    .{Lower(s.Name)}_on_{group.Key} = {Lower(s.Name)}_on_{group.Key},");

            foreach (var timer in s.Timers)
                sb.AppendLine($"    .{Lower(s.Name)}_after_{timer.Duration} = {Lower(s.Name)}_after_{timer.Duration},");

            sb.AppendLine("};");
            sid++;
        }

        // Dispatch function
        sb.AppendLine();
        sb.AppendLine("State* dispatch_event(State* current, const char* event) {");
        int d_sid = 0;
        foreach (var s in allStates)
        {
            var stateEvents = s.Transitions.Where(t => !t.IsAlways).Select(t => t.EventName).Distinct().ToList();
            if (stateEvents.Count == 0) { d_sid++; continue; }
            sb.AppendLine($"    if (current->state_id == {d_sid}) {{");
            foreach (var ev in stateEvents)
                sb.AppendLine($"        if (strcmp(event, \"{ev}\") == 0) return {Lower(s.Name)}_on_{ev}();");
            sb.AppendLine("        return current;");
            sb.AppendLine("    }");
            d_sid++;
        }
        sb.AppendLine("    return current;");
        sb.AppendLine("}");
        sb.AppendLine();

        // Entry point
        foreach (var entry in program.Entries)
        {
            sb.AppendLine();
            var retType = entry.ReturnType ?? "int";
            var entryName = entry.Name == "main" ? "main" : entry.Name;
            sb.AppendLine($"{retType} {entryName}(int argc, char** argv) {{");
            sb.AppendLine("    (void)argc; (void)argv;");
            var stack = new List<string>();
            foreach (var line in entry.BodyLines)
            {
                var trimmed = line.TrimStart();
                var indent = new string(' ', 4 + stack.Count * 4);
                if (trimmed.StartsWith("$$"))
                {
                    sb.AppendLine($"{indent}{trimmed[2..]}");
                    continue;
                }
                if (trimmed == "end")
                {
                    if (stack.Count > 0) { stack.RemoveAt(stack.Count - 1); sb.AppendLine($"{indent[..^4]}}}"); }
                    continue;
                }
                if (trimmed.StartsWith("while ") || trimmed.StartsWith("if ") || trimmed.StartsWith("for "))
                {
                    stack.Add("");
                    var parts = trimmed.Split(' ');
                    var kw = parts[0];
                    var rest = string.Join(" ", parts.Skip(1));
                    sb.AppendLine($"{indent}{kw} ({rest}) {{");
                    continue;
                }
                sb.AppendLine($"{indent}{TranslateBPlusToC(trimmed)};");
            }
            while (stack.Count > 0) { sb.AppendLine("    }"); stack.RemoveAt(stack.Count - 1); }

            // State machine event loop
            var cEvents = new HashSet<string>();
            void CollectCEvents(StateDefNode s) { foreach (var t in s.Transitions) if (!t.IsAlways) cEvents.Add(t.EventName); foreach (var ns in s.NestedStates) CollectCEvents(ns); }
            foreach (var st in program.States) CollectCEvents(st);
            foreach (var par in program.ParallelBlocks) foreach (var st in par.States) CollectCEvents(st);
            if (cEvents.Count > 0)
            {
                bool hasTimer = cEvents.Contains("timer");
                bool hasNetwork = cEvents.Any(e => e.StartsWith("tcp_") || e.StartsWith("udp_"));
                var firstState = Lower(allStates[0].Name);
                sb.AppendLine();
                sb.AppendLine("    // Thread-safe event queue");
                sb.AppendLine("    typedef struct EventNode { char data[64]; struct EventNode* next; } EventNode;");
                sb.AppendLine("    static EventNode* eq_head = NULL;");
                sb.AppendLine("    static EventNode* eq_tail = NULL;");
                sb.AppendLine("    #ifdef _WIN32");
                sb.AppendLine("    static CRITICAL_SECTION eq_lock;");
                sb.AppendLine("    static CONDITION_VARIABLE eq_cv;");
                sb.AppendLine("    #else");
                sb.AppendLine("    static pthread_mutex_t eq_lock = PTHREAD_MUTEX_INITIALIZER;");
                sb.AppendLine("    static pthread_cond_t eq_cv = PTHREAD_COND_INITIALIZER;");
                sb.AppendLine("    #endif");
                sb.AppendLine();
                sb.AppendLine("    static void eq_push(const char* event) {");
                sb.AppendLine("        EventNode* n = (EventNode*)malloc(sizeof(EventNode));");
                sb.AppendLine("        strcpy(n->data, event); n->next = NULL;");
                sb.AppendLine("        #ifdef _WIN32");
                sb.AppendLine("        EnterCriticalSection(&eq_lock);");
                sb.AppendLine("        #else");
                sb.AppendLine("        pthread_mutex_lock(&eq_lock);");
                sb.AppendLine("        #endif");
                sb.AppendLine("        if (eq_tail) eq_tail->next = n; else eq_head = n;");
                sb.AppendLine("        eq_tail = n;");
                sb.AppendLine("        #ifdef _WIN32");
                sb.AppendLine("        LeaveCriticalSection(&eq_lock);");
                sb.AppendLine("        WakeConditionVariable(&eq_cv);");
                sb.AppendLine("        #else");
                sb.AppendLine("        pthread_mutex_unlock(&eq_lock);");
                sb.AppendLine("        pthread_cond_signal(&eq_cv);");
                sb.AppendLine("        #endif");
                sb.AppendLine("    }");
                sb.AppendLine();
                sb.AppendLine("    static char eq_buf[256];");
                sb.AppendLine("    static int eq_pop(void) {");
                sb.AppendLine("        #ifdef _WIN32");
                sb.AppendLine("        EnterCriticalSection(&eq_lock);");
                sb.AppendLine("        while (!eq_head) { SleepConditionVariableCS(&eq_cv, &eq_lock, INFINITE); }");
                sb.AppendLine("        #else");
                sb.AppendLine("        pthread_mutex_lock(&eq_lock);");
                sb.AppendLine("        while (!eq_head) { pthread_cond_wait(&eq_cv, &eq_lock); }");
                sb.AppendLine("        #endif");
                sb.AppendLine("        EventNode* n = eq_head;");
                sb.AppendLine("        strcpy(eq_buf, n->data);");
                sb.AppendLine("        eq_head = n->next; if (!eq_head) eq_tail = NULL;");
                sb.AppendLine("        #ifdef _WIN32");
                sb.AppendLine("        LeaveCriticalSection(&eq_lock);");
                sb.AppendLine("        #else");
                sb.AppendLine("        pthread_mutex_unlock(&eq_lock);");
                sb.AppendLine("        #endif");
                sb.AppendLine("        free(n);");
                sb.AppendLine("        return 1;");
                sb.AppendLine("    }");
                sb.AppendLine();
                sb.AppendLine("    #ifdef _WIN32");
                sb.AppendLine("    DWORD WINAPI stdin_thread(LPVOID) {");
                sb.AppendLine("    #else");
                sb.AppendLine("    void* stdin_thread(void*) {");
                sb.AppendLine("    #endif");
                sb.AppendLine("        char buf[256];");
                sb.AppendLine("        while (fgets(buf, sizeof(buf), stdin)) {");
                sb.AppendLine("            buf[strcspn(buf, \"\\n\")] = 0;");
                sb.AppendLine("            eq_push(buf);");
                sb.AppendLine("            if (strcmp(buf, \"exit\") == 0) break;");
                sb.AppendLine("        }");
                sb.AppendLine("        return 0;");
                sb.AppendLine("    }");
                if (hasTimer)
                {
                    sb.AppendLine();
                    sb.AppendLine("    #ifdef _WIN32");
                    sb.AppendLine("    DWORD WINAPI timer_thread(LPVOID) {");
                    sb.AppendLine("    #else");
                    sb.AppendLine("    void* timer_thread(void*) {");
                    sb.AppendLine("    #endif");
                    sb.AppendLine("        while (1) {");
                    sb.AppendLine("        #ifdef _WIN32");
                    sb.AppendLine("            Sleep(1000);");
                    sb.AppendLine("        #else");
                    sb.AppendLine("            sleep(1);");
                    sb.AppendLine("        #endif");
                    sb.AppendLine("            eq_push(\"timer\");");
                    sb.AppendLine("        }");
                    sb.AppendLine("        return 0;");
                    sb.AppendLine("    }");
                }
                if (hasNetwork)
                {
                    sb.AppendLine();
                    sb.AppendLine("    #ifdef _WIN32");
                    sb.AppendLine("    DWORD WINAPI tcp_thread(LPVOID) {");
                    sb.AppendLine("    #else");
                    sb.AppendLine("    void* tcp_thread(void*) {");
                    sb.AppendLine("    #endif");
                    sb.AppendLine("        #ifdef _WIN32");
                    sb.AppendLine("        WSADATA wsa; WSAStartup(MAKEWORD(2,2), &wsa);");
                    sb.AppendLine("        SOCKET sock = socket(AF_INET, SOCK_STREAM, 0);");
                    sb.AppendLine("        sockaddr_in addr = {}; addr.sin_family = AF_INET; addr.sin_port = htons(8080); addr.sin_addr.s_addr = INADDR_ANY;");
                    sb.AppendLine("        bind(sock, (sockaddr*)&addr, sizeof(addr));");
                    sb.AppendLine("        listen(sock, 5);");
                    sb.AppendLine("        while (1) {");
                    sb.AppendLine("            SOCKET client = accept(sock, NULL, NULL);");
                    sb.AppendLine("            if (client == INVALID_SOCKET) break;");
                    sb.AppendLine("            eq_push(\"tcp_connect\");");
                    sb.AppendLine("            char buf[4096]; int n = recv(client, buf, sizeof(buf), 0);");
                    sb.AppendLine("            if (n > 0) eq_push(\"tcp_data\");");
                    sb.AppendLine("            closesocket(client);");
                    sb.AppendLine("            eq_push(\"tcp_disconnected\");");
                    sb.AppendLine("        }");
                    sb.AppendLine("        closesocket(sock); WSACleanup();");
                    sb.AppendLine("        #else");
                    sb.AppendLine("        int sock = socket(AF_INET, SOCK_STREAM, 0);");
                    sb.AppendLine("        sockaddr_in addr = {}; addr.sin_family = AF_INET; addr.sin_port = htons(8080); addr.sin_addr.s_addr = INADDR_ANY;");
                    sb.AppendLine("        bind(sock, (sockaddr*)&addr, sizeof(addr));");
                    sb.AppendLine("        listen(sock, 5);");
                    sb.AppendLine("        while (1) {");
                    sb.AppendLine("            int client = accept(sock, NULL, NULL);");
                    sb.AppendLine("            if (client < 0) break;");
                    sb.AppendLine("            eq_push(\"tcp_connect\");");
                    sb.AppendLine("            char buf[4096]; int n = read(client, buf, sizeof(buf));");
                    sb.AppendLine("            if (n > 0) eq_push(\"tcp_data\");");
                    sb.AppendLine("            close(client);");
                    sb.AppendLine("            eq_push(\"tcp_disconnected\");");
                    sb.AppendLine("        }");
                    sb.AppendLine("        close(sock);");
                    sb.AppendLine("        #endif");
                    sb.AppendLine("        return 0;");
                    sb.AppendLine("    }");
                }
                sb.AppendLine();
                sb.AppendLine("    // Init event queue");
                sb.AppendLine("    #ifdef _WIN32");
                sb.AppendLine("    InitializeCriticalSection(&eq_lock);");
                sb.AppendLine("    InitializeConditionVariable(&eq_cv);");
                sb.AppendLine("    #endif");
                sb.AppendLine();
                sb.AppendLine("    // Stdin reader thread");
                sb.AppendLine("    #ifdef _WIN32");
                sb.AppendLine("    HANDLE hStd = CreateThread(NULL, 0, stdin_thread, NULL, 0, NULL);");
                sb.AppendLine("    #else");
                sb.AppendLine("    pthread_t std_thread; pthread_create(&std_thread, NULL, stdin_thread, NULL); pthread_detach(std_thread);");
                sb.AppendLine("    #endif");
                if (hasTimer)
                {
                    sb.AppendLine();
                    sb.AppendLine("    // Timer thread");
                    sb.AppendLine("    #ifdef _WIN32");
                    sb.AppendLine("    HANDLE hTimer = CreateThread(NULL, 0, timer_thread, NULL, 0, NULL);");
                    sb.AppendLine("    #else");
                    sb.AppendLine("    pthread_t timer_thr; pthread_create(&timer_thr, NULL, timer_thread, NULL); pthread_detach(timer_thr);");
                    sb.AppendLine("    #endif");
                }
                if (hasNetwork)
                {
                    sb.AppendLine();
                    sb.AppendLine("    // TCP server thread");
                    sb.AppendLine("    #ifdef _WIN32");
                    sb.AppendLine("    HANDLE hTCP = CreateThread(NULL, 0, tcp_thread, NULL, 0, NULL);");
                    sb.AppendLine("    #else");
                    sb.AppendLine("    pthread_t tcp_thr; pthread_create(&tcp_thr, NULL, tcp_thread, NULL); pthread_detach(tcp_thr);");
                    sb.AppendLine("    #endif");
                }
                sb.AppendLine();
                sb.AppendLine("    // Event loop");
                sb.AppendLine("    State* current = &" + firstState + "_state;");
                sb.AppendLine("    while (1) {");
                sb.AppendLine("        eq_pop();");
                sb.AppendLine("        if (strcmp(eq_buf, \"exit\") == 0) break;");
                sb.AppendLine("        State* next = dispatch_event(current, eq_buf);");
                sb.AppendLine("        if (next != current) {");
                sb.AppendLine("            current = next;");
                sb.AppendLine("        }");
                sb.AppendLine("    }");
            }
            sb.AppendLine("}");
        }

        return sb.ToString();
    }

    private static string Lower(string s) =>
        s.Length > 0 ? char.ToLower(s[0]) + s[1..] : s;

    private static string[] SplitBodyCGen(string? body) =>
        body?.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries) ?? Array.Empty<string>();

    private static string TranslateBPlusToC(string line)
    {
        if (line.StartsWith("print(") && line.EndsWith(")"))
        {
            var inner = line.Substring(6, line.Length - 7);
            if (inner.StartsWith("\""))
            {
                var content = inner.Substring(1, inner.Length - 2);
                return $"printf(\"{content}\\n\")";
            }
            return $"printf(\"%d\\n\", {inner})";
        }
        return line;
    }

    private static string DefaultLiteral(string type) => type.ToLower() switch
    {
        "int" or "float" or "double" or "long" => "0",
        "bool" => "false",
        "string" => "\"\"",
        string t when t.StartsWith("bigfloat") => "0.0",
        _ => "0"
    };
}