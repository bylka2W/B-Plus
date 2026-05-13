using System.Text.RegularExpressions;
using BPlusTranspiler;
using BPlusTranspiler.AI;
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
using BPlusTranspiler.Runtime;

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

if (args.Length > 0 && args[0] == "publish")
{
    var runtime = "linux-x64";
    var publishAot = false;
    for (int i = 1; i < args.Length; i++)
    {
        if (args[i] == "--runtime" && i + 1 < args.Length) runtime = args[++i];
        else if (args[i] == "--aot") publishAot = true;
    }
    Console.WriteLine($"Publishing bpc for {runtime} (AOT={publishAot})...");
    var psi = new System.Diagnostics.ProcessStartInfo("dotnet", $"publish -c Release -r {runtime} --self-contained{(publishAot ? " -p:PublishAot=true" : "")} --no-build")
    {
        WorkingDirectory = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "BPlusTranspiler")),
        UseShellExecute = false,
        RedirectStandardOutput = true,
        RedirectStandardError = true
    };
    using var proc = System.Diagnostics.Process.Start(psi);
    if (proc == null) { Console.Error.WriteLine("Failed to start dotnet"); return 1; }
    Console.WriteLine(proc.StandardOutput.ReadToEnd());
    Console.WriteLine(proc.StandardError.ReadToEnd());
    proc.WaitForExit(300000);
    if (proc.ExitCode == 0)
        Console.WriteLine($"Published: release/{runtime}/bpc");
    else
        Console.Error.WriteLine($"Publish failed: exit {proc.ExitCode}");
    return proc.ExitCode;
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

// GPU/PGO/C-ABI flags — declared early for watch mode closure
var gpuArch = "auto";
var pgoCollect = false;
string? pgoUse = null;
string? ltoMode = null;
var cAbi = false;

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

            watcher.Changed += (_, e) => OnFileChanged(e.FullPath, watchGenArgs, cAbi);
            watcher.Created += (_, e) => OnFileChanged(e.FullPath, watchGenArgs, cAbi);
            watcher.Renamed += (_, e) => { OnFileChanged(e.FullPath, watchGenArgs, cAbi); if (e.OldFullPath != e.FullPath) OnFileChanged(e.OldFullPath, watchGenArgs, cAbi); };
    watcher.EnableRaisingEvents = true;

    // Initial build
        foreach (var bp in Directory.GetFiles(watchDir, "*.bp", SearchOption.AllDirectories))
            OnFileChanged(bp, watchGenArgs, cAbi);

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
    else if (args[i] == "--gpu-arch" && i + 1 < args.Length)
        gpuArch = args[++i];
    else if (args[i] == "--pgo-collect")
        pgoCollect = true;
    else if (args[i] == "--pgo-use" && i + 1 < args.Length)
        pgoUse = args[++i];
    else if (args[i] == "--lto" && i + 1 < args.Length)
        ltoMode = args[++i];
    else if (args[i] == "--c-abi")
        cAbi = true;
    // Skip flag values consumed by OptimizationFlags
    else if (args[i] is "--thread-pool" or "--prefetch" or "--pool" or "--memory"
             or "--eco" or "--target-arch" or "--target-os"
             or "--pin-regs" or "--benchmark" or "--stream")
    {
        if (i + 1 < args.Length && !args[i + 1].StartsWith("--"))
            i++;
    }
    else if (!args[i].StartsWith("-"))
        input = args[i];
}

if (args.Contains("--ai"))
{
    if (input == null || !File.Exists(input))
    {
        Console.Error.WriteLine("Usage: bpc <input.bp> --ai");
        return 1;
    }
    return RunAI(input);
}

if (args.Contains("--muarch"))
{
    var profile = MicroArchProfiles.Detect();
    Console.WriteLine(MicroArchProfiles.GenerateReport(profile));
    return 0;
}

if (args.Contains("--ilp"))
{
    if (input == null || !File.Exists(input))
    {
        Console.Error.WriteLine("Usage: bpc <input.bp> --ilp");
        return 1;
    }
    var srcIlp = File.ReadAllText(input);
    var parserIlp = new BPlusParser();
    var progIlp = parserIlp.Parse(srcIlp);
    var ilpScores = IlpAnalyzer.Analyze(progIlp);
    Console.WriteLine(IlpAnalyzer.GenerateReport(ilpScores));
    return 0;
}

if (args.Contains("--store-fwd"))
{
    if (input == null || !File.Exists(input))
    {
        Console.Error.WriteLine("Usage: bpc <input.bp> --store-fwd");
        return 1;
    }
    var srcSf = File.ReadAllText(input);
    var parserSf = new BPlusParser();
    var progSf = parserSf.Parse(srcSf);
    var sfIssues = StoreForwardGuard.Analyze(progSf);
    Console.WriteLine(StoreForwardGuard.GenerateReport(sfIssues));
    return 0;
}

if (args.Contains("--auto-tune"))
{
    if (input == null || !File.Exists(input))
    {
        Console.Error.WriteLine("Usage: bpc <input.bp> --auto-tune [iterations]");
        return 1;
    }
    int tuneIter = 5;
    for (int i = 0; i < args.Length; i++)
        if (args[i] == "--auto-tune" && i + 1 < args.Length && int.TryParse(args[i + 1], out var ti))
            tuneIter = ti;
    Console.WriteLine("B+ Auto-Tuner v3.0.4L BETA");
    var tuner = new AutoTuner(input);
    var tuneResult = tuner.Tune(iterations: tuneIter);
    Console.WriteLine(AutoTuner.GenerateReport(tuneResult));
    return 0;
}

if (args.Contains("--roofline"))
{
    if (input == null || !File.Exists(input))
    {
        Console.Error.WriteLine("Usage: bpc <input.bp> --roofline");
        return 1;
    }
    var srcR = File.ReadAllText(input);
    var parserR = new BPlusParser();
    var programR = parserR.Parse(srcR);
    var roofResult = RooflineAnalyzer.Analyze(programR);
    Console.WriteLine(RooflineAnalyzer.GenerateReport(roofResult));
    return 0;
}

