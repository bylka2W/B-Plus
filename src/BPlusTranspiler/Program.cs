using BPlusTranspiler;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Generators;
using BPlusTranspiler.Lsp;
using BPlusTranspiler.Optimizer;
using BPlusTranspiler.Parser;
using BPlusTranspiler.Visualizer;
using BPlusTranspiler.DocGen;
using BPlusTranspiler.Debugger;
using BPlusTranspiler.Profiler;
using BPlusTranspiler.Plugins;
using BPlusTranspiler.PackageManager;
using BPlusTranspiler.TestRunner;

if (args.Length > 0 && args[0] == "health")
{
    var healthInput = args.Length > 1 && !args[1].StartsWith("-") ? args[1] : null;
    var healthArgs = args.Skip(healthInput != null ? 2 : 1).ToArray();
    var healthFlags = OptimizationFlags.Parse(healthArgs);
    return BPlusHealth.Run(healthInput, healthFlags);
}

if (args.Length > 0 && args[0] == "diff")
{
    if (args.Length < 3)
    {
        Console.Error.WriteLine("Usage: bpc diff <file_a.bp> <file_b.bp>");
        return 1;
    }
    return BPlusDiff.Run(args[1], args[2]);
}

if (args.Length > 0 && args[0] == "build")
{
    string? buildConfig = null;
    var buildDryRun = false;
    for (int i = 1; i < args.Length; i++)
    {
        if (args[i] == "--config" && i + 1 < args.Length) buildConfig = args[++i];
        else if (args[i] == "--dry-run") buildDryRun = true;
    }
    return BPlusBuild.Run(buildConfig, buildDryRun);
}

if (args.Length > 0 && (args[0] == "test" || args[0] == "tests"))
{
    var testFile = "";
    if (args.Length > 2 && args[1] == "run") testFile = args[2];
    else if (args.Length > 1) testFile = args[1];
    if (!File.Exists(testFile))
    {
        Console.Error.WriteLine("Usage: bpc test run <input.bp>");
        return 1;
    }
    return BPlusTestRunner.RunTestsFromFiles(testFile, null);
}

if (args.Length > 0 && args[0] == "bpm")
{
    var sub = args.Length > 1 ? args[1] : "help";
    switch (sub)
    {
        case "init": return Bpm.Init(args.Length > 2 ? args[2] : "my-package");
        case "install": return Bpm.Install(args.Length > 2 ? args[2] : ".");
        case "list": return Bpm.List();
        case "search": return Bpm.Search(args.Length > 2 ? args[2] : "");
        case "publish": return Bpm.Publish(args.Length > 2 ? args[2] : ".");
        case "new" or "create" or "template":
            return Bpm.Create(args.Length > 2 ? args[2] : "default");
        default:
            Console.WriteLine("B+ Package Manager (BPM)");
            Console.WriteLine();
            Console.WriteLine("Usage: bpm <command> [args]");
            Console.WriteLine();
            Console.WriteLine("Commands:");
            Console.WriteLine("  init <name>        Create a new package");
            Console.WriteLine("  install <path>     Install a package");
            Console.WriteLine("  list               List installed packages");
            Console.WriteLine("  search <term>      Search packages");
            Console.WriteLine("  publish <dir>      Publish a package to local registry");
            Console.WriteLine("  new <template>     Create from template");
            return 0;
    }
}

if (args.Length > 0 && (args[0] == "profile" || args[0] == "prof"))
{
    var profInput = args.Length > 1 ? args[1] : null;
    var profIter = 100_000;
    if (profInput == null || !File.Exists(profInput))
    {
        Console.Error.WriteLine("Usage: bpc profile <input.bp> [iterations]");
        return 1;
    }
    if (args.Length > 2 && int.TryParse(args[2], out var n)) profIter = n;
    try
    {
        var src = File.ReadAllText(profInput);
        var prog = new BPlusParser().Parse(src);
        var profiler = new BPlusProfiler(prog);
        profiler.Run(profIter);
    }
    catch (ParseException ex)
    {
        Console.Error.WriteLine($"Parse error: {ex.Message}");
        return 1;
    }
    return 0;
}

