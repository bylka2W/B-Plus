using BPlus.Core.Ast;

namespace BPlus.Core;

public enum ErrorSeverity
{
    Error,      // E � �������, ���������
    Warning,    // ? � �����, ����� ���� ���������
    Hint        // ?? � �����, ����� �� ���������
}

public enum ErrorCategory
{
    Type,       // E � ���
    Bounds,     // E � �������
    DataRace,   // ? ����� ������
    Memory,     // ? ������
    Thermal,    // ? �����������
    Speed,      // ?? ��������
    Contract    // E � ��������
}

public class BPlusError
{
    public ErrorCategory Category { get; init; }
    public ErrorSeverity Severity { get; init; }
    public string File { get; init; } = "";
    public int Line { get; init; }
    public int Column { get; init; }
    public string Message { get; init; } = "";
    public string? YouWrote { get; init; }
    public string? Expected { get; init; }
    public string? Why { get; init; }
    public List<string> Fixes { get; init; } = new();

    public string CategoryLabel => Category switch
    {
        ErrorCategory.Type => "���",
        ErrorCategory.Bounds => "�������",
        ErrorCategory.DataRace => "����� ������",
        ErrorCategory.Memory => "������",
        ErrorCategory.Thermal => "�����������",
        ErrorCategory.Speed => "��������",
        ErrorCategory.Contract => "��������",
        _ => ""
    };

    public string SeverityLabel => Severity switch
    {
        ErrorSeverity.Error => "E",
        ErrorSeverity.Warning => "\u26a0",
        ErrorSeverity.Hint => "\ud83d\udca1",
        _ => "?"
    };

    public string Render()
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine($"{SeverityLabel} � {CategoryLabel}");
        sb.AppendLine($"\u26d4 ������ {Line}, ������� {Column}");
        if (Severity == ErrorSeverity.Error)
            sb.AppendLine($"\u274c {Message}");
        else if (Severity == ErrorSeverity.Warning)
            sb.AppendLine($"\u26a0\ufe0f {Message}");
        else
            sb.AppendLine($"\ud83d\udca1 {Message}");
        sb.AppendLine();
        if (YouWrote != null)
        {
            sb.AppendLine($"  \u0442\u044b \u043d\u0430\u043f\u0438\u0441\u0430\u043b:  {YouWrote}");
            if (Expected != null)
                sb.AppendLine($"  \u043d\u0443\u0436\u043d\u043e \u0431\u044b\u043b\u043e:  {Expected}");
        }
        if (Why != null)
        {
            sb.AppendLine();
            sb.AppendLine($"\u041f\u043e\u0447\u0435\u043c\u0443 \u0432\u0430\u0436\u043d\u043e:");
            foreach (var line in Why.Split('\n'))
                sb.AppendLine($"  {line.Trim()}");
        }
        if (Fixes.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("\u041a\u0430\u043a \u0438\u0441\u043f\u0440\u0430\u0432\u0438\u0442\u044c:");
            for (int i = 0; i < Fixes.Count; i++)
                sb.AppendLine($"  [{i + 1}] {Fixes[i]}");
        }
        sb.AppendLine();
        return sb.ToString();
    }
}

public class BPlusErrorReporter
{
    private readonly ProgramNode _program;
    private readonly OptimizationFlags? _flags;
    private readonly string _file;
    private readonly List<BPlusError> _errors = new();
    private readonly HashSet<string> _definedStates = new();
    private readonly HashSet<string> _definedEnums = new();
    private readonly Dictionary<string, StateDefNode> _stateMap = new();
    private readonly Dictionary<string, List<string>> _stateVars = new();

    public IReadOnlyList<BPlusError> Errors => _errors;
    public bool HasErrors => _errors.Any(e => e.Severity == ErrorSeverity.Error);

    public BPlusErrorReporter(ProgramNode program, string file, OptimizationFlags? flags = null)
    {
        _program = program;
        _file = file;
        _flags = flags;
        BuildIndex();
    }