if (args.Contains("--pgo"))
{
    if (input == null || !File.Exists(input))
    {
        Console.Error.WriteLine("Usage: bpc <input.bp> --pgo [--pgo-use merged.profdata]");
        return 1;
    }
    string? pgoProfile = null;
    for (int i = 0; i < args.Length; i++)
        if (args[i] == "--pgo-use" && i + 1 < args.Length) pgoProfile = args[++i];

    Console.WriteLine("B+ PGO Pipeline v3.0.4L BETA");
    Console.WriteLine($"  Input: {input}");
    Console.WriteLine($"  Mode: {(pgoProfile != null ? "use existing profile" : "collect + recompile")}");
    var pipeline = new PgoPipeline(input, collect: pgoProfile == null, pgoUsePath: pgoProfile);
    var result = pipeline.Run();
    Console.WriteLine($"  Profile files: {result.ProfileFilesCollected}");
    if (!string.IsNullOrEmpty(result.OptimizedBinaryPath))
        Console.WriteLine($"  Optimized binary: {result.OptimizedBinaryPath}");
    if (result.Speedup > 0)
        Console.WriteLine($"  Speedup: {result.Speedup:F2}x");
    return 0;
}

if (args.Contains("--bolt"))
{
    if (input == null || !File.Exists(input))
    {
        Console.Error.WriteLine("Usage: bpc <input.bp> --bolt [--binary path]");
        return 1;
    }
    string? binaryPath = input;
    for (int i = 0; i < args.Length; i++)
        if (args[i] == "--binary" && i + 1 < args.Length) binaryPath = args[++i];

    Console.WriteLine("B+ BOLT Post-Link Optimizer v3.0.4L BETA");
    var bolt = new BoltOptimizer();
    var result = bolt.Optimize(binaryPath);
    Console.WriteLine(BoltOptimizer.GenerateReport(result));
    return 0;
}

if (args.Contains("--buffer-counters"))
{
    Console.WriteLine("B+ Buffer PMC Counters v3.0.4L BETA");
    var analysis = BPlusTranspiler.Runtime.PerfCounterReader.AnalyzeBuffers(input ?? "");
    Console.WriteLine(BPlusTranspiler.Runtime.PerfCounterReader.GenerateBufferReport(analysis));
    return 0;
}

if (args.Contains("--l3-heap"))
{
    if (input == null || !File.Exists(input))
    {
        Console.Error.WriteLine("Usage: bpc <input.bp> --l3-heap [--heap-size 2MB] [--numa 0]");
        return 1;
    }

    ulong heapSize = 2 * 1024 * 1024;
    int numaNode = -1;
    for (int i = 0; i < args.Length; i++)
    {
        if (args[i] == "--heap-size" && i + 1 < args.Length)
        {
            var hs = args[++i];
            if (hs.EndsWith("MB") && ulong.TryParse(hs[..^2], out var mb))
                heapSize = mb * 1024 * 1024;
            else if (hs.EndsWith("KB") && ulong.TryParse(hs[..^2], out var kb))
                heapSize = kb * 1024;
            else if (ulong.TryParse(hs, out var raw))
                heapSize = raw;
        }
        if (args[i] == "--numa" && i + 1 < args.Length && int.TryParse(args[++i], out var nn))
            numaNode = nn;
    }

    Console.WriteLine("B+ L3-Heap Allocator v3.0.4L BETA");
    Console.WriteLine($"  Heap size: {heapSize / (1024*1024)} MB");
    Console.WriteLine($"  NUMA node: {(numaNode >= 0 ? numaNode.ToString() : "auto")}");

    var srcL3 = File.ReadAllText(input);
    var l3Parser = new BPlusParser();
    var l3Program = l3Parser.Parse(srcL3);

    var l3Allocator = new L3HeapAllocator();
    var l3Analysis = l3Allocator.Analyze(l3Program);
    Console.WriteLine(L3HeapAllocator.GenerateReport(l3Analysis));

    var outputDir = "gen_metal";
    Directory.CreateDirectory(outputDir);

    // Generate runtime header
    var config = new L3HeapConfig { HeapSize = heapSize, NumaNode = numaNode };
    var l3Alloc = new L3HeapAllocator(outputDir, config);
    File.WriteAllText(Path.Combine(outputDir, "l3_heap.h"), l3Alloc.GenerateRuntimeHeader());
    Console.WriteLine($"  Generated: {outputDir}/l3_heap.h");

    string llvmPath = Path.Combine(outputDir, "l3_heap_intrinsics.ll");
    File.WriteAllText(llvmPath, l3Alloc.GenerateLlvmIntrinsics());
    Console.WriteLine($"  Generated: {llvmPath}");

    string asmPath = Path.Combine(outputDir, "l3_heap_stubs.s");
    File.WriteAllText(asmPath, l3Alloc.GenerateAsmStubs());
    Console.WriteLine($"  Generated: {asmPath}");

    string ldPath = Path.Combine(outputDir, "l3_heap_layout.ld");
    File.WriteAllText(ldPath, l3Alloc.GenerateLinkerScript());
    Console.WriteLine($"  Generated: {ldPath}");

    // Try to init runtime heap
    try
    {
        var runtime = new L3HeapRuntime(numaNode, heapSize);
        Console.WriteLine();
        Console.WriteLine(runtime.GenerateStatsReport());
    }
    catch (Exception ex)
    {
        Console.WriteLine($"  Runtime init (managed): {ex.Message}");
    }

    Console.WriteLine();
    Console.WriteLine("Done. Compile with:");
    Console.WriteLine($"  gcc -c l3_heap_stubs.s");
    Console.WriteLine($"  gcc -include l3_heap.h -o output.elf ... -lnuma");
    return 0;
}