if (args.Length > 0 && (args[0] == "debug" || args[0] == "dbg"))
{
    var dbgInput = args.Length > 1 ? args[1] : null;
    if (dbgInput == null || !File.Exists(dbgInput))
    {
        Console.Error.WriteLine("Usage: bpc debug <input.bp>");
        return 1;
    }
    try
    {
        var src = File.ReadAllText(dbgInput);
        var prog = new BPlusParser().Parse(src);
        new BPlusDebugServer(prog).Run();
    }
    catch (ParseException ex)
    {
        Console.Error.WriteLine($"Parse error: {ex.Message}");
        return 1;
    }
    return 0;
}

if (args.Length > 0 && args[0] == "--lsp")
{
    new BPlusLspServer().Run();
    return 0;
}

if (args.Length > 0 && args[0] == "--install-lsp")
{
    InstallLsp();
    return 0;
}

if (args.Length > 0 && args[0] == "watch")
{
    var watchDir = args.Length > 1 ? args[1] : ".";
    if (!Directory.Exists(watchDir))
    {
        Console.Error.WriteLine($"Directory not found: {watchDir}");
        return 1;
    }

    var watchTarget = "all";
    var watchOutput = "./gen";
    var watchOtherArgs = new List<string>();
    for (int i = 2; i < args.Length; i++)
    {
        if (args[i] == "--target" && i + 1 < args.Length) { watchTarget = args[++i]; }
        else if (args[i] == "--output" && i + 1 < args.Length) { watchOutput = args[++i]; }
        else watchOtherArgs.Add(args[i]);
    }

    var watchGenArgs = new List<string>();
    if (watchTarget != "all") { watchGenArgs.Add("--target"); watchGenArgs.Add(watchTarget); }
    if (watchOutput != "./gen") { watchGenArgs.Add("--output"); watchGenArgs.Add(watchOutput); }
    watchGenArgs.AddRange(watchOtherArgs);

    Console.WriteLine($"Watching {Path.GetFullPath(watchDir)} for .bp changes...");
    Console.WriteLine($"  Target: {watchTarget}");
    Console.WriteLine($"  Output: {Path.GetFullPath(watchOutput)}");
    Console.WriteLine("  Press Ctrl+C to stop.");

    using var watcher = new FileSystemWatcher(watchDir, "*.bp")
    {
        IncludeSubdirectories = true,
        NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.CreationTime
    };

    watcher.Changed += (_, e) => OnFileChanged(e.FullPath, watchGenArgs);
    watcher.Created += (_, e) => OnFileChanged(e.FullPath, watchGenArgs);
    watcher.Renamed += (_, e) => { OnFileChanged(e.FullPath, watchGenArgs); if (e.OldFullPath != e.FullPath) OnFileChanged(e.OldFullPath, watchGenArgs); };
    watcher.EnableRaisingEvents = true;

    // Initial build
    foreach (var bp in Directory.GetFiles(watchDir, "*.bp", SearchOption.AllDirectories))
        OnFileChanged(bp, watchGenArgs);

    Console.CancelKeyPress += (_, _) => Environment.Exit(0);
    new ManualResetEventSlim().Wait();
    return 0;
}

if (args.Length > 0 && args[0] == "format")
{
    var fmtInput = args.Length > 1 ? args[1] : null;
    if (fmtInput == null || !File.Exists(fmtInput))
    {
        Console.Error.WriteLine("Usage: bpc format <input.bp>");
        return 1;
    }
    var fmtCheckOnly = args.Contains("--check");

    var fmtSrc = File.ReadAllText(fmtInput);
    var fmtFormatted = BPlusLspServer.FormatCode(fmtSrc);

    if (fmtCheckOnly)
    {
        if (fmtSrc == fmtFormatted)
        {
            Console.WriteLine($"{fmtInput} is already formatted.");
            return 0;
        }
        Console.WriteLine($"{fmtInput} needs formatting.");
        return 1;
    }

    File.WriteAllText(fmtInput, fmtFormatted);
    Console.WriteLine($"Formatted: {fmtInput}");
    return 0;
}

