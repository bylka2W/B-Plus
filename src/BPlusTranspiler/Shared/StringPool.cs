using System.Runtime.CompilerServices;

namespace BPlusTranspiler;

public class StringPool
{
    private readonly Dictionary<string, string> _interned = new();

    public string Intern(string value)
    {
        if (value == null) return null!;
        if (_interned.TryGetValue(value, out var existing))
            return existing;
        _interned[value] = value;
        return value;
    }

    public string Intern(ReadOnlySpan<char> value)
    {
        var key = value.ToString();
        if (_interned.TryGetValue(key, out var existing))
            return existing;
        _interned[key] = key;
        return key;
    }

    public void PreWarm(IEnumerable<string> values)
    {
        foreach (var v in values)
            _interned[v] = v;
    }
}