if (args.Contains("--train-unpack"))
{
    Console.WriteLine("B+ AI UnpackPredictor Trainer v3.0.4L BETA");
    Console.WriteLine();
    Console.WriteLine("Generating training data and training model...");
    UnpackPredictorTrainer.GenerateTrainingData();
    Console.WriteLine();
    Console.WriteLine("Done. Use: bpc <input.bp> --metal --unpack");
    return 0;
}

if (args.Contains("--metal"))
{
    if (input == null || !File.Exists(input))
    {
        Console.Error.WriteLine("Usage: bpc <input.bp> --metal [--tier=L0] [--fusion] [--register-alloc] [--unpack] [--hidden-buffers]");
        return 1;
    }

    bool fusion = args.Contains("--fusion");
    bool regAlloc = args.Contains("--register-alloc");
    bool unpack = args.Contains("--unpack");
    bool hiddenBuffers = args.Contains("--hidden-buffers");
    string? tierStr = null;
    for (int i = 0; i < args.Length; i++)
        if (args[i].StartsWith("--tier="))
            tierStr = args[i].Substring("--tier=".Length);

    return RunMetal(input, fusion, regAlloc, unpack, hiddenBuffers, tierStr);
}

if (input == null)
{
    Console.Error.WriteLine("Usage: bpc <input.bp> [--target llvm] [--pgo-collect] [--lto thin|full] [flags]");
    Console.Error.WriteLine("       bpc --lsp                         (start LSP server)");
    Console.Error.WriteLine("       bpc --install-lsp                  (install LSP for VS Code)");
    Console.Error.WriteLine("       bpc watch <dir> [--target ...]      (watch dir for changes and regenerate)");
    Console.Error.WriteLine("       bpc format <file.bp> [--check]      (format .bp file)");
    Console.Error.WriteLine("       bpc docs <file.bp> [--output ./dir]  (generate documentation)");
    Console.Error.WriteLine("       bpc debug <file.bp>                  (interactive state machine debugger)");
    Console.Error.WriteLine("       bpc profile <file.bp> [iterations]   (profile transition frequencies)");
    Console.Error.WriteLine("       bpc <input.bp> --metal [--tier=L0] [--fusion] [--register-alloc]  (full metal stack)");
    Console.Error.WriteLine("       bpc <input.bp> --ai                             (AI optimizer for metal config)");
    Console.Error.WriteLine("       bpc <input.bp> --metal --unpack                 (AI register unpack predictor)");
    Console.Error.WriteLine("       bpc <input.bp> --metal --hidden-buffers          (LSD/LFB/TLB/BTB/RSB analysis)");
    Console.Error.WriteLine("       bpc <input.bp> --roofline                       (roofline model: compute vs memory bound)");
    Console.Error.WriteLine("       bpc --muarch                                 (µarch profile: Agner Fog tables)");
    Console.Error.WriteLine("       bpc <input.bp> --ilp                            (ILP dependency chain analysis)");
    Console.Error.WriteLine("       bpc <input.bp> --store-fwd                      (store forwarding hazard detection)");
    Console.Error.WriteLine("       bpc <input.bp> --auto-tune [N]                  (auto-tune: AI + real perf counters)");
    Console.Error.WriteLine("       bpc <input> --plugin unity|unreal|godot|web|unigine  (engine-specific code generation)");
    Console.Error.WriteLine("       bpc bpm <init|install|list|search|publish>   (package manager)");
    Console.Error.WriteLine("       bpc test run <file.bp>                      (run auto-generated tests)");
    Console.Error.WriteLine("       bpc health [dir] [flags]                    (project health analysis)");
    Console.Error.WriteLine("       bpc diff <a.bp> <b.bp>                      (semantic diff)");
    Console.Error.WriteLine("       bpc build [--config bp.toml] [--dry-run]    (build from config)");
    Console.Error.WriteLine("       bpc publish [--runtime linux-x64] [--aot]   (NativeAOT publish)");
    Console.Error.WriteLine();
    Console.Error.WriteLine("Optimization flags (реалистичные ускорения на state machine):");
    Console.Error.WriteLine("  --pgo [--pgo-use file]       PGO pipeline: instrument→run→merge→recompile   +15-25%");
    Console.Error.WriteLine("  --bolt [--binary path]       BOLT post-link: reorder code by hot paths    +10-20%");
    Console.Error.WriteLine("  --buffer-counters            Store/Load buffer PMC analysis               (PMC)");
    Console.Error.WriteLine("  --self-contained             Self-contained binary (no .NET runtime)");
    Console.Error.WriteLine("  --aot                        NativeAOT compilation");
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
    Console.Error.WriteLine("  --lto <mode>                 Link-Time Optimization thin|full     +10-20%");
    Console.Error.WriteLine("  --thread-pool <N>            Многопоточная диспетчеризация");
    Console.Error.WriteLine("  --lock-free                  Безлоковые структуры               +5-10%");
    Console.Error.WriteLine("  --target-arch <arch>         native|zen4|raptor|m1|cortex");
    Console.Error.WriteLine("  --target-os <os>             linux|windows|baremetal");
    Console.Error.WriteLine("  --memory=regions             Region allocator (zero-free transitions)");
    Console.Error.WriteLine("  --pool=linear|ring           State pool allocator (linear: +20-40%, ring: ~0 alloc)");
    Console.Error.WriteLine("  --pgo-collect                PGO instrumentation in LLVM IR       +15-25%");
    Console.Error.WriteLine("  --pgo-use <file>             Apply PGO profile to LLVM IR");
    Console.Error.WriteLine("  --c-abi                      Generate C ABI exports (.dll/.so/.dylib)");
    Console.Error.WriteLine("  --target dxil|hlsl           Generate DirectX HLSL compute shaders (DXIL)");
    Console.Error.WriteLine("  --target spirv|vulkan|glsl   Generate Vulkan GLSL compute shaders (SPIR-V)");
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

// LLVM IR generators (machine code paths)
if (target is "llvm" or "all" or "wasm" or "arm64" or "ios" or "android")
{
    generators.Add(new LlvmGenerator(target, gpuArch, pgoCollect, pgoUse, ltoMode, cAbi));
}

// Bridge-only targets also generate .ll
if (target is "bridge" or "bridges")
{
    generators.Add(new LlvmGenerator("native", gpuArch, pgoCollect, pgoUse, ltoMode, cAbi));
}

// DXIL / HLSL shader generator (DirectX 12 compute shaders)
if (target is "dxil" or "hlsl" or "all")
{
    generators.Add(new DxilGenerator(gpuArch));
}

// SPIR-V / GLSL shader generator (Vulkan compute shaders)
if (target is "spirv" or "vulkan" or "glsl" or "all")
{
    generators.Add(new GlslGenerator(gpuArch));
}

// Add kernel code generator if program has kernels/pipelines
if (program.Kernels.Count > 0 || program.Pipelines.Count > 0 || program.Entries.Count > 0
    || program.UseCxxDecls.Count > 0 || program.ExternCppFns.Count > 0)
{
    generators.Add(new CppKernelGenerator());
}

// Error analysis (7 categories + BPlusValidator)
if (optFlags.Check || !optFlags.HasAny)
{
    var reporter = new BPlusErrorReporter(program, input, optFlags.HasAny ? optFlags : null);
    reporter.RunAll();
    var code = reporter.Report(Console.Out);

    // Run BPlusValidator — 121 checks
    var valErrors = BPlusValidator.Validate(program, input);
    if (valErrors.Any(e => e.Severity == "🔴"))
    {
        Console.Error.WriteLine(BPlusValidator.GenerateReport(valErrors));
        code = 1;
    }

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
        "unigine" => new UniginePlugin(),
        _ => null
    };
    if (pluginGen == null)
    {
        Console.Error.WriteLine($"Unknown plugin: {plugin}. Use: unity, unreal, godot, web, unigine");
        return 1;
    }
    generators.Clear();
    generators.Add(pluginGen);
}

