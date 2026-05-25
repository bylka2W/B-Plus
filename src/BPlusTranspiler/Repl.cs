using System.Text;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Generators;
using BPlusTranspiler.Parser;
using BPlusTranspiler.Optimizer;

namespace BPlusTranspiler;

public static class Repl
{
    static readonly string Logo = @"
██████╗      ██████╗ ██╗     ██╗   ██╗███████╗
██╔══██╗     ██╔══██╗██║     ██║   ██║██╔════╝
██████╔╝     ██████╔╝██║     ██║   ██║███████╗
██╔══██╗     ██╔═══╝ ██║     ██║   ██║╚════██║
██████╔╝     ██║     ███████╗╚██████╔╝███████║
╚══════╝     ╚═╝     ╚══════╝ ╚═════╝ ╚══════╝
";

    static readonly string[] HelpText =
    {
        "",
        "  .run              Compile buffer and run (Python)",
        "  .metal            Compile buffer to native .exe",
        "  .new <name>       Create new .bp file",
        "  .open <file>      Open existing .bp file into buffer",
        "  .save             Save buffer to current file",
        "  .clear            Clear screen and buffer",
        "  .version          Show version",
        "  .update           Check for updates",
        "  .help             This message",
        "  .help all         Show all 40+ optimization flags",
        "  .help lang        Show B+ language quick reference",
        "  .help metal       Show Metal Stack commands",
        "  .exit             Exit REPL",
        "",
        "  Type .run to compile and run the buffer.",
        "  Write B+ code directly — it accumulates in the buffer.",
        ""
    };

    static readonly string[] HelpAll =
    {
        "",
        "  === OPTIMIZATION FLAGS ===",
        "  --optimize          Enable all optimizations",
        "  --dead-elim         Dead state elimination",
        "  --const-fold        Constant folding",
        "  --dedup             Deduplicate states",
        "  --inline            Inline single-use states",
        "  --prune             Prune unreachable states",
        "  --merge             Merge identical states",
        "  --sink              Sink common code",
        "  --hoist             Hoist loop invariants",
        "  --reorder           Reorder transitions by probability",
        "  --tail-call         Tail call elimination",
        "  --loop-unroll       Loop unrolling",
        "  --vectorize         Auto-vectorization",
        "  --prefetch          Software prefetch insertion",
        "  --thread-pool N     Thread pool size",
        "  --lock-free         Lock-free state transitions",
        "  --pool              Memory pool size",
        "  --memory <profile>  Memory profile (low/high/balanced)",
        "  --eco               Eco mode (reduce power)",
        "  --stream            Stream mode",
        "  --target-arch <arch> Target architecture (x64/arm64/wasm)",
        "  --target-os <os>    Target OS",
        "  --pin-regs N        Pin N registers",
        "  --benchmark         Benchmark mode",
        "  --pgo-collect       Profile-guided optimization collect",
        "  --pgo-use <file>    Profile-guided optimization use",
        "  --train             AI model training",
        "  --samples N         Training samples",
        "  --real              Real execution benchmarks",
        "  --mega              Mega mode (thorough training)",
        "",
        "  === TARGET FLAGS ===",
        "  --target all        All targets (default)",
        "  --target llvm       LLVM IR",
        "  --target wasm       WebAssembly",
        "  --target dxil       DirectX IL",
        "  --target spirv      Vulkan SPIR-V",
        "  --target arm64      ARM64",
        "  --target ios        iOS",
        "  --target android    Android",
        "  --x64               x64 native",
        "  --linux             Linux ELF",
        "  --macos             macOS Mach-O",
        "",
        "  === OTHER COMMANDS ===",
        "  bpc health [file]   Health check",
        "  bpc diff a.bp b.bp  Diff two files",
        "  bpc test run <file> Run tests",
        "  bpc bench <file>    Benchmark",
        "  bpc profile <file>  Profile",
        "  bpc bpm <cmd>       Package manager",
        "  bpc --lsp           Start LSP server",
        "  bpc --watch <file>  Watch mode (recompile on change)",
        ""
    };

