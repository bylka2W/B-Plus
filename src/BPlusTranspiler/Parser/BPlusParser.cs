using System.Text.RegularExpressions;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Parser;

public class BPlusParser
{
    private string[] _lines = Array.Empty<string>();
    private int _pos;

    public ProgramNode Parse(string source)
    {
        _lines = source.Split('\n');
        _pos = 0;
        var program = new ProgramNode();

        while (_pos < _lines.Length)
        {
            var line = StripLine(_lines[_pos]);
            if (line == "")
            {
                _pos++;
                continue;
            }

            if (line.StartsWith("import "))
            {
                var m = Regex.Match(line, @"^import\s+""([^""]+)""\s*$");
                if (!m.Success)
                    throw new ParseException($"Invalid import at line {_pos + 1}");
                program.Imports.Add(new ImportNode { Path = m.Groups[1].Value });
                _pos++;
            }
            else if (line.StartsWith("state "))
            {
                program.States.Add(ParseState());
            }
            else
            {
                throw new ParseException($"Unexpected token at line {_pos + 1}: {line}");
            }
        }

        return program;
    }

    private StateNode ParseState()
    {
        var state = new StateNode();
        var header = StripLine(_lines[_pos]);
        var m = Regex.Match(header, @"^state\s+(\w+)\s*\{$");
        if (!m.Success)
            throw new ParseException($"Invalid state declaration at line {_pos + 1}");
        state.Name = m.Groups[1].Value;
        _pos++;

        while (_pos < _lines.Length)
        {
            var line = StripLine(_lines[_pos]);
            if (line == "")
            {
                _pos++;
                continue;
            }
            if (line == "}")
            {
                _pos++;
                return state;
            }

            if (line.StartsWith("on "))
                state.Transitions.Add(ParseTransition());
            else if (line.StartsWith("enter ") || line.StartsWith("exit "))
                state.Actions.Add(ParseAction());
            else
                throw new ParseException($"Unexpected token inside state '{state.Name}' at line {_pos + 1}: {line}");
        }

        throw new ParseException($"Unclosed state '{state.Name}'");
    }

    private TransitionNode ParseTransition()
    {
        var line = StripLine(_lines[_pos]);
        var m = Regex.Match(line, @"^on\s+(\w+)\s*(?:\[([^\]]+)\])?\s*->\s*(\w+)\s*$");
        if (!m.Success)
            throw new ParseException($"Invalid transition at line {_pos + 1}");
        _pos++;
        return new TransitionNode
        {
            Event = m.Groups[1].Value,
            Guard = m.Groups[2].Success ? m.Groups[2].Value : null,
            Target = m.Groups[3].Value
        };
    }

    private ActionNode ParseAction()
    {
        var line = StripLine(_lines[_pos]);
        var m = Regex.Match(line, @"^(enter|exit)\s+\{(.*)\}$");
        if (!m.Success)
            throw new ParseException($"Invalid action at line {_pos + 1}");
        _pos++;
        return new ActionNode
        {
            Type = m.Groups[1].Value == "enter" ? ActionType.Enter : ActionType.Exit,
            Body = m.Groups[2].Value.Trim()
        };
    }

    private static string StripLine(string raw)
    {
        var line = raw.Trim();
        var idx = line.IndexOf("//", StringComparison.Ordinal);
        if (idx >= 0)
            line = line[..idx].TrimEnd();
        return line;
    }
}

public class ParseException : Exception
{
    public ParseException(string msg) : base(msg) { }
}