using System;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace BPlusTranspiler;

/// <summary>Parses raw B+ body text into a JSON array of Stmt objects.</summary>
public static class BodyJsonParser
{
    public static void SerializeBodyStatements(Utf8JsonWriter writer, string src)
    {
        if (string.IsNullOrWhiteSpace(src)) { writer.WriteStartArray(); writer.WriteEndArray(); return; }
        var p = new Parser(src);
        writer.WriteStartArray();
        while (p.pos < p.src.Length)
        {
            p.SkipWs();
            if (p.pos >= p.src.Length) break;
            var stmt = p.ParseStmt();
            if (stmt == null) break;
            SerializeStmt(writer, stmt);
        }
        writer.WriteEndArray();
    }

    private static void SerializeStmt(Utf8JsonWriter w, StmtNode s)
    {
        w.WriteStartObject();
        w.WriteString("kind", s.Kind);
        switch (s)
        {
            case Print p:
                w.WritePropertyName("args");
                w.WriteStartArray();
                foreach (var a in p.Args) SerializeExpr(w, a);
                w.WriteEndArray();
                break;
            case Assign a:
                w.WriteString("target", a.Target);
                w.WriteString("op", a.Op);
                if (a.Value != null) { w.WritePropertyName("value"); SerializeExpr(w, a.Value); }
                break;
            case Return r:
                if (r.Value != null) { w.WritePropertyName("value"); SerializeExpr(w, r.Value); }
                break;
            case VarDecl v:
                w.WriteString("name", v.Name);
                w.WriteString("type", v.Type);
                if (v.Init != null) { w.WritePropertyName("init"); SerializeExpr(w, v.Init); }
                break;
            case If i:
                w.WritePropertyName("condition"); SerializeExpr(w, i.Condition);
                w.WritePropertyName("then"); w.WriteStartArray();
                foreach (var s2 in i.Then) SerializeStmt(w, s2);
                w.WriteEndArray();
                w.WritePropertyName("else"); w.WriteStartArray();
                foreach (var s2 in i.Else) SerializeStmt(w, s2);
                w.WriteEndArray();
                break;
            case While wl:
                w.WritePropertyName("condition"); SerializeExpr(w, wl.Condition);
                w.WritePropertyName("body"); w.WriteStartArray();
                foreach (var s2 in wl.Body) SerializeStmt(w, s2);
                w.WriteEndArray();
                break;
            case Block b:
                w.WritePropertyName("stmts"); w.WriteStartArray();
                foreach (var s2 in b.Stmts) SerializeStmt(w, s2);
                w.WriteEndArray();
                break;
            case ExprStmt es:
                w.WritePropertyName("expr"); SerializeExpr(w, es.Expr);
                break;
        }
        w.WriteEndObject();
    }

    private static void SerializeExpr(Utf8JsonWriter w, ExprNode e)
    {
        w.WriteStartObject();
        w.WriteString("kind", e.Kind);
        switch (e)
        {
            case Literal l:
                w.WritePropertyName("value");
                if (l.IsString) w.WriteStringValue(l.StrVal);
                else if (l.IsBool) w.WriteBooleanValue(l.BoolVal);
                else if (l.IsFloat) w.WriteNumberValue(l.FloatVal);
                else w.WriteNumberValue(l.IntVal);
                break;
            case Ident i:
                w.WriteString("name", i.Name);
                break;
            case Binary b:
                w.WriteString("op", b.Op);
                w.WritePropertyName("left"); SerializeExpr(w, b.Left);
                w.WritePropertyName("right"); SerializeExpr(w, b.Right);
                break;
            case Unary u:
                w.WriteString("op", u.Op);
                w.WritePropertyName("right"); SerializeExpr(w, u.Right);
                break;
            case Postfix p:
                w.WriteString("op", p.Op);
                w.WritePropertyName("left"); SerializeExpr(w, p.Left);
                break;
            case Call c:
                w.WriteString("callee", c.Callee);
                w.WritePropertyName("args"); w.WriteStartArray();
                foreach (var a in c.Args) SerializeExpr(w, a);
                w.WriteEndArray();
                break;
        }
        w.WriteEndObject();
    }

