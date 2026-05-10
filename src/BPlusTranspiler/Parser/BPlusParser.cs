using System.Text.RegularExpressions;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Parser;

public partial class BPlusParser
{
    private string _src = "";
    private int _pos;

    public ProgramNode Parse(string source)
    {
        _src = StripComments(source);
        _pos = 0;
        var program = new ProgramNode();

        SkipWs();
        while (_pos < _src.Length)
        {
            if (Peek("import "))
            {
                program.Imports.Add(ParseImport());
            }
            else if (Peek("context"))
            {
                program.Context = ParseContext();
            }
            else if (Peek("enum "))
            {
                program.Enums.Add(ParseEnum());
            }
            else if (Peek("parallel "))
            {
                program.ParallelBlocks.Add(ParseParallel());
            }
            else if (Peek("state ") || Peek("base "))
            {
                program.States.Add(ParseStateDef());
            }
            else
            {
                throw Err($"Unexpected '{PeekWord()}'");
            }
            SkipWs();
        }

        return program;
    }

    private ImportNode ParseImport()
    {
        Expect("import ");
        SkipWs();
        var m = Regex.Match(_src[_pos..], @"^""([^""]*)""");
        if (!m.Success) throw Err("Expected string literal after import");
        _pos += m.Length;
        return new ImportNode { Path = m.Groups[1].Value };
    }

    private ContextNode ParseContext()
    {
        Expect("context");
        SkipWs();
        Expect("{");
        var ctx = new ContextNode();
        SkipWs();
        while (_pos < _src.Length && _src[_pos] != '}')
        {
            ctx.Variables.Add(ParseVarDecl());
            SkipWs();
        }
        Expect("}");
        return ctx;
    }

    private EnumNode ParseEnum()
    {
        Expect("enum ");
        var name = ParseWord();
        SkipWs();
        Expect("{");
        var en = new EnumNode { Name = name };
        SkipWs();
        while (_pos < _src.Length && _src[_pos] != '}')
        {
            var member = ParseWord();
            en.Members.Add(member);
            SkipWs();
            if (_pos < _src.Length && _src[_pos] == ',')
            {
                _pos++;
                SkipWs();
            }
        }
        Expect("}");
        return en;
    }

    private StateDefNode ParseStateDef()
    {
        var state = new StateDefNode();

        if (Peek("base "))
        {
            Expect("base ");
            state.IsBaseClass = true;
            SkipWs();
        }

        Expect("state ");
        state.Name = ParseWord();

        // Generic <T>
        SkipWs();
        if (_pos < _src.Length && _src[_pos] == '<')
        {
            _pos++;
            state.GenericParam = ParseWord();
            SkipWs();
            Expect(">");
        }

        // Inheritance : Parent
        SkipWs();
        if (_pos < _src.Length && _src[_pos] == ':')
        {
            _pos++;
            SkipWs();
            state.BaseClass = ParseWord();
        }

        SkipWs();
        Expect("{");
        SkipWs();

        while (_pos < _src.Length && _src[_pos] != '}')
        {
            if (Peek("var "))
            {
                state.Variables.Add(ParseVarDecl());
            }
            else if (Peek("on "))
            {
                state.Transitions.Add(ParseTransition());
            }
            else if (Peek("after "))
            {
                state.Timers.Add(ParseTimer());
            }
            else if (Peek("enter ") || Peek("exit "))
            {
                state.Actions.Add(ParseAction());
            }
            else if (Peek("state ") || Peek("base "))
            {
                state.NestedStates.Add(ParseStateDef());
            }
            else if (Peek("always"))
            {
                state.Transitions.Add(ParseAlways());
            }
            else
            {
                throw Err($"Unexpected in state '{state.Name}': '{PeekWord()}'");
            }
            SkipWs();
        }

        Expect("}");
        return state;
    }

    private VariableNode ParseVarDecl()
    {
        Expect("var ");
        var name = ParseWord();
        SkipWs();
        Expect(":");
        SkipWs();
        var type = ParseType();
        string? def = null;
        SkipWs();
        if (_pos < _src.Length && _src[_pos] == '=')
        {
            _pos++;
            SkipWs();
            int start = _pos;
            while (_pos < _src.Length && !char.IsWhiteSpace(_src[_pos]) && _src[_pos] != '{' && _src[_pos] != '}' && _src[_pos] != ',')
                _pos++;
            def = _src[start.._pos];
        }
        return new VariableNode { Name = name, Type = type, DefaultValue = def };
    }