    private void BuildIndex()
    {
        void Collect(StateDefNode s)
        {
            _definedStates.Add(s.Name);
            _stateMap[s.Name] = s;
            _stateVars[s.Name] = s.Variables.Select(v => v.Name).ToList();
            foreach (var ns in s.NestedStates) Collect(ns);
        }
        foreach (var s in _program.States) Collect(s);
        foreach (var pb in _program.ParallelBlocks)
            foreach (var s in pb.States) Collect(s);
        foreach (var en in _program.Enums)
            _definedEnums.Add(en.Name);
    }

    // =========================================================
    // 1. E � ��� � type mismatches
    // =========================================================
    public void CheckTypes()
    {
        foreach (var s in _program.States)
            CheckStateTypes(s, 0, _program.States.IndexOf(s));
        foreach (var pb in _program.ParallelBlocks)
            foreach (var s in pb.States)
                CheckStateTypes(s, 0, 0);
    }

    private void CheckStateTypes(StateDefNode state, int depth, int index)
    {
        // Check that base class exists if specified
        if (state.BaseClass != null && state.BaseClass != "State" && !_definedStates.Contains(state.BaseClass))
        {
            _errors.Add(new BPlusError
            {
                Category = ErrorCategory.Type,
                Severity = ErrorSeverity.Error,
                File = _file,
                Line = index + 1,
                Column = 1,
                Message = $"������� ����� '{state.BaseClass}' �� ����������",
                YouWrote = $"state {state.Name} : {state.BaseClass}",
                Expected = state.BaseClass,
                Why = "���� �������� ������ ��� � ������������ �� ��������������",
                Fixes = { $"����� ': {state.BaseClass}'", $"������ state {state.BaseClass}" }
            });
        }

        // Check variable types
        foreach (var v in state.Variables)
        {
            if (!IsValidType(v.Type))
            {
                _errors.Add(new BPlusError
                {
                    Category = ErrorCategory.Type,
                    Severity = ErrorSeverity.Error,
                    File = _file,
                    Line = index + 1,
                    Column = 1,
                    Message = $"����������� ��� '{v.Type}'",
                    YouWrote = $"{v.Name}: {v.Type}",
                    Expected = "int | float | bool | string | double | long | enum",
                    Why = $"��� '{v.Type}' �� �������������� ����������� ����",
                    Fixes = { $"������ {v.Type} �� int/float/bool/string", $"������ ��� {v.Type} � codegen" }
                });
            }
        }

        foreach (var t in state.Transitions)
        {
            foreach (var p in t.Parameters)
            {
                if (!IsValidType(p.Type))
                {
                    _errors.Add(new BPlusError
                    {
                        Category = ErrorCategory.Type,
                        Severity = ErrorSeverity.Error,
                        File = _file,
                        Line = index + 1,
                        Column = 1,
                        Message = $"����������� ��� ��������� '{p.Type}'",
                        YouWrote = $"{p.Name}: {p.Type}",
                        Expected = "int | float | bool | string",
                        Why = "��������� � ���������������� ����� ������� ���������",
                        Fixes = { $"������ {p.Type} �� �������������� ���" }
                    });
                }
            }

            // Check target state exists
            if (!string.IsNullOrEmpty(t.Target) && !_definedStates.Contains(t.Target))
            {
                _errors.Add(new BPlusError
                {
                    Category = ErrorCategory.Type,
                    Severity = ErrorSeverity.Error,
                    File = _file,
                    Line = index + 1,
                    Column = 1,
                    Message = $"������� ��������� '{t.Target}' �� ���������",
                    YouWrote = $"-> {t.Target}",
                    Expected = "���� �� ����������� ���������: " + string.Join(", ", _definedStates.Take(5)),
                    Why = "������� � �������������� ��������� � ������ ����������",
                    Fixes = { $"������ state {t.Target}", $"������ ������� �� ������������ ���������" }
                });
            }
        }

        foreach (var timer in state.Timers)
        {
            if (!string.IsNullOrEmpty(timer.Target) && !_definedStates.Contains(timer.Target))
            {
                _errors.Add(new BPlusError
                {
                    Category = ErrorCategory.Type,
                    Severity = ErrorSeverity.Error,
                    File = _file,
                    Line = index + 1,
                    Column = 1,
                    Message = $"������ ���� � �������������� ��������� '{timer.Target}'",
                    YouWrote = $"after {timer.Duration} -> {timer.Target}",
                    Why = "������ �� ������ ��������� �������",
                    Fixes = { $"������ state {timer.Target}", $"������ ������ �������" }
                });
            }
        }

        foreach (var ns in state.NestedStates)
            CheckStateTypes(ns, depth + 1, index);
    }