    // --- Internal Parser ---

    private abstract class StmtNode { public abstract string Kind { get; } }
    private sealed class Print : StmtNode { public override string Kind => "print"; public List<ExprNode> Args = new(); }
    private sealed class Assign : StmtNode { public override string Kind => "assign"; public string Target = ""; public string Op = ""; public ExprNode? Value; }
    private sealed class Return : StmtNode { public override string Kind => "return"; public ExprNode? Value; }
    private sealed class VarDecl : StmtNode { public override string Kind => "var_decl"; public string Name = ""; public string Type = ""; public ExprNode? Init; }
    private sealed class If : StmtNode { public override string Kind => "if"; public ExprNode Condition = null!; public List<StmtNode> Then = new(); public List<StmtNode> Else = new(); }
    private sealed class While : StmtNode { public override string Kind => "while"; public ExprNode Condition = null!; public List<StmtNode> Body = new(); }
    private sealed class Block : StmtNode { public override string Kind => "block"; public List<StmtNode> Stmts = new(); }
    private sealed class ExprStmt : StmtNode { public override string Kind => "expr_stmt"; public ExprNode Expr = null!; }

    private abstract class ExprNode { public abstract string Kind { get; } }
    private sealed class Literal : ExprNode
    {
        public override string Kind => "literal";
        public long IntVal;
        public double FloatVal;
        public bool BoolVal;
        public string StrVal = "";
        public bool IsString, IsBool, IsFloat;
    }
    private sealed class Ident : ExprNode { public override string Kind => "ident"; public string Name = ""; }
    private sealed class Binary : ExprNode { public override string Kind => "binary"; public string Op = ""; public ExprNode Left = null!; public ExprNode Right = null!; }
    private sealed class Unary : ExprNode { public override string Kind => "unary"; public string Op = ""; public ExprNode Right = null!; }
    private sealed class Postfix : ExprNode { public override string Kind => "postfix"; public string Op = ""; public ExprNode Left = null!; }
    private sealed class Call : ExprNode { public override string Kind => "call"; public string Callee = ""; public List<ExprNode> Args = new(); }

