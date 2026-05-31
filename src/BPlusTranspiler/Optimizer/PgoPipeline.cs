using BPlusTranspiler.Generators;
using BPlusTranspiler.Parser;
using System.Diagnostics;
using System.Text.RegularExpressions;

namespace BPlusTranspiler.Optimizer;

public class PgoPipeline
{
    private readonly string _bpFile;
    private readonly string _outputDir;
    private readonly string? _pgoUsePath;
    private readonly bool _collect;
    private readonly List<string> _profileFiles = new();

    public PgoPipeline(string bpFile, bool collect = true, string? pgoUsePath = null)
    {
        _bpFile = bpFile;
        _outputDir = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(bpFile) ?? ".", "gen_pgo"));
        _pgoUsePath = pgoUsePath;
        _collect = collect;
    }

    public PgoResult Run(int warmupRuns = 3, int measureRuns = 10)
    {
        var result = new PgoResult();
        Directory.CreateDirectory(_outputDir);

        string instrumentedBinary = Phase1_Instrument(result);

        if (_collect)
        {
            Phase2_Collect(instrumentedBinary, warmupRuns, measureRuns, result);
            Phase3_MergeProfiles(result);
        }

        Phase4_Recompile(result);
        return result;
    }

    private string Phase1_Instrument(PgoResult r)
    {
        Console.WriteLine("[PGO] Phase 1: Generating instrumented binary via C wrapper...");
        var src = File.ReadAllText(_bpFile);
        var program = new BPlusParser().Parse(src);

        // Generate .ll WITHOUT instrumentation intrinsics (pgoCollect: false)
        // then wrap with a C file that uses -fprofile-instr-generate.
        string? irPath = null;
        foreach (var gen in new ICodeGenerator[]
        {
            new LlvmGenerator("native", "auto", pgoCollect: false, pgoUse: null, ltoMode: null, cAbi: false)
        })
        {
            var files = gen.GenerateFiles(program);
            foreach (var (name, code) in files)
            {
                if (name.EndsWith(".ll"))
                {
                    irPath = Path.Combine(_outputDir, name);
                    File.WriteAllText(irPath, code);
                    Console.WriteLine($"[PGO] Generated IR: {irPath}");
                }
            }
        }

        string binaryPath = CompileInstrumented(irPath!);
        r.InstrumentedBinaryPath = binaryPath;
        Console.WriteLine($"[PGO] Instrumented binary: {binaryPath}");
        return binaryPath;
    }

    private string CompileInstrumented(string irPath)
    {
        string? clang = FindClang();
        if (clang == null) throw new InvalidOperationException("clang not found");

        string objPath = Path.Combine(_outputDir, "kernels.o");
        string wrapperC = Path.Combine(_outputDir, "_pgo_main.c");
        string binaryPath = Path.Combine(_outputDir, "bpc_instrumented.exe");

        string irCode = File.ReadAllText(irPath);
        bool hasEntry = irCode.Contains("@main(");
        if (!hasEntry)
        {
            Console.WriteLine("[PGO] No @main in IR — compiling directly");
            return CompileWithPgo(irPath, null, forInstrumentation: true);
        }

        // Rename main -> __bpc_main so wrapper C can provide the real main
        irCode = Regex.Replace(irCode, @"define\s+i32\s+@main\s*\(", "define i32 @__bpc_main(");
        File.WriteAllText(irPath, irCode);

        var ccArgs = new ProcessStartInfo(clang, $"-c -O3 \"{irPath}\" -o \"{objPath}\"")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        using (var p1 = Process.Start(ccArgs))
        {
            p1?.WaitForExit(60000);
        }

        if (!File.Exists(objPath))
        {
            Console.WriteLine("[PGO] .ll → .obj failed — falling back to direct compilation");
            irCode = irCode.Replace("__bpc_main", "main");
            File.WriteAllText(irPath, irCode);
            return CompileWithPgo(irPath, null, forInstrumentation: true);
        }

        File.WriteAllText(wrapperC, "int __bpc_main(void); int main(void) { return __bpc_main(); }");

        string rtLib = FindProfileRt() ?? "";
        string extraLib = File.Exists(rtLib) ? $"\"{rtLib}\"" : "";
        var clArgs = new ProcessStartInfo(clang,
            $"-fprofile-instr-generate -fcoverage-mapping -O3 \"{wrapperC}\" \"{objPath}\" {extraLib} -o \"{binaryPath}\"")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        using (var p2 = Process.Start(clArgs))
        {
            p2?.WaitForExit(120000);
        }

        if (File.Exists(binaryPath))
        {
            Console.WriteLine($"[PGO] Compiled: {binaryPath}");
            return binaryPath;
        }

        Console.WriteLine("[PGO] Wrapper compilation failed — falling back");
        irCode = irCode.Replace("__bpc_main", "main");
        File.WriteAllText(irPath, irCode);
        return CompileWithPgo(irPath, null, forInstrumentation: true);
    }

    private void Phase2_Collect(string binaryPath, int warmup, int measure, PgoResult r)
    {
        Console.WriteLine($"[PGO] Phase 2: Collecting profiles ({warmup} warmup + {measure} measure runs)...");

        Console.WriteLine($"[PGO] Warming up ({warmup}x)...");
        for (int i = 0; i < warmup; i++)
        {
            RunWithEnv(binaryPath, new Dictionary<string, string>
            {
                ["LLVM_PROFILE_FILE"] = Path.Combine(_outputDir, $"warmup_%p_%m.profraw")
            }, timeout: 30000);
        }

        Console.WriteLine($"[PGO] Collecting profiles ({measure}x)...");
        for (int i = 0; i < measure; i++)
        {
            var pfPath = Path.Combine(_outputDir, $"run_{i}.profraw");
            bool ok = RunWithEnv(binaryPath, new Dictionary<string, string>
            {
                ["LLVM_PROFILE_FILE"] = pfPath
            }, timeout: 30000);

            if (ok && File.Exists(pfPath) && new FileInfo(pfPath).Length > 0)
            {
                _profileFiles.Add(pfPath);
                Console.WriteLine($"[PGO]   run {i + 1}/{measure} → {new FileInfo(pfPath).Length / 1024.0:F1} KB");
            }
            else
            {
                Console.WriteLine($"[PGO]   run {i + 1}/{measure} → failed or empty");
            }
        }

        r.ProfileFilesCollected = _profileFiles.Count;
    }

    private void Phase3_MergeProfiles(PgoResult r)
    {
        if (_profileFiles.Count == 0)
        {
            Console.WriteLine("[PGO] No profiles collected — skip merge");
            return;
        }

        Console.WriteLine($"[PGO] Phase 3: Merging {_profileFiles.Count} profiles...");
        string mergedProfraw = Path.Combine(_outputDir, "merged.profraw");
        string mergedProfdata = Path.Combine(_outputDir, "merged.profdata");

        string? profdataTool = FindProfdata();
        if (profdataTool == null)
        {
            Console.WriteLine("[PGO] llvm-profdata not found — using first profile raw");
            File.Copy(_profileFiles[0], mergedProfraw, overwrite: true);
            r.MergedProfilePath = mergedProfraw;
        }
        else
        {
            var args = "merge --output=\"" + mergedProfdata + "\" " + string.Join(" ", _profileFiles.Select(Path.GetFileName));
            var psi = new ProcessStartInfo(profdataTool, args)
            {
                WorkingDirectory = _outputDir,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using var proc = Process.Start(psi);
            proc?.WaitForExit(60000);

            r.MergedProfilePath = File.Exists(mergedProfdata) ? mergedProfdata : null;
        }

        if (r.MergedProfilePath != null && File.Exists(r.MergedProfilePath))
            Console.WriteLine($"[PGO] Merged profile: {r.MergedProfilePath} ({new FileInfo(r.MergedProfilePath!).Length / 1024.0:F1} KB)");
    }

    private void Phase4_Recompile(PgoResult r)
    {
        Console.WriteLine($"[PGO] Phase 4: Recompiling with profile data...");
        var program = new BPlusParser().Parse(File.ReadAllText(_bpFile));

        string? profdata = r.MergedProfilePath;
        if (profdata == null || !File.Exists(profdata))
        {
            Console.WriteLine("[PGO] No profile data — skipping recompile");
            return;
        }

        string optimizedDir = Path.Combine(_outputDir, "optimized");
        Directory.CreateDirectory(optimizedDir);

        foreach (var gen in new ICodeGenerator[]
        {
            new LlvmGenerator("native", "auto", pgoCollect: false, pgoUse: profdata, ltoMode: "thin", cAbi: false)
        })
        {
            var files = gen.GenerateFiles(program);
            foreach (var (name, code) in files)
            {
                var outPath = Path.Combine(optimizedDir, name);
                File.WriteAllText(outPath, code);
            }
        }

        string optBinary = CompileWithPgo(Path.Combine(optimizedDir, "main.ll"), profdata, forInstrumentation: false);
        r.OptimizedBinaryPath = optBinary;
        Console.WriteLine($"[PGO] Optimized binary: {optBinary}");

        if (File.Exists(r.InstrumentedBinaryPath) && File.Exists(optBinary))
        {
            Console.WriteLine("\n[PGO] Benchmarking...");
            double instrTime = Benchmark(r.InstrumentedBinaryPath, runs: 5);
            double optTime = Benchmark(optBinary, runs: 5);
            double speedup = instrTime / optTime;
            r.Speedup = speedup;
            Console.WriteLine($"  Instrumented: {instrTime:F3} ms");
            Console.WriteLine($"  Optimized:    {optTime:F3} ms");
            Console.WriteLine($"  Speedup:      {speedup:F2}x");
        }
    }

    private string CompileWithPgo(string? irPath, string? profdata, bool forInstrumentation)
    {
        string? clang = FindClang();
        if (clang == null)
        {
            Console.WriteLine("[PGO] clang not found — trying make on generated Makefile");
            string mkPath = Path.Combine(_outputDir, "Makefile");
            File.WriteAllText(mkPath, GenerateMakefile(irPath, profdata, forInstrumentation));
            try
            {
                using var make = Process.Start(new ProcessStartInfo("make", $"-C \"{_outputDir}\" -f Makefile {(forInstrumentation ? "instrument" : "binary")}")
                {
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                });
                if (make != null)
                {
                    make.WaitForExit(120000);
                    if (make.ExitCode == 0)
                    {
                        string makeOut = Path.Combine(_outputDir, (forInstrumentation ? "bpc_instrumented" : "bpc_optimized") + ".exe");
                        if (File.Exists(makeOut)) return makeOut;
                    }
                }
            }
            catch { }
            Console.Error.WriteLine("[PGO] clang and make not found — PGO unavailable. Install LLVM or run Makefile at " + mkPath);
            return "";
        }

        var args = new List<string>();
        if (forInstrumentation)
        {
            args.Add("-fprofile-instr-generate");
            args.Add("-fcoverage-mapping");
            var rt = FindProfileRt();
            if (rt != null) args.Add(rt);
        }
        else if (profdata != null && File.Exists(profdata))
        {
            args.Add($"-fprofile-instr-use={profdata}");
            args.Add("-fprofile-sample-accurate");
        }

        args.AddRange(new[] { "-O3" });
        if (irPath != null && File.Exists(irPath)) args.Add(irPath);
        args.AddRange(new[] { "-o", Path.Combine(_outputDir, (forInstrumentation ? "bpc_instrumented" : "bpc_optimized") + ".exe") });

        var psi = new ProcessStartInfo(clang)
        {
            WorkingDirectory = _outputDir,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var proc = Process.Start(psi);
        proc?.WaitForExit(120000);

        string outBinary = Path.Combine(_outputDir, (forInstrumentation ? "bpc_instrumented" : "bpc_optimized") + ".exe");
        if (File.Exists(outBinary)) Console.WriteLine($"[PGO] Compiled: {outBinary}");
        return outBinary;
    }

    private string GenerateMakefile(string? irPath, string? profdata, bool forInstr)
    {
        return $@"# PGO pipeline makefile — B+ v4.0.0 BETA
PGO_DIR := {_outputDir}
.PHONY: all instrument use
all: binary
instrument:
	$(CC) -fprofile-instr-generate -fcoverage-mapping -O3 -flto=thin {(irPath ?? "*.ll")} -o $(PGO_DIR)/bpc_instrumented
use:
	$(CC) -fprofile-instr-use=$(PGO_DIR)/merged.profdata -fprofile-sample-accurate -O3 -flto=thin {(irPath ?? "*.ll")} -o $(PGO_DIR)/bpc_optimized
binary:
	{(forInstr ? "$(MAKE) instrument" : $"$(MAKE) use PROF={profdata ?? "$(PGO_DIR)/merged.profdata"}")}";
    }

    private bool RunWithEnv(string binary, Dictionary<string, string> env, int timeout)
    {
        if (!File.Exists(binary)) { Console.WriteLine($"[PGO] Binary not found: {binary}"); return false; }
        var psi = new ProcessStartInfo(binary)
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = _outputDir
        };
        foreach (var kv in env) psi.Environment[kv.Key] = kv.Value;
        using var proc = Process.Start(psi);
        if (proc == null) return false;
        proc.StandardInput.WriteLine("exit");
        proc.StandardInput.Flush();
        proc.WaitForExit(timeout);
        return proc.ExitCode == 0;
    }

    private double Benchmark(string binaryPath, int runs = 5)
    {
        if (!File.Exists(binaryPath)) return 0;
        var times = new List<double>();
        for (int i = 0; i < runs; i++)
        {
            var sw = Stopwatch.StartNew();
            var psi = new ProcessStartInfo(binaryPath, _bpFile)
            {
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using var p = Process.Start(psi);
            if (p != null) { p.StandardInput.WriteLine("exit"); p.StandardInput.Flush(); }
            p?.WaitForExit(10000);
            sw.Stop();
            times.Add(sw.Elapsed.TotalMilliseconds);
            Thread.Sleep(100);
        }
        return times.OrderBy(t => t).Skip(1).Take(3).Average();
    }

    private string? FindClang()
    {
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string[] paths =
        {
            Path.Combine(userProfile, ".bplus", "llvm", "bin", "clang.exe"),
            "clang.exe", "clang",
            @"C:\Program Files\LLVM\bin\clang.exe",
        };
        foreach (var tool in paths)
            if (File.Exists(tool)) return tool;
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            var f = Path.Combine(dir, "clang.exe");
            if (File.Exists(f)) return f;
        }
        var psi = new ProcessStartInfo("where", "clang") { UseShellExecute = false, RedirectStandardOutput = true };
        using var proc = Process.Start(psi);
        return proc?.StandardOutput.ReadLine();
    }

    private string? FindProfdata()
    {
        string[] paths =
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".bplus", "llvm", "bin", "llvm-profdata.exe"),
            "llvm-profdata", "llvm-profdata-18",
            "/usr/bin/llvm-profdata",
            @"C:\Program Files\LLVM\bin\llvm-profdata.exe"
        };
        foreach (var p in paths) { if (File.Exists(p)) return p; }
        return null;
    }

    private string? FindProfileRt()
    {
        var clangDir = Path.GetDirectoryName(FindClang());
        if (clangDir == null) return null;
        var llvmRoot = Path.GetDirectoryName(clangDir);
        if (llvmRoot == null) return null;
        var libDir = Path.Combine(llvmRoot, "lib", "clang");
        if (!Directory.Exists(libDir)) return null;
        var verDirs = Directory.GetDirectories(libDir);
        if (verDirs.Length == 0) return null;
        var winDir = Path.Combine(verDirs[^1], "lib", "windows");
        if (!Directory.Exists(winDir)) return null;
        var rt = Directory.GetFiles(winDir, "clang_rt.profile-*.lib").FirstOrDefault();
        return rt;
    }

    private string FindInPath(string name)
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in path.Split(Path.PathSeparator))
        {
            var f = Path.Combine(dir, name);
            if (File.Exists(f)) return f;
        }
        return name;
    }
}

public class PgoResult
{
    public string? InstrumentedBinaryPath { get; set; }
    public string? OptimizedBinaryPath { get; set; }
    public string? MergedProfilePath { get; set; }
    public int ProfileFilesCollected { get; set; }
    public double Speedup { get; set; }
}
