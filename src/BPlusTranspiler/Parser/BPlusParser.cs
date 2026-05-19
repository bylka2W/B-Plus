using System.Text.RegularExpressions;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Parser;

public partial class BPlusParser
{
    private string _src = "";
    private int _pos;
    private int _line;
    private const int MaxNestingDepth = 100;
    private static readonly char[] RtlChars = {
        '\u200E', '\u200F', '\u202A', '\u202B', '\u202C',
        '\u202D', '\u202E', '\u2066', '\u2067', '\u2068', '\u2069'
    };

    public ProgramNode Parse(string source)
    {
        _src = StripComments(source);
        _pos = 0;
        _line = 1;

        // RTL override filter (CWE-451)
        foreach (var c in RtlChars)
        {
            if (_src.Contains(c))
                throw new ParseException($"RTL override character U+{(int)c:X4} detected — possible code injection (CWE-451)");
        }
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
                    if (_pos < _src.Length && _src[_pos] == '@')
                    {
                        program.StandaloneAnnotations.AddRange(annotations);
                    }
                    else if (Peek("corporate_network"))
                    {
                        var network = ParseNetwork(corporatePrefix: true);
                        if (network != null) program.Networks.Add(network);
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

    private static int _stateIdCounter;
    private readonly Dictionary<string, StateDefNode> _allStates = new();

    private StateDefNode ParseStateDef(int depth = 0)
    {
        if (depth > MaxNestingDepth)
            throw Err($"Maximum nesting depth {MaxNestingDepth} exceeded — possible stack overflow");

        var state = new StateDefNode();
        state.ParseLine = _line;
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
            // Self-inheritance
            if (state.BaseClass == state.Name)
                throw Err($"Cyclic inheritance: state '{state.Name}' cannot inherit from itself");
        }

        _allStates[state.Name] = state;
        _stateIdCounter++;

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

        // Handle unconditional transitions: on [condition] -> Target
        string eventName;
        if (_pos < _src.Length && _src[_pos] == '[')
        {
            // Guard-only transition: on [health <= 0] -> Dead
            eventName = "__always__";
        }
        else if (_pos < _src.Length && _src[_pos] == '\'')
        {
            // Handle quoted char event names: on 'x' -> Target, on '\n' -> Target
            _pos++; // skip opening '
            if (_pos < _src.Length && _src[_pos] != '\'')
            {
                if (_src[_pos] == '\\' && _pos + 1 < _src.Length)
                {
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
            if (_pos < _src.Length && _src[_pos] == '\'') _pos++;
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

            // Handle history keyword
            if (Peek("history"))
            {
                _pos += 7;
                target = "__history__";
            }
            else
            {
                target = ParseWord();
                SkipWs();
                if (_pos < _src.Length && _src[_pos] == '<')
                {
                    int gs = _pos;
                    while (_pos < _src.Length && _src[_pos] != '>') _pos++;
                    if (_pos < _src.Length) _pos++;
                    target = _src[gs.._pos];
                }
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
        var prefix = _pos + 4 <= _src.Length && _src.AsSpan(_pos, 4).SequenceEqual("exit") ? "exit" : "enter";
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
            if (Peek("machine "))
            {
                _pos += 7;
                SkipWs();
                var machineName = ParseWord();
                SkipWs();
                Expect("{");
                SkipWs();
                var machine = new StateDefNode { Name = machineName };
                while (_pos < _src.Length && _src[_pos] != '}')
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
                throw Err($"Unexpected in parallel '{name}'");
            SkipWs();
        }
        Expect("}");
        return par;
    }

    private NetworkNode? ParseNetwork(bool corporatePrefix = false)
    {
        if (!corporatePrefix && Peek("corporate_network"))
            _pos += 16;
        var name = ParseWord();
        SkipWs();

        var network = new NetworkNode { Name = name };

        if (_pos < _src.Length && _src[_pos] == '"')
        {
            _pos++;
            int end = _src.IndexOf('"', _pos);
            if (end > _pos)
            {
                network.Description = _src[_pos..end];
                _pos = end + 1;
            }
        }

        while (_pos < _src.Length && _src[_pos] != '{')
        {
            if (Peek("protocol:"))
            {
                _pos += 8;
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
                _pos += 5;
                SkipWs();
                var m = Regex.Match(_src[_pos..], @"^""([^""]*)""");
                if (m.Success)
                {
                    network.Host = m.Groups[1].Value;
                    _pos += m.Length;
                }
            }
            else if (Peek("port:"))
            {
                _pos += 5;
                SkipWs();
                var portStr = "";
                while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                {
                    portStr += _src[_pos];
                    _pos++;
                }
                if (int.TryParse(portStr, out var port))
                    network.Port = port;
            }
            else if (Peek("auto_reconnect"))
            {
                network.AutoReconnect = true;
                _pos += 14;
            }
            else if (Peek("timeout:"))
            {
                _pos += 8;
                SkipWs();
                var timeoutStr = "";
                while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                {
                    timeoutStr += _src[_pos];
                    _pos++;
                }
                if (int.TryParse(timeoutStr, out var t))
                    network.TimeoutMs = t;
            }
            else if (Peek("heartbeat:"))
            {
                _pos += 10;
                SkipWs();
                var hbStr = "";
                while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                {
                    hbStr += _src[_pos];
                    _pos++;
                }
                if (int.TryParse(hbStr, out var hb))
                    network.HeartbeatIntervalMs = hb;
            }
            else if (Peek("retries:"))
            {
                _pos += 7;
                SkipWs();
                var retriesStr = "";
                while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                {
                    retriesStr += _src[_pos];
                    _pos++;
                }
                if (int.TryParse(retriesStr, out var r))
                    network.MaxRetries = r;
            }
            else if (Peek("tls"))
            {
                network.Security = SecurityLevel.TLS;
                _pos += 3;
            }
            else if (Peek("encrypted"))
            {
                network.Security = SecurityLevel.Encrypted;
                _pos += 9;
            }
            else
            {
                break;
            }
            SkipWs();
        }

        Expect("{");
        SkipWs();

        while (_pos < _src.Length && _src[_pos] != '}')
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

        while (_pos < _src.Length && _src[_pos] != '}')
        {
            SkipWs();
            if (Peek("consensus:"))
            {
                _pos += 9;
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
                _pos += 6;
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
                _pos += 4;
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
                _pos += 8;
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
                _pos += 9;
                SkipWs();
                var n = "";
                while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                    n += _src[_pos++];
                if (int.TryParse(n, out var mp)) chain.MaxPeers = mp;
            }
            else if (Peek("min_validators:"))
            {
                _pos += 14;
                SkipWs();
                var n = "";
                while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                    n += _src[_pos++];
                if (int.TryParse(n, out var mv)) chain.MinValidators = mv;
            }
            else if (Peek("block_time:"))
            {
                _pos += 10;
                SkipWs();
                var n = "";
                while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                    n += _src[_pos++];
                if (int.TryParse(n, out var bt)) chain.BlockTimeMs = bt;
            }
            else if (Peek("difficulty:"))
            {
                _pos += 10;
                SkipWs();
                var n = "";
                while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                    n += _src[_pos++];
                if (int.TryParse(n, out var d)) chain.Difficulty = d;
            }
            else if (Peek("min_stake:"))
            {
                _pos += 9;
                SkipWs();
                var n = "";
                while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                    n += _src[_pos++];
                if (long.TryParse(n, out var ms)) chain.MinStake = ms;
            }
            else if (Peek("shard_count:"))
            {
                _pos += 11;
                SkipWs();
                var n = "";
                while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                    n += _src[_pos++];
                if (int.TryParse(n, out var sc)) chain.ShardCount = sc;
            }
            else if (Peek("segments:"))
            {
                _pos += 9;
                SkipWs();
                if (_pos < _src.Length && _src[_pos] == '[')
                {
                    _pos++;
                    SkipWs();
                    while (_pos < _src.Length && _src[_pos] != ']')
                    {
                        SkipWs();
                        if (_src[_pos] == '{')
                        {
                            _pos++;
                            SkipWs();
                            var seg = new NetworkSegment();
                            while (_pos < _src.Length && _src[_pos] != '}')
                            {
                                if (Peek("name:"))
                                {
                                    _pos += 5;
                                    SkipWs();
                                    seg.Name = ParseWord();
                                }
                                else if (Peek("vlan:"))
                                {
                                    _pos += 5;
                                    SkipWs();
                                    var n = "";
                                    while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                                        n += _src[_pos++];
                                    if (int.TryParse(n, out var v)) seg.Vlan = v;
                                }
                                else
                                {
                                    _pos += ParseWord().Length;
                                }
                                SkipWs();
                            }
                            Expect("}");
                            chain.Segments.Add(seg);
                        }
                        SkipWs();
                        if (_src[_pos] == ',') _pos++;
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
                _pos += 10;
                SkipWs();
                while (_src[_pos] == '[')
                {
                    _pos++;
                    SkipWs();
                    var addr = "";
                    while (_pos < _src.Length && _src[_pos] != ']' && _src[_pos] != ',')
                    {
                        addr += _src[_pos++];
                    }
                    if (_pos < _src.Length && _src[_pos] == ']') _pos++;
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
                    if (_src[_pos] == ',') _pos++;
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

        if (_pos < _src.Length && _src[_pos] == '[')
        {
            _pos++;
            SkipWs();
            while (_pos < _src.Length && _src[_pos] != ']')
            {
                SkipWs();
                if (_src[_pos] == '{')
                {
                    _pos++;
                    SkipWs();
                    var entry = new LedgerEntry();
                    while (_pos < _src.Length && _src[_pos] != '}')
                    {
                        if (Peek("from:"))
                        {
                            _pos += 5;
                            SkipWs();
                            entry.From = ParseWord();
                        }
                        else if (Peek("to:"))
                        {
                            _pos += 3;
                            SkipWs();
                            entry.To = ParseWord();
                        }
                        else if (Peek("amount:"))
                        {
                            _pos += 7;
                            SkipWs();
                            var n = "";
                            while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                                n += _src[_pos++];
                            if (long.TryParse(n, out var amt)) entry.Amount = amt;
                        }
                        else
                        {
                            _pos += ParseWord().Length;
                        }
                        SkipWs();
                    }
                    Expect("}");
                    entries.Add(entry);
                }
                SkipWs();
                if (_src[_pos] == ',') _pos++;
                SkipWs();
            }
            Expect("]");
        }

        return entries;
    }

    private CorporateCryptoConfig ParseCryptoConfig()
    {
        Expect("crypto:");
        SkipWs();
        var config = new CorporateCryptoConfig();

        SkipWs();

        if (_pos < _src.Length && _src[_pos] == '{')
        {
            _pos++;
            SkipWs();

            while (_pos < _src.Length && _src[_pos] != '}')
            {
                if (Peek("transport:"))
                {
                    _pos += 9;
                    SkipWs();
                    var m = Regex.Match(_src[_pos..], @"^(tls[_0-9]+|wireguard)");
                    if (m.Success)
                    {
                        var val = m.Value.ToLower();
                        if (val.Contains("tls13") || val == "tls_1_3") config.Transport = CryptoTransportMode.TLS13;
                        else if (val.Contains("tls12")) config.Transport = CryptoTransportMode.TLS12;
                        else if (val.Contains("tls11")) config.Transport = CryptoTransportMode.TLS11;
                        else if (val.Contains("tls10") || val == "tls") config.Transport = CryptoTransportMode.TLS10;
                        else if (val == "wireguard") config.Transport = CryptoTransportMode.WireGuard;
                        _pos += m.Length;
                    }
                    else if (Peek("tls_1_3"))
                    {
                        config.Transport = CryptoTransportMode.TLS13;
                        _pos += 7;
                    }
                }
                else if (Peek("session:"))
                {
                    _pos += 8;
                    SkipWs();
                    if (Peek("double_ratchet"))
                    {
                        config.Session = CryptoSessionMode.DoubleRatchet;
                        _pos += 14;
                    }
                    else if (Peek("signal"))
                    {
                        config.Session = CryptoSessionMode.Signal;
                        _pos += 6;
                    }
                }
                else if (Peek("payload:"))
                {
                    _pos += 8;
                    SkipWs();
                    if (Peek("aes_256_gcm"))
                    {
                        config.Payload = CryptoPayloadMode.AES256GCM;
                        _pos += 10;
                    }
                    else if (Peek("chacha20_poly1305"))
                    {
                        config.Payload = CryptoPayloadMode.ChaCha20Poly1305;
                        _pos += 16;
                    }
                }
                else if (Peek("post_quantum:"))
                {
                    _pos += 13;
                    SkipWs();
                    if (Peek("hybrid"))
                    {
                        config.PostQuantum = PostQuantumMode.HybridX25519MLKEM;
                        _pos += 5;
                    }
                    else if (Peek("ml_kem_1024"))
                    {
                        config.PostQuantum = PostQuantumMode.MLKEM1024;
                        _pos += 11;
                    }
                    else if (Peek("ml_kem_768"))
                    {
                        config.PostQuantum = PostQuantumMode.MLKEM768;
                        _pos += 9;
                    }
                }
                else if (Peek("key_rotation:"))
                {
                    _pos += 13;
                    SkipWs();
                    if (Peek("every("))
                    {
                        _pos += 6;
                        var numStr = "";
                        while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                        {
                            numStr += _src[_pos];
                            _pos++;
                        }
                        if (int.TryParse(numStr, out var num))
                        {
                            SkipWs();
                            if (Peek("s)"))
                            {
                                config.KeyRotationSeconds = num;
                                _pos += 2;
                            }
                            else if (Peek("mb)"))
                            {
                                config.KeyRotationBytes = num * 1_000_000;
                                _pos += 3;
                            }
                        }
                    }
                }
                else if (Peek("ciphers:"))
                {
                    _pos += 8;
                    SkipWs();
                    if (_src[_pos] == '[')
                    {
                        _pos++;
                        while (_pos < _src.Length && _src[_pos] != ']')
                        {
                            var cipher = ParseWord();
                            config.Ciphers.Add(cipher);
                            SkipWs();
                            if (_pos < _src.Length && _src[_pos] == ',') { _pos++; SkipWs(); }
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
            _pos += 7;
            SkipWs();
        }

        if (Peek("zero_trust"))
        {
            _pos += 10;
            SkipWs();
        }

        if (_pos < _src.Length && _src[_pos] == '{')
        {
            Expect("{");
            SkipWs();

            while (_pos < _src.Length && _src[_pos] != '}')
            {
                SkipWs();
                if (Peek("identity:"))
                {
                    _pos += 9;
                    SkipWs();
                    while (_pos < _src.Length && _src[_pos] != '\n' && _src[_pos] != '\r' && _src[_pos] != ',' && _src[_pos] != '{' && _src[_pos] != '}')
                    {
                        if (_src[_pos] == '+')
                        {
                            _pos++;
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
                        _pos += 4;
                        var hrs = "";
                        while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                        {
                            hrs += _src[_pos];
                            _pos++;
                        }
                        if (int.TryParse(hrs, out var h))
                            config.MaxSessionHours = h;
                        Expect("h)");
                        _pos += 2;
                    }
                }
                else if (Peek("behavior:") || Peek("anomaly:"))
                {
                    _pos += 9;
                    SkipWs();
                    config.MLAnomalyDetection = Peek("ml_") || Peek("ml_");
                    if (Peek("ml_")) _pos += 3;
                    while (_pos < _src.Length && _src[_pos] != '\n' && _src[_pos] != '\r' && _src[_pos] != ',' && _src[_pos] != '{' && _src[_pos] != '}')
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
                    _pos += 10;
                    SkipWs();
                    var th = "";
                    while (_pos < _src.Length && (char.IsDigit(_src[_pos]) || _src[_pos] == '.'))
                    {
                        th += _src[_pos];
                        _pos++;
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

        while (_pos < _src.Length && _src[_pos] != ']')
        {
            SkipWs();
            if (_pos >= _src.Length || _src[_pos] == ']') break;

            if (_src[_pos] == '{')
            {
                _pos++;
                SkipWs();
                var segment = new NetworkSegment();

                int braceDepth = 1;
                while (_pos < _src.Length && braceDepth > 0)
                {
                    if (_src[_pos] == '{') { braceDepth++; _pos++; }
                    else if (_src[_pos] == '}') { braceDepth--; if (braceDepth == 0) { _pos++; break; } _pos++; }
                    else
                    {
                        if (Peek("vlan:"))
                        {
                            _pos += 5;
                            SkipWs();
                            var vlan = "";
                            while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                            {
                                vlan += _src[_pos];
                                _pos++;
                            }
                            if (int.TryParse(vlan, out var v))
                                segment.Vlan = v;
                        }
                        else if (Peek("access:"))
                        {
                            _pos += 7;
                            SkipWs();
                            if (_pos < _src.Length && _src[_pos] == '[')
                            {
                                _pos++;
                                while (_pos < _src.Length && _src[_pos] != ']')
                                {
                                    var resource = ParseWord();
                                    segment.AllowedResources.Add(resource);
                                    SkipWs();
                                    if (_pos < _src.Length && _src[_pos] == ',') { _pos++; SkipWs(); }
                                }
                                if (_pos < _src.Length && _src[_pos] == ']') _pos++;
                            }
                        }
                        else if (Peek("isolated"))
                        {
                            segment.Isolated = true;
                            _pos += 8;
                        }
                        else if (Peek("name:"))
                        {
                            _pos += 5;
                            SkipWs();
                            segment.Name = ParseWord();
                        }
                        else
                        {
                            _pos++;
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
            if (_pos < _src.Length && _src[_pos] == ',') { _pos++; SkipWs(); }
        }

        Expect("]");
    }

    private void ParseSites(NetworkNode network)
    {
        Expect("sites:");
        SkipWs();
        Expect("[");
        SkipWs();

        while (_pos < _src.Length && _src[_pos] != ']')
        {
            if (_src[_pos] == '{')
            {
                _pos++;
                SkipWs();
                var site = new NetworkSite();

                while (_pos < _src.Length && _src[_pos] != '}')
                {
                    if (Peek("name:"))
                    {
                        _pos += 5;
                        SkipWs();
                        site.Name = ParseWord();
                    }
                    else if (Peek("role:"))
                    {
                        _pos += 5;
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
                        _pos += 8;
                        SkipWs();
                        var m = Regex.Match(_src[_pos..], @"^""([^""]*)""");
                        if (m.Success)
                        {
                            site.PrimaryAddress = m.Groups[1].Value;
                            _pos += m.Length;
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
            if (_pos < _src.Length && _src[_pos] == ',') { _pos++; SkipWs(); }
        }

        Expect("]");
    }

    private ResilienceConfig ParseResilienceConfig()
    {
        Expect("resilience:");
        SkipWs();
        var config = new ResilienceConfig();

        if (_src[_pos] == '{')
        {
            Expect("{");
            SkipWs();

            while (_pos < _src.Length && _src[_pos] != '}')
            {
                if (Peek("multipath:"))
                {
                    _pos += 9;
                    SkipWs();
                    if (Peek("active_active"))
                    {
                        config.Multipath = MultipathMode.ActiveActive;
                        _pos += 12;
                    }
                    else if (Peek("active_standby"))
                    {
                        config.Multipath = MultipathMode.ActiveStandby;
                        _pos += 13;
                    }
                }
                else if (Peek("failover:"))
                {
                    _pos += 9;
                    SkipWs();
                    var ms = "";
                    while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                    {
                        ms += _src[_pos];
                        _pos++;
                    }
                    if (int.TryParse(ms, out var m))
                        config.FailoverMs = m;
                    if (_pos < _src.Length && _src[_pos] == 'm') _pos++;
                }
                else if (Peek("mesh:") || Peek("nodes:"))
                {
                    _pos += 5;
                    SkipWs();
                    if (Peek("raft"))
                    {
                        config.Consensus = ConsensusProtocol.Raft;
                        _pos += 4;
                    }
                    else if (Peek("paxos"))
                    {
                        config.Consensus = ConsensusProtocol.Paxos;
                        _pos += 5;
                    }
                    else
                    {
                        var nodes = "";
                        while (_pos < _src.Length && char.IsDigit(_src[_pos]))
                        {
                            nodes += _src[_pos];
                            _pos++;
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
        while (_pos < _src.Length && _src[_pos] != '\n' && _src[_pos] != '\r')
            _pos++;
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

        // Mojo-style: simd<T, N>
        if (name.Equals("simd", StringComparison.OrdinalIgnoreCase) && _pos < _src.Length && _src[_pos] == '<')
        {
            _pos++;
            var elemType = ParseWord();
            SkipWs();
            if (_pos < _src.Length && _src[_pos] == ',') _pos++;
            SkipWs();
            var lanes = ParseWord();
            SkipWs();
            if (_pos < _src.Length && _src[_pos] == '>') _pos++;
            name = $"simd<{elemType},{lanes}>";
        }
        else if (_pos < _src.Length && _src[_pos] == '[')
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
        // NOTE: SkipWs is NOT called here - caller should call SkipWs before Peek if needed
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
        if (_pos + s.Length > _src.Length || !_src.AsSpan(_pos, s.Length).SequenceEqual(s))
        {
            int len = Math.Min(10, _src.Length - _pos);
            throw Err($"Expected '{s}' at position {_pos}, got '{(_pos + len <= _src.Length ? _src.AsSpan(_pos, len).ToString() : _src[_pos..])}'");
        }
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
        int ctxStart = Math.Max(0, _pos - 30);
        int ctxLen = Math.Min(60, _src.Length - ctxStart);
        var context = _src.Substring(ctxStart, ctxLen).Replace("\n", "\\n").Replace("\r", "");
        if (ctxStart > 0) context = "..." + context;
        
        // Calculate column relative to line start
        int lineStart = _src.LastIndexOf('\n', Math.Max(0, _pos - 1)) + 1;
        int column = _pos - lineStart + 1;
        
        throw new ParseException(msg, _line, column, context, suggestion);
    }

    private static string StripComments(string src)
    {
        src = Regex.Replace(src, @"//.*", "");
        src = Regex.Replace(src, @"--.*", "");
        return src;
    }

    private void SkipWs()
    {
        while (_pos < _src.Length && char.IsWhiteSpace(_src[_pos]))
        {
            if (_src[_pos] == '\n') _line++;
            _pos++;
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
