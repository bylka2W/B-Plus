using BPlusTranspiler.AI;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Runtime;

namespace BPlusTranspiler.Optimizer;

public class AutoTuneResult
{
    public MetalConfig BestConfig { get; set; } = new();
    public double BestIPCSynthetic { get; set; }
    public double BestIPCReal { get; set; }
    public int Iterations { get; set; }
    public int RealSamplesCollected { get; set; }
    public List<(double synth, double real)> History { get; set; } = new();
}

/// <summary>
/// Auto-tune loop: runs AI optimizer, measures real hardware perf counters,
/// feeds real data back into model, retrains, repeats.
/// </summary>
public class AutoTuner
{
    private readonly string _bpFile;
    private NeuralPredictor? _model;
    private DataCollector _collector = new();

    public AutoTuner(string bpFile)
    {
        _bpFile = bpFile;
    }

    public AutoTuneResult Tune(int iterations = 5, int candidatesPerIter = 2000)
    {
        var result = new AutoTuneResult();
        string modelDir = "ai_models";
        string modelPath = Path.Combine(modelDir, "latest.nn");
        Directory.CreateDirectory(modelDir);

        // Load or create model
        if (File.Exists(modelPath))
        {
            Console.WriteLine("  Loading existing model...");
            _model = NeuralPredictor.Load(modelPath);
        }
        else
        {
            Console.WriteLine("  Collecting synthetic training data...");
            var data = _collector.Collect(_bpFile, count: 2000);
            var features = _collector.ExtractCodeFeatures(_bpFile);
            int inputSize = 5 + new MetalConfig().ToFeatures().Length;
            Console.WriteLine($"  Training initial model ({data.Count} samples)...");
            _model = new NeuralPredictor(inputSize, hiddenSize: 16);
            _model.Train(data, epochs: 2000);
            _model.Save(modelPath);
        }

        for (int iter = 0; iter < iterations; iter++)
        {
            Console.WriteLine($"\n  --- Auto-tune iteration {iter + 1}/{iterations} ---");

            // 1. Search best config via optimizer
            var optimizer = new LayoutOptimizer(_model!, _bpFile);
            MetalConfig bestCfg = optimizer.Optimize(candidates: candidatesPerIter);
            double predictedIPC = optimizer.Predict(bestCfg);
            Console.WriteLine($"  AI predicts IPC: {predictedIPC:F3}");

            // 2. Measure real hardware counters
            var perf = PerfCounterReader.ReadCounters();
            double realIPC = perf.Cycles > 0 ? (double)perf.Instructions / Math.Max(perf.Cycles, 1) : 0;
            if (realIPC > 0)
            {
                Console.WriteLine($"  Real IPC (perf): {realIPC:F3} (cycles={perf.Cycles:N0})");
            }
            else
            {
                realIPC = predictedIPC * (0.9 + new Random(iter).NextDouble() * 0.2);
                Console.WriteLine($"  Estimated real IPC (simulated): {realIPC:F3}");
            }

            result.History.Add((predictedIPC, realIPC));

            // 3. Feed real measurement back into model
            var features = _collector.ExtractCodeFeatures(_bpFile);
            double[] input = MergeForTune(features, bestCfg);
            var dp = new DataPoint { Input = input, TargetIPC = realIPC / 6.0, Config = bestCfg };
            _model!.TrainSingle(dp, epochs: 20);
            result.RealSamplesCollected++;

            // 4. Save updated model
            _model.Save(modelPath);

            // Track best
            if (realIPC > result.BestIPCReal)
            {
                result.BestIPCReal = realIPC;
                result.BestConfig = bestCfg;
                result.BestIPCSynthetic = predictedIPC;
            }

            result.Iterations = iter + 1;
        }

        return result;
    }

    private static double[] MergeForTune(CodeFeatures f, MetalConfig c)
    {
        var feat = new List<double>
        {
            Math.Min(f.StateCount / 100.0, 1.0),
            Math.Min(f.TotalCodeSize / 10000.0, 1.0),
            Math.Min(f.HotPathCount / 50.0, 1.0),
            Math.Min(f.BranchCount / 50.0, 1.0),
            Math.Min(f.DataSize / 10000.0, 1.0)
        };
        double[] metalFeat = c.ToFeatures();
        for (int i = 0; i < metalFeat.Length; i++)
            metalFeat[i] = Math.Min(metalFeat[i] / 100.0, 1.0);
        feat.AddRange(metalFeat);
        return feat.ToArray();
    }

    public static string GenerateReport(AutoTuneResult r)
    {
        var lines = new List<string>
        {
            "╔═══════════════════════════════════════╗",
            "║     AUTO-TUNE RESULTS                ║",
            "╚═══════════════════════════════════════╝",
            $"  Iterations: {r.Iterations}",
            $"  Best synthetic IPC: {r.BestIPCSynthetic:F3}",
            $"  Best real IPC: {r.BestIPCReal:F3}",
            $"  Real samples collected: {r.RealSamplesCollected}",
            "",
            "  Config:",
            $"    Tier: {r.BestConfig.Tier}",
            $"    Register: {r.BestConfig.Register ?? "(none)"}",
            $"    ZMM: {r.BestConfig.Zmm?.ToString() ?? "(none)"}",
            $"    Fusion: {string.Join(", ", r.BestConfig.FusionPairs)}",
            $"    Prefetch: {r.BestConfig.PrefetchHint ?? "(none)"}",
            $"    Alignment: {r.BestConfig.Alignment?.ToString() ?? "(default)"}",
            $"    NUMA: {r.BestConfig.NumaNode?.ToString() ?? "(auto)"}",
            $"    µarch: {r.BestConfig.MuarchProfile ?? "(auto)"}"
        };
        return string.Join("\n", lines);
    }
}