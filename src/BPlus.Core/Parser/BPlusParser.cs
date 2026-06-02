using System.Text.RegularExpressions;
using BPlus.Core.Ast;

namespace BPlus.Core.Parser;

public partial class BPlusParser
{
    private Lexer _lexer = new();
    private const int MaxNestingDepth = 100;
    private static readonly char[] RtlChars = {
        '\u200E', '\u200F', '\u202A', '\u202B', '\u202C',
        '\u202D', '\u202E', '\u2066', '\u2067', '\u2068', '\u2069'
    };

    public ProgramNode Parse(string source)
    {
        // Strip UTF-8 BOM (\uFEFF) — added by Notepad and other editors
        if (source.Length > 0 && source[0] == '\uFEFF')
            source = source[1..];

        _lexer.Src = StripComments(source);
        _lexer.Pos = 0;
        _lexer.Line = 1;

#if DEBUG
        // RTL override filter (CWE-451) — heavy check, DEBUG only
        foreach (var c in RtlChars)
        {
            if (_lexer.Src.Contains(c))
                throw new ParseException($"RTL override character U+{(int)c:X4} detected — possible code injection (CWE-451)");
        }
#endif
        var program = new ProgramNode();

        SkipWs();
        while (_lexer.Pos < _lexer.Src.Length)
        {
            if (Peek("import "))
            {
                program.Imports.Add(ParseImport());
            }
            else if (_lexer.Src[_lexer.Pos] == '#')
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
            else if (_lexer.Src[_lexer.Pos] == '@')
            {
                var annotations = ParseAnnotations();
                SkipWs();
                if (Peek("kernel"))
                    program.Kernels.Add(ParseKernel(annotations));
                else if (Peek("pipeline"))
                    program.Pipelines.Add(ParsePipeline(annotations));
                else if (Peek("entry"))
                    program.Entries.Add(ParseEntry());
                else if (Peek("compute_shader") || Peek("@compute_shader"))
                {
                    var cs = ParseComputeShader();
                    if (cs != null) program.ComputeShaders.Add(cs);
                }
                else if (Peek("fragment_shader") || Peek("@fragment_shader"))
                {
                    var fs = ParseFragmentShader();
                    if (fs != null) program.FragmentShaders.Add(fs);
                }
                else if (Peek("vertex_shader") || Peek("@vertex_shader"))
                {
                    var vs = ParseVertexShader();
                    if (vs != null) program.VertexShaders.Add(vs);
                }
                else if (Peek("ray_shader") || Peek("@ray_shader"))
                {
                    var rt = ParseRayTracingShader();
                    if (rt != null) program.RayTracingShaders.Add(rt);
                }
                else if (Peek("local_group") || Peek("@local_group"))
                {
                    var lg = ParseLocalGroup();
                    if (lg != null) program.LocalGroups.Add(lg);
                }
                else if (annotations.Any(a => a.Name == "corporate_network"))
                {
                    var network = ParseNetwork(corporatePrefix: true);
                    if (network != null) program.Networks.Add(network);
                }
                else if (Peek("blockchain") || Peek("@blockchain"))
                {
                    var chain = ParseBlockchain();
                    if (chain != null) program.BlockchainNetworks.Add(chain);
                }
                else if (Peek("graphics_kernel") || Peek("@graphics_kernel") || annotations.Any(a => a.Name == "graphics_kernel"))
                {
                    var gk = ParseGraphicsKernel();
                    if (gk != null) program.GraphicsKernels.Add(gk);
                }
                else if (annotations.Any(a => a.Name == "compute_kernel"))
                {
                    var gk = ParseGpuKernel();
                    if (gk != null) program.ComputeShaders.Add(gk);
                }
                else if (annotations.Any(a => a.Name == "scientific_kernel"))
                {
                    var sk = ParseScientificKernel();
                    if (sk != null) program.ScientificKernels.Add(sk);
                }
                else if (annotations.Any(a => a.Name == "blockchain"))
                {
                    var chain = ParseBlockchain();
                    if (chain != null) program.BlockchainNetworks.Add(chain);
                }
                else if (Peek("state ") || Peek("base "))
                {
                    var state = ParseStateDef();
                    // Mojo-inspired annotations
                    if (annotations.Any(a => a.Name == "stream"))
                        state.IsStream = true;
                    if (annotations.Any(a => a.Name == "always_inline"))
                        state.Inline = InlineHint.AlwaysInline;
                    if (annotations.Any(a => a.Name == "no_inline"))
                        state.Inline = InlineHint.NoInline;
                    foreach (var a in annotations)
                    {
                        if (a.Name.StartsWith("parameter"))
                            state.ParameterConditions.Add(new ParameterCondition
                            {
                                Key = a.Args.GetValueOrDefault("_val", "target"),
                                Value = a.Args.GetValueOrDefault("_val", "")
                            });
                        if (a.Name.StartsWith("llvm_intrinsic"))
                            state.LlvmIntrinsics.Add(new LlvmIntrinsicDecl
                            {
                                Intrinsic = a.Args.GetValueOrDefault("_val", ""),
                                Target = state.Name
                            });
                        if (a.Name == "deadline" && a.Args.TryGetValue("_val", out var dlVal)
                            && long.TryParse(dlVal, out var dlUs))
                        {
                            state.DeadlineUs = dlUs;
                            state.DeadlineHard = a.Args.GetValueOrDefault("hard", "true") != "false";
                        }
                        if (a.Name == "cache" && a.Args.TryGetValue("_val", out var cacheVal))
                            state.CachePolicy = cacheVal;
                        if (a.Name == "cache_pin")
                            state.CachePin = true;
                        if (a.Name == "cache_align" && a.Args.TryGetValue("_val", out var caVal)
                            && int.TryParse(caVal, out var caInt))
                            state.CacheAlign = caInt;
                        if (a.Name == "predict" && a.Args.TryGetValue("_val", out var predVal))
                        {
                            state.Predict = predVal;
                            if (a.Args.TryGetValue("p", out var pStr) && double.TryParse(pStr, out var pVal))
                                state.PredictProbability = pVal;
                        }
                    }
                    program.States.Add(state);
                }
                else
                {
                    if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '@')
                    {
                        program.StandaloneAnnotations.AddRange(annotations);
                    }
                    else if (Peek("corporate_network"))
                    {
                        var network = ParseNetwork(corporatePrefix: true);
                        if (network != null) program.Networks.Add(network);
                    }
                    else if (_lexer.Pos >= _lexer.Src.Length)
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
                var state = ParseStateDef();
                program.States.Add(state);
            }
            else if (Peek("network ") || Peek("corporate_network"))
            {
                var network = ParseNetwork(corporatePrefix: Peek("corporate_network"));
                if (network != null) program.Networks.Add(network);
            }
            else if (Peek("blockchain ") || Peek("@blockchain"))
            {
                var chain = ParseBlockchain();
                if (chain != null) program.BlockchainNetworks.Add(chain);
            }
            else if (Peek("graphics_kernel ") || Peek("@graphics_kernel"))
            {
                var gk = ParseGraphicsKernel();
                if (gk != null) program.GraphicsKernels.Add(gk);
            }
            else if (Peek("scientific_kernel ") || Peek("@scientific_kernel"))
            {
                var sk = ParseScientificKernel();
                if (sk != null) program.ScientificKernels.Add(sk);
            }
            else if (Peek("struct "))
            {
                program.Structs.Add(ParseStruct());
            }
            else if (Peek("compute_kernel"))
            {
                var gk = ParseGpuKernel();
                if (gk != null) program.ComputeShaders.Add(gk);
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
        var m = Regex.Match(_lexer.Src[_lexer.Pos..], @"^""([^""]*)""");
        if (!m.Success) throw Err("Expected string literal after import");
        _lexer.Pos += m.Length;
        return new ImportNode { Path = m.Groups[1].Value };
    }

    private ContextNode ParseContext()
    {
        Expect("context");
        SkipWs();
        Expect("{");
        var ctx = new ContextNode();
        SkipWs();
        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
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
        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
        {
            var member = ParseWord();
            en.Members.Add(member);
            SkipWs();
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',')
            {
                _lexer.Pos++;
                SkipWs();
            }
        }
        Expect("}");
        return en;
    }

    private static int _stateIdCounter;
    private readonly Dictionary<string, StateDefNode> _allStates = new();

    private StateDefNode ParseStateDef(int depth = 0)
    {
        if (depth > MaxNestingDepth)
            throw Err($"Maximum nesting depth {MaxNestingDepth} exceeded — possible stack overflow");

        var state = new StateDefNode();
        state.ParseLine = _lexer.Line;
        state.Depth = depth;

        if (Peek("base "))
        {
            Expect("base ");
            state.IsBaseClass = true;
            SkipWs();
        }

        Expect("state ");
        state.Name = ParseWord();

        // Mojo: owned / borrowed after state name
        SkipWs();
        if (Peek("owned "))
        {
            Expect("owned");
            state.Ownership = OwnershipHint.Owned;
        }
        else if (Peek("borrowed "))
        {
            Expect("borrowed");
            state.Ownership = OwnershipHint.Borrowed;
        }

        // Detach if state already defined
        if (_allStates.ContainsKey(state.Name))
            throw Err($"Duplicate state '{state.Name}'");

        // Generic <T>
        SkipWs();
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '<')
        {
            _lexer.Pos++;
            state.GenericParam = ParseWord();
            SkipWs();
            Expect(">");
        }

        // Inheritance : Parent
        SkipWs();
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ':')
        {
            _lexer.Pos++;
            SkipWs();
            state.BaseClass = ParseWord();
            // Self-inheritance
            if (state.BaseClass == state.Name)
                throw Err($"Cyclic inheritance: state '{state.Name}' cannot inherit from itself");
        }

        _allStates[state.Name] = state;
        _stateIdCounter++;