if (target != "all" && target != "cpp_opt" && target != "llvm" && target != "wasm"
    && target != "arm64" && target != "ios" && target != "android" && target != "bridge" && target != "bridges"
    && target != "dxil" && target != "hlsl" && target != "spirv" && target != "vulkan" && target != "glsl")
{
    generators = generators.Where(g =>
        g.GetLanguageName().Equals(target, StringComparison.OrdinalIgnoreCase) ||
        g.GetFileExtension().Equals("." + target, StringComparison.OrdinalIgnoreCase)
    ).ToList();

    if (generators.Count == 0)
    {
        Console.Error.WriteLine($"Unknown target: {target}. Use: python, cpp, csharp, c, llvm, wasm, arm64, ios, android, dxil, hlsl, spirv, vulkan, glsl, bridges, all");
        return 1;
    }
}

Directory.CreateDirectory(output);
int count = 0;
var lockObj = new object();

Parallel.ForEach(generators, gen =>
{
    var files = gen.GenerateFiles(program);
    int localCount = 0;
    foreach (var (name, code) in files)
    {
        var outputFile = Path.Combine(output, name);
        File.WriteAllText(outputFile, code);
        Console.WriteLine($"  [{gen.GetLanguageName(),-10}] {outputFile}");
        localCount++;
    }
    if (localCount > 0)
        Interlocked.Add(ref count, localCount);
});

Console.WriteLine($"Done. Generated {count} file(s) to {output}");
return 0;

static string Sanitize(string name) =>
    string.Join("_", name.Split(System.IO.Path.GetInvalidFileNameChars()));

static void OnFileChanged(string file, List<string> genArgs, bool cAbi)
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

        if (target is "llvm" or "wasm" or "arm64" or "ios" or "android")
            generators.Add(new LlvmGenerator(target, "auto", false, null, null, cAbi));

        if (target is "dxil" or "hlsl" or "all")
            generators.Add(new DxilGenerator("auto"));

        if (target is "spirv" or "vulkan" or "glsl" or "all")
            generators.Add(new GlslGenerator("auto"));

        if (watchOptFlags.HasAny)
        {
            if (watchOptFlags.Optimize || watchOptFlags.DeadElim || watchOptFlags.ConstFold || watchOptFlags.Dedup)
                program = BPlusOptimizer.Optimize(program);
            generators.Add(new CppOptimizedGenerator(watchOptFlags));
            target = "cpp_opt";
        }

        if (target != "all" && target != "cpp_opt" && target != "llvm" && target != "wasm"
            && target != "arm64" && target != "ios" && target != "android" && target != "bridge" && target != "bridges"
            && target != "dxil" && target != "hlsl" && target != "spirv" && target != "vulkan" && target != "glsl")
            generators = generators.Where(g =>
                g.GetLanguageName().Equals(target, StringComparison.OrdinalIgnoreCase) ||
                g.GetFileExtension().Equals("." + target, StringComparison.OrdinalIgnoreCase)
            ).ToList();

        Directory.CreateDirectory(output);
        var count = 0;
        Parallel.ForEach(generators, gen =>
        {
            int localCount = 0;
            foreach (var (name, code) in gen.GenerateFiles(program))
            {
                var path = Path.Combine(output, name);
                File.WriteAllText(path, code);
                localCount++;
            }
            if (localCount > 0)
                Interlocked.Add(ref count, localCount);
        });

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

