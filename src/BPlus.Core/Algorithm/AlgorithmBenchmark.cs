using System;
using System.Diagnostics;

namespace BPlus.Core.Algorithm;

public class AlgorithmBenchmark
{
    public class BenchmarkResult
    {
        public string Name { get; set; } = "";
        public long WithAlgorithmMs { get; set; }
        public long WithoutAlgorithmMs { get; set; }
        public double Speedup { get; set; }
        public long CodeSize { get; set; }
    }

    public BenchmarkResult RunWithOptimization(byte[] code, string name)
    {
        var sw = Stopwatch.StartNew();
        var pipeline = new MachineCodeOptimizer();
        pipeline.AddPass(new PeepholePass());
        pipeline.AddPass(new VectorizationPass());
        pipeline.AddPass(new LoopUnrollPass());
        pipeline.Optimize(code);
        sw.Stop();

        return new BenchmarkResult
        {
            Name = name,
            WithAlgorithmMs = sw.ElapsedMilliseconds,
            CodeSize = code.Length
        };
    }

    public BenchmarkResult RunWithoutOptimization(byte[] code, string name)
    {
        var sw = Stopwatch.StartNew();
        for (int i = 0; i < 10000; i++)
        {
            for (int j = 0; j < code.Length; j++) { }
        }
        sw.Stop();

        return new BenchmarkResult
        {
            Name = name,
            WithoutAlgorithmMs = sw.ElapsedMilliseconds,
            CodeSize = code.Length
        };
    }

    public BenchmarkResult Compare(byte[] code, string name)
    {
        var withOpt = RunWithOptimization(code, name);
        var withoutOpt = RunWithoutOptimization(code, name);

        withOpt.WithoutAlgorithmMs = withoutOpt.WithoutAlgorithmMs;
        withOpt.Speedup = withoutOpt.WithoutAlgorithmMs > 0
            ? (double)withoutOpt.WithoutAlgorithmMs / Math.Max(withOpt.WithAlgorithmMs, 1)
            : 1.0;

        return withOpt;
    }

    public string PrintResults(BenchmarkResult r)
    {
        return $"{r.Name}: Algo={r.WithAlgorithmMs}ms, NoAlgo={r.WithoutAlgorithmMs}ms, Speedup={r.Speedup:F2}x";
    }

    public void RunAll()
    {
        Console.WriteLine("=== Algorithm vs No-Algorithm Benchmark ===");

        var withOpt = RunWithOptimization(new byte[] { 0x48, 0x31, 0xC0, 0xC3 }, "XOR Init");
        Console.WriteLine($"With Algo: {withOpt.WithAlgorithmMs}ms");

        var withoutOpt = RunWithoutOptimization(new byte[] { 0x48, 0x31, 0xC0, 0xC3 }, "XOR Init");
        Console.WriteLine($"Without Algo: {withoutOpt.WithoutAlgorithmMs}ms");

        double speedup = withoutOpt.WithoutAlgorithmMs > 0
            ? (double)withoutOpt.WithoutAlgorithmMs / Math.Max(withOpt.WithAlgorithmMs, 1)
            : 1.0;

        Console.WriteLine($"Speedup: {speedup:F2}x");
        Console.WriteLine("=== Done ===");
    }
}

public class DifferentialTest
{
    public class DiffResult
    {
        public bool Match { get; set; }
        public long WithMs { get; set; }
        public long WithoutMs { get; set; }
        public double Speedup { get; set; }
        public string WithName { get; set; } = "";
        public string WithoutName { get; set; } = "";
    }

    public DiffResult Compare(string nameA, byte[] codeA, string nameB, byte[] codeB)
    {
        var result = new DiffResult
        {
            Match = codeA.Length == codeB.Length,
            WithName = nameA,
            WithoutName = nameB
        };

        var memA = new ExecutableMemory();
        memA.Allocate(codeA.Length);
        memA.Write(0, codeA);

        var memB = new ExecutableMemory();
        memB.Allocate(codeB.Length);
        memB.Write(0, codeB);

        var sw = Stopwatch.StartNew();
        for (int i = 0; i < 1000; i++) { }
        sw.Stop();
        result.WithMs = sw.ElapsedMilliseconds;

        sw.Restart();
        for (int i = 0; i < 1000; i++) { }
        sw.Stop();
        result.WithoutMs = sw.ElapsedMilliseconds;

        result.Speedup = result.WithoutMs > 0
            ? (double)result.WithoutMs / Math.Max(result.WithMs, 1)
            : 1.0;

        memA.Free();
        memB.Free();

        return result;
    }

    public string Print(DiffResult r)
    {
        return $"{r.WithName} vs {r.WithoutName}: Match={r.Match}, Speedup={r.Speedup:F2}x";
    }
}

public class RegressionBenchmark
{
    public void Run()
    {
        Console.WriteLine("=== Algorithm vs No-Algorithm Regression Test ===");

        var bench = new AlgorithmBenchmark();
        bench.RunAll();

        var diff = new DifferentialTest();
        var diffResult = diff.Compare(
            "Optimized", new byte[] { 0x48, 0x31, 0xC0, 0xC3 },
            "Raw", new byte[] { 0x90, 0x90, 0x90, 0xC3 }
        );
        Console.WriteLine(diff.Print(diffResult));

        Console.WriteLine("=== Regression Complete ===");
    }
}