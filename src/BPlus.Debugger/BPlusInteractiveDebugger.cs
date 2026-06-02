using System.Diagnostics;
using System.Text;
using BPlus.Core.Ast;
using BPlus.Targets.Generators;

namespace BPlus.Debugger;

public static class BPlusInteractiveDebugger
{
    public static int Run(ProgramNode program, string inputFile)
    {
        var gen = new PythonGenerator();
        var files = gen.GenerateFiles(program);
        var pyCode = files.Values.First();

        pyCode = StripEntryFunctions(pyCode);
        pyCode += MakeHarness(program);

        var tmpDir = Path.Combine(Path.GetTempPath(), "bpc_debug");
        Directory.CreateDirectory(tmpDir);
        var pyPath = Path.Combine(tmpDir, Path.GetFileNameWithoutExtension(inputFile) + "_debug.py");
        File.WriteAllText(pyPath, pyCode);

        Console.WriteLine($"B+ Interactive Debugger — {inputFile}");
        Console.WriteLine(new string('-', 50));

        var psi = new ProcessStartInfo("python", $"\"{pyPath}\"")
        {
            UseShellExecute = false,
        };
        psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
        using var proc = Process.Start(psi);
        if (proc == null)
        {
            Console.Error.WriteLine("Python not found. Install Python or check PATH.");
            return 1;
        }
        proc.WaitForExit();
        return 0;
    }

    static string StripEntryFunctions(string pyCode)
    {
        var nameIdx = pyCode.LastIndexOf("if __name__ == \"__main__\":");
        if (nameIdx >= 0)
            pyCode = pyCode.Substring(0, nameIdx);
        var defIdx = pyCode.LastIndexOf("\ndef main():");
        if (defIdx >= 0)
            pyCode = pyCode.Substring(0, defIdx);
        return pyCode;
    }