static int RunMetal(string bpFile, bool fusion, bool regAlloc, bool unpack, bool hiddenBuffers, string? tierStr)
{
    Console.WriteLine("B+ v3.0.4L BETA Metal — NUMA + µarch + ILP + StoreFwd + AutoTune");
    Console.WriteLine();

    var srcRaw = File.ReadAllText(bpFile);
    var src = StripComments(srcRaw);

    // Strip @metal { ... } blocks before passing to BPlusParser
    var metalParser = new MetalParser();
    var metalBlocks = metalParser.ParseMetalBlocks(src);
    string srcClean = StripMetalBlocks(src);

    var parser = new BPlusParser();
    var program = parser.Parse(srcClean);

    // Apply CLI overrides
    if (tierStr != null && Enum.TryParse<MemoryTier>(tierStr, ignoreCase: true, out var tier))
    {
        if (metalBlocks.Count == 0)
            metalBlocks.Add(new MetalBlock { Config = new MetalConfig { Enabled = true, Tier = tier } });
        else
            metalBlocks[0].Config.Tier = tier;
    }

    Console.WriteLine($"Found {program.States.Count} states, {metalBlocks.Count} metal block(s).");

    // Apply generic metal blocks (no target state) as defaults for ALL states
    var genericBlock = metalBlocks.Find(b => b.TargetState == null && b.TargetKernel == null);
    if (genericBlock != null)
    {
        foreach (var state in program.States)
        {
            if (!metalBlocks.Any(b => b.TargetState == state.Name))
            {
                metalBlocks.Add(new MetalBlock
                {
                    Config = new MetalConfig
                    {
                        Enabled = true,
                        Tier = genericBlock.Config.Tier,
                        Register = genericBlock.Config.Register,
                        Zmm = genericBlock.Config.Zmm,
                        Mask = genericBlock.Config.Mask,
                        FusionPairs = { },
                        Section = genericBlock.Config.Section,
                        Gateway = genericBlock.Config.Gateway,
                        PrefetchHint = genericBlock.Config.PrefetchHint,
                        Alignment = genericBlock.Config.Alignment,
                        Packed = genericBlock.Config.Packed,
                        DataTier = genericBlock.Config.DataTier,
                        HotPath = genericBlock.Config.HotPath,
                        CriticalSize = genericBlock.Config.CriticalSize
                    },
                    TargetState = state.Name
                });
            }
        }
    }

    Console.WriteLine();

    // Phase 1: Classify tiers
    Console.WriteLine("[Phase 1] Classifying tiers...");
    var tiers = TierClassifier.Classify(program, metalBlocks);
    foreach (var t in tiers)
        Console.WriteLine($"  {t.StateName,-20} → {t.Section,-20} align {t.Alignment}");
    Console.WriteLine();

    // Phase 1: Pack code
    Console.WriteLine("[Phase 1] Packing code...");
    var packer = new CodePacker();
    var hotStates = tiers.Where(t => t.IsHot).Select(t => t.StateName).ToList();
    Console.WriteLine($"  L1 hot states: {string.Join(", ", hotStates)}");
    Console.WriteLine();

    // Phase 1: Pack data
    Console.WriteLine("[Phase 1] Packing data...");
    var dataSections = DataPacker.Pack(program, metalBlocks);
    foreach (var ds in dataSections)
        Console.WriteLine($"  {ds.Section,-20} {ds.Fields.Count} fields, {ds.TotalSize} bytes");
    Console.WriteLine();

    // Phase 2: Register allocation
    Console.WriteLine("[Phase 2] Register allocation...");
    var registers = RegisterAllocator.Allocate(program, metalBlocks);
    if (regAlloc)
    {
        foreach (var r in registers)
            Console.WriteLine($"  {r.Variable,-30} → {r.Register,-6} ({r.Class})");
        Console.WriteLine();
    }

    // Phase 2b: AI Unpacker (RegisterPacker + UnpackPredictor)
    if (unpack)
    {
        Console.WriteLine("[Phase 2b] AI Register Packer (unpack prediction)...");
        var regPacker = new RegisterPacker();
        regPacker.AnalyzeAccessPatterns(program.States);
        var packedRegs = regPacker.PackRegisters(program.States);
        foreach (var pr in packedRegs)
        {
            Console.WriteLine($"  {pr.Register}: {pr.TotalBits} bits, {pr.Fields.Count} fields");
            foreach (var f in pr.Fields)
                Console.WriteLine($"    {f.Name}: offset={f.Offset} bits={f.Bits} extract={f.ExtractionPattern} cycle={f.AccessCycle}");
        }
        Console.WriteLine();
        Console.WriteLine("  Unpack code:");
        foreach (var pr in packedRegs)
            Console.WriteLine(regPacker.GenerateUnpackCode(pr));
        Console.WriteLine();
    }

    // Phase 2c: Hidden Buffer Optimization (LSD, Store/Load Buffer, LFB, TLB, BTB, RSB)
    if (hiddenBuffers)
    {
        Console.WriteLine("[Phase 2c] Hidden buffer analysis (LSD / LFB / TLB / BTB / RSB)...");
        var hbAnalysis = HiddenBufferOptimizer.Analyze(program.States, tiers);
        Console.WriteLine(HiddenBufferOptimizer.GenerateReport(hbAnalysis));
        Console.WriteLine();
    }

    // Phase 2d: µarch profile verification for fusion pairs
    Console.WriteLine("[Phase 2d] µarch fusion verification...");
    string cpuHint = PrefetchInjector.DetectCpu();
    foreach (var mb in metalBlocks)
        foreach (var fp in mb.Config.FusionPairs)
        {
            var targetMuarch = mb.Config.MuarchProfile ?? cpuHint;
            bool valid = MicroArchProfiles.IsFusionValid(fp, targetMuarch);
            Console.WriteLine(valid
                ? $"  ✓ '{fp}' valid on {targetMuarch}"
                : $"  ⚠ '{fp}' NOT valid on {targetMuarch} — remove or change @muarch");
        }
    Console.WriteLine();

    // Phase 2e: ILP dependency analysis
    Console.WriteLine("[Phase 2e] ILP dependency analysis...");
    var ilpScores = IlpAnalyzer.Analyze(program, tiers);
    foreach (var ilp in ilpScores)
        if (ilp.MaxDependencyChain > 4)
            Console.WriteLine($"  ⚠ {ilp.StateName}: chain={ilp.MaxDependencyChain} ILP={ilp.Score:F2} — {ilp.Suggestion}");
        else
            Console.WriteLine($"  ✓ {ilp.StateName}: chain={ilp.MaxDependencyChain} ILP={ilp.Score:F2}");
    Console.WriteLine();

    // Phase 2: LLVM IR with intrinsics
    Console.WriteLine("[Phase 2] Generating LLVM IR with intrinsics...");
    var llvmGen = new LlvmGenMetal();
    string llvmIr = llvmGen.Generate(program, metalBlocks, tiers, registers);

    string outputDir = "gen_metal";
    Directory.CreateDirectory(outputDir);
    string llvmPath = Path.Combine(outputDir, "kernels_metal.ll");
    File.WriteAllText(llvmPath, llvmIr);
    Console.WriteLine($"  LLVM IR: {llvmPath}");
    Console.WriteLine();

    // Phase 3: Assembly generator
    Console.WriteLine("[Phase 3] Generating assembly...");
    var asmGen = new AsmGenerator();
    string asmCode = asmGen.GenerateAssembly(program, tiers, registers);
    string asmPath = Path.Combine(outputDir, "states_metal.asm");
    File.WriteAllText(asmPath, asmCode);
    Console.WriteLine($"  Assembly: {asmPath}");
    Console.WriteLine();

    // Phase 3: Linker script
    Console.WriteLine("[Phase 3] Generating linker script...");
    string ldScript = LinkerScriptGenerator.Generate(program, tiers, dataSections);
    string ldPath = Path.Combine(outputDir, "metal_layout.ld");
    File.WriteAllText(ldPath, ldScript);
    Console.WriteLine($"  Linker script: {ldPath}");
    Console.WriteLine();

    // Phase 4: Prefetch injection
    Console.WriteLine("[Phase 4] Analyzing prefetch opportunities...");
    var prefetchSites = PrefetchInjector.Analyze(program, tiers);
    foreach (var ps in prefetchSites)
        Console.WriteLine($"  {ps.PrefetchType,-14} {ps.Location}");
    var prefetchAsm = PrefetchInjector.GenerateAsm(prefetchSites);
    if (prefetchAsm.Count > 0)
    {
        string prefetchPath = Path.Combine(outputDir, "prefetch_hints.s");
        File.WriteAllLines(prefetchPath, prefetchAsm);
        Console.WriteLine($"  Prefetch asm: {prefetchPath}");
    }
    Console.WriteLine();

    // Phase 3b: Working set analysis (auto-tiling detection)
    Console.WriteLine("[Phase 3b] Working set analysis...");
    var ws = TierClassifier.AnalyzeWorkingSet(program);
    Console.WriteLine($"  Working set: ~{ws.WorkingSetBytes / 1024}KB");
    Console.WriteLine($"  Fits L1: {ws.FitsL1}, Fits L2: {ws.FitsL2}, Fits L3: {ws.FitsL3}");
    Console.WriteLine($"  Recommended tier: {ws.RecommendedTier}");
    if (ws.NeedsTiling)
        Console.WriteLine($"  ⚠ {ws.Warning}");
    Console.WriteLine();

    // Phase 3c: Perf counters snapshot
    Console.WriteLine("[Phase 3c] Hardware perf counters...");
    var perf = BPlusTranspiler.Runtime.PerfCounterReader.ReadCounters();
    double ipc = perf.Instructions > 0 ? (double)perf.Cycles / perf.Instructions : 0;
    Console.WriteLine($"  Cycles: {perf.Cycles:N0}");
    Console.WriteLine($"  Instructions: {perf.Instructions:N0}");
    Console.WriteLine($"  L1-D misses: {perf.L1DMisses:N0}");
    Console.WriteLine($"  L2 misses: {perf.L2Misses:N0}");
    Console.WriteLine($"  L3 misses: {perf.L3Misses:N0}");
    Console.WriteLine($"  Branch mispredicts: {perf.BranchMispredicts:N0}");
    Console.WriteLine($"  Store forward stalls: {perf.StoreForwardStalls:N0}");
    Console.WriteLine();

    // Phase 4: Metal runtime header
    Console.WriteLine("[Phase 4] Generating metal runtime...");
    string runtimeCs = @"
// Auto-generated metal runtime calls for: " + Path.GetFileName(bpFile) + @"
// To use, include in your C++ project:
//   #include ""metal_runtime.h""
//   MetalRuntime_LockHotSection(addr, size);
//   MetalRuntime_AllocateL3HugePage(size);
";
    string runtimePath = Path.Combine(outputDir, "metal_runtime.h");
    File.WriteAllText(runtimePath, runtimeCs);
    Console.WriteLine($"  Runtime header: {runtimePath}");
    Console.WriteLine();

    // Summary
    Console.WriteLine("═══════════════════════════════════════");
    Console.WriteLine("METAL OPTIMIZATION SUMMARY");
    Console.WriteLine("═══════════════════════════════════════");
    foreach (var t in tiers)
    {
        Console.WriteLine($"  {t.StateName,-16} {t.Section,-24} align {t.Alignment,-4} hot={t.IsHot,-5} gateway={t.NeedsGateway}");
    }
    Console.WriteLine($"  Total registers assigned: {registers.Count}");
    Console.WriteLine($"  Prefetch sites: {prefetchSites.Count}");
    Console.WriteLine();
    Console.WriteLine($"All files in {outputDir}/");
    Console.WriteLine("Done. Compile with:");
    Console.WriteLine($"  llc -filetype=obj {llvmPath}");
    Console.WriteLine($"  ld -T {ldPath} -o output.elf *.o");
    return 0;
}