        SkipWs();
        Expect("{");
        SkipWs();

        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
        {
            if (Peek("inline ") || Peek("fn "))
            {
                bool isInline;
                if (_lexer.Pos + 7 <= _lexer.Src.Length && _lexer.Src.AsSpan(_lexer.Pos, 7).SequenceEqual("inline "))
                {
                    _lexer.Pos += 7;
                    isInline = true;
                    // After "inline ", skip "fn " too
                    SkipWs();
                    if (_lexer.Pos + 3 <= _lexer.Src.Length && _lexer.Src.AsSpan(_lexer.Pos, 3).SequenceEqual("fn "))
                        _lexer.Pos += 3;
                    else if (_lexer.Pos + 2 <= _lexer.Src.Length && _lexer.Src.AsSpan(_lexer.Pos, 2).SequenceEqual("fn"))
                        _lexer.Pos += 2;
                }
                else
                {
                    isInline = false;
                    // Skipping "fn " — Peek("fn ") left _lexer.Pos at "fn "
                    _lexer.Pos += 3;
                }
                state.Functions.Add(ParseFn(isInline));
            }
            else if (Peek("volatile ") || Peek("fixed "))
            {
                ParseWord();
                state.Variables.Add(ParseVarDecl());
            }
            else if (Peek("var "))
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
            else if (_lexer.Src[_lexer.Pos] == '@')
            {
                // Parse annotations for next element (@hot, @cold, @fast_path)
                var annots = ParseAnnotations();
                SkipWs();

                // Mojo: @llvm_intrinsic and @parameter inside state body
                if (annots.Any(a => a.Name.StartsWith("llvm_intrinsic")))
                {
                    foreach (var a in annots.Where(an => an.Name.StartsWith("llvm_intrinsic")))
                        state.LlvmIntrinsics.Add(new LlvmIntrinsicDecl
                        {
                            Intrinsic = a.Args.GetValueOrDefault("_val", "llvm.prefetch"),
                            Args = { "ptr", "0", "3", "1" }
                        });
                    continue;
                }
                if (annots.Any(a => a.Name == "parameter"))
                {
                    foreach (var a in annots.Where(an => an.Name == "parameter"))
                        state.ParameterConditions.Add(new ParameterCondition
                        {
                            Key = a.Args.GetValueOrDefault("key", "target"),
                            Value = a.Args.GetValueOrDefault("_val", "avx512")
                        });
                    continue;
                }

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
            else if (_lexer.Src[_lexer.Pos] == '#')
            {
                // Skip precision directives inside state (e.g. #256 for bigfloat)
                while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n') _lexer.Pos++;
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
            case "predict":
                if (a.Args.TryGetValue("_val", out var predV))
                    trans.Predict = predV;
                if (a.Args.TryGetValue("p", out var probS) && double.TryParse(probS, out var prob))
                    trans.PredictProbability = prob;
                break;
        }
    }

    private VariableNode ParseVarDecl()
    {
        Expect("var ");
        List<string> mods = new();
        string name;
        int saved = _lexer.Pos;
        var first = ParseWord();
        if (first == "fixed" || first == "volatile")
        {
            mods.Add(first);
            SkipWs();
            name = ParseWord();
        }
        else
        {
            _lexer.Pos = saved;
            name = ParseWord();
        }
        string? type = null;
        string? def = null;
        SkipWs();
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ':')
        {
            _lexer.Pos++;
            SkipWs();
            type = ParseType();
            SkipWs();
        }
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '=')
        {
            _lexer.Pos++;
            SkipWs();
            int start = _lexer.Pos;
            int depth = 0;
            while (_lexer.Pos < _lexer.Src.Length)
            {
                var c = _lexer.Src[_lexer.Pos];
                if (c == '(' || c == '[' || c == '{') depth++;
                else if (c == ')' || c == ']' || c == '}') { if (depth == 0) break; depth--; }
                else if (c == ';') break;
                else if (c == '\n' || c == '\r') { if (depth == 0) break; _lexer.Pos++; continue; }
                else if (depth == 0 && (
                    (c == 'v' && Peek("var ")) ||
                    (c == 'o' && Peek("on ")) ||
                    (c == 'e' && (Peek("enter ") || Peek("exit "))) ||
                    (c == 's' && Peek("state ")) ||
                    (c == 'i' && Peek("inline ")) ||
                    (c == 'f' && Peek("fn ")) ||
                    (c == 'a' && Peek("always"))
                )) break;
                _lexer.Pos++;
            }
            def = _lexer.Src[start.._lexer.Pos].Trim();
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ';') _lexer.Pos++;
        }
        else
        {
            SkipWs();
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ';') _lexer.Pos++;
        }
        return new VariableNode { Name = name, Type = type ?? "inferred", DefaultValue = def };
    }

    private FunctionDecl ParseFn(bool isInline)
    {
        var fn = new FunctionDecl { IsInline = isInline };
        SkipWs();
        fn.Name = ParseWord();
        SkipWs();
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '(')
        {
            _lexer.Pos++;
            SkipWs();
            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ')')
            {
                var pName = ParseWord();
                SkipWs();
                if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ':')
                {
                    _lexer.Pos++;
                    SkipWs();
                    var pType = ParseWord();
                    fn.Parameters.Add((pName, pType));
                }
                else
                {
                    fn.Parameters.Add((pName, "inferred"));
                }
                SkipWs();
                if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
            }
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ')') _lexer.Pos++;
        }
        SkipWs();
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ':')
        {
            _lexer.Pos++;
            SkipWs();
            fn.ReturnType = ParseWord();
            SkipWs();
        }
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '{')
        {
            fn.Body = ExtractBracedBlock() ?? "";
        }
        else if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ';')
        {
            _lexer.Pos++;
        }
        return fn;
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
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '-')
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
            var m = Regex.Match(_lexer.Src[_lexer.Pos..], @"^""([^""]*)""");
            if (m.Success)
            {
                signalName = m.Groups[1].Value;
                _lexer.Pos += m.Length;
            }
            else
            {
                signalName = ParseWord();
            }
        }

        // Handle unconditional transitions: on [condition] -> Target
        string eventName;
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '[')
        {
            // Guard-only transition: on [health <= 0] -> Dead
            eventName = "__always__";
        }
        else if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '\'')
        {
            // Handle quoted char event names: on 'x' -> Target, on '\n' -> Target
            _lexer.Pos++; // skip opening '
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\'')
            {
                if (_lexer.Src[_lexer.Pos] == '\\' && _lexer.Pos + 1 < _lexer.Src.Length)
                {
                    _lexer.Pos++;
                    eventName = _lexer.Src[_lexer.Pos] switch
                    {
                        'n' => "\n",
                        'r' => "\r",
                        't' => "\t",
                        '\\' => "\\",
                        '\'' => "'",
                        _ => "\\" + _lexer.Src[_lexer.Pos]
                    };
                    _lexer.Pos++;
                }
                else
                {
                    eventName = _lexer.Src[_lexer.Pos].ToString();
                    _lexer.Pos++;
                }
            }
            else
                eventName = "";
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '\'') _lexer.Pos++;
        }
        else
        {
            eventName = isSignal ? signalName! : ParseWord();
        }
        SkipWs();

        // Parameters ( ... )
        var parameters = new List<ParamNode>();
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '(')
        {
            _lexer.Pos++;
            SkipWs();
            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ')')
            {
                var pName = ParseWord();
                SkipWs();
                Expect(":");
                SkipWs();
                var pType = ParseType();
                parameters.Add(new ParamNode { Name = pName, Type = pType });
                SkipWs();
                if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',')
                {
                    _lexer.Pos++;
                    SkipWs();
                }
            }
            Expect(")");
            SkipWs();
        }

        // Guard [ ... ]
        string? guard = null;
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '[')
        {
            _lexer.Pos++;
            int depth = 1;
            int start = _lexer.Pos;
            while (_lexer.Pos < _lexer.Src.Length && depth > 0)
            {
                if (_lexer.Src[_lexer.Pos] == '[') depth++;
                else if (_lexer.Src[_lexer.Pos] == ']') depth--;
                if (depth > 0) _lexer.Pos++;
            }
            guard = _lexer.Src[start.._lexer.Pos].Trim();
            _lexer.Pos++;
            SkipWs();
        }

        // -> Target
        string target = "";

        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '-')
        {
            Expect("->");
            SkipWs();

            // Handle history keyword
            if (Peek("history"))
            {
                _lexer.Pos += 7;
                target = "__history__";
            }
            else
            {
                target = ParseWord();
                SkipWs();
                if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '<')
                {
                    int gs = _lexer.Pos;
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '>') _lexer.Pos++;
                    if (_lexer.Pos < _lexer.Src.Length) _lexer.Pos++;
                    target = _lexer.Src[gs.._lexer.Pos];
                }
            }
        }
        SkipWs();

        // Body { ... }
        string? body = null;
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '{')
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
            IsAsync = isAsync,
            IsHistory = target == "__history__"
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
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '[')
        {
            _lexer.Pos++;
            int start = _lexer.Pos;
            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']') _lexer.Pos++;
            guard = _lexer.Src[start.._lexer.Pos].Trim();
            _lexer.Pos++;
            SkipWs();
        }

        Expect("->");
        SkipWs();
        var target = ParseWord();
        return new TimerNode { Duration = duration, Guard = guard, Target = target };
    }

    private ActionNode ParseAction()
    {
        var prefix = _lexer.Pos + 4 <= _lexer.Src.Length && _lexer.Src.AsSpan(_lexer.Pos, 4).SequenceEqual("exit") ? "exit" : "enter";
        _lexer.Pos += prefix.Length;
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
        var par = new ParallelBlockNode();

        // Bare parallel { ... } — no name, no machine wrapping
        if (Peek("{"))
        {
            par.Name = "_anonymous";
            SkipWs();
            Expect("{");
            SkipWs();
            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
            {
                var lineStart = _lexer.Pos;
                while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n' && _lexer.Src[_lexer.Pos] != '}')
                    _lexer.Pos++;
                var line = _lexer.Src[lineStart.._lexer.Pos].Trim();
                if (line != "") par.BodyLines.Add(line);
                if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '\n') _lexer.Pos++;
                SkipWs();
            }
            Expect("}");
            return par;
        }

        // Named parallel: parallel Name { machine Name { ... } }
        par.Name = ParseWord();
        SkipWs();
        Expect("{");
        SkipWs();
        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
        {
            if (Peek("machine "))
            {
                _lexer.Pos += 7;
                SkipWs();
                var machineName = ParseWord();
                SkipWs();
                Expect("{");
                SkipWs();
                var machine = new StateDefNode { Name = machineName };
                while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
                {
                    if (Peek("state ") || Peek("base "))
                        machine.NestedStates.Add(ParseStateDef());
                    else if (Peek("var "))
                        machine.Variables.Add(ParseVarDecl());
                    else if (Peek("on "))
                        machine.Transitions.Add(ParseTransition());
                    else if (Peek("after "))
                        machine.Timers.Add(ParseTimer());
                    else if (Peek("enter ") || Peek("exit "))
                        machine.Actions.Add(ParseAction());
                    else if (Peek("always"))
                        machine.Transitions.Add(ParseAlways());
                    else
                        throw Err($"Unexpected in machine '{machineName}'");
                    SkipWs();
                }
                Expect("}");
                par.States.Add(machine);
            }
            else if (Peek("state ") || Peek("base "))
                par.States.Add(ParseStateDef());
            else
                throw Err($"Unexpected in parallel '{par.Name}'");
            SkipWs();
        }
        Expect("}");
        return par;
    }

    private NetworkNode? ParseNetwork(bool corporatePrefix = false)
    {
        if (!corporatePrefix && Peek("corporate_network"))
            _lexer.Pos += 16;
        var name = ParseWord();
        SkipWs();

        var network = new NetworkNode { Name = name };

        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '"')
        {
            _lexer.Pos++;
            int end = _lexer.Src.IndexOf('"', _lexer.Pos);
            if (end > _lexer.Pos)
            {
                network.Description = _lexer.Src[_lexer.Pos..end];
                _lexer.Pos = end + 1;
            }
        }

        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '{')
        {
            if (Peek("protocol:"))
            {
                _lexer.Pos += 8;
                SkipWs();
                var proto = ParseWord();
                network.Protocol = proto.ToUpper() switch
                {
                    "TCP" => NetworkProtocol.TCP,
                    "UDP" => NetworkProtocol.UDP,
                    "QUIC" => NetworkProtocol.QUIC,
                    "WEBRTC" => NetworkProtocol.WebRTC,
                    "WEBSOCKET" => NetworkProtocol.WebSocket,
                    "GRPC" => NetworkProtocol.gRPC,
                    _ => NetworkProtocol.TCP
                };
            }
            else if (Peek("host:"))
            {
                _lexer.Pos += 5;
                SkipWs();
                var m = Regex.Match(_lexer.Src[_lexer.Pos..], @"^""([^""]*)""");
                if (m.Success)
                {
                    network.Host = m.Groups[1].Value;
                    _lexer.Pos += m.Length;
                }
            }
            else if (Peek("port:"))
            {
                _lexer.Pos += 5;
                SkipWs();
                var portStr = "";
                while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                {
                    portStr += _lexer.Src[_lexer.Pos];
                    _lexer.Pos++;
                }
                if (int.TryParse(portStr, out var port))
                    network.Port = port;
            }
            else if (Peek("auto_reconnect"))
            {
                network.AutoReconnect = true;
                _lexer.Pos += 14;
            }
            else if (Peek("timeout:"))
            {
                _lexer.Pos += 8;
                SkipWs();
                var timeoutStr = "";
                while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                {
                    timeoutStr += _lexer.Src[_lexer.Pos];
                    _lexer.Pos++;
                }
                if (int.TryParse(timeoutStr, out var t))
                    network.TimeoutMs = t;
            }
            else if (Peek("heartbeat:"))
            {
                _lexer.Pos += 10;
                SkipWs();
                var hbStr = "";
                while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                {
                    hbStr += _lexer.Src[_lexer.Pos];
                    _lexer.Pos++;
                }
                if (int.TryParse(hbStr, out var hb))
                    network.HeartbeatIntervalMs = hb;
            }
            else if (Peek("retries:"))
            {
                _lexer.Pos += 7;
                SkipWs();
                var retriesStr = "";
                while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                {
                    retriesStr += _lexer.Src[_lexer.Pos];
                    _lexer.Pos++;
                }
                if (int.TryParse(retriesStr, out var r))
                    network.MaxRetries = r;
            }
            else if (Peek("tls"))
            {
                network.Security = SecurityLevel.TLS;
                _lexer.Pos += 3;
            }
            else if (Peek("encrypted"))
            {
                network.Security = SecurityLevel.Encrypted;
                _lexer.Pos += 9;
            }
            else
            {
                break;
            }
            SkipWs();
        }

        Expect("{");
        SkipWs();

        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
        {
            SkipWs();
            if (Peek("crypto:"))
            {
                network.Crypto = ParseCryptoConfig();
            }
            else if (Peek("access:") || Peek("zero_trust"))
            {
                network.ZeroTrust = ParseZeroTrustConfig();
            }
            else if (Peek("segments:"))
            {
                ParseSegments(network);
            }
            else if (Peek("sites:"))
            {
                ParseSites(network);
            }
            else if (Peek("resilience:"))
            {
                network.Resilience = ParseResilienceConfig();
            }
            else if (Peek("state ") || Peek("base "))
            {
                network.States.Add(ParseStateDef());
            }
            else
            {
                throw Err($"Unexpected in network '{name}': '{PeekWord()}'");
            }
            SkipWs();
        }

        Expect("}");
        return network;
    }

    private BlockchainNetworkNode? ParseBlockchain()
    {
        // Caller has already consumed "@blockchain" or "blockchain" keyword
        // Position is already past the keyword, just parse name and body
        
        SkipWs();
        var name = ParseWord();
        var chain = new BlockchainNetworkNode { Name = name };

        Expect("{");
        SkipWs();

        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
        {
            SkipWs();
            if (Peek("consensus:"))
            {
                _lexer.Pos += 9;
                SkipWs();
                var c = ParseWord().ToUpper();
                chain.Consensus = c switch
                {
                    "POW" => ConsensusType.PoW,
                    "POS" => ConsensusType.PoS,
                    "DPOS" => ConsensusType.DPoS,
                    "PBFT" => ConsensusType.PBFT,
                    "RAFT" => ConsensusType.Raft,
                    _ => ConsensusType.PBFT
                };
            }
            else if (Peek("wallet:"))
            {
                _lexer.Pos += 6;
                SkipWs();
                var w = ParseWord().ToUpper();
                chain.WalletAlgo = w switch
                {
                    "ECDSA" => WalletAlgorithm.ECDSA,
                    "ED25519" => WalletAlgorithm.Ed25519,
                    "SCHNORR" => WalletAlgorithm.Schnorr,
                    _ => WalletAlgorithm.Ed25519
                };
            }
            else if (Peek("p2p:"))
            {
                _lexer.Pos += 4;
                SkipWs();
                var p = ParseWord().ToUpper();
                chain.P2PMode = p switch
                {
                    "KADEMLIA" => P2PProtocol.Kademlia,
                    "GOSSIP" => P2PProtocol.Gossip,
                    "CHORD" => P2PProtocol.Chord,
                    _ => P2PProtocol.Kademlia
                };
            }
            else if (Peek("sharding:"))
            {
                _lexer.Pos += 8;
                SkipWs();
                var s = ParseWord().ToUpper();
                chain.Sharding = s switch
                {
                    "NONE" => ShardingType.None,
                    "SHARD_CHAIN" => ShardingType.ShardChain,
                    "STATE_SHARDING" => ShardingType.StateSharding,
                    _ => ShardingType.None
                };
            }
            else if (Peek("max_peers:"))
            {
                _lexer.Pos += 9;
                SkipWs();
                var n = "";
                while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                    n += _lexer.Src[_lexer.Pos++];
                if (int.TryParse(n, out var mp)) chain.MaxPeers = mp;
            }
            else if (Peek("min_validators:"))
            {
                _lexer.Pos += 14;
                SkipWs();
                var n = "";
                while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                    n += _lexer.Src[_lexer.Pos++];
                if (int.TryParse(n, out var mv)) chain.MinValidators = mv;
            }
            else if (Peek("block_time:"))
            {
                _lexer.Pos += 10;
                SkipWs();
                var n = "";
                while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                    n += _lexer.Src[_lexer.Pos++];
                if (int.TryParse(n, out var bt)) chain.BlockTimeMs = bt;
            }
            else if (Peek("difficulty:"))
            {
                _lexer.Pos += 10;
                SkipWs();
                var n = "";
                while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                    n += _lexer.Src[_lexer.Pos++];
                if (int.TryParse(n, out var d)) chain.Difficulty = d;
            }
            else if (Peek("min_stake:"))
            {
                _lexer.Pos += 9;
                SkipWs();
                var n = "";
                while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                    n += _lexer.Src[_lexer.Pos++];
                if (long.TryParse(n, out var ms)) chain.MinStake = ms;
            }
            else if (Peek("shard_count:"))
            {
                _lexer.Pos += 11;
                SkipWs();
                var n = "";
                while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                    n += _lexer.Src[_lexer.Pos++];
                if (int.TryParse(n, out var sc)) chain.ShardCount = sc;
            }
            else if (Peek("segments:"))
            {
                _lexer.Pos += 9;
                SkipWs();
                if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '[')
                {
                    _lexer.Pos++;
                    SkipWs();
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
                    {
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == '{')
                        {
                            _lexer.Pos++;
                            SkipWs();
                            var seg = new NetworkSegment();
                            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
                            {
                                if (Peek("name:"))
                                {
                                    _lexer.Pos += 5;
                                    SkipWs();
                                    seg.Name = ParseWord();
                                }
                                else if (Peek("vlan:"))
                                {
                                    _lexer.Pos += 5;
                                    SkipWs();
                                    var n = "";
                                    while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                                        n += _lexer.Src[_lexer.Pos++];
                                    if (int.TryParse(n, out var v)) seg.Vlan = v;
                                }
                                else
                                {
                                    _lexer.Pos += ParseWord().Length;
                                }
                                SkipWs();
                            }
                            Expect("}");
                            chain.Segments.Add(seg);
                        }
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == ',') _lexer.Pos++;
                        SkipWs();
                    }
                    Expect("]");
                }
            }
            else if (Peek("genesis:"))
            {
                foreach (var entry in ParseGenesisLedger())
                    chain.GenesisLedger.Add(entry);
            }
            else if (Peek("boot_nodes:"))
            {
                _lexer.Pos += 10;
                SkipWs();
                while (_lexer.Src[_lexer.Pos] == '[')
                {
                    _lexer.Pos++;
                    SkipWs();
                    var addr = "";
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']' && _lexer.Src[_lexer.Pos] != ',')
                    {
                        addr += _lexer.Src[_lexer.Pos++];
                    }
                    if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ']') _lexer.Pos++;
                    SkipWs();
                    var parts = addr.Trim().Split(':');
                    if (parts.Length == 2 && int.TryParse(parts[1], out var port))
                    {
                        chain.BootNodes.Add(new BlockchainNetworkNode
                        {
                            Name = "boot",
                            Address = parts[0]
                        });
                    }
                    if (_lexer.Src[_lexer.Pos] == ',') _lexer.Pos++;
                    SkipWs();
                }
            }
            else if (Peek("state ") || Peek("base "))
            {
                chain.States.Add(ParseStateDef());
            }
            else
            {
                throw Err($"Unexpected in blockchain '{name}': '{PeekWord()}'");
            }
            SkipWs();
        }

        Expect("}");
        return chain;
    }

    private List<LedgerEntry> ParseGenesisLedger()
    {
        Expect("genesis:");
        SkipWs();
        var entries = new List<LedgerEntry>();

        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '[')
        {
            _lexer.Pos++;
            SkipWs();
            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
            {
                SkipWs();
                if (_lexer.Src[_lexer.Pos] == '{')
                {
                    _lexer.Pos++;
                    SkipWs();
                    var entry = new LedgerEntry();
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
                    {
                        if (Peek("from:"))
                        {
                            _lexer.Pos += 5;
                            SkipWs();
                            entry.From = ParseWord();
                        }
                        else if (Peek("to:"))
                        {
                            _lexer.Pos += 3;
                            SkipWs();
                            entry.To = ParseWord();
                        }
                        else if (Peek("amount:"))
                        {
                            _lexer.Pos += 7;
                            SkipWs();
                            var n = "";
                            while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                                n += _lexer.Src[_lexer.Pos++];
                            if (long.TryParse(n, out var amt)) entry.Amount = amt;
                        }
                        else
                        {
                            _lexer.Pos += ParseWord().Length;
                        }
                        SkipWs();
                    }
                    Expect("}");
                    entries.Add(entry);
                }
                SkipWs();
                if (_lexer.Src[_lexer.Pos] == ',') _lexer.Pos++;
                SkipWs();
            }
            Expect("]");
        }