    // =========================================================
    // 2. E � ������� � out of bounds
    // =========================================================
    public void CheckBounds()
    {
        foreach (var s in _program.States)
            CheckStateBounds(s, _program.States.IndexOf(s));
        foreach (var pb in _program.ParallelBlocks)
            foreach (var s in pb.States)
                CheckStateBounds(s, 0);
    }

    private void CheckStateBounds(StateDefNode state, int index)
    {
        // Check for timer overflow patterns
        foreach (var timer in state.Timers)
        {
            if (int.TryParse(timer.Duration.TrimEnd('s', 'm', 'h', 'd'), out var dur))
            {
                if (dur <= 0)
                {
                    _errors.Add(new BPlusError
                    {
                        Category = ErrorCategory.Bounds,
                        Severity = ErrorSeverity.Error,
                        File = _file,
                        Line = index + 1,
                        Column = 1,
                        Message = $"������ � ������������� {dur} � ��� ���� ��� ������������� �����",
                        YouWrote = $"after {timer.Duration} -> {timer.Target}",
                        Expected = "after 1s (��� ������)",
                        Why = "������ ��������� ��������� � ��������, ����������� ����",
                        Fixes = { $"������� ������������ �������", $"����� ������ ���� �� �����" }
                    });
                }
                if (dur > 86_400)
                {
                    _errors.Add(new BPlusError
                    {
                        Category = ErrorCategory.Bounds,
                        Severity = ErrorSeverity.Warning,
                        File = _file,
                        Line = index + 1,
                        Column = 1,
                        Message = $"������ {timer.Duration} � ������ �����. ������?",
                        Why = "����� ������� ������� ����� ���� �������",
                        Fixes = { $"������� ������� ��������� (s/m/h/d)", $"������� ������������" }
                    });
                }
            }
        }

        // Check for self-referencing transitions that might cause infinite loops
        var selfLoopCount = state.Transitions.Count(t => t.Target == state.Name && t.Guard == null);
        if (selfLoopCount > 1)
        {
            _errors.Add(new BPlusError
            {
                Category = ErrorCategory.Bounds,
                Severity = ErrorSeverity.Warning,
                File = _file,
                Line = index + 1,
                Column = 1,
                Message = $"��������� '{state.Name}' ����� {selfLoopCount} ����������� ��������� � ���� � �������� ����������� ����",
                YouWrote = $"on ... -> {state.Name} (��� guard)",
                Why = "��� ��������� ������ �� ���� ������� ������� ����������",
                Fixes = { $"������ guard: [condition] -> {state.Name}", $"������ ���� �� ���� ������� � ������ ���������" }
            });
        }
    }

