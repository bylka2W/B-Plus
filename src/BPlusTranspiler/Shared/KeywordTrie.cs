using System.Runtime.CompilerServices;

namespace BPlusTranspiler;

internal sealed class KeywordTrie
{
    private readonly Node _root = new();

    private sealed class Node
    {
        public Node?[] Children = new Node?[256];
        public bool IsEnd;
        public string? Value;
    }

    public void Add(string keyword)
    {
        var node = _root;
        foreach (byte b in System.Text.Encoding.ASCII.GetBytes(keyword))
        {
            node.Children[b] ??= new Node();
            node = node.Children[b]!;
        }
        node.IsEnd = true;
        node.Value = keyword;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public string? Match(ReadOnlySpan<byte> input, out int consumed)
    {
        consumed = 0;
        var node = _root;
        string? lastMatch = null;
        int lastLen = 0;
        for (int i = 0; i < input.Length; i++)
        {
            var b = input[i];
            var next = node.Children[b];
            if (next == null) break;
            node = next;
            if (node.IsEnd)
            {
                lastMatch = node.Value;
                lastLen = i + 1;
            }
        }
        if (lastMatch != null)
        {
            // Only match if next char is not alphanumeric/underscore
            if (lastLen < input.Length)
            {
                var next = input[lastLen];
                if ((next >= 'a' && next <= 'z') || (next >= 'A' && next <= 'Z') || (next >= '0' && next <= '9') || next == '_')
                    return null;
            }
            consumed = lastLen;
            return lastMatch;
        }
        return null;
    }

    public static KeywordTrie CreateDefault()
    {
        var trie = new KeywordTrie();
        foreach (var kw in s_keywords)
            trie.Add(kw);
        return trie;
    }

    private static readonly string[] s_keywords =
    {
        "state", "on", "enter", "exit", "always", "var", "fn", "return",
        "if", "else", "while", "for", "import", "context", "entry", "print",
        "parallel", "pipeline", "step", "kernel", "inline", "true", "false",
        "metal", "shader", "network", "blockchain", "validator", "zero_trust",
        "int", "float", "bool", "string", "void", "i8", "i16", "i32", "i64",
        "u8", "u16", "u32", "u64", "f32", "f64",
    };
}
