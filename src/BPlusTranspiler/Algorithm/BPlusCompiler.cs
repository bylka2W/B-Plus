using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace BPlusTranspiler.Algorithm;

public class BPlusCompiler
{
    private readonly X64Encoder encoder = new();
    private readonly MultiTargetLinker linker = new();
    private readonly OptimizationPipeline pipeline = new();
    private readonly JITCompiler jit = new();
    private readonly AutoTuningFramework tuner = new();

    public class CompileOptions
    {
        public string OutputFile { get; set; } = "output.exe";
        public ExecutableFormat Format { get; set; } = ExecutableFormat.PE;
        public bool EnableOptimization { get; set; } = true;
        public bool EnableVectorization { get; set; } = true;
        public bool EnableAutoTuning { get; set; } = true;
        public string TargetArch { get; set; } = "skylake";
        public int MaxIterations { get; set; } = 1000;
    }

    public class CompileResult
    {
        public byte[] MachineCode { get; set; } = Array.Empty<byte>();
        public byte[]? Executable { get; set; }
        public long CodeSize { get; set; }
        public long CompileTimeMs { get; set; }
        public int Instructions { get; set; }
        public double EstSpeedup { get; set; }
        public List<string> Warnings { get; set; } = new();
        public List<string> Errors { get; set; } = new();
    }

    public CompileResult Compile(ASTNode[] ast, CompileOptions opts)
    {
        var sw = Stopwatch.StartNew();
        var result = new CompileResult();

        try
        {
            var asmToMachine = new ASTToMachineCode();
            var compileResult = asmToMachine.Compile(ast.ToList(), AbiType.Windows);

            if (opts.EnableOptimization)
            {
                var optResult = RunOptimization(compileResult.Code);
                result.MachineCode = optResult.Code;
                result.EstSpeedup = optResult.Speedup;
            }
            else
            {
                result.MachineCode = compileResult.Code;
            }

            result.CodeSize = result.MachineCode.Length;
            result.Instructions = result.MachineCode.Length / 4;

            if (opts.EnableAutoTuning)
            {
                var tuned = AutoTune(result.MachineCode, opts.MaxIterations);
                result.MachineCode = tuned.Code;
                result.EstSpeedup = tuned.Speedup;
            }

            if (opts.Format == ExecutableFormat.PE)
            {
                var pe = linker.Link(new ObjectFile(), opts.Format, new());
                result.Executable = pe;
                linker.WriteFile(pe, opts.OutputFile);
            }

            sw.Stop();
            result.CompileTimeMs = sw.ElapsedMilliseconds;
        }
        catch (Exception ex)
        {
            result.Errors.Add(ex.Message);
            sw.Stop();
            result.CompileTimeMs = sw.ElapsedMilliseconds;
        }

        return result;
    }

    private OptimizationResult RunOptimization(byte[] code)
    {
        var pipeline = new MachineCodeOptimizer();
        pipeline.AddPass(new PeepholePass());
        pipeline.AddPass(new JumpShrinkPass());
        pipeline.AddPass(new VectorizationPass());
        pipeline.AddPass(new LoopUnrollPass());
        pipeline.AddPass(new CacheHintPass());
        pipeline.AddPass(new BranchPredictPass());

        var optResult = pipeline.Optimize(code);
        return new OptimizationResult
        {
            Code = optResult.Output.ToArray(),
            Speedup = optResult.Stats.SpeedupEst > 0 ? optResult.Stats.SpeedupEst : 1.0
        };
    }

    private OptimizationResult AutoTune(byte[] code, int maxIter)
    {
        var result = new OptimizationResult { Code = code, Speedup = 1.0 };
        var sw = Stopwatch.StartNew();

        var tuningResult = tuner.SmartTune(config =>
        {
            return Simulate(config, code);
        }, maxIter);

        sw.Stop();
        return result;
    }

    private double Simulate(Dictionary<string, object> config, byte[] code)
    {
        double score = code.Length * 0.1;

        if (config.TryGetValue("loop_unroll", out var unroll))
            score -= (int)unroll * 0.05;

        if (config.TryGetValue("vectorize", out var vec) && (bool)vec)
            score *= 0.8;

        if (config.TryGetValue("prefetch", out var prefetch))
            score -= (int)prefetch * 0.1;

        return Math.Max(score, 0.1);
    }

    public IntPtr JitCompile(byte[] code)
    {
        return jit.AllocateAndExecute(code);
    }

    public TDelegate JitCompile<TDelegate>(byte[] code) where TDelegate : Delegate
    {
        return jit.CompileAndExecute<TDelegate>(encoder);
    }