    private TransitionNode ParseTransition()
    {
        Expect("on ");
        SkipWs();

        // always
        if (Peek("always"))
        {
            Expect("always");
            var t = new TransitionNode { EventName = "always", IsAlways = true };
            SkipWs();
            if (_pos < _src.Length && _src[_pos] == '-')
            {
                Expect("->");
                SkipWs();
                t.Target = ParseWord();
            }
            return t;
        }

        if (Peek("enter"))
        {
            Expect("enter");
            SkipWs();
            Expect("->");
            SkipWs();
            var t = new TransitionNode { EventName = "enter", IsEnterAuto = true, Target = ParseWord() };
            return t;
        }

        // async?
        bool isAsync = false;
        if (Peek("async"))
        {
            Expect("async");
            isAsync = true;
            SkipWs();
        }

        // signal?
        bool isSignal = false;
        string? signalName = null;
        if (Peek("signal"))
        {
            Expect("signal");
            isSignal = true;
            SkipWs();
            var m = Regex.Match(_src[_pos..], @"^""([^""]*)""");
            if (m.Success)
            {
                signalName = m.Groups[1].Value;
                _pos += m.Length;
            }
            else
            {
                signalName = ParseWord();
            }
        }

        var eventName = isSignal ? signalName! : ParseWord();
        SkipWs();

        // Parameters ( ... )
        var parameters = new List<ParamNode>();
        if (_pos < _src.Length && _src[_pos] == '(')
        {
            _pos++;
            SkipWs();
            while (_pos < _src.Length && _src[_pos] != ')')
            {
                var pName = ParseWord();
                SkipWs();
                Expect(":");
                SkipWs();
                var pType = ParseType();
                parameters.Add(new ParamNode { Name = pName, Type = pType });
                SkipWs();
                if (_pos < _src.Length && _src[_pos] == ',')
                {
                    _pos++;
                    SkipWs();
                }
            }
            Expect(")");
            SkipWs();
        }

        // Guard [ ... ]
        string? guard = null;
        if (_pos < _src.Length && _src[_pos] == '[')
        {
            _pos++;
            int depth = 1;
            int start = _pos;
            while (_pos < _src.Length && depth > 0)
            {
                if (_src[_pos] == '[') depth++;
                else if (_src[_pos] == ']') depth--;
                if (depth > 0) _pos++;
            }
            guard = _src[start.._pos].Trim();
            _pos++;
            SkipWs();
        }

        // -> Target
        string target = "";
        if (_pos < _src.Length && _src[_pos] == '-')
        {
            Expect("->");
            SkipWs();
            target = ParseWord();
            // Handle generics in target like Inventory<T>
            SkipWs();
            if (_pos < _src.Length && _src[_pos] == '<')
            {
                int gs = _pos;
                while (_pos < _src.Length && _src[_pos] != '>') _pos++;
                if (_pos < _src.Length) _pos++;
                target = _src[gs.._pos];
            }
        }
        SkipWs();

        // Body { ... }
        string? body = null;
        if (_pos < _src.Length && _src[_pos] == '{')
        {
            body = ExtractBracedBlock();
        }

        var trans = new TransitionNode
        {
            EventName = eventName,
            IsSignal = isSignal,
            SignalName = isSignal ? signalName : null,
            Guard = guard,
            Target = target,
            Body = body,
            IsAsync = isAsync
        };
        trans.Parameters.AddRange(parameters);
        return trans;
    }

    private TransitionNode ParseAlways()
    {
        Expect("always");
        SkipWs();
        Expect("->");
        SkipWs();
        var target = ParseWord();
        return new TransitionNode { EventName = "always", IsAlways = true, Target = target };
    }

    private TimerNode ParseTimer()
    {
        Expect("after ");
        var duration = ParseWord();
        SkipWs();

        string? guard = null;
        if (_pos < _src.Length && _src[_pos] == '[')
        {
            _pos++;
            int start = _pos;
            while (_pos < _src.Length && _src[_pos] != ']') _pos++;
            guard = _src[start.._pos].Trim();
            _pos++;
            SkipWs();
        }

        Expect("->");
        SkipWs();
        var target = ParseWord();
        return new TimerNode { Duration = duration, Guard = guard, Target = target };
    }

