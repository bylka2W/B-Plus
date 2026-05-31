using System.Text;
using System.Text.RegularExpressions;

namespace BPlusTranspiler;

public static class BPlusFormatter
{
    public static string Format(string source)
    {
        source = source.Replace("\r\n", "\n");
        source = source.Replace("\r", "\n");
        source = Unpack(source);
        source = Reindent(source);
        source = CollapseBlankLines(source);
        return source + "\n";
    }

    public static bool IsFormatted(string source)
    {
        var norm = source.Replace("\r\n", "\n").TrimEnd();
        return Format(norm).TrimEnd() == norm;
    }

    // Convert any one-line state/context blocks into multi-line
    static string Unpack(string src)
    {
        var sb = new StringBuilder();
        int pos = 0;

        while (pos < src.Length)
        {
            // Skip whitespace (not newlines) at start of line
            while (pos < src.Length && (src[pos] == ' ' || src[pos] == '\t'))
                pos++;

            // Comment
            if (pos + 1 < src.Length && ((src[pos] == '/' && src[pos + 1] == '/') || (src[pos] == '-' && src[pos + 1] == '-')))
            {
                int end = src.IndexOf('\n', pos);
                if (end < 0) end = src.Length;
                sb.Append(src, pos, end - pos);
                sb.Append('\n');
                pos = end + 1;
                continue;
            }

            // Newline
            if (pos < src.Length && src[pos] == '\n')
            {
                pos++;
                continue;
            }

            // Detect start of a braced block (state/context)
            // Check if we're at a state or context declaration followed by {
            var rest = src[pos..];
            var stateM = Regex.Match(rest, @"^(state\s+\w+)\s*(\{)");
            var ctxM = Regex.Match(rest, @"^(context)\s*(\{)");

            if (stateM.Success || ctxM.Success)
            {
                var m = stateM.Success ? stateM : ctxM;
                string keyword = m.Groups[1].Value;
                sb.Append(keyword);
                sb.Append(" {\n");
                pos += m.Length;

                // Parse the block body until matching }
                pos = ParseBody(src, pos, sb);
                continue;
            }

            // Not a block start — copy as-is to end of line
            int nl = src.IndexOf('\n', pos);
            if (nl < 0) nl = src.Length;
            sb.Append(src, pos, nl - pos);
            sb.Append('\n');
            pos = nl + 1;
        }

        return sb.ToString();
    }

    // Parse { ... } body, emitting each construct on its own line
    static int ParseBody(string src, int pos, StringBuilder sb)
    {
        int depth = 1;
        // Known keywords that start a new line inside a block
        var keywords = new[] { "on ", "enter", "exit ", "after", "always", "var " };

        while (pos < src.Length && depth > 0)
        {
            // Skip whitespace / newlines between constructs
            if (src[pos] == '\n' || src[pos] == '\r') { pos++; continue; }
            if (src[pos] == ' ' || src[pos] == '\t') { pos++; continue; }

            // Comment
            if (pos + 1 < src.Length && ((src[pos] == '/' && src[pos + 1] == '/') || (src[pos] == '-' && src[pos + 1] == '-')))
            {
                int end = src.IndexOf('\n', pos);
                if (end < 0) end = src.Length;
                sb.Append("    ");
                sb.Append(src, pos, end - pos);
                sb.Append('\n');
                pos = end;
                continue;
            }

            // Closing brace
            if (src[pos] == '}')
            {
                sb.Append("}\n");
                pos++;
                depth--;
                continue;
            }

            // Check if this position starts a keyword
            string rem = src[pos..];
            string? matchedKw = null;
            foreach (var kw in keywords)
            {
                if (rem.StartsWith(kw))
                {
                    matchedKw = kw;
                    break;
                }
            }

            if (matchedKw != null)
            {
                sb.Append("    ");
                sb.Append(matchedKw);
                pos += matchedKw.Length;

                // Read rest of this construct until next keyword, }, or end
                bool inBrace = false; // track if we're inside a { } block
                while (pos < src.Length && depth > 0)
                {
                    char c = src[pos];
                    if (c == '{') { inBrace = true; sb.Append(c); pos++; continue; }
                    if (c == '}')
                    {
                        if (!inBrace)
                        {
                            // End of block — emit newline and return
                            sb.Append('\n');
                            sb.Append("}\n");
                            pos++;
                            depth--;
                            return pos;
                        }
                        inBrace = false;
                        sb.Append(c);
                        pos++;
                        continue;
                    }
                    if (c == '\n' || c == '\r')
                    {
                        if (!inBrace)
                        {
                            // End of line while not in a brace block — new construct
                            sb.Append('\n');
                            pos++;
                            break;
                        }
                        pos++;
                        continue;
                    }
                    if (!inBrace && (c == ' ' || c == '\t'))
                    {
                        // Check if next word is a keyword
                        int lookahead = pos + 1;
                        while (lookahead < src.Length && (src[lookahead] == ' ' || src[lookahead] == '\t'))
                            lookahead++;
                        string after = src[lookahead..];
                        bool nextIsKw = keywords.Any(k => after.StartsWith(k));
                        if (nextIsKw)
                        {
                            // End of this construct, next one begins
                            sb.Append('\n');
                            pos = lookahead;
                            break;
                        }
                        sb.Append(c);
                        pos++;
                        continue;
                    }
                    sb.Append(c);
                    pos++;
                }
                continue;
            }

            // Unknown content — skip to end of line or }
            int until = src.IndexOfAny(new[] { '\n', '}' }, pos);
            if (until < 0) until = src.Length;
            sb.Append("    ");
            sb.Append(src, pos, until - pos);
            sb.Append('\n');
            pos = until;
        }

        return pos;
    }

    static string Reindent(string src)
    {
        var lines = src.Split('\n');
        var sb = new StringBuilder();
        int depth = 0;

        foreach (var raw in lines)
        {
            string t = raw.Trim();
            if (t == "")
                continue;

            bool isComment = t.StartsWith("//") || t.StartsWith("--");

            int opens = t.Count(c => c == '{');
            int closes = t.Count(c => c == '}');

            int ld = depth;
            if (!isComment && t.Length > 0 && t[0] == '}')
                ld--;

            bool isState = Regex.IsMatch(t, @"^state\s+\w+");
            bool isTopBlock = Regex.IsMatch(t, @"^(state|context|entry|import|enum|parallel)\b");
            if (isTopBlock && sb.Length > 0)
            {
                string cur = sb.ToString();
                if (!cur.EndsWith("\n\n"))
                    sb.Append('\n');
            }

            sb.Append(' ', ld * 4);
            sb.Append(t);
            sb.Append('\n');

            if (!isComment)
                depth += opens - closes;
            if (depth < 0) depth = 0;
        }

        return sb.ToString().TrimEnd();
    }

    static string CollapseBlankLines(string s)
    {
        return Regex.Replace(s, "\n{3,}", "\n\n");
    }
}