static int RunAI(string bpFile)
{
    Console.WriteLine("B+ AI Optimizer v3.0.4L BETA");
    Console.WriteLine();

    string modelDir = "ai_models";
    string modelPath = Path.Combine(modelDir, "latest.nn");
    Directory.CreateDirectory(modelDir);

    DataCollector collector = new();
    NeuralPredictor? model = null;

    if (File.Exists(modelPath))
    {
        Console.WriteLine("Loading existing model...");
        model = NeuralPredictor.Load(modelPath);
    }
    else
    {
        Console.WriteLine("Collecting training data...");
        var data = collector.Collect(bpFile, count: 2000);
        Console.WriteLine($"  {data.Count} samples collected.");

        CodeFeatures features = collector.ExtractCodeFeatures(bpFile);
        int inputSize = 5 + new MetalConfig().ToFeatures().Length; // code features + metal config features

        Console.WriteLine("Training neural network...");
        model = new NeuralPredictor(inputSize, hiddenSize: 16);
        model.Train(data, epochs: 2000);
        model.Save(modelPath);
        Console.WriteLine("  Model saved to " + modelPath);
    }

    Console.WriteLine();
    Console.WriteLine("Searching optimal configuration...");

    var optimizer = new LayoutOptimizer(model, bpFile);
    MetalConfig best = optimizer.Optimize(candidates: 10000);
    double predictedIPC = optimizer.Predict(best);

    Console.WriteLine($"  Predicted IPC: {predictedIPC:F3}");
    Console.WriteLine($"  Tier: {best.Tier}");
    Console.WriteLine($"  Register pin: {best.Register ?? "(none)"}");
    Console.WriteLine($"  ZMM: {best.Zmm?.ToString() ?? "(none)"}");
    Console.WriteLine($"  Mask: {best.Mask ?? "(none)"}");
    Console.WriteLine($"  Fusion: {string.Join(", ", best.FusionPairs)}");
    Console.WriteLine($"  Section: {best.Section ?? "(default)"}");
    Console.WriteLine($"  Gateway: {best.Gateway?.ToString() ?? "(none)"}");
    Console.WriteLine($"  Prefetch: {best.PrefetchHint ?? "(none)"}");
    Console.WriteLine($"  Alignment: {best.Alignment?.ToString() ?? "(default)"}");
    Console.WriteLine($"  Packed: {best.Packed}");
    Console.WriteLine($"  Data tier: {best.DataTier?.ToString() ?? "(default)"}");
    Console.WriteLine($"  Hot path: {best.HotPath}");
    Console.WriteLine($"  Critical size: {best.CriticalSize?.ToString() ?? "(default)"}");

    Console.WriteLine();
    Console.WriteLine("Generating metal-annotated output...");

    // Parse metal blocks from source
    string src = File.ReadAllText(bpFile);
    var metalParser = new MetalParser();
    var blocks = metalParser.ParseMetalBlocks(src);
    Console.WriteLine($"  Found {blocks.Count} existing metal block(s).");

    // Write optimized config as annotation block
    string outputBp = Path.Combine(
        Path.GetDirectoryName(bpFile) ?? ".",
        Path.GetFileNameWithoutExtension(bpFile) + "_metal.bp");

    using (var writer = new StreamWriter(outputBp))
    {
        writer.WriteLine("// B+ v3.0.4L BETA Metal — AI-optimized + NUMA + µarch + ILP + AutoTune");
        writer.WriteLine($"// Predicted IPC: {predictedIPC:F3}");
        writer.WriteLine();
        writer.WriteLine("@metal {");
        if (best.Tier.HasValue)
            writer.WriteLine($"    @tier({(int)best.Tier.Value})  // {best.Tier}");
        if (best.Register != null)
            writer.WriteLine($"    @register({best.Register})");
        if (best.Zmm.HasValue)
            writer.WriteLine($"    @zmm({best.Zmm.Value})");
        if (best.Mask != null)
            writer.WriteLine($"    @mask({best.Mask})");
        foreach (var fp in best.FusionPairs)
            writer.WriteLine($"    @fusion({fp})");
        if (best.Section != null)
            writer.WriteLine($"    @section(\"{best.Section}\")");
        if (best.Gateway.HasValue)
            writer.WriteLine($"    @gateway({best.Gateway.Value})");
        if (best.PrefetchHint != null)
            writer.WriteLine($"    @prefetch({best.PrefetchHint})");
        if (best.Alignment.HasValue)
            writer.WriteLine($"    @align({best.Alignment.Value})");
        if (best.Packed)
            writer.WriteLine($"    @packed");
        if (best.DataTier.HasValue)
            writer.WriteLine($"    @data_tier({(int)best.DataTier.Value})");
        if (best.HotPath)
            writer.WriteLine($"    @hot_path(true)");
        if (best.CriticalSize.HasValue)
            writer.WriteLine($"    @critical_size({best.CriticalSize.Value})");
        writer.WriteLine("}");
        writer.WriteLine();

        // Write original source
        writer.Write(src);
    }

    Console.WriteLine($"  Output: {outputBp}");
    Console.WriteLine();
    Console.WriteLine("Done. Compile with: bpc " + outputBp);
    return 0;
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

    // Also try .exe self-contained
    var bpcExePath = Path.ChangeExtension(bpcPath, ".exe");
    if (!File.Exists(bpcPath) && File.Exists(bpcExePath))
        bpcPath = bpcExePath;

    bool isSelfContained = bpcPath.EndsWith(".exe", StringComparison.OrdinalIgnoreCase);

    var packageJson = new
    {
        name = "bplus-lsp",
        version = "2.5.0GH",
        displayName = "B+ Language Support",
        description = "B+ state machine language — LSP + syntax highlighting + Snippets",
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
            },
            snippets = new[]
            {
                new { language = "bp", path = "./snippets/bp.json" }
            }
        }
    };

    var esc = bpcPath.Replace("\\", "\\\\");
    var runCmd = isSelfContained ? esc : "dotnet";
    var runArgsStr = isSelfContained ? "['--lsp']" : "['" + esc + "', '--lsp']";

    var extensionJs = @"
