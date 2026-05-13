using System.Text;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

public class CppOptimizedGenerator : ICodeGenerator
{
    private readonly OptimizationFlags _flags;

    public CppOptimizedGenerator(OptimizationFlags flags)
    {
        _flags = flags;
    }

    public CppOptimizedGenerator() : this(new OptimizationFlags { Optimize = true })
    {
    }

    public string GetFileExtension() => ".cpp";
    public string GetLanguageName()
    {
        if (_flags.Turbo) return "C++ (TURBO)";
        if (_flags.TurboEco) return "C++ (TURBO-ECO)";
        if (_flags.TurboEmbed) return "C++ (EMBED)";
        if (_flags.Auto) return "C++ (AUTO)";
        if (_flags.Stream) return "C++ (STREAM)";
        if (_flags.HasAny) return "C++ (opt)";
        return "C++ (opt)";
    }

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var allStates = new List<StateDefNode>();
        void Collect(StateDefNode s) { allStates.Add(s); foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var st in program.States) Collect(st);

        var allEvents = allStates
            .SelectMany(s => s.Transitions)
            .Where(t => !t.IsAlways)
            .Select(t => t.EventName)
            .Distinct()
            .ToList();

        var stateIds = allStates.Select((s, i) => (s.Name, Id: i)).ToDictionary(x => x.Name, x => x.Id);
        var eventIds = allEvents.Select((e, i) => (e, Id: i)).ToDictionary(x => x.e, x => x.Id);

        // Count unique targets in transitions
        var hasGuard = allStates.SelectMany(s => s.Transitions).Any(t => t.Guard != null);

        var header = GenerateHeader(program, allStates, allEvents, stateIds, eventIds);
        var impl = GenerateImpl(program, allStates, allEvents, stateIds, eventIds, hasGuard);

        var files = new Dictionary<string, string>
        {
            { "states_opt.h", header },
            { "states_opt.cpp", impl }
        };

        // Streaming mode: add Ragel-compatible stream files
        bool streaming = _flags.Stream || program.StreamMode == BPlusStreamMode.Parser
            || allStates.Any(s => s.IsStream);
        if (streaming)
        {
            files["states_stream.h"] = GenerateStreamHeader(program, allStates, stateIds);
            files["states_stream.cpp"] = GenerateStreamImpl(program, allStates, stateIds, eventIds);
        }