if (args.Length > 0 && args[0] == "docs")
{
    var docsInput = args.Length > 1 ? args[1] : null;
    if (docsInput == null || !File.Exists(docsInput))
    {
        Console.Error.WriteLine("Usage: bpc docs <input.bp> [--output ./dir]");
        return 1;
    }
    var docsOutput = "./docs";
    for (int i = 2; i < args.Length; i++)
        if (args[i] == "--output" && i + 1 < args.Length) docsOutput = args[++i];

    try
    {
        var docsSrc = File.ReadAllText(docsInput);
        var docsProg = new BPlusParser().Parse(docsSrc);
        Directory.CreateDirectory(docsOutput);
        var title = Path.GetFileNameWithoutExtension(docsInput);
        foreach (var (name, code) in BPlusDocGenerator.GenerateFiles(docsProg, title))
        {
            var path = Path.Combine(docsOutput, name);
            File.WriteAllText(path, code);
            Console.WriteLine($"  [docs] {path}");
        }
        Console.WriteLine($"Done. Generated documentation in {docsOutput}/");
    }
    catch (ParseException ex)
    {
        Console.Error.WriteLine($"Parse error: {ex.Message}");
        return 1;
    }
    return 0;
}

if (args.Length > 0 && (args[0] == "--visualize" || args[0] == "--vis"))
{
    var visInput = args.Length > 1 ? args[1] : null;
    if (visInput == null || !File.Exists(visInput))
    {
        Console.Error.WriteLine("Usage: bpc --visualize <input.bp> [--output ./dir]");
        return 1;
    }
    var visOutput = "./gen";
    for (int i = 2; i < args.Length; i++)
        if (args[i] == "--output" && i + 1 < args.Length) visOutput = args[++i];

    var visSrc = File.ReadAllText(visInput);
    var visParser = new BPlusParser();
    try
    {
        var visProgram = visParser.Parse(visSrc);
        Directory.CreateDirectory(visOutput);
        var visTitle = Path.GetFileNameWithoutExtension(visInput);
        var visFiles = BPlusVisualizer.GenerateFiles(visProgram, visTitle);
        foreach (var (name, code) in visFiles)
        {
            var visPath = Path.Combine(visOutput, name);
            File.WriteAllText(visPath, code);
            Console.WriteLine($"  [visual] {visPath}");
        }
        Console.WriteLine($"Done. Open {Path.Combine(visOutput, $"{Sanitize(visTitle)}.html")} in a browser.");
    }
    catch (ParseException ex)
    {
        Console.Error.WriteLine($"Parse error: {ex.Message}");
        return 1;
    }
    return 0;
}

var target = "all";
var output = "./gen";
string? plugin = null;
string? input = null;

var optFlags = OptimizationFlags.Parse(args);

for (int i = 0; i < args.Length; i++)
{
    if (args[i] == "--target" && i + 1 < args.Length)
        target = args[++i];
    else if (args[i] == "--output" && i + 1 < args.Length)
        output = args[++i];
    else if (args[i] == "--plugin" && i + 1 < args.Length)
        plugin = args[++i];
    // Skip flag values consumed by OptimizationFlags
    else if (args[i] is "--thread-pool" or "--prefetch" or "--pool" or "--memory"
             or "--eco" or "--target-arch" or "--target-os"
             or "--pin-regs" or "--benchmark")
    {
        if (i + 1 < args.Length && !args[i + 1].StartsWith("--"))
            i++;
    }
    else if (!args[i].StartsWith("-"))
        input = args[i];
}