    public void WriteExecutable(CompileResult result, string path)
    {
        if (result.Executable != null)
            File.WriteAllBytes(path, result.Executable);
        else
            File.WriteAllBytes(path, result.MachineCode);
    }

    public string PrintReport(CompileResult result)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("=== B+ Compiler Report ===");
        sb.AppendLine($"Code size: {result.CodeSize} bytes");
        sb.AppendLine($"Instructions: {result.Instructions}");
        sb.AppendLine($"Compile time: {result.CompileTimeMs:F2} ms");
        sb.AppendLine($"Est speedup: {result.EstSpeedup:F2}x");

        if (result.Warnings.Count > 0)
        {
            sb.AppendLine("Warnings:");
            foreach (var w in result.Warnings)
                sb.AppendLine($"  - {w}");
        }

        if (result.Errors.Count > 0)
        {
            sb.AppendLine("Errors:");
            foreach (var e in result.Errors)
                sb.AppendLine($"  - {e}");
        }

        return sb.ToString();
    }

    private class OptimizationResult
    {
        public byte[] Code { get; set; } = Array.Empty<byte>();
        public double Speedup { get; set; }
    }
}

public class BPlusRuntime
{
    private readonly JITCompiler jit = new();
    private readonly ExecutableMemory mem = new();

    public IntPtr AllocateCode(byte[] code)
    {
        return jit.AllocateAndExecute(code);
    }

    public void FreeCode(IntPtr ptr)
    {
        mem.Free();
    }

    public TFunc GetFunction<TFunc>(IntPtr addr) where TFunc : Delegate
    {
        return Marshal.GetDelegateForFunctionPointer<TFunc>(addr);
    }

    public long MeasureExecution(IntPtr code, int iterations = 1000)
    {
        var del = Marshal.GetDelegateForFunctionPointer<Func<long>>(code);
        var sw = Stopwatch.StartNew();

        for (int i = 0; i < iterations; i++)
            del();

        sw.Stop();
        return sw.ElapsedMilliseconds;
    }
}

public class BPlusBenchmark
{
    private readonly BPlusCompiler compiler = new();

    public class BenchmarkResult
    {
        public string Name { get; set; } = "";
        public double Score { get; set; }
        public double CompileTimeMs { get; set; }
        public double EstSpeedup { get; set; }
    }

    public BenchmarkResult RunBenchmark(string name, ASTNode[] code)
    {
        var sw = Stopwatch.StartNew();
        var result = compiler.Compile(code, new BPlusCompiler.CompileOptions());
        sw.Stop();

        return new BenchmarkResult
        {
            Name = name,
            Score = result.CodeSize,
            CompileTimeMs = result.CompileTimeMs,
            EstSpeedup = result.EstSpeedup
        };
    }

    public string PrintResults(List<BenchmarkResult> results)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("=== B+ Benchmark Results ===");

        foreach (var r in results.OrderBy(x => x.Score))
        {
            sb.AppendLine($"{r.Name}: score={r.Score:F2}, compile={r.CompileTimeMs:F2}ms, speedup={r.EstSpeedup:F2}x");
        }

        return sb.ToString();
    }
}

public class BPlusModule
{
    public string Name { get; set; } = "";
    public List<BPlusFunction> Functions { get; set; } = new();
    public Dictionary<string, long> Globals { get; set; } = new();
    public Dictionary<string, long> Exports { get; set; } = new();
    public Dictionary<string, long> Imports { get; set; } = new();
}

public class BPlusFunction
{
    public string Name { get; set; } = "";
    public byte[] Code { get; set; } = Array.Empty<byte>();
    public int CodeSize => Code.Length;
    public long Address { get; set; }
    public List<string> Params { get; set; } = new();
    public string ReturnType { get; set; } = "void";
}

public class BPlusLinker
{
    private readonly MultiTargetLinker linker = new();
    private readonly List<BPlusModule> modules = new();

    public void AddModule(BPlusModule module)
    {
        modules.Add(module);
    }

    public byte[] Link(ExecutableFormat format, string entryPoint)
    {
        var obj = new ObjectFile();

        foreach (var mod in modules)
        {
            var sec = new Section
            {
                Name = ".text",
                Data = mod.Functions.SelectMany(f => f.Code).ToArray(),
                Flags = Section.SectionFlags.Executable | Section.SectionFlags.Alloc
            };
            linker.AddSection(obj, sec);

            foreach (var exp in mod.Exports)
            {
                var sym = new Symbol
                {
                    Name = exp.Key,
                    Value = exp.Value,
                    Type = Symbol.SymbolType.Function
                };
                linker.AddSymbol(obj, sym);
            }
        }

        return linker.Link(obj, format, new());
    }

    public void Write(string path, byte[] data)
    {
        linker.WriteFile(data, path);
    }
}