    private ref struct Parser
    {
        public ReadOnlySpan<char> src;
        public int pos;

        public Parser(ReadOnlySpan<char> s) { src = s; pos = 0; }

        public void SkipWs()
        {
            while (pos < src.Length && (src[pos] == ' ' || src[pos] == '\t' || src[pos] == '\n' || src[pos] == '\r'))
                pos++;
        }

        public bool Skip(string s)
        {
            if (pos + s.Length > src.Length) return false;
            for (int i = 0; i < s.Length; i++)
                if (src[pos + i] != s[i]) return false;
            pos += s.Length;
            return true;
        }

        public bool Peek(string s)
        {
            if (pos + s.Length > src.Length) return false;
            for (int i = 0; i < s.Length; i++)
                if (src[pos + i] != s[i]) return false;
            if (char.IsLetterOrDigit(s[^1]))
            {
                int n = pos + s.Length;
                if (n < src.Length && (char.IsLetterOrDigit(src[n]) || src[n] == '_'))
                    return false;
            }
            return true;
        }

        public char PeekChar() => pos < src.Length ? src[pos] : '\0';

        public bool IsWsOrEnd() => pos >= src.Length || src[pos] == ' ' || src[pos] == '\t' || src[pos] == '\n' || src[pos] == '\r' || src[pos] == ';' || src[pos] == '}';

        // --- Statement parser ---
        public StmtNode? ParseStmt()
        {
            SkipWs();
            if (pos >= src.Length || src[pos] == '}') return null;

            if (Peek("print")) { return ParsePrint(); }
            if (Peek("return") && !char.IsLetterOrDigit(PeekCharAfter("return"))) { return ParseReturn(); }
            if (Peek("var ")) { return ParseVarDecl(); }
            if (Peek("if ") || Peek("if(")) { return ParseIf(); }
            if (Peek("while ") || Peek("while(")) { return ParseWhile(); }
            if (src[pos] == '{') { return ParseBlock(); }

            // Assignment or expression
            return ParseAssignOrExpr();
        }

        private char PeekCharAfter(string word)
        {
            int n = pos + word.Length;
            if (n < src.Length && (src[n] == ' ' || src[n] == '\t' || src[n] == '\n'))
            {
                while (n < src.Length && (src[n] == ' ' || src[n] == '\t')) n++;
            }
            return n < src.Length ? src[n] : '\0';
        }

        private StmtNode ParsePrint()
        {
            Skip("print");
            SkipWs();
            if (src[pos] == '(') pos++;
            SkipWs();
            var args = new List<ExprNode>();
            if (pos < src.Length && src[pos] != ')')
            {
                args.Add(ParseExpr());
                SkipWs();
                while (pos < src.Length && src[pos] == ',')
                {
                    pos++; SkipWs();
                    args.Add(ParseExpr());
                    SkipWs();
                }
            }
            if (pos < src.Length && src[pos] == ')') pos++;
            return new Print { Args = args };
        }

        private StmtNode ParseReturn()
        {
            Skip("return");
            SkipWs();
            ExprNode? val = null;
            if (pos < src.Length && src[pos] != '\n' && src[pos] != ';' && src[pos] != '}')
            {
                val = ParseExpr();
            }
            SkipSemicolon();
            return new Return { Value = val };
        }

        private StmtNode ParseVarDecl()
        {
            Skip("var "); SkipWs();
            var name = ParseWord();
            SkipWs();
            string type = "";
            if (pos < src.Length && src[pos] == ':')
            {
                pos++; SkipWs();
                type = ParseWord();
                SkipWs();
            }
            ExprNode? init = null;
            if (pos < src.Length && src[pos] == '=')
            {
                pos++; SkipWs();
                init = ParseExpr();
            }
            SkipSemicolon();
            return new VarDecl { Name = name, Type = type, Init = init };
        }

        private StmtNode ParseIf()
        {
            Skip("if"); SkipWs();
            bool hasParens = src[pos] == '(';
            if (hasParens) pos++;
            SkipWs();
            var cond = ParseExpr();
            if (hasParens && pos < src.Length && src[pos] == ')') pos++;
            SkipWs();
            var thenBlock = ParseBlockStmts();
            SkipWs();
            List<StmtNode> elseBlock = new();
            if (Peek("else ") || Peek("else{"))
            {
                Skip("else"); SkipWs();
                if (src[pos] == '{')
                    elseBlock = ParseBlockStmts();
                else if (Peek("if"))
                    elseBlock.Add(ParseIf());
            }
            return new If { Condition = cond, Then = thenBlock, Else = elseBlock };
        }

        private StmtNode ParseWhile()
        {
            Skip("while"); SkipWs();
            bool hasParens = src[pos] == '(';
            if (hasParens) pos++;
            SkipWs();
            var cond = ParseExpr();
            if (hasParens && pos < src.Length && src[pos] == ')') pos++;
            SkipWs();
            var body = ParseBlockStmts();
            return new While { Condition = cond, Body = body };
        }

        private StmtNode ParseBlock()
        {
            var stmts = ParseBlockStmts();
            return new Block { Stmts = stmts };
        }

        private List<StmtNode> ParseBlockStmts()
        {
            var stmts = new List<StmtNode>();
            if (pos < src.Length && src[pos] == '{') pos++;
            SkipWs();
            while (pos < src.Length && src[pos] != '}')
            {
                var s = ParseStmt();
                if (s != null) stmts.Add(s);
                SkipWs();
            }
            if (pos < src.Length && src[pos] == '}') pos++;
            return stmts;
        }

        private StmtNode ParseAssignOrExpr()
        {
            // Peek ahead to find operator
            var save = pos;
            var lhs = ParseExpr();
            SkipWs();

            // Check for += / -= / =
            string? op = null;
            if (pos < src.Length)
            {
                if (src[pos] == '=') op = "=";
                else if (pos + 1 < src.Length && src[pos] == '+' && src[pos + 1] == '=') op = "+=";
                else if (pos + 1 < src.Length && src[pos] == '-' && src[pos + 1] == '=') op = "-=";
            }

            if (op != null)
            {
                pos += op.Length;
                SkipWs();
                var rhs = ParseExpr();
                SkipSemicolon();
                if (lhs is Ident id)
                    return new Assign { Target = id.Name, Op = op, Value = rhs };
                return new ExprStmt { Expr = lhs };
            }

            // Expression statement
            SkipSemicolon();
            return new ExprStmt { Expr = lhs };
        }

        // --- Expression parser (Pratt) ---

        private enum Prec { None, Assign, Or, And, Cmp, Add, Mul, Unary, Call, Primary }

        private ExprNode ParseExpr() => ParseExpr(Prec.None);

        private ExprNode ParseExpr(Prec minPrec)
        {
            var lhs = ParsePrefix();
            if (lhs == null) return new Literal { IntVal = 0 };

            while (true)
            {
                var prec = GetInfixPrec();
                if (prec == Prec.None || prec < minPrec) break;
                lhs = ParseInfix(lhs, prec);
            }
            return lhs;
        }

        private Prec GetInfixPrec()
        {
            SkipWs();
            if (pos >= src.Length) return Prec.None;
            var c = src[pos];
            if (pos + 1 < src.Length)
            {
                var d = src[pos + 1];
                if ((c == '&' && d == '&') || (c == '|' && d == '|')) return Prec.Or;
                if (c == '=' && d == '=') return Prec.Cmp;
                if (c == '!' && d == '=') return Prec.Cmp;
                if (c == '<' && d == '=') return Prec.Cmp;
                if (c == '>' && d == '=') return Prec.Cmp;
            }
            return c switch
            {
                '=' when pos > 0 && src[pos - 1] != '=' => Prec.None,
                '+' or '-' when pos + 1 < src.Length && src[pos + 1] == '=' => Prec.None,
                '+' or '-' => Prec.Add,
                '<' or '>' => Prec.Cmp,
                '*' or '/' or '%' => Prec.Mul,
                '(' => Prec.Call,
                '.' => Prec.Primary,
                _ => Prec.None,
            };
        }

        private ExprNode ParsePrefix()
        {
            SkipWs();
            if (pos >= src.Length) return null!;
            var c = src[pos];
            if (c == '-' || c == '!')
            {
                pos++;
                var right = ParseExpr(Prec.Unary);
                return new Unary { Op = c.ToString(), Right = right };
            }
            if (c == '(')
            {
                pos++;
                var expr = ParseExpr();
                if (pos < src.Length && src[pos] == ')') pos++;
                return expr;
            }
            if (c == '"')
            {
                pos++;
                var val = new StringBuilder();
                while (pos < src.Length && src[pos] != '"')
                {
                    if (src[pos] == '\\')
                    {
                        pos++;
                        if (pos >= src.Length) break;
                        switch (src[pos])
                        {
                            case 'n': val.Append('\n'); break;
                            case 't': val.Append('\t'); break;
                            case 'r': val.Append('\r'); break;
                            case '\\': val.Append('\\'); break;
                            case '"': val.Append('"'); break;
                            case '0': val.Append('\0'); break;
                            default: val.Append(src[pos]); break;
                        }
                        pos++;
                    }
                    else
                    {
                        val.Append(src[pos]);
                        pos++;
                    }
                }
                if (pos < src.Length) pos++;
                return new Literal { IsString = true, StrVal = val.ToString() };
            }
            if (c == '\'')
            {
                pos++;
                var val = "";
                if (pos < src.Length && src[pos] == '\\') { pos++; if (pos < src.Length) { val = src[pos] == 'n' ? "\n" : src[pos].ToString(); pos++; } }
                else if (pos < src.Length) { val = src[pos].ToString(); pos++; }
                if (pos < src.Length && src[pos] == '\'') pos++;
                return new Literal { IsString = true, StrVal = val };
            }
            if (char.IsDigit(c) || (c == '.' && pos + 1 < src.Length && char.IsDigit(src[pos + 1])))
            {
                return ParseNumber();
            }
            if (Peek("true")) { pos += 4; return new Literal { IsBool = true, BoolVal = true }; }
            if (Peek("false")) { pos += 5; return new Literal { IsBool = true, BoolVal = false }; }
            if (char.IsLetter(c) || c == '_')
            {
                return ParseIdentOrCall();
            }
            return new Literal { IntVal = 0 };
        }

        private ExprNode ParseNumber()
        {
            int start = pos;
            bool isFloat = false;
            while (pos < src.Length && (char.IsDigit(src[pos]) || src[pos] == '.'))
            {
                if (src[pos] == '.') isFloat = true;
                pos++;
            }
            var text = new string(src.Slice(start, pos - start));
            if (isFloat && double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var fv))
                return new Literal { IsFloat = true, FloatVal = fv };
            if (long.TryParse(text, out var iv))
                return new Literal { IntVal = iv };
            return new Literal { IntVal = 0 };
        }