if (input == null)
{
    Console.Error.WriteLine("Usage: bpc <input.bp> [--target python|cpp|csharp|c|all] [flags] [--output ./dir] [--plugin unity|unreal|godot|web]");
    Console.Error.WriteLine("       bpc --lsp                         (start LSP server)");
    Console.Error.WriteLine("       bpc --install-lsp                  (install LSP for VS Code)");
    Console.Error.WriteLine("       bpc watch <dir> [--target ...]      (watch dir for changes and regenerate)");
    Console.Error.WriteLine("       bpc format <file.bp> [--check]      (format .bp file)");
    Console.Error.WriteLine("       bpc docs <file.bp> [--output ./dir]  (generate documentation)");
    Console.Error.WriteLine("       bpc debug <file.bp>                  (interactive state machine debugger)");
    Console.Error.WriteLine("       bpc profile <file.bp> [iterations]   (profile transition frequencies)");
    Console.Error.WriteLine("       bpc <input> --plugin unity|unreal|godot|web  (engine-specific code generation)");
    Console.Error.WriteLine("       bpc bpm <init|install|list|search|publish>   (package manager)");
    Console.Error.WriteLine("       bpc test run <file.bp>                      (run auto-generated tests)");
    Console.Error.WriteLine("       bpc health [dir] [flags]                    (project health analysis)");
    Console.Error.WriteLine("       bpc diff <a.bp> <b.bp>                      (semantic diff)");
    Console.Error.WriteLine("       bpc build [--config bp.toml] [--dry-run]    (build from config)");
    Console.Error.WriteLine();
    Console.Error.WriteLine("Optimization flags (реалистичные ускорения на state machine):");
    Console.Error.WriteLine("  --optimize                  Таблица переходов вместо virtual   +10-30%");
    Console.Error.WriteLine("  --pool                       Пул состояний без new/delete       +20-40%");
    Console.Error.WriteLine("  --cache-friendly             Упорядоченный layout данных        +10-20%");
    Console.Error.WriteLine("  --prefetch                   Предзагрузка кэша                  +10-20%");
    Console.Error.WriteLine("  --branchless                cmov вместо if/else в переходах    +5-15%");
    Console.Error.WriteLine("  --pack                       Битфилды, упаковка структур        -40% памяти");
    Console.Error.WriteLine("  --predict                    Предсказание след. состояния       +5-15%");
    Console.Error.WriteLine("  --eco                        Энергосбережение (узкие SIMD)");
    Console.Error.WriteLine("  --turbo                      --optimize + --pool + --pack       +40-80%");
    Console.Error.WriteLine("  --turbo-embed                Для embedded (--pack + --eco)");
    Console.Error.WriteLine("  --vectorize                  Инлайн SIMD (только с числовыми данными)");
    Console.Error.WriteLine("  --benchmark [iterations]     Сгенерировать бенчмарк");
    Console.Error.WriteLine("  --check / --analyze          Диагностика 7 категорий");
    Console.Error.WriteLine("  --lto                        Link-Time Optimization             +5-10%");
    Console.Error.WriteLine("  --thread-pool <N>            Многопоточная диспетчеризация");
    Console.Error.WriteLine("  --lock-free                  Безлоковые структуры               +5-10%");
    Console.Error.WriteLine("  --target-arch <arch>         native|zen4|raptor|m1|cortex");
    Console.Error.WriteLine("  --target-os <os>             linux|windows|baremetal");
    Console.Error.WriteLine("  --memory=regions             Region allocator (zero-free transitions)");
    Console.Error.WriteLine("  --pool=linear|ring           State pool allocator (linear: +20-40%, ring: ~0 alloc)");
    Console.Error.WriteLine("  --pgo                        PGO counters + __builtin_expect instrumentation");
    return 1;
}

if (!File.Exists(input))
{
    Console.Error.WriteLine($"File not found: {input}");
    return 1;
}

var source = File.ReadAllText(input);
var parser = new BPlusParser();
ProgramNode program;
try
{
    program = parser.Parse(source);
}
catch (ParseException ex)
{
    Console.Error.WriteLine($"Parse error: {ex.Message}");
    return 1;
}

var generators = new List<ICodeGenerator>
{
    new PythonGenerator(),
    new CppGenerator(),
    new CSharpGenerator(),
    new CGenerator()
};

// LLVM IR generator (native machine code path)
if (target == "llvm" || target == "all")
{
    generators.Add(new LlvmGenerator());
}

// Add kernel code generator if program has kernels/pipelines
if (program.Kernels.Count > 0 || program.Pipelines.Count > 0 || program.Entries.Count > 0
    || program.UseCxxDecls.Count > 0 || program.ExternCppFns.Count > 0)
{
    generators.Add(new CppKernelGenerator());
}

// Error analysis (7 categories)
if (optFlags.Check || !optFlags.HasAny)
{
    var reporter = new BPlusErrorReporter(program, input, optFlags.HasAny ? optFlags : null);
    reporter.RunAll();
    var code = reporter.Report(Console.Out);
    if (optFlags.Check)
        return code;
}

if (optFlags.HasAny)
{
    if (optFlags.Optimize || optFlags.DeadElim || optFlags.ConstFold || optFlags.Dedup)
        program = BPlusOptimizer.Optimize(program);

    generators.Add(new CppOptimizedGenerator(optFlags));
    target = "cpp_opt";
}