return entries;
    }

    private GraphicsKernelDecl? ParseGraphicsKernel()
    {
        if (Peek("graphics_kernel"))
            _lexer.Pos += 15;
        else if (Peek("@graphics_kernel"))
            _lexer.Pos += 16;

        SkipWs();
        var name = ParseWord();
        var gk = new GraphicsKernelDecl { Name = name };

        Expect("{");
        SkipWs();

        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
        {
            SkipWs();
            if (Peek("stage:"))
            {
                _lexer.Pos += 6;
                SkipWs();
                var s = ParseWord().ToLower();
                gk.Stage = s switch
                {
                    "vertex" => ShaderStage.Vertex,
                    "fragment" => ShaderStage.Fragment,
                    "compute" => ShaderStage.Compute,
                    "ray" => ShaderStage.RayTrace,
                    _ => ShaderStage.Compute
                };
            }
            else if (Peek("threads:"))
            {
                _lexer.Pos += 8;
                SkipWs();
                var t = ParseWord().Replace("x", ",").Split(',');
                if (t.Length >= 1 && int.TryParse(t[0], out var x)) gk.ThreadsX = x;
                if (t.Length >= 2 && int.TryParse(t[1], out var y)) gk.ThreadsY = y;
                if (t.Length >= 3 && int.TryParse(t[2], out var z)) gk.ThreadsZ = z;
            }
            else if (Peek("texture:"))
            {
                _lexer.Pos += 8;
                SkipWs();
                if (_lexer.Src[_lexer.Pos] == '[')
                {
                    _lexer.Pos++;
                    SkipWs();
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
                    {
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == '{')
                        {
                            _lexer.Pos++;
                            SkipWs();
                            var tex = new TextureDecl();
                            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
                            {
                                if (Peek("name:"))
                                {
                                    _lexer.Pos += 5;
                                    SkipWs();
                                    tex.Name = ParseWord();
                                }
                                else if (Peek("format:"))
                                {
                                    _lexer.Pos += 7;
                                    SkipWs();
                                    var fmtStr = ParseWord().ToUpper();
                                    tex.Format = fmtStr switch
                                    {
                                        "R8G8B8A8" => TextureFormat.R8G8B8A8,
                                        "R16G16B16A16" => TextureFormat.R16G16B16A16,
                                        "R32G32B32" => TextureFormat.R32G32B32,
                                        "R32G32B32A32" => TextureFormat.R32G32B32A32,
                                        "BC7" => TextureFormat.BC7,
                                        "ASTC" => TextureFormat.ASTC,
                                        _ => TextureFormat.R8G8B8A8
                                    };
                                }
                                else
                                {
                                    _lexer.Pos += ParseWord().Length;
                                }
                                SkipWs();
                            }
                            Expect("}");
                            gk.Textures.Add(tex);
                        }
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == ',') _lexer.Pos++;
                        SkipWs();
                    }
                    Expect("]");
                }
            }
            else if (Peek("buffer:"))
            {
                _lexer.Pos += 7;
                SkipWs();
                if (_lexer.Src[_lexer.Pos] == '[')
                {
                    _lexer.Pos++;
                    SkipWs();
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
                    {
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == '{')
                        {
                            _lexer.Pos++;
                            SkipWs();
                            var buf = new BufferDecl();
                            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
                            {
                                if (Peek("name:"))
                                {
                                    _lexer.Pos += 5;
                                    SkipWs();
                                    buf.Name = ParseWord();
                                }
                                else if (Peek("count:"))
                                {
                                    _lexer.Pos += 6;
                                    SkipWs();
                                    var n = "";
                                    while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                                        n += _lexer.Src[_lexer.Pos++];
                                    if (int.TryParse(n, out var s)) buf.Count = s;
                                }
                                else
                                {
                                    _lexer.Pos += ParseWord().Length;
                                }
                                SkipWs();
                            }
                            Expect("}");
                            gk.Buffers.Add(buf);
                        }
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == ',') _lexer.Pos++;
                        SkipWs();
                    }
                    Expect("]");
                }
            }
            else if (Peek("sampler:"))
            {
                _lexer.Pos += 8;
                SkipWs();
                if (_lexer.Src[_lexer.Pos] == '[')
                {
                    _lexer.Pos++;
                    SkipWs();
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
                    {
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == '{')
                        {
                            _lexer.Pos++;
                            SkipWs();
                            var sam = new SamplerDecl();
                            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
                            {
                                if (Peek("name:"))
                                {
                                    _lexer.Pos += 5;
                                    SkipWs();
                                    sam.Name = ParseWord();
                                }
                                else if (Peek("filter:"))
                                {
                                    _lexer.Pos += 7;
                                    SkipWs();
                                    sam.Filter = ParseWord().ToLower();
                                }
                                else
                                {
                                    _lexer.Pos += ParseWord().Length;
                                }
                                SkipWs();
                            }
                            Expect("}");
                            gk.Samplers.Add(sam);
                        }
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == ',') _lexer.Pos++;
                        SkipWs();
                    }
                    Expect("]");
                }
            }
            else if (Peek("state ") || Peek("base "))
            {
                gk.States.Add(ParseStateDef());
            }
            else
            {
                throw Err($"Unexpected in graphics_kernel '{name}': '{PeekWord()}'");
            }
            SkipWs();
        }

        Expect("}");
        return gk;
    }

    private ScientificKernelDecl? ParseScientificKernel()
    {
        if (Peek("scientific_kernel"))
            _lexer.Pos += 17;
        else if (Peek("@scientific_kernel"))
            _lexer.Pos += 18;

        SkipWs();
        var name = ParseWord();
        var sk = new ScientificKernelDecl { Name = name };

        Expect("{");
        SkipWs();

        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
        {
            SkipWs();
            if (Peek("tensor_mode:"))
            {
                _lexer.Pos += 12;
                SkipWs();
                var mode = ParseWord().ToUpper();
                sk.TensorMode = mode switch
                {
                    "WMMA" => TensorCoreMode.WMMA,
                    "DP4A" => TensorCoreMode.DP4A,
                    "HMMA" => TensorCoreMode.HMMA,
                    _ => TensorCoreMode.WMMA
                };
            }
            else if (Peek("autodiff"))
            {
                _lexer.Pos += 8;
                sk.AutoDiff = true;
            }
            else if (Peek("interval:"))
            {
                _lexer.Pos += 9;
                SkipWs();
                if (_lexer.Src[_lexer.Pos] == '[')
                {
                    _lexer.Pos++;
                    SkipWs();
                    var lower = "";
                    while (_lexer.Pos < _lexer.Src.Length && (char.IsDigit(_lexer.Src[_lexer.Pos]) || _lexer.Src[_lexer.Pos] == '.' || _lexer.Src[_lexer.Pos] == '-'))
                        lower += _lexer.Src[_lexer.Pos++];
                    SkipWs();
                    if (_lexer.Src[_lexer.Pos] == ',') _lexer.Pos++;
                    SkipWs();
                    var upper = "";
                    while (_lexer.Pos < _lexer.Src.Length && (char.IsDigit(_lexer.Src[_lexer.Pos]) || _lexer.Src[_lexer.Pos] == '.'))
                        upper += _lexer.Src[_lexer.Pos++];
                    SkipWs();
                    if (_lexer.Src[_lexer.Pos] == ']') _lexer.Pos++;
                    sk.IntervalConfig = new IntervalArithmetic
                    {
                        Lower = double.TryParse(lower, out var l) ? l : 0,
                        Upper = double.TryParse(upper, out var u) ? u : 1
                    };
                }
            }
            else if (Peek("matrix:"))
            {
                _lexer.Pos += 7;
                SkipWs();
                if (_lexer.Src[_lexer.Pos] == '[')
                {
                    _lexer.Pos++;
                    SkipWs();
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
                    {
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == '{')
                        {
                            _lexer.Pos++;
                            SkipWs();
                            var mat = new SparseMatrix();
                            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
                            {
                                if (Peek("name:"))
                                {
                                    _lexer.Pos += 5;
                                    SkipWs();
                                    mat.Name = ParseWord();
                                }
                                else if (Peek("format:"))
                                {
                                    _lexer.Pos += 7;
                                    SkipWs();
                                    mat.Format = ParseWord().ToUpper();
                                }
                                else if (Peek("size:"))
                                {
                                    _lexer.Pos += 5;
                                    SkipWs();
                                    var s = ParseWord().Replace("x", ",").Split(',');
                                    if (s.Length >= 1 && int.TryParse(s[0], out var r)) mat.Rows = r;
                                    if (s.Length >= 2 && int.TryParse(s[1], out var c)) mat.Cols = c;
                                }
                                else
                                {
                                    _lexer.Pos += ParseWord().Length;
                                }
                                SkipWs();
                            }
                            Expect("}");
                            sk.Matrices.Add(mat);
                        }
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == ',') _lexer.Pos++;
                        SkipWs();
                    }
                    Expect("]");
                }
            }
            else if (Peek("qubit:"))
            {
                _lexer.Pos += 6;
                SkipWs();
                if (_lexer.Src[_lexer.Pos] == '[')
                {
                    _lexer.Pos++;
                    SkipWs();
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
                    {
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == '{')
                        {
                            _lexer.Pos++;
                            SkipWs();
                            var q = new QubitType();
                            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
                            {
                                if (Peek("name:"))
                                {
                                    _lexer.Pos += 5;
                                    SkipWs();
                                    q.Name = ParseWord();
                                }
                                else if (Peek("slot:"))
                                {
                                    _lexer.Pos += 5;
                                    SkipWs();
                                    var n = "";
                                    while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                                        n += _lexer.Src[_lexer.Pos++];
                                    if (int.TryParse(n, out var s)) q.Slot = s;
                                }
                                else
                                {
                                    _lexer.Pos += ParseWord().Length;
                                }
                                SkipWs();
                            }
                            Expect("}");
                            sk.Qubits.Add(q);
                        }
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == ',') _lexer.Pos++;
                        SkipWs();
                    }
                    Expect("]");
                }
            }
            else if (Peek("tpu:"))
            {
                _lexer.Pos += 4;
                SkipWs();
                if (_lexer.Src[_lexer.Pos] == '{')
                {
                    _lexer.Pos++;
                    SkipWs();
                    var tpu = new TPUConfig();
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
                    {
                        if (Peek("backend:"))
                        {
                            _lexer.Pos += 8;
                            SkipWs();
                            tpu.Backend = ParseWord();
                        }
                        else if (Peek("pod:"))
                        {
                            _lexer.Pos += 4;
                            SkipWs();
                            var n = "";
                            while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                                n += _lexer.Src[_lexer.Pos++];
                            if (int.TryParse(n, out var p)) tpu.PodSlice = p;
                        }
                        else
                        {
                            _lexer.Pos += ParseWord().Length;
                        }
                        SkipWs();
                    }
                    Expect("}");
                    sk.TPU = tpu;
                }
            }
            else if (Peek("fpga:"))
            {
                _lexer.Pos += 5;
                SkipWs();
                if (_lexer.Src[_lexer.Pos] == '{')
                {
                    _lexer.Pos++;
                    SkipWs();
                    var fpga = new FPGAConfig();
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
                    {
                        if (Peek("lang:"))
                        {
                            _lexer.Pos += 5;
                            SkipWs();
                            fpga.TargetLanguage = ParseWord().ToLower();
                        }
                        else if (Peek("clock:"))
                        {
                            _lexer.Pos += 6;
                            SkipWs();
                            var n = "";
                            while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                                n += _lexer.Src[_lexer.Pos++];
                            if (int.TryParse(n, out var c)) fpga.ClockMhz = c;
                        }
                        else
                        {
                            _lexer.Pos += ParseWord().Length;
                        }
                        SkipWs();
                    }
                    Expect("}");
                    sk.FPGA = fpga;
                }
            }
            else if (Peek("async_queue:"))
            {
                _lexer.Pos += 11;
                SkipWs();
                if (_lexer.Src[_lexer.Pos] == '[')
                {
                    _lexer.Pos++;
                    SkipWs();
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
                    {
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == '{')
                        {
                            _lexer.Pos++;
                            SkipWs();
                            var q = new AsyncComputeQueue();
                            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
                            {
                                if (Peek("name:"))
                                {
                                    _lexer.Pos += 5;
                                    SkipWs();
                                    q.Name = ParseWord();
                                }
                                else if (Peek("priority:"))
                                {
                                    _lexer.Pos += 9;
                                    SkipWs();
                                    var n = "";
                                    while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                                        n += _lexer.Src[_lexer.Pos++];
                                    if (int.TryParse(n, out var p)) q.Priority = p;
                                }
                                else
                                {
                                    _lexer.Pos += ParseWord().Length;
                                }
                                SkipWs();
                            }
                            Expect("}");
                            sk.AsyncQueues.Add(q);
                        }
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == ',') _lexer.Pos++;
                        SkipWs();
                    }
                    Expect("]");
                }
            }
            else if (Peek("optical_flow:"))
            {
                _lexer.Pos += 12;
                SkipWs();
                if (_lexer.Src[_lexer.Pos] == '{')
                {
                    _lexer.Pos++;
                    SkipWs();
                    var of = new OpticalFlowConfig();
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
                    {
                        if (Peek("hardware"))
                        {
                            _lexer.Pos += 8;
                            of.UseHardware = true;
                        }
                        else if (Peek("algorithm:"))
                        {
                            _lexer.Pos += 10;
                            SkipWs();
                            of.Algorithm = ParseWord();
                        }
                        else
                        {
                            _lexer.Pos += ParseWord().Length;
                        }
                        SkipWs();
                    }
                    Expect("}");
                    sk.OpticalFlow = of;
                }
            }
            else if (Peek("memory:"))
            {
                _lexer.Pos += 7;
                SkipWs();
                if (_lexer.Src[_lexer.Pos] == '[')
                {
                    _lexer.Pos++;
                    SkipWs();
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
                    {
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == '{')
                        {
                            _lexer.Pos++;
                            SkipWs();
                            var mem = new UnifiedMemoryBuffer();
                            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
                            {
                                if (Peek("name:"))
                                {
                                    _lexer.Pos += 5;
                                    SkipWs();
                                    mem.Name = ParseWord();
                                }
                                else if (Peek("size:"))
                                {
                                    _lexer.Pos += 5;
                                    SkipWs();
                                    var n = "";
                                    while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                                        n += _lexer.Src[_lexer.Pos++];
                                    if (int.TryParse(n, out var s)) mem.SizeBytes = s;
                                }
                                else if (Peek("arch:"))
                                {
                                    _lexer.Pos += 5;
                                    SkipWs();
                                    var arch = ParseWord().ToUpper();
                                    mem.Architecture = arch switch
                                    {
                                        "UMA" => MemoryArchitecture.UMA,
                                        "NUMA" => MemoryArchitecture.NUMA,
                                        "HCC" => MemoryArchitecture.HCC,
                                        _ => MemoryArchitecture.UMA
                                    };
                                }
                                else
                                {
                                    _lexer.Pos += ParseWord().Length;
                                }
                                SkipWs();
                            }
                            Expect("}");
                            sk.Buffers.Add(mem);
                        }
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == ',') _lexer.Pos++;
                        SkipWs();
                    }
                    Expect("]");
                }
            }
            else if (Peek("state ") || Peek("base "))
            {
                sk.States.Add(ParseStateDef());
            }
            else
            {
                throw Err($"Unexpected in scientific_kernel '{name}': '{PeekWord()}'");
            }
            SkipWs();
        }

        Expect("}");
        return sk;
    }

    private ComputeShaderDecl? ParseComputeShader()
    {
        if (Peek("compute_shader"))
            _lexer.Pos += 14;
        else if (Peek("@compute_shader"))
            _lexer.Pos += 15;

        SkipWs();
        var name = ParseWord();
        var cs = new ComputeShaderDecl { Name = name };

        Expect("{");
        SkipWs();

        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
        {
            SkipWs();
            if (Peek("threads:"))
            {
                _lexer.Pos += 8;
                SkipWs();
                var t = ParseWord().Replace("x", ",").Split(',');
                if (t.Length >= 1 && int.TryParse(t[0], out var x)) cs.ThreadsX = x;
                if (t.Length >= 2 && int.TryParse(t[1], out var y)) cs.ThreadsY = y;
                if (t.Length >= 3 && int.TryParse(t[2], out var z)) cs.ThreadsZ = z;
            }
            else if (Peek("groups:"))
            {
                _lexer.Pos += 7;
                SkipWs();
                var t = ParseWord().Replace("x", ",").Split(',');
                if (t.Length >= 1 && int.TryParse(t[0], out var x)) cs.GroupSizeX = x;
                if (t.Length >= 2 && int.TryParse(t[1], out var y)) cs.GroupSizeY = y;
                if (t.Length >= 3 && int.TryParse(t[2], out var z)) cs.GroupSizeZ = z;
            }
            else if (Peek("autodiff"))
            {
                _lexer.Pos += 8;
                cs.AutoDiff = true;
            }
            else if (Peek("register:"))
            {
                _lexer.Pos += 9;
                SkipWs();
                if (_lexer.Src[_lexer.Pos] == '[')
                {
                    _lexer.Pos++;
                    SkipWs();
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
                    {
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == '{')
                        {
                            _lexer.Pos++;
                            SkipWs();
                            var rb = new ShaderResourceBinding();
                            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
                            {
                                if (Peek("name:"))
                                {
                                    _lexer.Pos += 5;
                                    SkipWs();
                                    rb.Name = ParseWord();
                                }
                                else if (Peek("register:"))
                                {
                                    _lexer.Pos += 9;
                                    SkipWs();
                                    rb.Register = ParseWord();
                                }
                                else if (Peek("space:"))
                                {
                                    _lexer.Pos += 6;
                                    SkipWs();
                                    var n = "";
                                    while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                                        n += _lexer.Src[_lexer.Pos++];
                                    if (int.TryParse(n, out var s)) rb.Space = s;
                                }
                                else if (Peek("dimension:"))
                                {
                                    _lexer.Pos += 10;
                                    SkipWs();
                                    var d = ParseWord().ToLower();
                                    rb.Dimension = d switch
                                    {
                                        "buffer" => ResourceDimension.Buffer,
                                        "texture1d" => ResourceDimension.Texture1D,
                                        "texture2d" => ResourceDimension.Texture2D,
                                        "texture3d" => ResourceDimension.Texture3D,
                                        "texturecube" => ResourceDimension.TextureCube,
                                        _ => ResourceDimension.Buffer
                                    };
                                }
                                else
                                {
                                    _lexer.Pos += ParseWord().Length;
                                }
                                SkipWs();
                            }
                            Expect("}");
                            cs.Resources.Add(rb);
                        }
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == ',') _lexer.Pos++;
                        SkipWs();
                    }
                    Expect("]");
                }
            }
            else if (Peek("state ") || Peek("base "))
            {
                cs.States.Add(ParseStateDef());
            }
            else
            {
                throw Err($"Unexpected in compute_shader '{name}': '{PeekWord()}'");
            }
            SkipWs();
        }

        Expect("}");
        return cs;
    }

    private ComputeShaderDecl? ParseGpuKernel()
    {
        if (Peek("compute_kernel"))
            _lexer.Pos += 14;
        else if (Peek("@compute_kernel"))
            _lexer.Pos += 15;
        SkipWs();
        var name = ParseWord();
        var cs = new ComputeShaderDecl { Name = name };
        SkipWs();
        var body = ExtractBracedBlock();
        if (body != null)
            cs.States.Add(new StateDefNode { Name = name + "_body", AsmBlock = body });
        return cs;
    }

    private StructDecl ParseStruct()
    {
        Expect("struct ");
        var name = ParseWord();
        var sd = new StructDecl { Name = name };
        SkipWs();
        Expect("{");
        SkipWs();
        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
        {
            if (Peek("var "))
            {
                sd.Fields.Add(ParseVarDecl());
            }
            else
            {
                SkipWs();
                if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '}') break;
                throw Err($"Unexpected in struct '{name}': '{PeekWord()}'");
            }
            SkipWs();
        }
        Expect("}");
        return sd;
    }

    private FragmentShaderDecl? ParseFragmentShader()
    {
        if (Peek("fragment_shader"))
            _lexer.Pos += 15;
        else if (Peek("@fragment_shader"))
            _lexer.Pos += 16;

        SkipWs();
        var name = ParseWord();
        var fs = new FragmentShaderDecl { Name = name };

        Expect("{");
        SkipWs();

        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
        {
            SkipWs();
            if (Peek("early_depth_stencil"))
            {
                _lexer.Pos += 17;
                fs.EarlyDepthStencil = true;
            }
            else if (Peek("alpha_to_coverage"))
            {
                _lexer.Pos += 17;
                fs.AlphaToCoverage = true;
            }
            else if (Peek("state ") || Peek("base "))
            {
                fs.States.Add(ParseStateDef());
            }
            else
            {
                throw Err($"Unexpected in fragment_shader '{name}': '{PeekWord()}'");
            }
            SkipWs();
        }

        Expect("}");
        return fs;
    }

    private VertexShaderDecl? ParseVertexShader()
    {
        if (Peek("vertex_shader"))
            _lexer.Pos += 13;
        else if (Peek("@vertex_shader"))
            _lexer.Pos += 14;

        SkipWs();
        var name = ParseWord();
        var vs = new VertexShaderDecl { Name = name };

        Expect("{");
        SkipWs();

        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
        {
            SkipWs();
            if (Peek("input_layout:"))
            {
                _lexer.Pos += 12;
                SkipWs();
                vs.InputLayout = ParseWord();
            }
            else if (Peek("state ") || Peek("base "))
            {
                vs.States.Add(ParseStateDef());
            }
            else
            {
                throw Err($"Unexpected in vertex_shader '{name}': '{PeekWord()}'");
            }
            SkipWs();
        }

        Expect("}");
        return vs;
    }

    private RayTracingShaderDecl? ParseRayTracingShader()
    {
        if (Peek("ray_shader"))
            _lexer.Pos += 11;
        else if (Peek("@ray_shader"))
            _lexer.Pos += 12;

        SkipWs();
        var name = ParseWord();
        var rt = new RayTracingShaderDecl { Name = name };

        Expect("{");
        SkipWs();

        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
        {
            SkipWs();
            if (Peek("max_recursion:"))
            {
                _lexer.Pos += 14;
                SkipWs();
                var n = "";
                while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                    n += _lexer.Src[_lexer.Pos++];
                if (int.TryParse(n, out var d)) rt.MaxRecursionDepth = d;
            }
            else if (Peek("state ") || Peek("base "))
            {
                rt.States.Add(ParseStateDef());
            }
            else
            {
                throw Err($"Unexpected in ray_shader '{name}': '{PeekWord()}'");
            }
            SkipWs();
        }

        Expect("}");
        return rt;
    }

    private LocalGroupDecl? ParseLocalGroup()
    {
        if (Peek("local_group"))
            _lexer.Pos += 11;
        else if (Peek("@local_group"))
            _lexer.Pos += 12;

        SkipWs();
        var name = ParseWord();
        var lg = new LocalGroupDecl { Name = name };

        Expect("{");
        SkipWs();

        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
        {
            SkipWs();
            if (Peek("size:"))
            {
                _lexer.Pos += 5;
                SkipWs();
                var t = ParseWord().Replace("x", ",").Split(',');
                if (t.Length >= 1 && int.TryParse(t[0], out var x)) lg.Width = x;
                if (t.Length >= 2 && int.TryParse(t[1], out var y)) lg.Height = y;
            }
            else if (Peek("shared:"))
            {
                _lexer.Pos += 7;
                SkipWs();
                if (_lexer.Src[_lexer.Pos] == '[')
                {
                    _lexer.Pos++;
                    SkipWs();
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
                    {
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == '{')
                        {
                            _lexer.Pos++;
                            SkipWs();
                            var sm = new SharedMemoryDecl();
                            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
                            {
                                if (Peek("name:"))
                                {
                                    _lexer.Pos += 5;
                                    SkipWs();
                                    sm.Name = ParseWord();
                                }
                                else if (Peek("size:"))
                                {
                                    _lexer.Pos += 5;
                                    SkipWs();
                                    var n = "";
                                    while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                                        n += _lexer.Src[_lexer.Pos++];
                                    if (int.TryParse(n, out var s)) sm.SizeBytes = s;
                                }
                                else
                                {
                                    _lexer.Pos += ParseWord().Length;
                                }
                                SkipWs();
                            }
                            Expect("}");
                            lg.SharedVariables.Add(sm);
                        }
                        SkipWs();
                        if (_lexer.Src[_lexer.Pos] == ',') _lexer.Pos++;
                        SkipWs();
                    }
                    Expect("]");
                }
            }
            else
            {
                throw Err($"Unexpected in local_group '{name}': '{PeekWord()}'");
            }
            SkipWs();
        }

        Expect("}");
        return lg;
    }

    private CorporateCryptoConfig ParseCryptoConfig()
    {
        Expect("crypto:");
        SkipWs();
        var config = new CorporateCryptoConfig();

        SkipWs();

        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '{')
        {
            _lexer.Pos++;
            SkipWs();

            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
            {
                if (Peek("transport:"))
                {
                    _lexer.Pos += 9;
                    SkipWs();
                    var m = Regex.Match(_lexer.Src[_lexer.Pos..], @"^(tls[_0-9]+|wireguard)");
                    if (m.Success)
                    {
                        var val = m.Value.ToLower();
                        if (val.Contains("tls13") || val == "tls_1_3") config.Transport = CryptoTransportMode.TLS13;
                        else if (val.Contains("tls12")) config.Transport = CryptoTransportMode.TLS12;
                        else if (val.Contains("tls11")) config.Transport = CryptoTransportMode.TLS11;
                        else if (val.Contains("tls10") || val == "tls") config.Transport = CryptoTransportMode.TLS10;
                        else if (val == "wireguard") config.Transport = CryptoTransportMode.WireGuard;
                        _lexer.Pos += m.Length;
                    }
                    else if (Peek("tls_1_3"))
                    {
                        config.Transport = CryptoTransportMode.TLS13;
                        _lexer.Pos += 7;
                    }
                }
                else if (Peek("session:"))
                {
                    _lexer.Pos += 8;
                    SkipWs();
                    if (Peek("double_ratchet"))
                    {
                        config.Session = CryptoSessionMode.DoubleRatchet;
                        _lexer.Pos += 14;
                    }
                    else if (Peek("signal"))
                    {
                        config.Session = CryptoSessionMode.Signal;
                        _lexer.Pos += 6;
                    }
                }
                else if (Peek("payload:"))
                {
                    _lexer.Pos += 8;
                    SkipWs();
                    if (Peek("aes_256_gcm"))
                    {
                        config.Payload = CryptoPayloadMode.AES256GCM;
                        _lexer.Pos += 10;
                    }
                    else if (Peek("chacha20_poly1305"))
                    {
                        config.Payload = CryptoPayloadMode.ChaCha20Poly1305;
                        _lexer.Pos += 16;
                    }
                }
                else if (Peek("post_quantum:"))
                {
                    _lexer.Pos += 13;
                    SkipWs();
                    if (Peek("hybrid"))
                    {
                        config.PostQuantum = PostQuantumMode.HybridX25519MLKEM;
                        _lexer.Pos += 5;
                    }
                    else if (Peek("ml_kem_1024"))
                    {
                        config.PostQuantum = PostQuantumMode.MLKEM1024;
                        _lexer.Pos += 11;
                    }
                    else if (Peek("ml_kem_768"))
                    {
                        config.PostQuantum = PostQuantumMode.MLKEM768;
                        _lexer.Pos += 9;
                    }
                }
                else if (Peek("key_rotation:"))
                {
                    _lexer.Pos += 13;
                    SkipWs();
                    if (Peek("every("))
                    {
                        _lexer.Pos += 6;
                        var numStr = "";
                        while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                        {
                            numStr += _lexer.Src[_lexer.Pos];
                            _lexer.Pos++;
                        }
                        if (int.TryParse(numStr, out var num))
                        {
                            SkipWs();
                            if (Peek("s)"))
                            {
                                config.KeyRotationSeconds = num;
                                _lexer.Pos += 2;
                            }
                            else if (Peek("mb)"))
                            {
                                config.KeyRotationBytes = num * 1_000_000;
                                _lexer.Pos += 3;
                            }
                        }
                    }
                }
                else if (Peek("ciphers:"))
                {
                    _lexer.Pos += 8;
                    SkipWs();
                    if (_lexer.Src[_lexer.Pos] == '[')
                    {
                        _lexer.Pos++;
                        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
                        {
                            var cipher = ParseWord();
                            config.Ciphers.Add(cipher);
                            SkipWs();
                            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
                        }
                        Expect("]");
                    }
                }
                else
                {
                    SkipToEndOfLine();
                }
                SkipWs();
            }

            Expect("}");
        }

        return config;
    }

    private ZeroTrustConfig ParseZeroTrustConfig()
    {
        var config = new ZeroTrustConfig();

        if (Peek("access:"))
        {
            _lexer.Pos += 7;
            SkipWs();
        }

        if (Peek("zero_trust"))
        {
            _lexer.Pos += 10;
            SkipWs();
        }

        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '{')
        {
            Expect("{");
            SkipWs();

            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
            {
                SkipWs();
                if (Peek("identity:"))
                {
                    _lexer.Pos += 9;
                    SkipWs();
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n' && _lexer.Src[_lexer.Pos] != '\r' && _lexer.Src[_lexer.Pos] != ',' && _lexer.Src[_lexer.Pos] != '{' && _lexer.Src[_lexer.Pos] != '}')
                    {
                        if (_lexer.Src[_lexer.Pos] == '+')
                        {
                            _lexer.Pos++;
                            SkipWs();
                            continue;
                        }
                        var method = ParseWord();
                        if (method == "certificate") config.IdentityAuth |= AuthMethod.Certificate;
                        else if (method == "hardware_key" || method == "yubikey") config.IdentityAuth |= AuthMethod.HardwareKey;
                        else if (method == "tpm") config.IdentityAuth |= AuthMethod.TPM;
                        else if (method == "biometric") config.IdentityAuth |= AuthMethod.Biometric;
                        else break;
                        SkipWs();
                    }
                }
                else if (Peek("session:") || Peek("time:"))
                {
                    SkipWs();
                    if (Peek("max("))
                    {
                        _lexer.Pos += 4;
                        var hrs = "";
                        while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                        {
                            hrs += _lexer.Src[_lexer.Pos];
                            _lexer.Pos++;
                        }
                        if (int.TryParse(hrs, out var h))
                            config.MaxSessionHours = h;
                        Expect("h)");
                        _lexer.Pos += 2;
                    }
                }
                else if (Peek("behavior:") || Peek("anomaly:"))
                {
                    _lexer.Pos += 9;
                    SkipWs();
                    config.MLAnomalyDetection = Peek("ml_") || Peek("ml_");
                    if (Peek("ml_")) _lexer.Pos += 3;
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n' && _lexer.Src[_lexer.Pos] != '\r' && _lexer.Src[_lexer.Pos] != ',' && _lexer.Src[_lexer.Pos] != '{' && _lexer.Src[_lexer.Pos] != '}')
                    {
                        ParseWord();
                        SkipWs();
                    }
                }
                else if (Peek("device:") || Peek("tpm"))
                {
                    config.TPMAttestation = true;
                    SkipToEndOfLine();
                }
                else if (Peek("mfa:") || Peek("require_mfa"))
                {
                    config.RequireMFA = true;
                    SkipToEndOfLine();
                }
                else if (Peek("threshold:"))
                {
                    _lexer.Pos += 10;
                    SkipWs();
                    var th = "";
                    while (_lexer.Pos < _lexer.Src.Length && (char.IsDigit(_lexer.Src[_lexer.Pos]) || _lexer.Src[_lexer.Pos] == '.'))
                    {
                        th += _lexer.Src[_lexer.Pos];
                        _lexer.Pos++;
                    }
                    if (double.TryParse(th, out var threshold))
                        config.AnomalyThreshold = threshold;
                }
                else
                {
                    SkipToEndOfLine();
                }
                SkipWs();
            }

            Expect("}");
        }

        return config;
    }

    private void ParseSegments(NetworkNode network)
    {
        Expect("segments:");
        SkipWs();
        Expect("[");
        SkipWs();

        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
        {
            SkipWs();
            if (_lexer.Pos >= _lexer.Src.Length || _lexer.Src[_lexer.Pos] == ']') break;

            if (_lexer.Src[_lexer.Pos] == '{')
            {
                _lexer.Pos++;
                SkipWs();
                var segment = new NetworkSegment();

                int braceDepth = 1;
                while (_lexer.Pos < _lexer.Src.Length && braceDepth > 0)
                {
                    if (_lexer.Src[_lexer.Pos] == '{') { braceDepth++; _lexer.Pos++; }
                    else if (_lexer.Src[_lexer.Pos] == '}') { braceDepth--; if (braceDepth == 0) { _lexer.Pos++; break; } _lexer.Pos++; }
                    else
                    {
                        if (Peek("vlan:"))
                        {
                            _lexer.Pos += 5;
                            SkipWs();
                            var vlan = "";
                            while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                            {
                                vlan += _lexer.Src[_lexer.Pos];
                                _lexer.Pos++;
                            }
                            if (int.TryParse(vlan, out var v))
                                segment.Vlan = v;
                        }
                        else if (Peek("access:"))
                        {
                            _lexer.Pos += 7;
                            SkipWs();
                            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '[')
                            {
                                _lexer.Pos++;
                                while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
                                {
                                    var resource = ParseWord();
                                    segment.AllowedResources.Add(resource);
                                    SkipWs();
                                    if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
                                }
                                if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ']') _lexer.Pos++;
                            }
                        }
                        else if (Peek("isolated"))
                        {
                            segment.Isolated = true;
                            _lexer.Pos += 8;
                        }
                        else if (Peek("name:"))
                        {
                            _lexer.Pos += 5;
                            SkipWs();
                            segment.Name = ParseWord();
                        }
                        else
                        {
                            _lexer.Pos++;
                        }
                        SkipWs();
                    }
                }
                
                SkipWs();
                network.Segments.Add(segment);
            }
            else
            {
                var name = ParseWord();
                network.Segments.Add(new NetworkSegment { Name = name, Vlan = network.Segments.Count * 10 + 10 });
            }
            SkipWs();
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
        }

        Expect("]");
    }

    private void ParseSites(NetworkNode network)
    {
        Expect("sites:");
        SkipWs();
        Expect("[");
        SkipWs();

        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
        {
            if (_lexer.Src[_lexer.Pos] == '{')
            {
                _lexer.Pos++;
                SkipWs();
                var site = new NetworkSite();

                while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
                {
                    if (Peek("name:"))
                    {
                        _lexer.Pos += 5;
                        SkipWs();
                        site.Name = ParseWord();
                    }
                    else if (Peek("role:"))
                    {
                        _lexer.Pos += 5;
                        SkipWs();
                        var role = ParseWord().ToLower();
                        site.Role = role switch
                        {
                            "primary" => SiteRole.Primary,
                            "replica" => SiteRole.Replica,
                            "backup" => SiteRole.Backup,
                            _ => SiteRole.Endpoint
                        };
                    }
                    else if (Peek("primary") || Peek("address:"))
                    {
                        _lexer.Pos += 8;
                        SkipWs();
                        var m = Regex.Match(_lexer.Src[_lexer.Pos..], @"^""([^""]*)""");
                        if (m.Success)
                        {
                            site.PrimaryAddress = m.Groups[1].Value;
                            _lexer.Pos += m.Length;
                        }
                    }
                    else
                    {
                        SkipToEndOfLine();
                    }
                    SkipWs();
                }

                Expect("}");
                network.Sites.Add(site);
            }
            else
            {
                var name = ParseWord();
                network.Sites.Add(new NetworkSite { Name = name, Role = SiteRole.Endpoint });
            }
            SkipWs();
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
        }

        Expect("]");
    }

    private ResilienceConfig ParseResilienceConfig()
    {
        Expect("resilience:");
        SkipWs();
        var config = new ResilienceConfig();

        if (_lexer.Src[_lexer.Pos] == '{')
        {
            Expect("{");
            SkipWs();

            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
            {
                if (Peek("multipath:"))
                {
                    _lexer.Pos += 9;
                    SkipWs();
                    if (Peek("active_active"))
                    {
                        config.Multipath = MultipathMode.ActiveActive;
                        _lexer.Pos += 12;
                    }
                    else if (Peek("active_standby"))
                    {
                        config.Multipath = MultipathMode.ActiveStandby;
                        _lexer.Pos += 13;
                    }
                }
                else if (Peek("failover:"))
                {
                    _lexer.Pos += 9;
                    SkipWs();
                    var ms = "";
                    while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                    {
                        ms += _lexer.Src[_lexer.Pos];
                        _lexer.Pos++;
                    }
                    if (int.TryParse(ms, out var m))
                        config.FailoverMs = m;
                    if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == 'm') _lexer.Pos++;
                }
                else if (Peek("mesh:") || Peek("nodes:"))
                {
                    _lexer.Pos += 5;
                    SkipWs();
                    if (Peek("raft"))
                    {
                        config.Consensus = ConsensusProtocol.Raft;
                        _lexer.Pos += 4;
                    }
                    else if (Peek("paxos"))
                    {
                        config.Consensus = ConsensusProtocol.Paxos;
                        _lexer.Pos += 5;
                    }
                    else
                    {
                        var nodes = "";
                        while (_lexer.Pos < _lexer.Src.Length && char.IsDigit(_lexer.Src[_lexer.Pos]))
                        {
                            nodes += _lexer.Src[_lexer.Pos];
                            _lexer.Pos++;
                        }
                        if (int.TryParse(nodes, out var n))
                            config.MeshNodes = n;
                    }
                }
                else
                {
                    SkipToEndOfLine();
                }
                SkipWs();
            }

            Expect("}");
        }

        return config;
    }

    private void SkipToEndOfLine()
    {
        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n' && _lexer.Src[_lexer.Pos] != '\r')
            _lexer.Pos++;
    }

    // ════════════════════════════════════════
    // NEW v2.2+ parsing methods
    // ════════════════════════════════════════

    private Directive ParseDirective()
    {
        Expect("#");
        var name = ParseWord();
        // Only skip spaces/tabs, NOT newlines (to avoid consuming next line)
        while (_lexer.Pos < _lexer.Src.Length && (_lexer.Src[_lexer.Pos] == ' ' || _lexer.Src[_lexer.Pos] == '\t')) _lexer.Pos++;
        var value = "";
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n' && _lexer.Src[_lexer.Pos] != '\r')
        {
            int start = _lexer.Pos;
            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n' && _lexer.Src[_lexer.Pos] != '\r') _lexer.Pos++;
            value = _lexer.Src[start.._lexer.Pos].Trim();
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
        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
        {
            var m = Regex.Match(_lexer.Src[_lexer.Pos..], @"^""([^""]*)""");
            if (!m.Success) throw Err("Expected string literal in use cxx");
            decl.Headers.Add(m.Groups[1].Value);
            _lexer.Pos += m.Length;
            SkipWs();
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
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
        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ')')
        {
            var pName = ParseWord();
            SkipWs();
            Expect(":");
            SkipWs();
            // Consume raw C++ type until ',' or ')'
            int start = _lexer.Pos;
            int depth = 0;
            while (_lexer.Pos < _lexer.Src.Length)
            {
                if (_lexer.Src[_lexer.Pos] == '(' || _lexer.Src[_lexer.Pos] == '<') depth++;
                else if (_lexer.Src[_lexer.Pos] == ')' && depth == 0) break;
                else if (_lexer.Src[_lexer.Pos] == '>' && depth == 0) break;
                else if (_lexer.Src[_lexer.Pos] == ',' && depth == 0) break;
                _lexer.Pos++;
            }
            var rawType = _lexer.Src[start.._lexer.Pos].Trim();
            decl.Parameters.Add(new KernelParam { Name = pName, Type = new SimpleType { Name = rawType } });
            SkipWs();
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
        }
        Expect(")");
        SkipWs();
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '-')
        {
            Expect("->");
            SkipWs();
            // Consume rest of return type
            int start = _lexer.Pos;
            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n' && _lexer.Src[_lexer.Pos] != '\r') _lexer.Pos++;
            decl.ReturnType = _lexer.Src[start.._lexer.Pos].Trim();
        }
        return decl;
    }

    private List<Annotation> ParseAnnotations()
    {
        var list = new List<Annotation>();
        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '@')
        {
            _lexer.Pos++;
            var a = new Annotation();
            a.Name = ParseWord();
            SkipWs();
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '(')
            {
                _lexer.Pos++;
                SkipWs();
                while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ')')
                {
                    if (char.IsDigit(_lexer.Src[_lexer.Pos]) || _lexer.Src[_lexer.Pos] == '-' || _lexer.Src[_lexer.Pos] == '.')
                    {
                        // Positional numeric value: @hot(0.9)
                        var numVal = ParseAnnotationValue();
                        a.Args["_val"] = numVal;
                    }
                    else
                    {
                        var key = ParseWord();
                        SkipWs();
                        if (_lexer.Pos < _lexer.Src.Length && (_lexer.Src[_lexer.Pos] == ':' || _lexer.Src[_lexer.Pos] == '='))
                        {
                            _lexer.Pos++;
                            SkipWs();
                            var val = ParseAnnotationValue();
                            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '(')
                            {
                                // Handle nested like `switch_policy: quality_feedback(ssim, 0.92)`
                                _lexer.Pos++;
                                var nestStart = _lexer.Pos;
                                int depth = 1;
                                while (_lexer.Pos < _lexer.Src.Length && depth > 0)
                                {
                                    if (_lexer.Src[_lexer.Pos] == '(') depth++;
                                    else if (_lexer.Src[_lexer.Pos] == ')') depth--;
                                    if (depth > 0) _lexer.Pos++;
                                }
                                val += "(" + _lexer.Src[nestStart.._lexer.Pos] + ")";
                                _lexer.Pos++;
                            }
                            a.Args[key] = val;
                        }
                        else
                        {
                            a.Args["_val"] = key;
                        }
                    }
                    SkipWs();
                    if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
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
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ':')
        {
            _lexer.Pos++;
            SkipWs();
            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '@')
            {
                var ma = ParseSingleMemoryAnnotation();
                vd.MemoryAnnotations.Add(ma);
                SkipWs();
            }
            vd.Type = ParseBPlusType();
        }
        SkipWs();
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '=')
        {
            _lexer.Pos++;
            SkipWs();
            int start = _lexer.Pos;
            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n' && _lexer.Src[_lexer.Pos] != ';' && _lexer.Src[_lexer.Pos] != '}')
                _lexer.Pos++;
            vd.Init = _lexer.Src[start.._lexer.Pos].Trim();
        }
        return vd;
    }

    private MemoryAnnotation ParseSingleMemoryAnnotation()
    {
        var ma = new MemoryAnnotation();
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '@')
        {
            _lexer.Pos++;
            ma.Name = ParseWord();
            SkipWs();
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '(')
            {
                _lexer.Pos++;
                SkipWs();
                while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ')')
                {
                    var key = ParseWord();
                    SkipWs();
                    if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ':')
                    {
                        _lexer.Pos++;
                        SkipWs();
                        var val = ParseWord();
                        ma.Args[key] = val;
                    }
                    else
                    {
                        ma.Args["_val"] = key;
                    }
                    SkipWs();
                    if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
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
        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ')')
        {
            k.Parameters.Add(ParseKernelParam());
            SkipWs();
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
        }
        Expect(")");
        SkipWs();
        // Optional -> Output
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '-')
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
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '@')
            ParseAnnotations();
        p.Name = ParseWord();
        SkipWs();
        Expect(":");
        SkipWs();
        // Handle annotations before type name
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '@')
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
            else if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '|' && _lexer.Pos + 1 < _lexer.Src.Length && _lexer.Src[_lexer.Pos + 1] == '>')
            {
                _lexer.Pos += 2; // skip |>
                SkipWs();
            }
            else
                break;
            var op = new PipelineOp();
            op.Name = ParseWord();
            // Support dotted names like mpi.broadcast
            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '.')
            {
                _lexer.Pos++;
                op.Name += "." + ParseWord();
            }
            SkipWs();
            // Parse optional (args)
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '(')
            {
                _lexer.Pos++;
                SkipWs();
                while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ')')
                {
                    int argStart = _lexer.Pos;
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ',' && _lexer.Src[_lexer.Pos] != ')')
                        _lexer.Pos++;
                    var arg = _lexer.Src[argStart.._lexer.Pos].Trim();
                    if (arg != "") op.Args.Add(arg);
                    SkipWs();
                    if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
                }
                Expect(")");
                SkipWs();
            }
            // Parse optional { body } block (for if/for/while)
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '{')
            {
                _lexer.Pos++; SkipWs();
                op.NestedBody = ParsePipelineExpr(false); // no source — inherits from outer
                SkipWs();
                Expect("}");
                SkipWs();
                // Parse optional else { body } for if
                if (op.Name == "if" && _lexer.Pos + 3 < _lexer.Src.Length &&
                    _lexer.Src[_lexer.Pos..(_lexer.Pos + 4)] == "else")
                {
                    _lexer.Pos += 4; SkipWs();
                    if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '{')
                    {
                        _lexer.Pos++; SkipWs();
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
        if (_lexer.Pos + 1 < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '>' && _lexer.Src[_lexer.Pos + 1] == '>')
        {
            _lexer.Pos += 2;
            SkipWs();
            expr.OutputTarget = ParseWord();
        }
        return expr;
    }

    private void ParseNeedsGivesTouches(KernelDecl k)
    {
        while (_lexer.Pos < _lexer.Src.Length)
        {
            if (Peek("needs"))
            {
                Expect("needs");
                SkipWs();
                Expect(":");
                SkipWs();
                while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n' && !Peek("gives") && !Peek("touches") && !Peek("body"))
                {
                    int start = _lexer.Pos;
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n') _lexer.Pos++;
                    var line = _lexer.Src[start.._lexer.Pos].Trim();
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
                while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n' && !Peek("touches") && !Peek("body") && !Peek("needs"))
                {
                    int start = _lexer.Pos;
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n') _lexer.Pos++;
                    var line = _lexer.Src[start.._lexer.Pos].Trim();
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
                while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n' && !Peek("body") && !Peek("needs") && !Peek("gives"))
                {
                    if (Peek("reads"))
                    {
                        Expect("reads");
                        SkipWs();
                        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '[')
                        {
                            _lexer.Pos++;
                            SkipWs();
                            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
                            {
                                t.Reads.Add(ParseWord());
                                SkipWs();
                                if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
                            }
                            if (_lexer.Pos < _lexer.Src.Length) _lexer.Pos++; // skip ]
                        }
                    }
                    else if (Peek("writes"))
                    {
                        Expect("writes");
                        SkipWs();
                        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '[')
                        {
                            _lexer.Pos++;
                            SkipWs();
                            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
                            {
                                t.Writes.Add(ParseWord());
                                SkipWs();
                                if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
                            }
                            if (_lexer.Pos < _lexer.Src.Length) _lexer.Pos++; // skip ]
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
                    if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
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
                if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',')
                {
                    _lexer.Pos++;
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
                while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']')
                {
                    cw.Dimensions.Add(int.Parse(ParseWord()));
                    SkipWs();
                    if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
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
                if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '[')
                {
                    _lexer.Pos++;
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

        // Optional parameters: pipeline Name(...)
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '(')
        {
            _lexer.Pos++;
            SkipWs();
            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ')')
            {
                p.Parameters.Add(ParseKernelParam());
                SkipWs();
                if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
            }
            Expect(")");
            SkipWs();
        }

        // Optional return type: -> Type
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Pos + 1 < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '-' && _lexer.Src[_lexer.Pos + 1] == '>')
        {
            _lexer.Pos += 2;
            SkipWs();
            p.ReturnType = ParseBPlusType();
            SkipWs();
        }

        // Expect '{' for body
        Expect("{");
        SkipWs();

        // Parse steps (supports both "step Name = KernelName" and "stage: StateName" and "pass Name()")
        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '}')
        {
            SkipWs();
            if (Peek("step"))
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
                if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '(')
                {
                    _lexer.Pos++;
                    SkipWs();
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ')')
                    {
                        int argStart = _lexer.Pos;
                        while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ',' && _lexer.Src[_lexer.Pos] != ')')
                            _lexer.Pos++;
                        var arg = _lexer.Src[argStart.._lexer.Pos].Trim();
                        if (arg != "") step.Args.Add(arg);
                        SkipWs();
                        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') { _lexer.Pos++; SkipWs(); }
                    }
                    Expect(")");
                }
                p.Steps.Add(step);
            }
            else if (Peek("stage"))
            {
                Expect("stage");
                SkipWs();
                Expect(":");
                SkipWs();
                var stateName = ParseWord();
                p.Steps.Add(new PipelineStep { Name = stateName, KernelName = stateName });
            }
            else if (Peek("pass"))
            {
                // pass <name>() — simplified step (kernel name = function name)
                Expect("pass");
                SkipWs();
                var funcName = ParseWord();
                SkipWs();
                if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '(')
                {
                    _lexer.Pos++;
                    while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ')') _lexer.Pos++;
                    if (_lexer.Pos < _lexer.Src.Length) _lexer.Pos++;
                }
                p.Steps.Add(new PipelineStep { Name = funcName, KernelName = funcName });
            }
            else
            {
                // Skip unknown lines (e.g. queue: compute) to avoid infinite loop
                while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n' && _lexer.Src[_lexer.Pos] != '}') _lexer.Pos++;
            }
            SkipWs();
            // Skip semicolons and commas
            while (_lexer.Pos < _lexer.Src.Length && (_lexer.Src[_lexer.Pos] == ';' || _lexer.Src[_lexer.Pos] == ','))
                _lexer.Pos++;
            SkipWs();
        }
        Expect("}");
        SkipWs();
        // Telemetry block
        if (Peek("telemetry"))
        {
            Expect("telemetry");
            SkipWs();
            Expect(":");
            SkipWs();
            var tb = new TelemetryBlock();
            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n' && Peek("log"))
            {
                Expect("log");
                SkipWs();
                var entry = new TelemetryEntry();
                entry.LogSource = ParseWord();
                SkipWs();
                Expect("->");
                SkipWs();
                var m = Regex.Match(_lexer.Src[_lexer.Pos..], @"^""([^""]*)""");
                if (m.Success)
                {
                    entry.FilePath = m.Groups[1].Value;
                    _lexer.Pos += m.Length;
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
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '-')
        {
            Expect("->");
            SkipWs();
            e.ReturnType = ParseWord();
        }
        // Body is everything until end or next top-level construct
        if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '\n')
        {
            _lexer.Pos++;
            SkipWs();
        }
        // Parse body lines
        while (_lexer.Pos < _lexer.Src.Length && !Peek("state ") && !Peek("kernel") && !Peek("pipeline")
               && !Peek("entry") && !Peek("enum ") && !Peek("import ") && !Peek("context")
               && !Peek("parallel ") && !Peek("use cxx") && !Peek("extern") && _lexer.Src[_lexer.Pos] != '#')
        {
            int start = _lexer.Pos;
            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != '\n') _lexer.Pos++;
            var line = _lexer.Src[start.._lexer.Pos].Trim();
            if (line != "") e.BodyLines.Add(line);
            if (_lexer.Pos < _lexer.Src.Length) _lexer.Pos++;
            SkipWs();
        }
        return e;
    }

    // --- Helpers ---

    private string ParseWord() => _lexer.ParseWord();

    private string ParseType()
    {
        var name = ParseWord();
        SkipWs();

        // Mojo-style: simd<T, N>
        if (name.Equals("simd", StringComparison.OrdinalIgnoreCase) && _lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '<')
        {
            _lexer.Pos++;
            var elemType = ParseWord();
            SkipWs();
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == ',') _lexer.Pos++;
            SkipWs();
            var lanes = ParseWord();
            SkipWs();
            if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '>') _lexer.Pos++;
            name = $"simd<{elemType},{lanes}>";
        }
        else if (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] == '[')
        {
            _lexer.Pos++;
            int start = _lexer.Pos;
            while (_lexer.Pos < _lexer.Src.Length && _lexer.Src[_lexer.Pos] != ']') _lexer.Pos++;
            var inner = _lexer.Src[start.._lexer.Pos].Trim();
            if (_lexer.Pos < _lexer.Src.Length) _lexer.Pos++;
            if (string.IsNullOrEmpty(inner))
                name += "[]";
            else
                name += $"[{inner}]";
        }
        return name;
    }

    private string ConsumeUntilOr(string terminators) => _lexer.ConsumeUntilOr(terminators);

    private string? ExtractBracedBlock() => _lexer.ExtractBracedBlock();

    private string ParseAnnotationValue() => _lexer.ParseAnnotationValue();

    private bool Peek(string s) => _lexer.Peek(s);

    private string PeekWord() => _lexer.PeekWord();

    private void Expect(string s)
    {
        SkipWs();
        if (_lexer.Pos + s.Length > _lexer.Src.Length || !_lexer.Src.AsSpan(_lexer.Pos, s.Length).SequenceEqual(s))
        {
            int len = Math.Min(10, _lexer.Src.Length - _lexer.Pos);
            throw Err($"Expected '{s}' at position {_lexer.Pos} (srcLen={_lexer.Src.Length}), got '{(_lexer.Pos + len <= _lexer.Src.Length ? _lexer.Src.AsSpan(_lexer.Pos, len).ToString() : _lexer.Src[_lexer.Pos..])}'");
        }
        _lexer.Pos += s.Length;
    }

    private static string PeekN(int n) => ""; // unused overload placeholder

    private bool IsVarDeclStart() => _lexer.IsVarDeclStart();

    private static string ReadUntilWsOr(string s, char[] terminators)
    {
        int i = 0;
        while (i < s.Length && !char.IsWhiteSpace(s[i]) && !terminators.Contains(s[i]))
            i++;
        return s[..i];
    }

    private ParseException Err(string msg) 
    { 
        var suggestion = "";
        
        // Smart suggestions based on common errors
        if (msg.Contains("Unexpected") && msg.Contains("'state'"))
        {
            suggestion = "Did you forget a closing brace '}' before 'state'?";
        }
        else if (msg.Contains("Expected"))
        {
            if (msg.Contains("'{'") || msg.Contains("{"))
                suggestion = "State body must start with '{'. Example: state Red { ... }";
            else if (msg.Contains("'}'") || msg.Contains("}"))
                suggestion = "State body must end with '}'. Check for missing closing brace.";
            else if (msg.Contains("'on'") || msg.Contains("on "))
                suggestion = "Transition syntax: on <event> -> <target>. Example: on timer -> Green";
        }
        else if (msg.Contains("Duplicate"))
        {
            suggestion = "Each state must have a unique name. Rename or remove duplicate.";
        }
        
        // Get context: 30 chars before error
        int ctxStart = Math.Max(0, _lexer.Pos - 30);
        int ctxLen = Math.Min(60, _lexer.Src.Length - ctxStart);
        var context = _lexer.Src.Substring(ctxStart, ctxLen).Replace("\n", "\\n").Replace("\r", "");
        if (ctxStart > 0) context = "..." + context;
        
        // Calculate column relative to line start
        int lineStart = _lexer.Src.LastIndexOf('\n', Math.Max(0, _lexer.Pos - 1)) + 1;
        int column = _lexer.Pos - lineStart + 1;
        
        throw new ParseException(msg, _lexer.Line, column, context, suggestion);
    }

    private static string StripComments(string src)
    {
        src = Regex.Replace(src, @"//.*", "");
        return src;
    }

    private void SkipWs()
    {
        while (_lexer.Pos < _lexer.Src.Length && char.IsWhiteSpace(_lexer.Src[_lexer.Pos]))
        {
            if (_lexer.Src[_lexer.Pos] == '\n') _lexer.Line++;
            _lexer.Pos++;
        }
    }

    // Post-parse validation
    public static List<string> Validate(ProgramNode program)
    {
        var errors = new List<string>();
        var stateNames = new HashSet<string>();
        foreach (var s in program.States) stateNames.Add(s.Name);

        // Check cyclic inheritance (DFS)
        foreach (var s in program.States)
        {
            if (s.BaseClass == null) continue;
            if (!stateNames.Contains(s.BaseClass))
            {
                errors.Add($"Undefined base class '{s.BaseClass}' for state '{s.Name}'");
                continue;
            }
            // Detect cycles: A → B → C → A
            var visited = new HashSet<string>();
            var cur = s.BaseClass;
            while (cur != null)
            {
                if (!visited.Add(cur))
                {
                    errors.Add($"Cyclic inheritance detected: state '{s.Name}' chain contains '{cur}'");
                    break;
                }
                var parent = program.States.Find(st => st.Name == cur);
                if (parent == null || parent.BaseClass == null) break;
                cur = parent.BaseClass;
            }
        }

        // Check void type
        foreach (var s in program.States)
            foreach (var v in s.Variables)
                if (v.Type == "void")
                    errors.Add($"Variable '{v.Name}' in state '{s.Name}' has type 'void' — not allowed");

        // Check variable initialization type compatibility
        foreach (var s in program.States)
            foreach (var v in s.Variables)
                if (v.DefaultValue != null && !IsTypeCompatible(v.Type, v.DefaultValue))
                    errors.Add($"Type mismatch: '{v.Name}: {v.Type}' cannot be initialized with '{v.DefaultValue}'");

        // Check parallel independent states
        foreach (var p in program.ParallelBlocks)
        {
            var shared = new HashSet<string>();
            for (int i = 0; i < p.States.Count; i++)
            {
                foreach (var v in p.States[i].Variables)
                {
                    if (!shared.Add(v.Name))
                        errors.Add($"State '{p.States[i].Name}' in parallel block '{p.Name}' shares variable '{v.Name}' — data race risk");
                }
            }
        }

        return errors;
    }

    private static bool IsTypeCompatible(string type, string value)
    {
        if (type is "int" or "i32" or "i64" or "u32" or "u64")
            return int.TryParse(value, out _) || long.TryParse(value, out _);
        if (type is "float" or "f32" or "double" or "f64")
            return double.TryParse(value, out _);
        if (type is "bool" or "boolean")
            return value is "true" or "false" or "0" or "1";
        if (type is "string")
            return value.StartsWith('"') && value.EndsWith('"');
        return true; // custom types pass through
    }
}

public class ParseException : Exception
{
    public int Line { get; }
    public int Column { get; }
    public string Context { get; }
    public string Suggestion { get; }

    public ParseException(string msg, int line = 0, int column = 0, string context = "", string suggestion = "") 
        : base(msg)
    {
        Line = line;
        Column = column;
        Context = context;
        Suggestion = suggestion;
    }

    public override string ToString()
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine($"Error at line {Line}, column {Column}:");
        sb.AppendLine($"  {Message}");
        if (!string.IsNullOrEmpty(Context))
            sb.AppendLine($"  Context: {Context}");
        if (!string.IsNullOrEmpty(Suggestion))
            sb.AppendLine($"  Suggestion: {Suggestion}");
        return sb.ToString();
    }
}