    private ActionNode ParseAction()
    {
        var prefix = _pos + 4 <= _src.Length && _src.Substring(_pos, 4) == "exit" ? "exit" : "enter";
        _pos += prefix.Length;
        SkipWs();
        var body = ExtractBracedBlock();
        return new ActionNode
        {
            Type = prefix == "enter" ? ActionType.Enter : ActionType.Exit,
            Body = body ?? ""
        };
    }

    private ParallelBlockNode ParseParallel()
    {
        Expect("parallel ");
        var name = ParseWord();
        SkipWs();
        Expect("{");
        var par = new ParallelBlockNode { Name = name };
        SkipWs();
        while (_pos < _src.Length && _src[_pos] != '}')
        {
            if (Peek("state ") || Peek("base "))
                par.States.Add(ParseStateDef());
            else
                throw Err($"Unexpected in parallel '{name}'");
            SkipWs();
        }
        Expect("}");
        return par;
    }

    // --- Helpers ---

    private string ParseWord()
    {
        SkipWs();
        int start = _pos;
        while (_pos < _src.Length && (char.IsLetterOrDigit(_src[_pos]) || _src[_pos] == '_'))
            _pos++;
        if (_pos == start) throw Err($"Expected identifier at position {_pos}");
        return _src[start.._pos];
    }

    private string ParseType()
    {
        var name = ParseWord();
        SkipWs();
        if (_pos < _src.Length && _src[_pos] == '[')
        {
            _pos++;
            Expect("]");
            name += "[]";
        }
        return name;
    }

    private string? ExtractBracedBlock()
    {
        if (_pos >= _src.Length || _src[_pos] != '{') return null;
        _pos++;
        int depth = 1;
        int start = _pos;
        while (_pos < _src.Length && depth > 0)
        {
            if (_src[_pos] == '{') depth++;
            else if (_src[_pos] == '}') depth--;
            if (depth > 0) _pos++;
        }
        var body = _src[start.._pos].Trim();
        _pos++;
        return body;
    }

    private void SkipWs()
    {
        while (_pos < _src.Length && char.IsWhiteSpace(_src[_pos]))
            _pos++;
    }

    private bool Peek(string s)
    {
        if (_pos + s.Length > _src.Length) return false;
        for (int i = 0; i < s.Length; i++)
            if (_src[_pos + i] != s[i]) return false;
        // Make sure we're at a word boundary if s ends with a letter
        if (char.IsLetterOrDigit(s[^1]))
        {
            int next = _pos + s.Length;
            if (next < _src.Length && (char.IsLetterOrDigit(_src[next]) || _src[next] == '_'))
                return false;
        }
        return true;
    }

    private string PeekWord()
    {
        SkipWs();
        int start = _pos;
        while (_pos < _src.Length && (char.IsLetterOrDigit(_src[_pos]) || _src[_pos] == '_'))
            _pos++;
        var word = _src[start.._pos];
        _pos = start;
        return word != "" ? word : (_pos < _src.Length ? _src[_pos].ToString() : "(eof)");
    }

    private void Expect(string s)
    {
        SkipWs();
        if (_pos + s.Length > _src.Length || _src[_pos..(_pos + s.Length)] != s)
            throw Err($"Expected '{s}' at position {_pos}, got '{_src.Substring(_pos, Math.Min(10, _src.Length - _pos))}'");
        _pos += s.Length;
    }

    private static string PeekN(int n) => ""; // unused overload placeholder

    private static string ReadUntilWsOr(string s, char[] terminators)
    {
        int i = 0;
        while (i < s.Length && !char.IsWhiteSpace(s[i]) && !terminators.Contains(s[i]))
            i++;
        return s[..i];
    }

    private ParseException Err(string msg) { throw new ParseException(msg); }

    private static string StripComments(string src)
    {
        src = Regex.Replace(src, @"//.*", "");
        return src;
    }
}

public class ParseException : Exception
{
    public ParseException(string msg) : base(msg) { }
}