if (plugin != null)
{
    var pluginGen = (plugin.ToLower()) switch
    {
        "unity" => (ICodeGenerator)new UnityPlugin(),
        "unreal" => new UnrealPlugin(),
        "godot" => new GodotPlugin(),
        "web" or "ts" or "typescript" => new WebPlugin(),
        _ => null
    };
    if (pluginGen == null)
    {
        Console.Error.WriteLine($"Unknown plugin: {plugin}. Use: unity, unreal, godot, web");
        return 1;
    }
    generators.Clear();
    generators.Add(pluginGen);
}

if (target != "all" && target != "cpp_opt")
{
    generators = generators.Where(g =>
        g.GetLanguageName().Equals(target, StringComparison.OrdinalIgnoreCase) ||
        g.GetFileExtension().Equals("." + target, StringComparison.OrdinalIgnoreCase)
    ).ToList();

    if (generators.Count == 0)
    {
        Console.Error.WriteLine($"Unknown target: {target}. Use: python, cpp, csharp, c, llvm, all");
        return 1;
    }
}

Directory.CreateDirectory(output);
int count = 0;

foreach (var gen in generators)
{
    var files = gen.GenerateFiles(program);
    foreach (var (name, code) in files)
    {
        var outputFile = Path.Combine(output, name);
        File.WriteAllText(outputFile, code);
        Console.WriteLine($"  [{gen.GetLanguageName(),-10}] {outputFile}");
        count++;
    }
}

Console.WriteLine($"Done. Generated {count} file(s) to {output}");
return 0;

static string Sanitize(string name) =>
    string.Join("_", name.Split(System.IO.Path.GetInvalidFileNameChars()));

static void OnFileChanged(string file, List<string> genArgs)
{
    try
    {
        // Debounce: wait a bit for file to be fully written
        Thread.Sleep(100);
        var src = File.ReadAllText(file);
        var parser = new BPlusParser();
        var program = parser.Parse(src);

        var target = "all";
        var output = "./gen";

        var watchOptFlags = OptimizationFlags.Parse(genArgs.ToArray());

        for (int i = 0; i < genArgs.Count; i++)
        {
            if (genArgs[i] == "--target" && i + 1 < genArgs.Count) target = genArgs[++i];
            else if (genArgs[i] == "--output" && i + 1 < genArgs.Count) output = genArgs[++i];
        }

        var generators = new List<ICodeGenerator>
        {
            new PythonGenerator(), new CppGenerator(), new CSharpGenerator(), new CGenerator()
        };

        if (watchOptFlags.HasAny)
        {
            if (watchOptFlags.Optimize || watchOptFlags.DeadElim || watchOptFlags.ConstFold || watchOptFlags.Dedup)
                program = BPlusOptimizer.Optimize(program);
            generators.Add(new CppOptimizedGenerator(watchOptFlags));
            target = "cpp_opt";
        }

        if (target != "all" && target != "cpp_opt")
            generators = generators.Where(g =>
                g.GetLanguageName().Equals(target, StringComparison.OrdinalIgnoreCase) ||
                g.GetFileExtension().Equals("." + target, StringComparison.OrdinalIgnoreCase)
            ).ToList();

        Directory.CreateDirectory(output);
        var count = 0;
        foreach (var gen in generators)
        {
            foreach (var (name, code) in gen.GenerateFiles(program))
            {
                var path = Path.Combine(output, name);
                File.WriteAllText(path, code);
                count++;
            }
        }

        Console.WriteLine($"[{DateTime.Now:HH:mm:ss}] {Path.GetFileName(file)} → {count} file(s) regenerated");
    }
    catch (ParseException ex)
    {
        Console.WriteLine($"[{DateTime.Now:HH:mm:ss}] {Path.GetFileName(file)} PARSE ERROR: {ex.Message}");
    }
    catch (Exception ex)
    {
        Console.WriteLine($"[{DateTime.Now:HH:mm:ss}] {Path.GetFileName(file)} ERROR: {ex.Message}");
    }
}

