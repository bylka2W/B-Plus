using System.Collections.Immutable;

namespace BPlusTranspiler;

public readonly struct Symbol
{
    public string Name { get; }
    public string Type { get; }
    public SymbolKind Kind { get; }
    public int ScopeDepth { get; }
    public string? DeclaringState { get; }

    public Symbol(string name, string type, SymbolKind kind, int scopeDepth, string? declaringState = null)
    {
        Name = name;
        Type = type;
        Kind = kind;
        ScopeDepth = scopeDepth;
        DeclaringState = declaringState;
    }
}

public enum SymbolKind { Variable, State, Function, Kernel, Event, Import, Enum, Type }

public class Scope
{
    public Scope? Parent { get; }
    public int Depth { get; }
    private readonly Dictionary<string, Symbol> _symbols = new();

    public Scope(Scope? parent = null)
    {
        Parent = parent;
        Depth = parent?.Depth + 1 ?? 0;
    }

    public void Declare(Symbol symbol)
    {
        _symbols[symbol.Name] = symbol;
    }

    public Symbol? Lookup(string name)
    {
        if (_symbols.TryGetValue(name, out var sym))
            return sym;
        return Parent?.Lookup(name);
    }

    public Symbol? LookupLocal(string name)
    {
        return _symbols.TryGetValue(name, out var sym) ? sym : null;
    }
}

public class SymbolTable
{
    private Scope _global;
    public Scope CurrentScope { get; private set; }

    public SymbolTable()
    {
        _global = new Scope();
        CurrentScope = _global;
    }

    public Scope PushScope()
    {
        var scope = new Scope(CurrentScope);
        CurrentScope = scope;
        return scope;
    }

    public Scope PopScope()
    {
        if (CurrentScope.Parent != null)
            CurrentScope = CurrentScope.Parent;
        return CurrentScope;
    }

    public void Declare(Symbol symbol) => CurrentScope.Declare(symbol);

    public Symbol? Lookup(string name) => CurrentScope.Lookup(name);

    public Symbol? LookupCurrent(string name) => CurrentScope.LookupLocal(name);
}