    // =========================================================
    // 3. ? ����� ������ � parallel block shared state
    // =========================================================
    public void CheckDataRace()
    {
        if (_program.ParallelBlocks.Count == 0) return;

        // Collect all variables written in each parallel state
        var writesByState = new Dictionary<string, HashSet<string>>();
        var readsByState = new Dictionary<string, HashSet<string>>();

        foreach (var pb in _program.ParallelBlocks)
        {
            foreach (var s in pb.States)
            {
                var writes = new HashSet<string>();
                var reads = new HashSet<string>();

                // Variables declared in the state are writes
                foreach (var v in s.Variables)
                    writes.Add($"{s.Name}.{v.Name}");

                // Context variables referenced in actions/transitions
                foreach (var a in s.Actions)
                {
                    if (_program.Context != null)
                    {
                        foreach (var cv in _program.Context.Variables)
                        {
                            if (a.Body.Contains(cv.Name))
                                reads.Add($"ctx.{cv.Name}");
                        }
                    }
                }
                foreach (var t in s.Transitions)
                {
                    if (_program.Context != null)
                    {
                        foreach (var cv in _program.Context.Variables)
                        {
                            if ((t.Body ?? "").Contains(cv.Name))
                                reads.Add($"ctx.{cv.Name}");
                        }
                    }
                }

                writesByState[s.Name] = writes;
                readsByState[s.Name] = reads;
            }
        }

        // Check for read-write conflicts between parallel states
        var stateList = _program.ParallelBlocks.SelectMany(pb => pb.States).ToList();
        for (int i = 0; i < stateList.Count; i++)
        {
            for (int j = i + 1; j < stateList.Count; j++)
            {
                var aWrites = writesByState.GetValueOrDefault(stateList[i].Name) ?? new();
                var bWrites = writesByState.GetValueOrDefault(stateList[j].Name) ?? new();
                var bReads = readsByState.GetValueOrDefault(stateList[j].Name) ?? new();

                // If A writes and B reads the same context variable
                foreach (var w in aWrites)
                {
                    if (bReads.Contains(w) || bWrites.Contains(w))
                    {
                        _errors.Add(new BPlusError
                        {
                            Category = ErrorCategory.DataRace,
                            Severity = ErrorSeverity.Warning,
                            File = _file,
                            Line = i + 1,
                            Column = 1,
                            Message = $"����� ������: '{stateList[i].Name}' ����� '{w}', � '{stateList[j].Name}' ������/����� �� �� �����",
                            Why = "���� ������ �������� �� ���� ��� ������ ����� �������� � ����� ���������",
                            Fixes =
                            {
                                $"������ '{w}' � ��������� ����������",
                                $"������ @barrier ����� ������������� ��������",
                                $"��������� state_data.{w} ������ context"
                            }
                        });
                    }
                }
            }
        }
    }

    // =========================================================
    // 4. ? ������ � unnecessary allocations
    // =========================================================
    public void CheckMemory()
    {
        var hasOptimize = _flags is { Optimize: true } || _flags is { Turbo: true };

        foreach (var s in _program.States)
            CheckStateMemory(s, _program.States.IndexOf(s));

        void CheckStateMemory(StateDefNode state, int index)
        {
            // Count allocations in transitions (new State)
            var allocCount = state.Transitions.Count;
            if (allocCount > 3 && !hasOptimize && !(_flags is { Pool: not PoolMode.None } or { ZeroCopy: true } or { NoAlloc: true }))
            {
                _errors.Add(new BPlusError
                {
                    Category = ErrorCategory.Memory,
                    Severity = ErrorSeverity.Warning,
                    File = _file,
                    Line = index + 1,
                    Column = 1,
                    Message = $"��������� '{state.Name}' ������ {allocCount} ����� ���������. ������ ������� � new/malloc",
                    YouWrote = $"{allocCount} ��������� � {state.Name}",
                    Why = "��� state pool ������ new State() = malloc = 50-200 ������. ��� 60 fps ? {allocCount} ��������� = ������ ~0.3 ��/����",
                    Fixes = new List<string>
                    {
                        "������ --pool � state pool ������ malloc",
                        "������ --zero-copy � ��� ��������� ������",
                        hasOptimize ? "" : "������ --optimize � ������� ���������, ������ new"
                    }.Where(f => !string.IsNullOrEmpty(f)).ToList()
                });
            }

            foreach (var ns in state.NestedStates)
                CheckStateMemory(ns, index);
        }
    }