    static string MakeHarness(ProgramNode program)
    {
        var stateNames = new List<string>();
        void Walk(StateDefNode s) { stateNames.Add(s.Name); foreach (var ns in s.NestedStates) Walk(ns); }
        foreach (var s in program.States) Walk(s);
        foreach (var pb in program.ParallelBlocks)
            foreach (var s in pb.States) Walk(s);

        var ctxVars = program.Context?.Variables.Select(v => v.Name).ToList() ?? new List<string>();

        var statesJson = string.Join(", ", stateNames.Select(n => $"\"{n}\""));
        var ctxJson = string.Join(", ", ctxVars.Select(v => $"\"{v}\""));

        var sb = new StringBuilder();
        sb.AppendLine();
        sb.AppendLine("# B+ Interactive Debugger Harness");
        sb.AppendLine("import sys");
        sb.AppendLine("try:");
        sb.AppendLine("    sys.stdout.reconfigure(encoding='utf-8')");
        sb.AppendLine("except AttributeError:");
        sb.AppendLine("    pass");
        sb.AppendLine("if __name__ == \"__main__\":");
        sb.AppendLine($"    _bpc_states = [{statesJson}]");
        sb.AppendLine($"    _bpc_ctx = [{ctxJson}]");
        sb.AppendLine("    _bpc_map = {}");
        sb.AppendLine("    for _bpc_n in _bpc_states:");
        sb.AppendLine("        _bpc_map[_bpc_n] = globals()[_bpc_n]");
        sb.AppendLine("    _bpc_cur = _bpc_map[_bpc_states[0]]()");
        sb.AppendLine("    _bpc_cur.enter()");
        sb.AppendLine("    print(f\"  Initial state: {_bpc_states[0]}\")");
        sb.AppendLine("    print()");
        sb.AppendLine("    print(\"  Commands:\")");
        sb.AppendLine("    print(\"    <event>        Fire event (e.g., timer, tick)\")");
        sb.AppendLine("    print(\"    print <var>    Show variable value\")");
        sb.AppendLine("    print(\"    vars           List all variables\")");
        sb.AppendLine("    print(\"    state          Show current state\")");
        sb.AppendLine("    print(\"    help           Show this help\")");
        sb.AppendLine("    print(\"    quit           Exit\")");
        sb.AppendLine("    print()");
        sb.AppendLine("    while True:");
        sb.AppendLine("        try:");
        sb.AppendLine("            _bpc_line = input(f\"[{type(_bpc_cur).__name__}]> \").strip()");
        sb.AppendLine("        except (EOFError, KeyboardInterrupt):");
        sb.AppendLine("            print()");
        sb.AppendLine("            break");
        sb.AppendLine("        if not _bpc_line:");
        sb.AppendLine("            continue");
        sb.AppendLine("        _bpc_parts = _bpc_line.split(None, 1)");
        sb.AppendLine("        _bpc_cmd = _bpc_parts[0].lower()");
        sb.AppendLine("        _bpc_arg = _bpc_parts[1] if len(_bpc_parts) > 1 else \"\"");
        sb.AppendLine("        if _bpc_cmd in (\"quit\", \"q\", \"exit\"):");
        sb.AppendLine("            break");
        sb.AppendLine("        elif _bpc_cmd == \"state\":");
        sb.AppendLine("            print(f\"  State: {type(_bpc_cur).__name__}\")");
        sb.AppendLine("        elif _bpc_cmd == \"print\" and _bpc_arg:");
        sb.AppendLine("            _bpc_val = getattr(_bpc_cur, _bpc_arg, None)");
        sb.AppendLine("            if _bpc_val is not None:");
        sb.AppendLine("                print(f\"  {_bpc_arg} = {_bpc_val}\")");
        sb.AppendLine("            else:");
        sb.AppendLine("                _bpc_val = globals().get(_bpc_arg)");
        sb.AppendLine("                if _bpc_val is not None:");
        sb.AppendLine("                    print(f\"  {_bpc_arg} = {_bpc_val}\")");
        sb.AppendLine("                else:");
        sb.AppendLine("                    print(f\"  Unknown: {_bpc_arg}\")");
        sb.AppendLine("        elif _bpc_cmd == \"vars\":");
        sb.AppendLine("            _bpc_sv = {k: v for k, v in _bpc_cur.__dict__.items() if not k.startswith('_')}");
        sb.AppendLine("            if _bpc_sv:");
        sb.AppendLine("                print(\"  State vars:\", _bpc_sv)");
        sb.AppendLine("            _bpc_cv = {k: globals()[k] for k in _bpc_ctx}");
        sb.AppendLine("            if _bpc_cv:");
        sb.AppendLine("                print(\"  Context vars:\", _bpc_cv)");
        sb.AppendLine("        elif _bpc_cmd == \"help\":");
        sb.AppendLine("            print(\"    <event>        Fire event\")");
        sb.AppendLine("            print(\"    print <var>    Show variable value\")");
        sb.AppendLine("            print(\"    vars           List all variables\")");
        sb.AppendLine("            print(\"    state          Show current state\")");
        sb.AppendLine("            print(\"    transitions    Show available transitions\")");
        sb.AppendLine("            print(\"    help           This help\")");
        sb.AppendLine("            print(\"    quit           Exit\")");
        sb.AppendLine("        elif _bpc_cmd == \"transitions\":");
        sb.AppendLine("            if hasattr(_bpc_cur, 'handle_event'):");
        sb.AppendLine("                import inspect");
        sb.AppendLine("                _bpc_src = inspect.getsource(type(_bpc_cur).handle_event)");
        sb.AppendLine("                for _bpc_ln in _bpc_src.split('\\n'):");
        sb.AppendLine("                    if 'if event_name ==' in _bpc_ln:");
        sb.AppendLine("                        _bpc_ev = _bpc_ln.split('\"')[1]");
        sb.AppendLine("                        print(f\"    {_bpc_ev}\")");
        sb.AppendLine("        else:");
        sb.AppendLine("            _bpc_prev = type(_bpc_cur).__name__");
        sb.AppendLine("            _bpc_res = _bpc_cur.handle_event(_bpc_cmd)");
        sb.AppendLine("            if _bpc_res is not None:");
        sb.AppendLine("                _bpc_cur.exit()");
        sb.AppendLine("                _bpc_cur = _bpc_res");
        sb.AppendLine("                _bpc_cur.enter()");
        sb.AppendLine("                print(f\"  {_bpc_prev} -> {type(_bpc_cur).__name__}\")");
        sb.AppendLine("            else:");
        sb.AppendLine("                print(f\"  Event '{_bpc_cmd}' not handled in {_bpc_prev}\")");
        sb.AppendLine("    _bpc_cur.exit()");
        sb.AppendLine("    print(\"Debug session ended.\")");
        return sb.ToString();
    }
}
