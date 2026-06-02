using System.Collections.Immutable;

namespace BPlus.Core.Ast;

public interface IAstVisitor<TResult>
{
    TResult Visit(ProgramNode node);
    TResult Visit(StateDefNode node);
    TResult Visit(TransitionNode node);
    TResult Visit(VariableNode node);
    TResult Visit(TimerNode node);
    TResult Visit(ActionNode node);
    TResult Visit(EntryDecl node);
    TResult Visit(FunctionDecl node);
    TResult Visit(KernelDecl node);
}

public static class AstVisitors
{
    public static TResult Accept<TResult>(this ProgramNode node, IAstVisitor<TResult> visitor) => visitor.Visit(node);
    public static TResult Accept<TResult>(this StateDefNode node, IAstVisitor<TResult> visitor) => visitor.Visit(node);
    public static TResult Accept<TResult>(this TransitionNode node, IAstVisitor<TResult> visitor) => visitor.Visit(node);
    public static TResult Accept<TResult>(this VariableNode node, IAstVisitor<TResult> visitor) => visitor.Visit(node);
    public static TResult Accept<TResult>(this TimerNode node, IAstVisitor<TResult> visitor) => visitor.Visit(node);
    public static TResult Accept<TResult>(this ActionNode node, IAstVisitor<TResult> visitor) => visitor.Visit(node);
    public static TResult Accept<TResult>(this EntryDecl node, IAstVisitor<TResult> visitor) => visitor.Visit(node);
    public static TResult Accept<TResult>(this FunctionDecl node, IAstVisitor<TResult> visitor) => visitor.Visit(node);
    public static TResult Accept<TResult>(this KernelDecl node, IAstVisitor<TResult> visitor) => visitor.Visit(node);
}
