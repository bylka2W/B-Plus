using BPlusTranspiler.Ast;

namespace BPlusTranspiler.AI;

public class LayoutOptimizer
{
    private NeuralPredictor _model;
    private CodeFeatures _features;
    private string _bpFile;

    public LayoutOptimizer(string modelPath, string bpFile)
    {
        _model = NeuralPredictor.Load(modelPath);
        _bpFile = bpFile;
        var collector = new DataCollector();
        _features = collector.ExtractCodeFeatures(bpFile);
    }

    public LayoutOptimizer(NeuralPredictor model, string bpFile)
    {
        _model = model;
        _bpFile = bpFile;
        var collector = new DataCollector();
        _features = collector.ExtractCodeFeatures(bpFile);
    }

    public MetalConfig Optimize(int candidates = 10000)
    {
        MetalConfig? bestConfig = null;
        double bestIPC = 0;

        foreach (var config in GenerateCandidates(candidates))
        {
            double predictedIPC = Predict(config);
            if (predictedIPC > bestIPC)
            {
                bestIPC = predictedIPC;
                bestConfig = config;
            }
        }

        if (bestConfig != null)
            bestConfig.Enabled = true;

        return bestConfig ?? new MetalConfig { Enabled = true };
    }

    public double Predict(MetalConfig config)
    {
        double[] input = Merge(_features, config);
        return _model.Predict(input) * 6.0; // denormalize
    }

    private static IEnumerable<MetalConfig> GenerateCandidates(int count)
    {
        for (int i = 0; i < count; i++)
            yield return MetalConfig.Random();
    }

    private static double[] Merge(CodeFeatures f, MetalConfig c)
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
}