static void InstallLsp()
{
    var vscodeDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ".vscode", "extensions", "bplus-lsp");

    Directory.CreateDirectory(vscodeDir);

    var bpcPath = Path.Combine(
        AppContext.BaseDirectory,
        AppDomain.CurrentDomain.FriendlyName + ".dll");

    // Fallback: try the known output path
    if (!File.Exists(bpcPath))
        bpcPath = Path.GetFullPath(Path.Combine(
            AppContext.BaseDirectory, "..", "..", "..", "..",
            "BPlusTranspiler", "bin", "Debug", "net8.0", "bpc.dll"));

    var packageJson = new
    {
        name = "bplus-lsp",
        version = "2.1.3VS",
        displayName = "B+ Language Support",
        description = "B+ state machine language — LSP integration",
        categories = new[] { "Programming Languages" },
        engines = new { vscode = "^1.75.0" },
        activationEvents = new[] { "onLanguage:bp" },
        main = "./extension.js",
        contributes = new
        {
            languages = new[]
            {
                new
                {
                    id = "bp",
                    aliases = new[] { "B+", "BPlus" },
                    extensions = new[] { ".bp" },
                    configuration = "./language-configuration.json"
                }
            },
            grammars = new[]
            {
                new
                {
                    language = "bp",
                    scopeName = "source.bp",
                    path = "./syntaxes/bp.tmLanguage.json"
                }
            }
        }
    };

    var extensionJs = @"
const vscode = require('vscode');
const { spawn } = require('child_process');
const path = require('path');

function activate(context) {
    const serverPath = " + "\"" + bpcPath.Replace("\\", "\\\\") + "\"" + @";
    const serverOptions = {
        run: { command: 'dotnet', args: [serverPath, '--lsp'] },
        debug: { command: 'dotnet', args: [serverPath, '--lsp'] }
    };
    const clientOptions = {
        documentSelector: [{ scheme: 'file', language: 'bp' }],
        synchronize: { configurationSection: 'bplus' }
    };
    const client = new (require('vscode-languageclient').LanguageClient)(
        'bplusLsp', 'B+ Language Server', serverOptions, clientOptions
    );
    context.subscriptions.push(client.start());
}
exports.activate = activate;
function deactivate() {}
exports.deactivate = deactivate;
";

    var tmLanguage = new
    {
        scopeName = "source.bp",
        fileTypes = new[] { "bp" },
        name = "B+",
        patterns = new object[]
        {
            new { name = "comment.line.double-slash.bp", match = "//.*" },
            new { name = "keyword.control.bp", match = "\\b(state|base|var|on|after|enter|exit|always|async|import|context|enum|parallel)\\b" },
            new { name = "storage.type.bp", match = "\\b(int|float|string|bool|void|double|long)\\b" },
            new { name = "constant.language.bp", match = "\\b(true|false)\\b" },
            new { name = "entity.name.type.bp", match = "\\b[A-Z]\\w*\\b" },
            new { name = "string.quoted.double.bp", match = "\"[^\"]*\"" },
            new { name = "constant.numeric.bp", match = "\\b\\d+\\b" }
        },
        uuid = "bplus-grammar"
    };

    var langConfig = new
    {
        comments = new { lineComment = "//" },
        brackets = new[] { new[] { "{", "}" }, new[] { "(", ")" }, new[] { "[", "]" } },
        autoClosingPairs = new[]
        {
            new { open = "{", close = "}" },
            new { open = "(", close = ")" },
            new { open = "[", close = "]" },
            new { open = "\"", close = "\"" }
        }
    };

    var jsonOpts = new System.Text.Json.JsonSerializerOptions
    {
        PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };

    File.WriteAllText(Path.Combine(vscodeDir, "package.json"),
        System.Text.Json.JsonSerializer.Serialize(packageJson, jsonOpts));
    File.WriteAllText(Path.Combine(vscodeDir, "extension.js"), extensionJs);

    var syntaxesDir = Path.Combine(vscodeDir, "syntaxes");
    Directory.CreateDirectory(syntaxesDir);
    File.WriteAllText(Path.Combine(syntaxesDir, "bp.tmLanguage.json"),
        System.Text.Json.JsonSerializer.Serialize(tmLanguage, jsonOpts));
    File.WriteAllText(Path.Combine(vscodeDir, "language-configuration.json"),
        System.Text.Json.JsonSerializer.Serialize(langConfig, jsonOpts));

    Console.WriteLine($"LSP extension installed to: {vscodeDir}");
    Console.WriteLine("Restart VS Code and open a .bp file to activate B+ support.");
    Console.WriteLine();
    Console.WriteLine("NOTE: Requires the 'vscode-languageclient' npm package.");
    Console.WriteLine("Install it in the extension directory:");
    Console.WriteLine($"  cd \"{vscodeDir}\" && npm install vscode-languageclient");
}
