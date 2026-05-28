using System.Text.RegularExpressions;

namespace BPlusTranspiler.Parser;

internal class Lexer
{
    public string Src { get; set; } = "";
    public int Pos { get; set; }
    public int Line { get; set; } = 1;

    public Lexer() { }

    public Lexer(string src) { Src = src; Pos = 0; Line = 1; }

    public char Current => Pos < Src.Length ? Src[Pos] : '\0';
    public bool IsEnd => Pos >= Src.Length;

    public void SkipWs()
    {
        while (Pos < Src.Length && char.IsWhiteSpace(Src[Pos]))
        {
            if (Src[Pos] == '\n') Line++;
            Pos++;
        }
    }

    public void SkipToEndOfLine()
    {
        while (Pos < Src.Length && Src[Pos] != '\n') Pos++;
    }

    public string ParseWord()
    {
        SkipWs();
        int start = Pos;
        while (Pos < Src.Length && (char.IsLetterOrDigit(Src[Pos]) || Src[Pos] == '_'))
            Pos++;
        if (Pos == start) throw new ParseException($"Expected identifier at position {Pos}");
        return Src[start..Pos];
    }

    public bool Peek(string s)
    {
        if (Pos + s.Length > Src.Length) return false;
        for (int i = 0; i < s.Length; i++)
            if (Src[Pos + i] != s[i]) return false;
        if (char.IsLetterOrDigit(s[^1]))
        {
            int next = Pos + s.Length;
            if (next < Src.Length && (char.IsLetterOrDigit(Src[next]) || Src[next] == '_'))
                return false;
        }
        return true;
    }

    public string PeekWord()
    {
        SkipWs();
        int start = Pos;
        while (Pos < Src.Length && (char.IsLetterOrDigit(Src[Pos]) || Src[Pos] == '_'))
            Pos++;
        var word = Src[start..Pos];
        Pos = start;
        return word != "" ? word : (Pos < Src.Length ? Src[Pos].ToString() : "(eof)");
    }

    public string ConsumeUntilOr(string terminators)
    {
        int start = Pos;
        while (Pos < Src.Length && !terminators.Contains(Src[Pos]))
            Pos++;
        return Src[start..Pos].Trim();
    }

    public string? ExtractBracedBlock()
    {
        if (Pos >= Src.Length || Src[Pos] != '{') return null;
        Pos++;
        int depth = 1;
        int start = Pos;
        while (Pos < Src.Length && depth > 0)
        {
            if (Src[Pos] == '{') depth++;
            else if (Src[Pos] == '}') depth--;
            if (depth > 0) Pos++;
        }
        var body = Src[start..Pos].Trim();
        Pos++;
        return body;
    }

    public string ParseAnnotationValue()
    {
        if (Pos < Src.Length && Src[Pos] == '"')
        {
            Pos++;
            int start = Pos;
            while (Pos < Src.Length && Src[Pos] != '"')
                Pos++;
            var val = Src[start..Pos];
            Pos++;
            return val;
        }
        if (Pos < Src.Length && (char.IsDigit(Src[Pos]) || (Src[Pos] == '-' && Pos + 1 < Src.Length && char.IsDigit(Src[Pos + 1]))))
        {
            int start = Pos;
            if (Src[Pos] == '-') Pos++;
            while (Pos < Src.Length && (char.IsLetterOrDigit(Src[Pos]) || Src[Pos] == '_' || Src[Pos] == '.'))
                Pos++;
            return Src[start..Pos];
        }
        return ParseWord();
    }

    public bool IsVarDeclStart()
    {
        var saved = Pos;
        try
        {
            var word = ParseWord();
            SkipWs();
            if (Pos < Src.Length && Src[Pos] == ':')
            {
                return word != "state" && word != "base"
                    && word != "import" && word != "context"
                    && word != "enum" && word != "parallel"
                    && word != "kernel" && word != "pipeline"
                    && word != "entry" && word != "always"
                    && word != "step" && word != "body"
                    && word != "needs" && word != "gives" && word != "touches"
                    && word != "var" && word != "on" && word != "after";
            }
            return false;
        }
        finally { Pos = saved; }
    }

    public static string ReadUntilWsOr(string s, char[] terminators)
    {
        int i = 0;
        while (i < s.Length && !char.IsWhiteSpace(s[i]) && !terminators.Contains(s[i]))
            i++;
        return s[..i];
    }

    public static string StripComments(string src)
    {
        src = Regex.Replace(src, @"//.*", "");
        return src;
    }
}