        private ExprNode ParseIdentOrCall()
        {
            var name = ParseWord();
            SkipWs();
            if (pos < src.Length && src[pos] == '(')
            {
                pos++;
                SkipWs();
                var args = new List<ExprNode>();
                if (pos < src.Length && src[pos] != ')')
                {
                    args.Add(ParseExpr());
                    SkipWs();
                    while (pos < src.Length && src[pos] == ',')
                    {
                        pos++; SkipWs();
                        args.Add(ParseExpr());
                        SkipWs();
                    }
                }
                if (pos < src.Length && src[pos] == ')') pos++;
                return new Call { Callee = name, Args = args };
            }
            return new Ident { Name = name };
        }

        private ExprNode ParseInfix(ExprNode lhs, Prec minPrec)
        {
            SkipWs();
            if (pos >= src.Length) return lhs;

            var c = src[pos];

            // Postfix ++ / -- (must precede binary + / -)
            if (pos + 1 < src.Length)
            {
                if ((c == '+' && src[pos + 1] == '+') || (c == '-' && src[pos + 1] == '-'))
                {
                    pos += 2;
                    return new Postfix { Op = c == '+' ? "++" : "--", Left = lhs };
                }
            }

            // Compound assignment (+=, -=) — let ParseAssignOrExpr handle
            if (pos + 1 < src.Length)
            {
                if ((c == '+' && src[pos + 1] == '=') || (c == '-' && src[pos + 1] == '='))
                    return lhs;
            }

            // Binary operators
            string? op = null;
            int advance = 0;
            if (pos + 1 < src.Length)
            {
                var d = src[pos + 1];
                if (c == '&' && d == '&') { op = "&&"; advance = 2; }
                else if (c == '|' && d == '|') { op = "||"; advance = 2; }
                else if (c == '=' && d == '=') { op = "=="; advance = 2; }
                else if (c == '!' && d == '=') { op = "!="; advance = 2; }
                else if (c == '<' && d == '=') { op = "<="; advance = 2; }
                else if (c == '>' && d == '=') { op = ">="; advance = 2; }
            }
            if (op == null)
            {
                op = c switch
                {
                    '+' => "+", '-' => "-",
                    '*' => "*", '/' => "/", '%' => "%",
                    '<' => "<", '>' => ">",
                    _ => null,
                };
                advance = op != null ? 1 : 0;
            }

            if (op != null && advance > 0)
            {
                var rightPrec = op switch
                {
                    "&&" => Prec.And,
                    "||" => Prec.Or,
                    "==" or "!=" or "<" or ">" or "<=" or ">=" => Prec.Cmp,
                    "+" or "-" => Prec.Add,
                    "*" or "/" or "%" => Prec.Mul,
                    _ => Prec.Primary,
                };
                pos += advance;
                SkipWs();
                var right = ParseExpr(rightPrec);
                return new Binary { Op = op, Left = lhs, Right = right };
            }

            return lhs;
        }

        private string ParseWord()
        {
            SkipWs();
            int start = pos;
            while (pos < src.Length && (char.IsLetterOrDigit(src[pos]) || src[pos] == '_'))
                pos++;
            return new string(src.Slice(start, pos - start));
        }

        private void SkipSemicolon()
        {
            SkipWs();
            if (pos < src.Length && src[pos] == ';') pos++;
        }
    }
}