const vscode = require('vscode');
const { spawn } = require('child_process');
const path = require('path');

function activate(context) {
    const serverPath = """ + esc + @""";
    const serverOptions = {
        run: { command: '" + runCmd + @"', args: " + runArgsStr + @" },
        debug: { command: '" + runCmd + @"', args: " + runArgsStr + @" }
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
            new { name = "comment.line.dash.bp", match = "--.*" },
            new { name = "keyword.control.bp", match = "\\b(state|base|var|on|after|enter|exit|always|async|import|context|enum|parallel|kernel|pipeline|entry)\\b" },
            new { name = "storage.type.bp", match = "\\b(int|float|string|bool|void|double|long|Image|ConvWeights|MotionVec|stream|TextureAtlas|ParticleBuffer)\\b" },
            new { name = "constant.language.bp", match = "\\b(true|false)\\b" },
            new { name = "entity.name.type.bp", match = "\\b[A-Z]\\w*\\b" },
            new { name = "annotation.bp", match = "@\\w+" },
            new { name = "directive.bp", match = "#\\w+" },
            new { name = "string.quoted.double.bp", match = "\"[^\"]*\"" },
            new { name = "constant.numeric.bp", match = "\\b\\d+(\\.\\d+)?\\b" },
            new { name = "keyword.operator.bp", match = "->|\\|>|>>" }
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

    var snippets = new Dictionary<string, object>
    {
        ["State Machine"] = new
        {
            scope = "bp",
            prefix = "state",
            body = new[] { "state ${1:Name} {", "\ton ${2:event} -> ${3:Target}", "}" },
            description = "Create a state with a transition"
        },
        ["Kernel"] = new
        {
            scope = "bp",
            prefix = "kernel",
            body = new[] { "kernel ${1:name}(${2:src}: Image) -> ${3:dst}: Image", "\tbody: ${4:src} |> ${5:relu} >> ${6:output}" },
            description = "Create a GPU kernel"
        },
        ["Hot Transition"] = new
        {
            scope = "bp",
            prefix = "hot",
            body = new[] { "@hot(${1:0.9})", "\ton ${2:event} -> ${3:Target}" },
            description = "Hot transition with PGO weight"
        },
        ["Cold Transition"] = new
        {
            scope = "bp",
            prefix = "cold",
            body = new[] { "@cold(${1:0.01})", "\ton ${2:event} -> ${3:Target}" },
            description = "Cold transition with PGO weight"
        },
        ["Fast Path Variable"] = new
        {
            scope = "bp",
            prefix = "fast",
            body = new[] { "@fast_path", "var ${1:name}: ${2:int}" },
            description = "Register-hinted fast-path variable"
        },
        ["Memory Comptime"] = new
        {
            scope = "bp",
            prefix = "comptime",
            body = new[] { "#memory comptime" },
            description = "Enable compile-time memory safety proofs"
        },
        ["SIMD Kernel"] = new
        {
            scope = "bp",
            prefix = "simd",
            body = new[] { "@simd_width(${1:512})", "@simd_unroll(${2:8})", "kernel ${3:name}(${4:src}: Image) -> Image", "\tbody: ${5:src} |> ${6:relu} >> ${7:output}" },
            description = "Kernel with SIMD annotations"
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

    var snippetsDir = Path.Combine(vscodeDir, "snippets");
    Directory.CreateDirectory(snippetsDir);
    File.WriteAllText(Path.Combine(snippetsDir, "bp.json"),
        System.Text.Json.JsonSerializer.Serialize(snippets, jsonOpts));

    // Auto-install npm dependency
    try
    {
        var psi = new System.Diagnostics.ProcessStartInfo("npm", $"install --prefix \"{vscodeDir}\" vscode-languageclient")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using var proc = System.Diagnostics.Process.Start(psi);
        if (proc != null)
        {
            proc.WaitForExit(60000);
            if (proc.ExitCode == 0)
                Console.WriteLine("  ✓ npm dependency installed.");
            else
                Console.WriteLine("  ⚠ npm install failed (run manually: cd \"{0}\" && npm install vscode-languageclient)", vscodeDir);
        }
    }
    catch
    {
        Console.WriteLine("  ⚠ npm not found. Install manually: cd \"{0}\" && npm install vscode-languageclient", vscodeDir);
    }

    Console.WriteLine();
    Console.WriteLine($"✓ B+ extension installed to: {vscodeDir}");
    Console.WriteLine("  Restart VS Code and open a .bp file to activate B+ support.");
    Console.WriteLine();
    Console.WriteLine("  Features:");
    Console.WriteLine("    • Syntax highlighting (.bp files)");
    Console.WriteLine("    • LSP: errors, completions, hover info, formatting");
    Console.WriteLine("    • Code snippets: state, kernel, hot, cold, simd, comptime");
    Console.WriteLine("    • Auto-closing pairs, bracket matching");
}

static string StripComments(string src)
{
    src = Regex.Replace(src, @"//.*", "");
    src = Regex.Replace(src, @"--.*", "");
    return src;
}

static string StripMetalBlocks(string src)
{
    int i = 0;
    while (true)
    {
        int idx = src.IndexOf("@metal", i, StringComparison.Ordinal);
        if (idx < 0) break;

        // Find opening {
        int brace = src.IndexOf('{', idx);
        if (brace < 0) { i = idx + 6; continue; }

        // Find matching closing }
        int depth = 1;
        int end = brace + 1;
        while (end < src.Length && depth > 0)
        {
            if (src[end] == '{') depth++;
            else if (src[end] == '}') depth--;
            if (depth > 0) end++;
        }
        if (depth == 0) end++; // include closing }

        // Also strip any @ annotations that precede a state/kernel declaration
        // (inline metal annotations like @tier(0) state Foo)
        int start = idx;
        while (start > 0 && (src[start - 1] == ' ' || src[start - 1] == '\t' || src[start - 1] == '\n'))
            start--;

        src = src.Remove(start, end - start);
        i = start;
    }
    return src;
}
