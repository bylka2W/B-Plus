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
    var watchOptimize = false;
    for (int i = 2; i < args.Length; i++)
    {
        if (args[i] == "--target" && i + 1 < args.Length) watchTarget = args[++i];
        else if (args[i] == "--output" && i + 1 < args.Length) watchOutput = args[++i];
        else if (args[i] == "--optimize") watchOptimize = true;
    }

    var watchGenArgs = new List<string>();
    if (watchTarget != "all") { watchGenArgs.Add("--target"); watchGenArgs.Add(watchTarget); }
    if (watchOutput != "./gen") { watchGenArgs.Add("--output"); watchGenArgs.Add(watchOutput); }
    if (watchOptimize) watchGenArgs.Add("--optimize");

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
var optimize = false;
string? plugin = null;
string? input = null;

for (int i = 0; i < args.Length; i++)
{
    if (args[i] == "--target" && i + 1 < args.Length)
        target = args[++i];
    else if (args[i] == "--output" && i + 1 < args.Length)
        output = args[++i];
    else if (args[i] == "--optimize")
        optimize = true;
    else if (args[i] == "--plugin" && i + 1 < args.Length)
        plugin = args[++i];
    else if (!args[i].StartsWith("-"))
        input = args[i];
}

if (input == null)
{
    Console.Error.WriteLine("Usage: bpc <input.bp> [--target python|cpp|csharp|c|all] [--optimize] [--output ./dir] [--plugin unity|unreal|godot|web]");
    Console.Error.WriteLine("       bpc --lsp                         (start LSP server)");
    Console.Error.WriteLine("       bpc --install-lsp                  (install LSP for VS Code)");
    Console.Error.WriteLine("       bpc watch <dir> [--target ...]      (watch dir for changes and regenerate)");
    Console.Error.WriteLine("       bpc format <file.bp> [--check]      (format .bp file)");
    Console.Error.WriteLine("       bpc docs <file.bp> [--output ./dir]  (generate documentation)");
    Console.Error.WriteLine("       bpc debug <file.bp>                  (interactive state machine debugger)");
    Console.Error.WriteLine("       bpc profile <file.bp> [iterations]   (profile transition frequencies)");
    Console.Error.WriteLine("       bpc <input> --plugin unity|unreal|godot|web  (engine-specific code generation)");
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

if (optimize)
{
    program = BPlusOptimizer.Optimize(program);
    generators.Add(new CppOptimizedGenerator());
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
        Console.Error.WriteLine($"Unknown target: {target}. Use: python, cpp, csharp, c, all");
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
        var optimize = false;

        for (int i = 0; i < genArgs.Count; i++)
        {
            if (genArgs[i] == "--target" && i + 1 < genArgs.Count) target = genArgs[++i];
            else if (genArgs[i] == "--output" && i + 1 < genArgs.Count) output = genArgs[++i];
            else if (genArgs[i] == "--optimize") optimize = true;
        }

        var generators = new List<ICodeGenerator>
        {
            new PythonGenerator(), new CppGenerator(), new CSharpGenerator(), new CGenerator()
        };

        if (optimize)
        {
            program = BPlusOptimizer.Optimize(program);
            generators.Add(new CppOptimizedGenerator());
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
        version = "2.0.0",
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