    // =========================================================
    // 5. ? ����������� � AVX-512 thermal warning
    // =========================================================
    public void CheckThermal()
    {
        if (_flags == null) return;

        var hasAvx512 = _flags.Vectorize == VectorizeMode.AVX512
                     || _flags.Vectorize == VectorizeMode.Auto;
        var hasTurbo = _flags.Turbo || _flags.TurboEco;
        var hasEco = _flags.Eco;

        if (hasAvx512 && !hasEco && !hasTurbo)
        {
            _errors.Add(new BPlusError
            {
                Category = ErrorCategory.Thermal,
                Severity = ErrorSeverity.Warning,
                File = _file,
                Line = 1,
                Column = 1,
                Message = "AVX-512 ����� ��������� CPU. ��� ���������� TDP �������� � 65W �� ~95W",
                YouWrote = "--vectorize (AVX-512 ����������)",
                Why = "����� ~30 ��� CPU ������� �������, fps �����, ������������ ������� �����",
                Fixes =
                {
                    "������ ��� ���� � ��� �������� ���������",
                    "������ --eco � ����������������� �����, ������ ������",
                    "������ --turbo-eco � AVX2 ������ AVX-512, ����"
                }
            });
        }

        if (hasAvx512 && hasEco && _flags.EcoMode != EcoMode.AVX2 && _flags.EcoMode != EcoMode.SSE && _flags.EcoMode != EcoMode.Scalar)
        {
            _errors.Add(new BPlusError
            {
                Category = ErrorCategory.Thermal,
                Severity = ErrorSeverity.Hint,
                File = _file,
                Line = 1,
                Column = 1,
                Message = "AVX-512 + --eco=sse ���� ����. �������� �������",
                Why = "AVX-512 ��������� ������� CPU, --eco=sse �������. �� ������ ��� �����������",
                Fixes =
                {
                    "��������� --eco=sse � ������ SSE, ����� ���",
                    "��������� --eco=scalar � ������ ��� SIMD"
                }
            });
        }
    }

    // =========================================================
    // 6. ?? �������� � performance suggestions
    // =========================================================
    public void CheckSpeed()
    {
        if (_flags == null) return;

        var hasOptimize = _flags.Optimize || _flags.Turbo || _flags.TurboEco;

        foreach (var s in _program.States)
            CheckStateSpeed(s, _program.States.IndexOf(s));

        // Suggest --optimize if not using it
        if (!hasOptimize && _program.States.Sum(s => CountTransitions(s)) > 5)
        {
            _errors.Add(new BPlusError
            {
                Category = ErrorCategory.Speed,
                Severity = ErrorSeverity.Hint,
                File = _file,
                Line = 1,
                Column = 1,
                Message = $"����� ����� ������� ������� � {_program.States.Sum(s => CountTransitions(s))} ���������, � --optimize �� �������",
                Why = "��� --optimize ������ ������� = virtual call. � --optimize: ������� ��������� = ������ ������. �������: 10-15% ��������",
                Fixes =
                {
                    "������ --optimize � ������� ���������, +10-15%",
                    "������ --turbo � ��� ����������� �����, +150%"
                }
            });
        }
    }

    private void CheckStateSpeed(StateDefNode state, int index)
    {
        // Suggest inline for small states
        if (state.Variables.Count == 0 && state.Actions.Count == 0 && state.Transitions.Count <= 1 && state.Timers.Count == 0)
        {
            _errors.Add(new BPlusError
            {
                Category = ErrorCategory.Speed,
                Severity = ErrorSeverity.Hint,
                File = _file,
                Line = index + 1,
                Column = 1,
                Message = $"��������� '{state.Name}' � ������. ����� ������ ��� ����������",
                Why = "������ ��������� ��������� ������� ����� ���� = ������ �����",
                Fixes =
                {
                    $"����� state {state.Name}, ����������� ��������",
                    $"�������� {state.Name} � ������������ ����������"
                }
            });
        }
    }

    // =========================================================
    // 7. E � �������� � contract violations
    // =========================================================
    public void CheckContract()
    {
        // Check that all referenced states exist
        foreach (var s in _program.States)
            CheckStateContract(s, _program.States.IndexOf(s));
        foreach (var pb in _program.ParallelBlocks)
            foreach (var s in pb.States)
                CheckStateContract(s, 0);

        // Check for orphaned states (not reachable from first state)
        var reachable = ComputeReachableStates();
        foreach (var s in _program.States)
        {
            if (s != _program.States[0] && !reachable.Contains(s.Name))
            {
                _errors.Add(new BPlusError
                {
                    Category = ErrorCategory.Contract,
                    Severity = ErrorSeverity.Warning,
                    File = _file,
                    Line = 1,
                    Column = 1,
                    Message = $"��������� '{s.Name}' ����������� � �� ���� ������� �� ���� �� ����",
                    Why = "̸����� ���: ��������� ���������, �� ������� �� ������������",
                    Fixes =
                    {
                        $"������ ������� � {s.Name} �� ���������� ���������",
                        $"����� {s.Name} ���� �� �����",
                        "������� ������� ���������"
                    }
                });
            }
        }

        // Check for duplicate state names
        var names = new HashSet<string>();
        foreach (var s in _program.States)
        {
            if (!names.Add(s.Name))
            {
                _errors.Add(new BPlusError
                {
                    Category = ErrorCategory.Contract,
                    Severity = ErrorSeverity.Error,
                    File = _file,
                    Line = 1,
                    Column = 1,
                    Message = $"������������� ��������� '{s.Name}'",
                    Why = "��� ��������� � ����� ������ � ���������������",
                    Fixes = { $"���������� ���� �� ���������" }
                });
            }
        }
    }