    static readonly string[] HelpLang =
    {
        "",
        "  === B+ LANGUAGE QUICK REFERENCE ===",
        "",
        "  state <Name> [: <Base>] {",
        "      on <Event> [(<params>)] -> <Target> [if <guard>]",
        "      enter { <code> }",
        "      exit  { <code> }",
        "      always -> <Target>",
        "      after <ms> -> <Target> [if <guard>]",
        "  }",
        "",
        "  enum <Name> { <member>, ... }",
        "",
        "  pipeline <Name> [(<params>)] { <stage>: <step>, ... }",
        "",
        "  parallel [<Name>] { <states> }",
        "",
        "  entry <Name> { <body> }",
        "",
        "  import \"<file>.bp\"",
        "",
        "  @<annotation>(<key>: <val>, ...)",
        "",
        "  context { var <name>: <type> [= <default>] }",
        "",
        "  Types: int, float, bool, string, void, [u]int[8|16|32|64], float[32|64]",
        ""
    };

    static readonly string[] HelpMetal =
    {
        "",
        "  === METAL STACK ===",
        "",
        "  The B+ Metal Stack compiles state machines to native",
        "  machine code with profile-guided tiering and CPU-level",
        "  optimizations (prefetch, cache pinning, loop tiling).",
        "",
        "  Usage outside REPL:",
        "    bpc file.bp --metal --tier=L0",
        "    bpc file.bp --metal --tier=L1 --prefetch --pin-regs=8",
        "",
        "  Tiers: L0 (4KB), L1 (32KB), L2 (256KB), L3 (8MB)",
        "  Flags: --eco, --lock-free, --thread-pool=N, --stream",
        "         --prefetch, --pin-regs=N, --pgo-collect",
        "",
        "  Pipeline: .bp -> LLVM IR -> llc .obj -> lld-link .exe",
        "  See compile-metal.bat for the full pipeline.",
        ""
    };

    static readonly string UpdateMsg = "  What's new: REPL mode, .help metal, BigFloat + Async Compute fixes";

    public static void Run(string[] args)
    {
        var buffer = new StringBuilder();
        string? currentFile = null;
        var generators = new ICodeGenerator[]
        {
            new PythonGenerator(), new CppGenerator(), new CSharpGenerator(), new CGenerator(),
            new RustGenerator(), new GoGenerator()
        };

        var promptPrefix = "B Plus> ";

        try { Console.Clear(); } catch { }
        ShowWelcome();
        Console.WriteLine();

        while (true)
        {
            Console.Write(promptPrefix);
            var line = Console.ReadLine();

            if (line == null) break;

            var trimmed = line.Trim();

            if (trimmed == ".exit")
                break;

            if (trimmed == ".clear")
            {
                try { Console.Clear(); } catch { }
                buffer.Clear();
                currentFile = null;
                ShowWelcome();
                continue;
            }

            if (trimmed == ".version")
            {
                Console.WriteLine("  B+ Machine Code Optimizer v4.0.0 BETA");
                continue;
            }

            if (trimmed == ".update")
            {
                Console.WriteLine("  Checking for updates... (not implemented in REPL)");
                Console.WriteLine("  Run 'git pull' in the project directory to update.");
                continue;
            }

            if (trimmed == ".help")
            {
                foreach (var l in HelpText) Console.WriteLine(l);
                continue;
            }

            if (trimmed == ".help all")
            {
                foreach (var l in HelpAll) Console.WriteLine(l);
                continue;
            }

            if (trimmed == ".help lang")
            {
                foreach (var l in HelpLang) Console.WriteLine(l);
                continue;
            }

            if (trimmed == ".help metal")
            {
                foreach (var l in HelpMetal) Console.WriteLine(l);
                continue;
            }

            if (trimmed == ".save")
            {
                if (currentFile == null)
                {
                    Console.Error.WriteLine("  No file set. Use .new <name> or .open <file> first.");
                }
                else
                {
                    File.WriteAllText(currentFile, buffer.ToString());
                    Console.WriteLine($"  Saved to {currentFile}");
                }
                continue;
            }

            if (trimmed.StartsWith(".new "))
            {
                var name = trimmed[5..].Trim();
                if (string.IsNullOrEmpty(name))
                {
                    Console.Error.WriteLine("  Usage: .new <filename>");
                    continue;
                }
                if (!name.EndsWith(".bp")) name += ".bp";
                currentFile = name;
                buffer.Clear();
                Console.WriteLine($"  New file: {currentFile}");
                continue;
            }

            if (trimmed.StartsWith(".open "))
            {
                var name = trimmed[6..].Trim();
                if (string.IsNullOrEmpty(name))
                {
                    Console.Error.WriteLine("  Usage: .open <filename>");
                    continue;
                }
                if (!File.Exists(name))
                {
                    Console.Error.WriteLine($"  File not found: {name}");
                    continue;
                }
                currentFile = name;
                buffer.Clear();
                buffer.Append(File.ReadAllText(name));
                Console.WriteLine($"  Loaded {name} ({buffer.Length} chars)");
                continue;
            }

            if (trimmed == ".run")
            {
                RunBuffer(buffer, generators, runPython: true);
                continue;
            }

            if (trimmed == ".metal")
            {
                RunBuffer(buffer, generators, runPython: false);
                continue;
            }

            if (trimmed.StartsWith("."))
            {
                Console.Error.WriteLine($"  Unknown command: {trimmed}  (try .help)");
                continue;
            }

            buffer.AppendLine(line);
        }

        Console.WriteLine("Bye!");
        Console.WriteLine("Press any key to exit...");
        try { Console.ReadKey(true); } catch { }
    }

