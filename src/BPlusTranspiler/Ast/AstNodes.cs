namespace BPlusTranspiler.Ast;

public enum ActionType { Enter, Exit }

public class ProgramNode
{
    public List<ImportNode> Imports { get; } = new();
    public ContextNode? Context { get; set; }
    public List<EnumNode> Enums { get; } = new();
    public List<StateDefNode> States { get; } = new();
    public List<ParallelBlockNode> ParallelBlocks { get; } = new();
}

public class ImportNode
{
    public string Path { get; set; } = "";
}

public class VariableNode
{
    public string Name { get; set; } = "";
    public string Type { get; set; } = "";
    public string? DefaultValue { get; set; }
}

public class ContextNode
{
    public List<VariableNode> Variables { get; } = new();
}

public class EnumNode
{
    public string Name { get; set; } = "";
    public List<string> Members { get; } = new();
}

public class StateDefNode
{
    public string Name { get; set; } = "";
    public string? BaseClass { get; set; }
    public string? GenericParam { get; set; }
    public bool IsBaseClass { get; set; }
    public List<VariableNode> Variables { get; } = new();
    public List<TransitionNode> Transitions { get; } = new();
    public List<ActionNode> Actions { get; } = new();
    public List<TimerNode> Timers { get; } = new();
    public List<StateDefNode> NestedStates { get; } = new();
}

public class TransitionNode
{
    public string EventName { get; set; } = "";
    public bool IsSignal { get; set; }
    public string? SignalName { get; set; }
    public List<ParamNode> Parameters { get; } = new();
    public string? Guard { get; set; }
    public string Target { get; set; } = "";
    public string? Body { get; set; }
    public bool IsAsync { get; set; }
    public bool IsAlways { get; set; }
    public bool IsEnterAuto { get; set; }
}

public class ParamNode
{
    public string Name { get; set; } = "";
    public string Type { get; set; } = "";
}

public class TimerNode
{
    public string Duration { get; init; } = "";
    public string? Guard { get; init; }
    public string Target { get; init; } = "";
}

public class ActionNode
{
    public ActionType Type { get; init; }
    public string Body { get; init; } = "";
}

public class ParallelBlockNode
{
    public string Name { get; set; } = "";
    public List<StateDefNode> States { get; } = new();
}