namespace BPlusTranspiler.Ast;

public enum ActionType { Enter, Exit, Action }

public class ProgramNode
{
    public List<ImportNode> Imports { get; } = new();
    public List<StateNode> States { get; } = new();
}

public class ImportNode
{
    public string Path { get; init; } = "";
}

public class StateNode
{
    public string Name { get; set; } = "";
    public List<TransitionNode> Transitions { get; } = new();
    public List<ActionNode> Actions { get; } = new();
}

public class TransitionNode
{
    public string Event { get; init; } = "";
    public string Target { get; init; } = "";
    public string? Guard { get; init; }
}

public class ActionNode
{
    public ActionType Type { get; init; }
    public string Body { get; init; } = "";
}