    static void ShowWelcome()
    {
        Console.WriteLine(Logo);
        Console.WriteLine("   Machine Code Optimizer v4.0.0 BETA");
        Console.ForegroundColor = ConsoleColor.Green;
        Console.WriteLine(UpdateMsg);
        Console.ResetColor();
        Console.WriteLine("   Type .help for commands");
    }

    static void RunBuffer(StringBuilder buffer, ICodeGenerator[] generators, bool runPython)
    {
        var code = buffer.ToString().Trim();
        if (string.IsNullOrEmpty(code))
        {
            Console.Error.WriteLine("  Buffer is empty. Write some B+ code first.");
            return;
        }

        try
        {
            var parser = new BPlusParser();
            var program = parser.Parse(code);

            var outputDir = "gen";
            Directory.CreateDirectory(outputDir);

            Console.WriteLine($"  Parsed OK — {program.States.Count} state(s), {program.Entries.Count} entry(ies)");
            Console.WriteLine();

            if (runPython)
            {
                var pyGen = new PythonGenerator();
                var files = pyGen.GenerateFiles(program);
                var pyFile = Path.Combine(outputDir, "repl_output.py");
                if (files.TryGetValue("generated.py", out var pyCode))
                {
                    File.WriteAllText(pyFile, pyCode);
                    Console.WriteLine("  Running Python...");
                    Console.WriteLine();

                    var psi = new System.Diagnostics.ProcessStartInfo("python", $"\"{pyFile}\"")
                    {
                        UseShellExecute = false,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true
                    };
                    using var proc = System.Diagnostics.Process.Start(psi);
                    if (proc == null)
                    {
                        Console.Error.WriteLine("  Python not found. Install Python or check PATH.");
                    }
                    else
                    {
                        var output = proc.StandardOutput.ReadToEnd();
                        var error = proc.StandardError.ReadToEnd();
                        proc.WaitForExit(15000);

                        if (!string.IsNullOrEmpty(output))
                            Console.WriteLine(output);

                        if (!string.IsNullOrEmpty(error))
                        {
                            Console.ForegroundColor = ConsoleColor.Red;
                            Console.Error.WriteLine(error);
                            Console.ResetColor();
                        }

                        Console.WriteLine($"  Exit code: {proc.ExitCode}");
                        Console.WriteLine();
                    }
                }
            }
            else
            {
                foreach (var gen in generators)
                {
                    var files = gen.GenerateFiles(program);
                    foreach (var (name, content) in files)
                    {
                        var outFile = Path.Combine(outputDir, "repl_" + name);
                        File.WriteAllText(outFile, content);
                        Console.WriteLine($"  [{gen.GetLanguageName(),-10}] {outFile}");
                    }
                }
                Console.WriteLine();
                Console.WriteLine("  Use .run to execute as Python, or open generated files.");
            }
        }
        catch (ParseException ex)
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine($"  Parse error at line {ex.Line}: {ex.Message}");
            if (!string.IsNullOrEmpty(ex.Context))
                Console.WriteLine($"  Near: {ex.Context}");
            Console.ResetColor();
        }
        catch (Exception ex)
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine($"  Error: {ex.Message}");
            Console.ResetColor();
        }
    }
}
