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
            else if (_src[_pos] == '#')
            {
                var dir = ParseDirective();
                program.Directives.Add(dir);
                HandleMemoryDirective(program, dir);
            }
            else if (Peek("use cxx"))
            {
                program.UseCxxDecls.Add(ParseUseCxx());
            }
            else if (Peek("extern"))
            {
                program.ExternCppFns.Add(ParseExternCppFn());
            }
            else if (_src[_pos] == '@')
            {
                var annotations = ParseAnnotations();
                SkipWs();
                if (Peek("kernel"))
                    program.Kernels.Add(ParseKernel(annotations));
                else if (Peek("pipeline"))
                    program.Pipelines.Add(ParsePipeline(annotations));
                else if (Peek("entry"))
                    program.Entries.Add(ParseEntry());
                else if (Peek("state ") || Peek("base "))
                {
                    var state = ParseStateDef();
                    if (annotations.Any(a => a.Name == "stream"))
                        state.IsStream = true;
                    program.States.Add(state);
                }
                else
                {
                    if (_pos < _src.Length && _src[_pos] == '@')
                    {
                        program.StandaloneAnnotations.AddRange(annotations);
                    }
                    else
                    {
                        var vd = ParseAnnotatedVar(annotations);
                        if (vd != null) program.VarDecls.Add(vd);
                    }
                }
            }
            else if (Peek("kernel"))
            {
                program.Kernels.Add(ParseKernel(new List<Annotation>()));
            }
            else if (Peek("pipeline"))
            {
                program.Pipelines.Add(ParsePipeline(new List<Annotation>()));
            }
            else if (Peek("entry"))
            {
                program.Entries.Add(ParseEntry());
            }
            else if (Peek("context"))
            {
                program.Context = ParseContext();
            }
            // Bare variable declaration: name: Type = value
            else if (IsVarDeclStart())
            {
                var vd = ParseAnnotatedVar(new List<Annotation>());
                if (vd != null) program.VarDecls.Add(vd);
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
            else if (_src[_pos] == '@')
            {
                // Parse annotations for next element (@hot, @cold, @fast_path)
                var annots = ParseAnnotations();
                SkipWs();
                // Apply to next transition or var
                if (Peek("on ") || Peek("always"))
                {
                    TransitionNode? trans = null;
                    if (Peek("on "))
                        trans = ParseTransition();
                    else
                        trans = ParseAlways();
                    if (trans != null)
                    {
                        foreach (var a in annots)
                            ApplyTransitionAnnotation(trans, a);
                        state.Transitions.Add(trans);
                    }
                }
                else if (Peek("var "))
                {
                    var vd = ParseVarDecl();
                    if (vd != null && annots.Any(a => a.Name == "fast_path"))
                        vd.IsFastPath = true;
                    if (vd != null) state.Variables.Add(vd);
                }
                else
                {
                    throw Err($"Expected transition or var after annotation in state '{state.Name}'");
                }
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

    private void ApplyTransitionAnnotation(TransitionNode trans, Annotation a)
    {
        switch (a.Name)
        {
            case "hot":
                if (a.Args.TryGetValue("_val", out var hotVal) && double.TryParse(hotVal, out var hotW))
                    trans.HotWeight = hotW;
                else if (a.Args.TryGetValue("weight", out var hotW2) && double.TryParse(hotW2, out var hotW3))
                    trans.HotWeight = hotW3;
                else
                    trans.HotWeight = 0.9; // default hot
                break;
            case "cold":
                if (a.Args.TryGetValue("_val", out var coldVal) && double.TryParse(coldVal, out var coldW))
                    trans.HotWeight = coldW;
                else if (a.Args.TryGetValue("weight", out var coldW2) && double.TryParse(coldW2, out var coldW3))
                    trans.HotWeight = coldW3;
                else
                    trans.HotWeight = 0.1; // default cold
                break;
        }
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

        string eventName;
        // Handle quoted char event names: on 'x' -> Target, on '\n' -> Target
        if (_pos < _src.Length && _src[_pos] == '\'')
        {
            _pos++; // skip opening '
            if (_pos < _src.Length && _src[_pos] != '\'')
            {
                if (_src[_pos] == '\\' && _pos + 1 < _src.Length)
                {
                    // Escape sequence: \n, \r, \t, \\, \', etc.
                    _pos++;
                    eventName = _src[_pos] switch
                    {
                        'n' => "\n",
                        'r' => "\r",
                        't' => "\t",
                        '\\' => "\\",
                        '\'' => "'",
                        _ => "\\" + _src[_pos]
                    };
                    _pos++;
                }
                else
                {
                    eventName = _src[_pos].ToString();
                    _pos++;
                }
            }
            else
                eventName = "";
            if (_pos < _src.Length && _src[_pos] == '\'') _pos++; // skip closing '
        }
        else
        {
            eventName = isSignal ? signalName! : ParseWord();
        }
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

    // ════════════════════════════════════════
    // NEW v2.2+ parsing methods
    // ════════════════════════════════════════

    private Directive ParseDirective()
    {
        Expect("#");
        var name = ParseWord();
        // Only skip spaces/tabs, NOT newlines (to avoid consuming next line)
        while (_pos < _src.Length && (_src[_pos] == ' ' || _src[_pos] == '\t')) _pos++;
        var value = "";
        if (_pos < _src.Length && _src[_pos] != '\n' && _src[_pos] != '\r')
        {
            int start = _pos;
            while (_pos < _src.Length && _src[_pos] != '\n' && _src[_pos] != '\r') _pos++;
            value = _src[start.._pos].Trim();
        }
        return new Directive { Name = name, Value = value };
    }

    private UseCxxDecl ParseUseCxx()
    {
        Expect("use cxx");
        SkipWs();
        Expect("{");
        var decl = new UseCxxDecl();
        SkipWs();
        while (_pos < _src.Length && _src[_pos] != '}')
        {
            var m = Regex.Match(_src[_pos..], @"^""([^""]*)""");
            if (!m.Success) throw Err("Expected string literal in use cxx");
            decl.Headers.Add(m.Groups[1].Value);
            _pos += m.Length;
            SkipWs();
            if (_pos < _src.Length && _src[_pos] == ',') { _pos++; SkipWs(); }
        }
        Expect("}");
        return decl;
    }

    private ExternCppFnDecl ParseExternCppFn()
    {
        Expect("extern");
        SkipWs();
        Expect("\"C++\"");
        SkipWs();
        Expect("fn");
        SkipWs();
        var decl = new ExternCppFnDecl();
        decl.Name = ParseWord();
        SkipWs();
        Expect("(");
        SkipWs();
        while (_pos < _src.Length && _src[_pos] != ')')
        {
            var pName = ParseWord();
            SkipWs();
            Expect(":");
            SkipWs();
            // Consume raw C++ type until ',' or ')'
            int start = _pos;
            int depth = 0;
            while (_pos < _src.Length)
            {
                if (_src[_pos] == '(' || _src[_pos] == '<') depth++;
                else if (_src[_pos] == ')' && depth == 0) break;
                else if (_src[_pos] == '>' && depth == 0) break;
                else if (_src[_pos] == ',' && depth == 0) break;
                _pos++;
            }
            var rawType = _src[start.._pos].Trim();
            decl.Parameters.Add(new KernelParam { Name = pName, Type = new SimpleType { Name = rawType } });
            SkipWs();
            if (_pos < _src.Length && _src[_pos] == ',') { _pos++; SkipWs(); }
        }
        Expect(")");
        SkipWs();
        if (_pos < _src.Length && _src[_pos] == '-')
        {
            Expect("->");
            SkipWs();
            // Consume rest of return type
            int start = _pos;
            while (_pos < _src.Length && _src[_pos] != '\n' && _src[_pos] != '\r') _pos++;
            decl.ReturnType = _src[start.._pos].Trim();
        }
        return decl;
    }

    private List<Annotation> ParseAnnotations()
    {
        var list = new List<Annotation>();
        while (_pos < _src.Length && _src[_pos] == '@')
        {
            _pos++;
            var a = new Annotation();
            a.Name = ParseWord();
            SkipWs();
            if (_pos < _src.Length && _src[_pos] == '(')
            {
                _pos++;
                SkipWs();
                while (_pos < _src.Length && _src[_pos] != ')')
                {
                    if (char.IsDigit(_src[_pos]) || _src[_pos] == '-' || _src[_pos] == '.')
                    {
                        // Positional numeric value: @hot(0.9)
                        var numVal = ParseAnnotationValue();
                        a.Args["_val"] = numVal;
                    }
                    else
                    {
                        var key = ParseWord();
                        SkipWs();
                        if (_pos < _src.Length && _src[_pos] == ':')
                        {
                            _pos++;
                            SkipWs();
                            var val = ParseAnnotationValue();
                            if (_pos < _src.Length && _src[_pos] == '(')
                            {
                                // Handle nested like `switch_policy: quality_feedback(ssim, 0.92)`
                                _pos++;
                                var nestStart = _pos;
                                int depth = 1;
                                while (_pos < _src.Length && depth > 0)
                                {
                                    if (_src[_pos] == '(') depth++;
                                    else if (_src[_pos] == ')') depth--;
                                    if (depth > 0) _pos++;
                                }
                                val += "(" + _src[nestStart.._pos] + ")";
                                _pos++;
                            }
                            a.Args[key] = val;
                        }
                        else
                        {
                            a.Args["_val"] = key;
                        }
                    }
                    SkipWs();
                    if (_pos < _src.Length && _src[_pos] == ',') { _pos++; SkipWs(); }
                }
                Expect(")");
            }
            list.Add(a);
            SkipWs();
        }
        return list;
    }

    private VarDecl? ParseAnnotatedVar(List<Annotation> annotations)
    {
        var vd = new VarDecl();
        foreach (var a in annotations)
        {
            var ma = new MemoryAnnotation { Name = a.Name };
            foreach (var kv in a.Args) ma.Args[kv.Key] = kv.Value;
            vd.MemoryAnnotations.Add(ma);
        }
        vd.Name = ParseWord();
        SkipWs();
        if (_pos < _src.Length && _src[_pos] == ':')
        {
            _pos++;
            SkipWs();
            while (_pos < _src.Length && _src[_pos] == '@')
            {
                var ma = ParseSingleMemoryAnnotation();
                vd.MemoryAnnotations.Add(ma);
                SkipWs();
            }
            vd.Type = ParseBPlusType();
        }
        SkipWs();
        if (_pos < _src.Length && _src[_pos] == '=')
        {
            _pos++;
            SkipWs();
            int start = _pos;
            while (_pos < _src.Length && _src[_pos] != '\n' && _src[_pos] != ';' && _src[_pos] != '}')
                _pos++;
            vd.Init = _src[start.._pos].Trim();
        }
        return vd;
    }

    private MemoryAnnotation ParseSingleMemoryAnnotation()
    {
        var ma = new MemoryAnnotation();
        if (_pos < _src.Length && _src[_pos] == '@')
        {
            _pos++;
            ma.Name = ParseWord();
            SkipWs();
            if (_pos < _src.Length && _src[_pos] == '(')
            {
                _pos++;
                SkipWs();
                while (_pos < _src.Length && _src[_pos] != ')')
                {
                    var key = ParseWord();
                    SkipWs();
                    if (_pos < _src.Length && _src[_pos] == ':')
                    {
                        _pos++;
                        SkipWs();
                        var val = ParseWord();
                        ma.Args[key] = val;
                    }
                    else
                    {
                        ma.Args["_val"] = key;
                    }
                    SkipWs();
                    if (_pos < _src.Length && _src[_pos] == ',') { _pos++; SkipWs(); }
                }
                Expect(")");
            }
        }
        return ma;
    }

    private void HandleMemoryDirective(ProgramNode program, Directive dir)
    {
        switch (dir.Name)
        {
            case "parser":
                program.StreamMode = BPlusStreamMode.Parser;
                return;
        }

        program.Memory ??= new MemoryConfig();
        switch (dir.Name)
        {
            case "memory":
                program.Memory.Mode = dir.Value.ToLower() switch
                {
                    "smart" => BPlusMemoryMode.Smart,
                    "precise" => BPlusMemoryMode.Precise,
                    "ultra" => BPlusMemoryMode.Ultra,
                    "comptime" => BPlusMemoryMode.Comptime,
                    _ => BPlusMemoryMode.Smart
                };
                break;
            case "vram":
                program.Memory.VramBudget = dir.Value;
                break;
            case "ram":
                program.Memory.RamBudget = dir.Value;
                break;
            case "cache":
                program.Memory.CacheAuto = dir.Value.ToLower() == "auto";
                break;
            case "defrag":
                program.Memory.Defrag = dir.Value.ToLower() == "auto";
                break;
            case "streaming":
                program.Memory.Streaming ??= new StreamingConfig();
                // Parse "priority: camera" etc.
                var parts = dir.Value.Split(':', 2);
                if (parts.Length == 2)
                    program.Memory.Streaming.Priority = parts[1].Trim();
                break;
        }
    }

    private KernelDecl ParseKernel(List<Annotation> annotations)
    {
        Expect("kernel");
        SkipWs();
        var k = new KernelDecl();
        k.Annotations.AddRange(annotations);
        // Extract SIMD annotations
        foreach (var a in annotations)
        {
            switch (a.Name)
            {
                case "simd_width":
                    if (a.Args.TryGetValue("_val", out var sw) && int.TryParse(sw, out var swi))
                        k.SimdWidth = swi;
                    break;
                case "simd_unroll":
                    if (a.Args.TryGetValue("_val", out var su) && int.TryParse(su, out var sui))
                        k.SimdUnroll = sui;
                    break;
                case "simd_gather":
                    k.SimdGather = true;
                    break;
            }
        }
        k.Name = ParseWord();
        SkipWs();
        Expect("(");
        SkipWs();
        while (_pos < _src.Length && _src[_pos] != ')')
        {
            k.Parameters.Add(ParseKernelParam());
            SkipWs();
            if (_pos < _src.Length && _src[_pos] == ',') { _pos++; SkipWs(); }
        }
        Expect(")");
        SkipWs();
        // Optional -> Output
        if (_pos < _src.Length && _src[_pos] == '-')
        {
            Expect("->");
            SkipWs();
            k.OutputParam = new KernelParam { Name = "output", Type = ParseBPlusType(), IsOutput = true };
        }
        SkipWs();
        // Optional needs: / gives: / touches: blocks
        ParseNeedsGivesTouches(k);
        SkipWs();
        // body: pipeline_expr
        if (Peek("body"))
        {
            Expect("body");
            SkipWs();
            Expect(":");
            SkipWs();
            k.Body = ParsePipelineExpr();
        }
        return k;
    }

    private KernelParam ParseKernelParam()
    {
        var p = new KernelParam();
        // Handle annotations on params
        if (_pos < _src.Length && _src[_pos] == '@')
            ParseAnnotations();
        p.Name = ParseWord();
        SkipWs();
        Expect(":");
        SkipWs();
        // Handle annotations before type name
        if (_pos < _src.Length && _src[_pos] == '@')
            ParseAnnotations();
        p.Type = ParseBPlusType();
        return p;
    }

    private PipelineExpr ParsePipelineExpr(bool sourceRequired = true)
    {
        var expr = new PipelineExpr();
        if (sourceRequired)
        {
            expr.Source = ParseWord();
            SkipWs();
        }
        bool firstInBlock = !sourceRequired;
        while (true)
        {
            if (firstInBlock)
            {
                firstInBlock = false; // first op in inner block: no |> needed
            }
            else if (_pos < _src.Length && _src[_pos] == '|' && _pos + 1 < _src.Length && _src[_pos + 1] == '>')
            {
                _pos += 2; // skip |>
                SkipWs();
            }
            else
                break;
            var op = new PipelineOp();
            op.Name = ParseWord();
            SkipWs();
            // Parse optional (args)
            if (_pos < _src.Length && _src[_pos] == '(')
            {
                _pos++;
                SkipWs();
                while (_pos < _src.Length && _src[_pos] != ')')
                {
                    int argStart = _pos;
                    while (_pos < _src.Length && _src[_pos] != ',' && _src[_pos] != ')')
                        _pos++;
                    var arg = _src[argStart.._pos].Trim();
                    if (arg != "") op.Args.Add(arg);
                    SkipWs();
                    if (_pos < _src.Length && _src[_pos] == ',') { _pos++; SkipWs(); }
                }
                Expect(")");
                SkipWs();
            }
            // Parse optional { body } block (for if/for/while)
            if (_pos < _src.Length && _src[_pos] == '{')
            {
                _pos++; SkipWs();
                op.NestedBody = ParsePipelineExpr(false); // no source — inherits from outer
                SkipWs();
                Expect("}");
                SkipWs();
                // Parse optional else { body } for if
                if (op.Name == "if" && _pos + 3 < _src.Length &&
                    _src[_pos..(_pos + 4)] == "else")
                {
                    _pos += 4; SkipWs();
                    if (_pos < _src.Length && _src[_pos] == '{')
                    {
                        _pos++; SkipWs();
                        op.ElseBody = ParsePipelineExpr(false);
                        SkipWs();
                        Expect("}");
                        SkipWs();
                    }
                }
            }
            expr.Operations.Add(op);
            SkipWs();
        }
        SkipWs();
        if (_pos + 1 < _src.Length && _src[_pos] == '>' && _src[_pos + 1] == '>')
        {
            _pos += 2;
            SkipWs();
            expr.OutputTarget = ParseWord();
        }
        return expr;
    }

    private void ParseNeedsGivesTouches(KernelDecl k)
    {
        while (_pos < _src.Length)
        {
            if (Peek("needs"))
            {
                Expect("needs");
                SkipWs();
                Expect(":");
                SkipWs();
                while (_pos < _src.Length && _src[_pos] != '\n' && !Peek("gives") && !Peek("touches") && !Peek("body"))
                {
                    int start = _pos;
                    while (_pos < _src.Length && _src[_pos] != '\n') _pos++;
                    var line = _src[start.._pos].Trim();
                    if (line != "") k.Needs.Add(line);
                    SkipWs();
                }
            }
            else if (Peek("gives"))
            {
                Expect("gives");
                SkipWs();
                Expect(":");
                SkipWs();
                while (_pos < _src.Length && _src[_pos] != '\n' && !Peek("touches") && !Peek("body") && !Peek("needs"))
                {
                    int start = _pos;
                    while (_pos < _src.Length && _src[_pos] != '\n') _pos++;
                    var line = _src[start.._pos].Trim();
                    if (line != "") k.Gives.Add(line);
                    SkipWs();
                }
            }
            else if (Peek("touches"))
            {
                Expect("touches");
                SkipWs();
                Expect(":");
                SkipWs();
                var t = new TouchesBlock();
                while (_pos < _src.Length && _src[_pos] != '\n' && !Peek("body") && !Peek("needs") && !Peek("gives"))
                {
                    if (Peek("reads"))
                    {
                        Expect("reads");
                        SkipWs();
                        if (_pos < _src.Length && _src[_pos] == '[')
                        {
                            _pos++;
                            SkipWs();
                            while (_pos < _src.Length && _src[_pos] != ']')
                            {
                                t.Reads.Add(ParseWord());
                                SkipWs();
                                if (_pos < _src.Length && _src[_pos] == ',') { _pos++; SkipWs(); }
                            }
                            if (_pos < _src.Length) _pos++; // skip ]
                        }
                    }
                    else if (Peek("writes"))
                    {
                        Expect("writes");
                        SkipWs();
                        if (_pos < _src.Length && _src[_pos] == '[')
                        {
                            _pos++;
                            SkipWs();
                            while (_pos < _src.Length && _src[_pos] != ']')
                            {
                                t.Writes.Add(ParseWord());
                                SkipWs();
                                if (_pos < _src.Length && _src[_pos] == ',') { _pos++; SkipWs(); }
                            }
                            if (_pos < _src.Length) _pos++; // skip ]
                        }
                    }
                    else if (Peek("dx12"))
                    {
                        Expect("dx12");
                        SkipWs();
                        Expect(":");
                        SkipWs();
                        t.Dx12 = ParseWord();
                    }
                    else
                        break;
                    // Consume comma separator between touches entries
                    if (_pos < _src.Length && _src[_pos] == ',') { _pos++; SkipWs(); }
                    SkipWs();
                }
                k.Touches = t;
            }
            else break;
            SkipWs();
        }
    }

    private BPlusType ParseBPlusType()
    {
        var name = ParseWord();
        SkipWs();
        switch (name)
        {
            case "Image":
            {
                Expect("[");
                var h = ConsumeUntilOr(",");
                SkipWs();
                Expect(",");
                SkipWs();
                var w = ConsumeUntilOr("]");
                var img = new ImageType { H = h, W = w };
                SkipWs();
                if (_pos < _src.Length && _src[_pos] == ',')
                {
                    _pos++;
                    SkipWs();
                    img.Channels = int.Parse(ParseWord());
                }
                Expect("]");
                return img;
            }
            case "ConvWeights":
            {
                Expect("[");
                var cw = new ConvWeightsType();
                while (_pos < _src.Length && _src[_pos] != ']')
                {
                    cw.Dimensions.Add(int.Parse(ParseWord()));
                    SkipWs();
                    if (_pos < _src.Length && _src[_pos] == ',') { _pos++; SkipWs(); }
                }
                Expect("]");
                return cw;
            }
            case "stream":
            {
                Expect("<");
                var elem = ParseBPlusType();
                Expect(">");
                return new StreamType { ElementType = elem };
            }
            case "MotionVec":
            {
                Expect("[");
                var h = ConsumeUntilOr(",");
                SkipWs();
                Expect(",");
                SkipWs();
                var w = ConsumeUntilOr("]");
                Expect("]");
                return new MotionVecType { H = h, W = w };
            }
            default:
            {
                var st = new SimpleType { Name = name };
                SkipWs();
                if (_pos < _src.Length && _src[_pos] == '[')
                {
                    _pos++;
                    var size = ConsumeUntilOr("]");
                    Expect("]");
                    return new ArrayType { ElementType = st, Size = size };
                }
                return st;
            }
        }
    }

    private PipelineDecl ParsePipeline(List<Annotation> annotations)
    {
        Expect("pipeline");
        SkipWs();
        var p = new PipelineDecl();
        p.Annotations.AddRange(annotations);
        p.Name = ParseWord();
        SkipWs();
        Expect("(");
        SkipWs();
        while (_pos < _src.Length && _src[_pos] != ')')
        {
            p.Parameters.Add(ParseKernelParam());
            SkipWs();
            if (_pos < _src.Length && _src[_pos] == ',') { _pos++; SkipWs(); }
        }
        Expect(")");
        SkipWs();
        if (_pos < _src.Length && _src[_pos] == '-')
        {
            Expect("->");
            SkipWs();
            p.ReturnType = ParseBPlusType();
        }
        SkipWs();
        // Parse steps
        while (_pos < _src.Length && Peek("step"))
        {
            Expect("step");
            SkipWs();
            var stepName = ParseWord();
            SkipWs();
            Expect("=");
            SkipWs();
            var kernelName = ParseWord();
            SkipWs();
            var step = new PipelineStep { Name = stepName, KernelName = kernelName };
            if (_pos < _src.Length && _src[_pos] == '(')
            {
                _pos++;
                SkipWs();
                while (_pos < _src.Length && _src[_pos] != ')')
                {
                    int argStart = _pos;
                    while (_pos < _src.Length && _src[_pos] != ',' && _src[_pos] != ')')
                        _pos++;
                    var arg = _src[argStart.._pos].Trim();
                    if (arg != "") step.Args.Add(arg);
                    SkipWs();
                    if (_pos < _src.Length && _src[_pos] == ',') { _pos++; SkipWs(); }
                }
                Expect(")");
            }
            p.Steps.Add(step);
            SkipWs();
        }
        // Telemetry block
        if (Peek("telemetry"))
        {
            Expect("telemetry");
            SkipWs();
            Expect(":");
            SkipWs();
            var tb = new TelemetryBlock();
            while (_pos < _src.Length && _src[_pos] != '\n' && Peek("log"))
            {
                Expect("log");
                SkipWs();
                var entry = new TelemetryEntry();
                entry.LogSource = ParseWord();
                SkipWs();
                Expect("->");
                SkipWs();
                var m = Regex.Match(_src[_pos..], @"^""([^""]*)""");
                if (m.Success)
                {
                    entry.FilePath = m.Groups[1].Value;
                    _pos += m.Length;
                }
                else
                    entry.FilePath = ParseWord();
                tb.Entries.Add(entry);
                SkipWs();
            }
            p.Telemetry = tb;
        }
        return p;
    }

    private EntryDecl ParseEntry()
    {
        Expect("entry");
        SkipWs();
        var e = new EntryDecl();
        e.Name = ParseWord();
        SkipWs();
        Expect("(");
        SkipWs();
        Expect(")");
        SkipWs();
        // Optional return type
        if (_pos < _src.Length && _src[_pos] == '-')
        {
            Expect("->");
            SkipWs();
            e.ReturnType = ParseWord();
        }
        // Body is everything until end or next top-level construct
        if (_pos < _src.Length && _src[_pos] == '\n')
        {
            _pos++;
            SkipWs();
        }
        // Parse body lines
        while (_pos < _src.Length && !Peek("state ") && !Peek("kernel") && !Peek("pipeline")
               && !Peek("entry") && !Peek("enum ") && !Peek("import ") && !Peek("context")
               && !Peek("parallel ") && !Peek("use cxx") && !Peek("extern") && _src[_pos] != '#')
        {
            int start = _pos;
            while (_pos < _src.Length && _src[_pos] != '\n') _pos++;
            var line = _src[start.._pos].Trim();
            if (line != "") e.BodyLines.Add(line);
            if (_pos < _src.Length) _pos++;
            SkipWs();
        }
        return e;
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

    private string ConsumeUntilOr(string terminators)
    {
        int start = _pos;
        while (_pos < _src.Length && !terminators.Contains(_src[_pos]))
            _pos++;
        return _src[start.._pos].Trim();
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

    private string ParseAnnotationValue()
    {
        if (_pos < _src.Length && _src[_pos] == '"')
        {
            _pos++;
            int start = _pos;
            while (_pos < _src.Length && _src[_pos] != '"')
                _pos++;
            var val = _src[start.._pos];
            _pos++;
            return val;
        }
        if (_pos < _src.Length && (char.IsDigit(_src[_pos]) || (_src[_pos] == '-' && _pos + 1 < _src.Length && char.IsDigit(_src[_pos + 1]))))
        {
            int start = _pos;
            // Handle negative numbers, floats, hex, etc.
            if (_src[_pos] == '-') _pos++;
            while (_pos < _src.Length && (char.IsLetterOrDigit(_src[_pos]) || _src[_pos] == '_' || _src[_pos] == '.'))
                _pos++;
            return _src[start.._pos];
        }
        return ParseWord();
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

    private bool IsVarDeclStart()
    {
        // Check if current position looks like "name: Type" (not state, kernel, etc.)
        var saved = _pos;
        try
        {
            var word = ParseWord();
            SkipWs();
            if (_pos < _src.Length && _src[_pos] == ':')
            {
                // Check it's not a state base class like "state Foo : Bar"
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
        finally { _pos = saved; }
    }

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
        src = Regex.Replace(src, @"--.*", "");
        return src;
    }
}

public class ParseException : Exception
{
    public ParseException(string msg) : base(msg) { }
}
