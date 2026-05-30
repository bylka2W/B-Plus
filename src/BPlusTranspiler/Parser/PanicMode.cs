namespace BPlusTranspiler.Parser;

internal sealed class PanicMode
{
    private readonly Lexer _lexer;
    private int _recoveryAttempts;

    private static readonly HashSet<string> SyncTokens = new(StringComparer.Ordinal)
    {
        "state", "on", "enter", "exit", "var", "fn", "import",
        "entry", "context", "}", "always", "inline", "parallel",
        "pipeline", "step", "kernel", "blockchain", "network",
        "graphics_kernel", "compute_shader", "fragment_shader",
        "vertex_shader", "ray_tracing_shader", "local_group",
        "scientific_kernel", "#",
    };

    public PanicMode(Lexer lexer)
    {
        _lexer = lexer;
    }

    public bool TryRecover()
    {
        if (_recoveryAttempts++ > 16)
            return false;

        var src = _lexer.Src;
        var pos = _lexer.Pos;
        if (pos >= src.Length)
            return false;

        int depth = 0;
        for (int i = pos; i < src.Length; i++)
        {
            char c = src[i];
            if (c == '{') depth++;
            else if (c == '}') { depth--; if (depth < 0) { _lexer.Pos = i; return true; } }

            if (depth > 0) continue;

            foreach (var sync in SyncTokens)
            {
                if (i + sync.Length <= src.Length &&
                    src.AsSpan(i, sync.Length).SequenceEqual(sync.AsSpan()) &&
                    (i + sync.Length >= src.Length || !char.IsLetterOrDigit(src[i + sync.Length])))
                {
                    _lexer.Pos = i;
                    _lexer.SkipWs();
                    return true;
                }
            }
        }

        _lexer.Pos = src.Length;
        return true;
    }
}