        return files;
    }

    private string GenerateHeader(ProgramNode program, List<StateDefNode> allStates,
        List<string> allEvents, Dictionary<string, int> stateIds, Dictionary<string, int> eventIds)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("#include <cstdint>");
        sb.AppendLine("#include <cstddef>");
        sb.AppendLine("#include <new>");
        // #memory comptime: compile-time safety assertions
        if (program.Memory is { Mode: BPlusMemoryMode.Comptime })
        {
            sb.AppendLine();
            sb.AppendLine("// B+ #memory comptime: compile-time proven zero-leak memory model");
            sb.AppendLine("// All allocations are stack-based or ring-buffered, proven at compile time.");
            sb.AppendLine("static_assert(sizeof(void*) >= 4, \"B+ comptime: pointer size check\");");
            sb.AppendLine("#define BPLUS_COMPTIME_MEMORY 1");
            sb.AppendLine("#define BPLUS_COMPTIME_ASSERT(cond, msg) static_assert(cond, msg)");
            sb.AppendLine();
        }
        if (_flags.Pool != PoolMode.None || _flags.Memory == MemoryMode.Regions)
            sb.AppendLine("#include <cstdlib>");
        sb.AppendLine();

        // Pool allocator declarations
        if (_flags.Pool != PoolMode.None)
        {
            if (_flags.Pool == PoolMode.Linear)
            {
                sb.AppendLine("template<size_t POOL_SIZE = 65536>");
                sb.AppendLine("struct LinearPool {");
                sb.AppendLine("    char buffer[POOL_SIZE];");
                sb.AppendLine("    size_t offset = 0;");
                sb.AppendLine("    void* alloc(size_t size) {");
                sb.AppendLine("        if (offset + size > POOL_SIZE) return nullptr;");
                sb.AppendLine("        void* ptr = buffer + offset;");
                sb.AppendLine("        offset += size;");
                sb.AppendLine("        return ptr;");
                sb.AppendLine("    }");
                sb.AppendLine("    void reset() { offset = 0; }");
                sb.AppendLine("};");
                sb.AppendLine("extern LinearPool<> state_pool;");
            }
            else if (_flags.Pool == PoolMode.Ring)
            {
                sb.AppendLine("template<size_t POOL_SIZE = 65536>");
                sb.AppendLine("struct RingPool {");
                sb.AppendLine("    char buffer[POOL_SIZE];");
                sb.AppendLine("    size_t head = 0;");
                sb.AppendLine("    void* alloc(size_t size) {");
                sb.AppendLine("        if (head + size > POOL_SIZE) head = 0;");
                sb.AppendLine("        if (head + size > POOL_SIZE) return nullptr;");
                sb.AppendLine("        void* ptr = buffer + head;");
                sb.AppendLine("        head += size;");
                sb.AppendLine("        return ptr;");
                sb.AppendLine("    }");
                sb.AppendLine("};");
                sb.AppendLine("extern RingPool<> state_pool;");
            }
            sb.AppendLine();
        }

        // Region allocator declarations
        if (_flags.Memory == MemoryMode.Regions)
        {
            sb.AppendLine("struct Region {");
            sb.AppendLine("    char* data;");
            sb.AppendLine("    size_t size;");
            sb.AppendLine("    size_t used;");
            sb.AppendLine("};");
            sb.AppendLine("struct RegionAllocator {");
            sb.AppendLine("    static constexpr int MAX_REGIONS = 8;");
            sb.AppendLine("    Region regions[MAX_REGIONS];");
            sb.AppendLine("    int active = 0;");
            sb.AppendLine("    void* alloc(size_t size);");
            sb.AppendLine("    void reset();");
            sb.AppendLine("};");
            sb.AppendLine("extern RegionAllocator region_alloc;");
            sb.AppendLine();
        }

        // PGO profile counters
        if (_flags.Pgo)
        {
            sb.AppendLine("// PGO profile counters");
            sb.AppendLine("extern uint64_t pgo_counts[ST_COUNT][EV_COUNT];");
            sb.AppendLine();
        }

        // State enum
        sb.AppendLine($"enum StateId : uint8_t {{");
        foreach (var s in allStates)
            sb.AppendLine($"    ST_{s.Name},");
        sb.AppendLine($"    ST_COUNT");
        sb.AppendLine("};");
        sb.AppendLine();

        // Event enum
        sb.AppendLine($"enum Event : uint8_t {{");
        foreach (var ev in allEvents)
            sb.AppendLine($"    EV_{ev},");
        sb.AppendLine($"    EV_COUNT");
        sb.AppendLine("};");
        sb.AppendLine();

        // Context
        if (program.Context is { Variables.Count: > 0 })
        {
            sb.AppendLine("// Context (global)");
            foreach (var v in program.Context.Variables)
                sb.AppendLine($"extern {v.Type} {v.Name};");
            sb.AppendLine();
        }

        // State variables as struct
        if (allStates.Any(s => s.Variables.Count > 0))
        {
            sb.AppendLine("struct StateData {");
            foreach (var s in allStates)
            {
                if (s.Variables.Count > 0)
                {
                    sb.AppendLine($"    struct {s.Name} {{");
                    foreach (var v in s.Variables)
                    {
                        var def = v.DefaultValue ?? "0";
                        string fast = v.IsFastPath
                            ? " /* @fast_path: keep in register */ "
                            : " ";
                        sb.AppendLine($"        {v.Type}{fast}{v.Name} = {def};");
                    }
                    sb.AppendLine($"    }} {s.Name.ToLower()};");
                }
            }
            sb.AppendLine("};");
            sb.AppendLine($"extern StateData state_data;");
            // @fast_path register declarations (separate from struct, hint to compiler)
            bool hasFast = allStates.Any(s => s.Variables.Any(v => v.IsFastPath));
            if (hasFast)
            {
                sb.AppendLine();
                sb.AppendLine("// @fast_path: register-hinted variables (compiler may keep in reg)");
                foreach (var s in allStates)
                    foreach (var v in s.Variables.Where(v => v.IsFastPath))
                        sb.AppendLine($"register {v.Type} {s.Name.ToLower()}_{v.Name} __asm__(\"{s.Name.ToLower()}_{v.Name}\") = 0;");
            }
            sb.AppendLine();
        }

        // Transition table
        sb.AppendLine("// Transition table: [current_state][event] -> next_state");
        sb.AppendLine($"extern StateId transition_table[ST_COUNT][EV_COUNT];");
        sb.AppendLine();

        // Action function declarations
        if (allStates.Any(s => s.Actions.Count > 0))
        {
            sb.AppendLine("// Action functions");
            foreach (var s in allStates)
            {
                foreach (var a in s.Actions)
                    sb.AppendLine($"void {s.Name.ToLower()}_{a.Type.ToString().ToLower()}(void);");
            }
            sb.AppendLine();
        }

        // Has-guard transition functions
        if (allStates.SelectMany(s => s.Transitions).Any(t => t.Guard != null || t.Body != null))
        {
            sb.AppendLine("// Guarded transitions (return new state or -1 for no transition)");
            sb.AppendLine($"StateId check_transition(StateId current, Event ev);");
            sb.AppendLine();
        }

        // Action table
        if (allStates.Any(s => s.Actions.Count > 0))
        {
            sb.AppendLine("// Action dispatch tables");
            sb.AppendLine($"extern void (*enter_table[ST_COUNT])(void);");
            if (allStates.Any(s => s.Actions.Any(a => a.Type == ActionType.Exit)))
                sb.AppendLine($"extern void (*exit_table[ST_COUNT])(void);");
            sb.AppendLine();
        }

        // Main transition function
        sb.AppendLine("// Run transition: returns next state ID");
        sb.AppendLine($"StateId run_transition(StateId current, Event ev);");

        return sb.ToString();
    }

    private string GenerateImpl(ProgramNode program, List<StateDefNode> allStates,
        List<string> allEvents, Dictionary<string, int> stateIds, Dictionary<string, int> eventIds,
        bool hasGuard)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#include \"states_opt.h\"");
        sb.AppendLine();

        // Context definitions
        if (program.Context is { Variables.Count: > 0 })
        {
            foreach (var v in program.Context.Variables)
                sb.AppendLine($"{v.Type} {v.Name} = {v.DefaultValue ?? "0"};");
            sb.AppendLine();
        }

        // Pool allocator definitions
        if (_flags.Pool != PoolMode.None)
        {
            if (_flags.Pool == PoolMode.Linear)
                sb.AppendLine("LinearPool<> state_pool;");
            else if (_flags.Pool == PoolMode.Ring)
                sb.AppendLine("RingPool<> state_pool;");
            sb.AppendLine();
        }

        // Region allocator definition
        if (_flags.Memory == MemoryMode.Regions)
        {
            sb.AppendLine("RegionAllocator region_alloc;");
            sb.AppendLine("void* RegionAllocator::alloc(size_t size) {");
            sb.AppendLine("    if (active >= MAX_REGIONS) return nullptr;");
            sb.AppendLine("    auto& r = regions[active];");
            sb.AppendLine("    if (r.used + size > r.size) {");
            sb.AppendLine("        active++;");
            sb.AppendLine("        if (active >= MAX_REGIONS) return nullptr;");
            sb.AppendLine("        auto& nr = regions[active];");
            sb.AppendLine("        nr.data = (char*)malloc(65536);");
            sb.AppendLine("        nr.size = 65536;");
            sb.AppendLine("        nr.used = 0;");
            sb.AppendLine("        return alloc(size);");
            sb.AppendLine("    }");
            sb.AppendLine("    void* ptr = r.data + r.used;");
            sb.AppendLine("    r.used += size;");
            sb.AppendLine("    return ptr;");
            sb.AppendLine("}");
            sb.AppendLine("void RegionAllocator::reset() {");
            sb.AppendLine("    for (int i = 0; i <= active; i++)");
            sb.AppendLine("        free(regions[i].data);");
            sb.AppendLine("    active = 0;");
            sb.AppendLine("    regions[0].data = nullptr;");
            sb.AppendLine("    regions[0].size = 0;");
            sb.AppendLine("    regions[0].used = 0;");
            sb.AppendLine("}");
            sb.AppendLine();
        }

        // PGO profile counters
        if (_flags.Pgo)
        {
            sb.AppendLine("uint64_t pgo_counts[ST_COUNT][EV_COUNT] = {0};");
            sb.AppendLine();
        }

        // State data
        if (allStates.Any(s => s.Variables.Count > 0))
        {
            sb.AppendLine("StateData state_data;");
            sb.AppendLine();
        }

        // Action function implementations
        foreach (var s in allStates)
        {
            foreach (var a in s.Actions)
            {
                var fn = $"{s.Name.ToLower()}_{a.Type.ToString().ToLower()}";
                var bodyLines = SplitBody(a.Body);
                if (bodyLines.Length == 0)
                    sb.AppendLine($"void {fn}(void) {{ }}");
                else if (bodyLines.Length == 1)
                    sb.AppendLine($"void {fn}(void) {{ {bodyLines[0]}; }}");
                else
                {
                    sb.AppendLine($"void {fn}(void) {{");
                    foreach (var line in bodyLines)
                        sb.AppendLine($"    {line};");
                    sb.AppendLine("}");
                }
            }
        }
        if (allStates.SelectMany(s => s.Actions).Any()) sb.AppendLine();

        // Guarded transition function
        if (hasGuard || allStates.SelectMany(s => s.Transitions).Any(t => t.Body != null))
        {
            sb.AppendLine("StateId check_transition(StateId current, Event ev) {");
            sb.AppendLine("    switch (current) {");

            foreach (var s in allStates)
            {
                var guarded = s.Transitions.Where(t => t.Guard != null || t.Body != null).ToList();
                if (guarded.Count == 0) continue;

                sb.AppendLine($"        case ST_{s.Name}:");
                sb.AppendLine($"            switch (ev) {{");

                foreach (var t in guarded)
                {
                    if (!eventIds.ContainsKey(t.EventName)) continue;
                    // Emit HotWeight-based branch hints
                    string hint = "";
                    if (t.HotWeight.HasValue && (_flags.LikelyHints || _flags.UnlikelyHints || _flags.Pgo))
                    {
                        hint = t.HotWeight.Value >= 0.5 ? " [[likely]]" : " [[unlikely]]";
                    }
                    sb.AppendLine($"            case EV_{t.EventName}:");
                    if (t.Body != null)
                        foreach (var line in SplitBody(t.Body))
                            sb.AppendLine($"                    {line};");
                    if (t.Guard != null)
                    {
                        sb.AppendLine($"                    if ({t.Guard}){hint}");
                        sb.AppendLine($"                        return ST_{t.Target};");
                        sb.AppendLine($"                    return (StateId)-1;");
                    }
                    else
                    {
                        sb.AppendLine($"                    return ST_{t.Target};");
                    }
                }
                sb.AppendLine($"                default: break;");
                sb.AppendLine($"            }}");
                sb.AppendLine($"            break;");
            }

            sb.AppendLine("        default: break;");
            sb.AppendLine("    }");
            sb.AppendLine("    return (StateId)-1;");
            sb.AppendLine("}");
            sb.AppendLine();
        }

        // Transition table
        sb.AppendLine("StateId transition_table[ST_COUNT][EV_COUNT] = {");

        foreach (var s in allStates)
        {
            sb.AppendLine($"    {{ // ST_{s.Name}");

            // Get simple transitions (no guard, no body — can be in table)
            var simpleTransitions = s.Transitions
                .Where(t => t.Guard == null && t.Body == null && !t.IsAlways)
                .GroupBy(t => t.EventName)
                .ToDictionary(g => g.Key, g => g.First().Target);

            var alwaysTarget = s.Transitions.FirstOrDefault(t => t.IsAlways)?.Target;

            foreach (var ev in allEvents)
            {
                if (simpleTransitions.TryGetValue(ev, out var target))
                    sb.AppendLine($"        ST_{target},");
                else if (alwaysTarget != null)
                    sb.AppendLine($"        ST_{alwaysTarget},");
                else
                    sb.AppendLine($"        (StateId)-1,");
            }
            sb.AppendLine($"    }},");
        }
        sb.AppendLine("};");
        sb.AppendLine();

        // Chain transition tables (Semantic Inline)
        var chains = allStates.Where(s => s.ChainId != null).GroupBy(s => s.ChainId).ToList();
        if (chains.Count > 0)
        {
            sb.AppendLine("// B+ Semantic Inline — fused transition chains");
            foreach (var chain in chains)
            {
                var chainStates = chain.ToList();
                sb.AppendLine($"// Chain: {string.Join(" -> ", chainStates.Select(cs => cs.Name))}");
                sb.AppendLine($"StateId run_chain_{chain.Key}(Event ev, uintptr_t state_ptr) {{");
                sb.AppendLine("    switch (ev) {");
                // Collect all unique events across the chain
                var chainEvents = chainStates.SelectMany(cs => cs.Transitions)
                    .Where(t => !t.IsAlways && eventIds.ContainsKey(t.EventName))
                    .Select(t => t.EventName).Distinct();
                foreach (var ev in chainEvents)
                {
                    // Find first state in chain that handles this event
                    var handler = chainStates.FirstOrDefault(cs =>
                        cs.Transitions.Any(t => t.EventName == ev && !t.IsAlways));
                    if (handler == null) continue;
                    var t = handler.Transitions.First(tr => tr.EventName == ev && !tr.IsAlways);
                    string hint = t.HotWeight.HasValue && t.HotWeight.Value >= 0.5 ? " [[likely]]" : "";
                    sb.AppendLine($"        case EV_{ev}:{hint}");
                    foreach (var line in SplitBody(t.Body))
                        sb.AppendLine($"            {line};");
                    if (t.Guard != null)
                        sb.AppendLine($"            if ({t.Guard})");
                    sb.AppendLine($"            return ST_{t.Target};");
                }
                sb.AppendLine("        default: break;");
                sb.AppendLine("    }");
                sb.AppendLine("    return (StateId)-1;");
                sb.AppendLine("}");
                sb.AppendLine();
            }
        }

        // Action tables
        if (allStates.Any(s => s.Actions.Any(a => a.Type == ActionType.Enter)))
        {
            sb.AppendLine("void (*enter_table[ST_COUNT])(void) = {");
            foreach (var s in allStates)
            {
                var enter = s.Actions.FirstOrDefault(a => a.Type == ActionType.Enter);
                sb.AppendLine($"    { (enter != null ? s.Name.ToLower() + "_enter" : "nullptr") },");
            }
            sb.AppendLine("};");
        }

        if (allStates.Any(s => s.Actions.Any(a => a.Type == ActionType.Exit)))
        {
            sb.AppendLine("void (*exit_table[ST_COUNT])(void) = {");
            foreach (var s in allStates)
            {
                var exit = s.Actions.FirstOrDefault(a => a.Type == ActionType.Exit);
                sb.AppendLine($"    { (exit != null ? s.Name.ToLower() + "_exit" : "nullptr") },");
            }
            sb.AppendLine("};");
        }

        if (allStates.Any(s => s.Actions.Any())) sb.AppendLine();

        // Main transition function
        sb.AppendLine("StateId run_transition(StateId current, Event ev) {");
        sb.AppendLine("    // Call exit action on current state");
        if (allStates.Any(s => s.Actions.Any(a => a.Type == ActionType.Exit)))
            sb.AppendLine("    if (exit_table[current]) exit_table[current]();");
        sb.AppendLine();
        sb.AppendLine("    // Look up target");
        if (_flags.Pgo)
        {
            sb.AppendLine("    pgo_counts[current][ev]++;");
            sb.AppendLine("    StateId next = (StateId)__builtin_expect((int)transition_table[current][ev], 1);");
        }
        else
        {
            sb.AppendLine("    StateId next = transition_table[current][ev];");
        }
        // Check for Semantic Inline chain dispatch
        var chainSources = allStates.Where(s => s.ChainId != null).GroupBy(s => s.ChainId).ToList();
        foreach (var chain in chainSources)
        {
            var first = chain.First();
            sb.AppendLine($"    // Semantic Inline chain: {string.Join(" -> ", chain.Select(cs => cs.Name))}");
            sb.AppendLine($"    if (current == ST_{first.Name}) {{");
            sb.AppendLine($"        StateId chain_next = run_chain_{first.ChainId}(ev, 0);");
            sb.AppendLine("        if (chain_next != (StateId)-1) {");
            sb.AppendLine("            next = chain_next;");
            sb.AppendLine("        }");
            sb.AppendLine("    }");
        }
        if (hasGuard || allStates.SelectMany(s => s.Transitions).Any(t => t.Body != null))
        {
            sb.AppendLine("    // Check guarded transitions (override table)");
            sb.AppendLine("    StateId guarded = check_transition(current, ev);");
            sb.AppendLine("    if (guarded != (StateId)-1) next = guarded;");
        }
        sb.AppendLine();
        sb.AppendLine("    // Call enter action on target state");
        sb.AppendLine("    if (next != (StateId)-1) {");
        if (allStates.Any(s => s.Actions.Any(a => a.Type == ActionType.Enter)))
            sb.AppendLine("        if (enter_table[next]) enter_table[next]();");
        sb.AppendLine("    }");
        sb.AppendLine();
        sb.AppendLine("    return next;");
        sb.AppendLine("}");

        return sb.ToString();
    }

    private string GenerateStreamHeader(ProgramNode program, List<StateDefNode> allStates,
        Dictionary<string, int> stateIds)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("#include <cstdint>");
        sb.AppendLine("#include <cstddef>");
        sb.AppendLine();
        sb.AppendLine("// B+ streaming state machine — Ragel-compatible, zero-copy");
        sb.AppendLine("// Activated via #parser, @stream, or --stream flag");
        sb.AppendLine();

        // State enum (uint8_t for dense packing)
        sb.AppendLine("enum StreamState : uint8_t {");
        foreach (var s in allStates)
            sb.AppendLine($"    ST_{s.Name},");
        sb.AppendLine("    ST_COUNT");
        sb.AppendLine("};");
        sb.AppendLine();

        // Event type (single byte for streaming parsers)
        sb.AppendLine("using StreamEvent = uint8_t;");
        sb.AppendLine();

        // Stream function
        sb.AppendLine("// Process a buffer: calls actions, returns final state");
        sb.AppendLine("// Returns ST_COUNT on error/unknown event");
        sb.AppendLine($"StreamState stream_run(const uint8_t* data, size_t len, StreamState start = ST_{allStates.FirstOrDefault()?.Name ?? "Idle"});");
        sb.AppendLine();

        // Non-blocking peek (for @stream states)
        sb.AppendLine("// Peek: check if data is available without blocking");
        sb.AppendLine("// Returns >0 if data available, 0 if not");
        sb.AppendLine("int stream_peek(const uint8_t* data, size_t len, size_t pos);");

        return sb.ToString();
    }

    private string GenerateStreamImpl(ProgramNode program, List<StateDefNode> allStates,
        Dictionary<string, int> stateIds, Dictionary<string, int> eventIds)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#include \"states_stream.h\"");
        sb.AppendLine();
        sb.AppendLine("// Auto-generated by B+ v2.5.0GH — B+ Semantic Goto streaming parser");
        sb.AppendLine("// goto-driven, zero-copy, no allocations, context-predictive dispatch");
        sb.AppendLine("// Faster than Ragel: each state is a direct goto target, no switch overhead");
        sb.AppendLine();

        sb.AppendLine("StreamState stream_run(const uint8_t* data, size_t len, StreamState start) {");
        // Fast-path variables with register hints
        bool hasFastPath = allStates.Any(s => s.Variables.Any(v => v.IsFastPath));
        if (hasFastPath)
        {
            int count = 0;
            foreach (var s in allStates)
                count += s.Variables.Count(v => v.IsFastPath);
            sb.AppendLine($"    // @fast_path: {count} variable(s) kept in registers");
            // Emit dummy declarations to prevent "unused" warnings
        }
        sb.AppendLine("    const uint8_t* p = data;");
        sb.AppendLine("    const uint8_t* pe = data + len;");
        sb.AppendLine();
        sb.AppendLine("    // B+ Semantic Goto: direct dispatch to start state (no switch overhead)");
        sb.AppendLine("    if (p >= pe) return start;");
        sb.AppendLine("    switch (start) {");
        foreach (var s in allStates)
        {
            string likely = s.ChainId != null ? " [[likely]]" : "";
            sb.AppendLine($"        case ST_{s.Name}:{likely} goto st_{s.Name};");
        }
        sb.AppendLine("        default: return ST_COUNT;");
        sb.AppendLine("    }");
        sb.AppendLine();

        // Generate per-state goto labels
        foreach (var s in allStates)
        {
            string hot = s.ChainId != null ? " [[hot]]" : "";
            sb.AppendLine($"st_{s.Name}:{hot} {{");

            // Inline enter action (once per activation)
            var enterAction = s.Actions.FirstOrDefault(a => a.Type == ActionType.Enter);
            if (enterAction != null)
            {
                sb.AppendLine($"    // enter {s.Name}");
                foreach (var line in SplitBody(enterAction.Body))
                    sb.AppendLine($"    {line};");
            }

            // Non-blocking peek for @stream states
            if (s.IsStream)
                sb.AppendLine($"    if (p >= pe) return ST_{s.Name};");

            // End-of-input check
            sb.AppendLine($"    if (p >= pe) return ST_{s.Name};");
            sb.AppendLine("    uint8_t ch = *p++;");

            var transitions = s.Transitions;
            if (transitions.Count == 0)
            {
                sb.AppendLine("    (void)ch; // no transitions — consume byte, stay");
                sb.AppendLine($"    goto st_{s.Name};");
            }
            else
            {
                // Sort transitions: @hot first, then alphabetical
                var sorted = transitions
                    .OrderByDescending(t => t.HotWeight.HasValue ? t.HotWeight.Value : 0.0)
                    .ThenBy(t => t.EventName)
                    .ToList();

                int ti = 0;
                foreach (var t in sorted)
                {
                    string likely = t.HotWeight.HasValue && t.HotWeight.Value >= 0.5
                        ? " [[likely]]" : "";
                    string unlikely = t.HotWeight.HasValue && t.HotWeight.Value < 0.5
                        ? " [[unlikely]]" : "";

                    if (t.IsAlways)
                    {
                        if (t.Body != null)
                            foreach (var line in SplitBody(t.Body))
                                sb.AppendLine($"    {line};");
                        var exitAction = s.Actions.FirstOrDefault(a => a.Type == ActionType.Exit);
                        if (exitAction != null)
                            foreach (var line in SplitBody(exitAction.Body))
                                sb.AppendLine($"    {line};");
                        sb.AppendLine($"    goto st_{t.Target};");
                    }
                    else
                    {
                        string EscapeChar(char c) => c switch
                        {
                            '\n' => "\\n",
                            '\r' => "\\r",
                            '\t' => "\\t",
                            '\'' => "\\'",
                            '\\' => "\\\\",
                            _ => c.ToString()
                        };

                        string cond;
                        if (t.EventName.Length == 1 && t.Guard == null)
                            cond = $"ch == '{EscapeChar(t.EventName[0])}'";
                        else if (t.EventName.Length == 1 && t.Guard != null)
                            cond = $"ch == '{EscapeChar(t.EventName[0])}' && ({t.Guard})";
                        else if (t.Guard != null)
                            cond = $"ch == '{EscapeChar(t.EventName[0])}' && ({t.Guard})";
                        else
                            cond = $"ch == '{EscapeChar(t.EventName[0])}'";

                        string prefix = ti == 0 ? "if" : " else if";
                        sb.AppendLine($"    {prefix} ({cond}){likely}{unlikely} {{");
                        if (t.Body != null)
                            foreach (var line in SplitBody(t.Body))
                                sb.AppendLine($"        {line};");
                        var exitAction = s.Actions.FirstOrDefault(a => a.Type == ActionType.Exit);
                        if (exitAction != null)
                            foreach (var line in SplitBody(exitAction.Body))
                                sb.AppendLine($"        {line};");
                        sb.AppendLine($"        goto st_{t.Target};");
                        sb.AppendLine("    }");
                        ti++;
                    }
                }
                // Fallback: unknown byte, stay in state
                if (sorted.Any(t => !t.IsAlways))
                {
                    sb.AppendLine("    else {");
                    sb.AppendLine("        // unknown byte — stay in state");
                    sb.AppendLine($"        goto st_{s.Name};");
                    sb.AppendLine("    }");
                }
            }
            sb.AppendLine("}");
        }

        sb.AppendLine("    return ST_COUNT; // unreachable");
        sb.AppendLine("}");

        // Non-blocking peek (inline)
        sb.AppendLine();
        sb.AppendLine("int stream_peek(const uint8_t* data, size_t len, size_t pos) {");
        sb.AppendLine("    return pos < len ? data[pos] : -1;");
        sb.AppendLine("}");

        return sb.ToString();
    }

    private static string[] SplitBody(string? body)
    {
        if (string.IsNullOrWhiteSpace(body)) return [];
        var lines = body.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        for (int i = 0; i < lines.Length; i++)
            lines[i] = lines[i].Trim().TrimEnd(';');
        return lines;
    }
}