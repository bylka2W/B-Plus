using System.Collections.Immutable;
using BPlus.Core.Parser;

namespace BPlus.Core;

public class DiagnosticsBag
{
    private readonly List<ParseException> _errors = new();
    public ImmutableArray<ParseException> Errors => _errors.ToImmutableArray();
    public bool HasErrors => _errors.Count > 0;
    public int Count => _errors.Count;

    public void Add(ParseException error) => _errors.Add(error);

    public void Add(string message, int line = 0, int column = 0, string context = "", string suggestion = "")
        => _errors.Add(new ParseException(message, line, column, context, suggestion));

    public void ThrowIfAny()
    {
        if (_errors.Count > 0)
            throw new AggregateException("Parse errors", _errors.Select(e => (Exception)e));
    }
}