    private void CheckStateContract(StateDefNode state, int index)
    {
        // Check for undefined event sources (signals)
        foreach (var t in state.Transitions)
        {
            if (t.IsSignal && string.IsNullOrEmpty(t.SignalName))
            {
                _errors.Add(new BPlusError
                {
                    Category = ErrorCategory.Contract,
                    Severity = ErrorSeverity.Error,
                    File = _file,
                    Line = index + 1,
                    Column = 1,
                    Message = "������ ������, �� ��� ������� ������",
                    YouWrote = "on signal -> Target",
                    Expected = "on signal \"name\" -> Target",
                    Why = "��� ����� ������� ��������� �� ��� �������������",
                    Fixes = { "����� ��� �������: on signal \"my_signal\" -> Target" }
                });
            }
        }
    }

    // =========================================================
    // Helpers
    // =========================================================
    private HashSet<string> ComputeReachableStates()
    {
        var reachable = new HashSet<string>();
        var queue = new Queue<string>();

        if (_program.States.Count > 0)
            queue.Enqueue(_program.States[0].Name);

        foreach (var pb in _program.ParallelBlocks)
            foreach (var s in pb.States)
                queue.Enqueue(s.Name);

        while (queue.Count > 0)
        {
            var cur = queue.Dequeue();
            if (!reachable.Add(cur)) continue;
            if (!_stateMap.TryGetValue(cur, out var node)) continue;
            foreach (var t in node.Transitions)
                if (!string.IsNullOrEmpty(t.Target))
                    queue.Enqueue(t.Target);
            foreach (var t in node.Timers)
                if (!string.IsNullOrEmpty(t.Target))
                    queue.Enqueue(t.Target);
        }
        return reachable;
    }

    public void RunAll()
    {
        CheckTypes();
        CheckBounds();
        CheckDataRace();
        CheckMemory();
        CheckThermal();
        CheckSpeed();
        CheckContract();
    }

    public int Report(TextWriter writer)
    {
        if (_errors.Count == 0)
        {
            writer.WriteLine("\u2705 ������ �� �������");
            return 0;
        }

        var errors = _errors.Where(e => e.Severity == ErrorSeverity.Error).ToList();
        var warnings = _errors.Where(e => e.Severity == ErrorSeverity.Warning).ToList();
        var hints = _errors.Where(e => e.Severity == ErrorSeverity.Hint).ToList();

        foreach (var err in _errors)
            writer.WriteLine(err.Render());

        writer.WriteLine(new string('-', 40));
        writer.WriteLine($"\u0418\u0442\u043e\u0433\u043e: {errors.Count} \u043e\u0448\u0438\u0431\u043e\u043a, {warnings.Count} \u043f\u0440\u0435\u0434\u0443\u043f\u0440\u0435\u0436\u0434\u0435\u043d\u0438\u0439, {hints.Count} \u043f\u043e\u0434\u0441\u043a\u0430\u0437\u043e\u043a");
        writer.WriteLine();

        return errors.Count > 0 ? 1 : 0;
    }

    private bool IsValidType(string type) => type.ToLower() switch
    {
        "int" or "float" or "double" or "long" or "bool" or "string" or "void" or "ptr" => true,
        string t when t.StartsWith("bigfloat") => true,
        _ => _definedEnums.Contains(type)
    };

    private static int CountTransitions(StateDefNode state)
    {
        var count = state.Transitions.Count + state.Timers.Count;
        foreach (var ns in state.NestedStates)
            count += CountTransitions(ns);
        return count;
    }
}
