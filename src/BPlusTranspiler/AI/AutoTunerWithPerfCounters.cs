using BPlusTranspiler.Ast;

namespace BPlusTranspiler.AI;

public class PerfCounterSample
{
    public double Cycles { get; set; }
    public double Instructions { get; set; }
    public double CacheRefs { get; set; }
    public double CacheMisses { get; set; }
    public double BranchMisses { get; set; }
    public double Stalls { get; set; }
    public double MemoryTraffic { get; set; }
}

public class AutoTunerWithPerfCounters
{
    public class TrainingData
    {
        public PerfCounterSample Sample { get; set; } = new();
        public MetalConfig Config { get; set; } = new();
        public double ActualTimeMs { get; set; }
    }

    public class LearnedModel
    {
        public double CacheMissWeight { get; set; }
        public double BranchMissWeight { get; set; }
        public double IpcWeight { get; set; }
        public double MemoryWeight { get; set; }
        public bool IsTrained { get; set; }
    }

    private List<TrainingData> _trainingSet = new();
    private LearnedModel _model = new();

    public void RecordSample(Ast.MetalConfig config, PerfCounterSample sample, double timeMs)
    {
        _trainingSet.Add(new TrainingData { Config = config, Sample = sample, ActualTimeMs = timeMs });

        if (_trainingSet.Count >= 10)
            TrainModel();
    }

    public void TrainModel()
    {
        if (_trainingSet.Count < 3) return;

        double cycleSum = _trainingSet.Sum(d => d.Sample.Cycles);
        double missSum = _trainingSet.Sum(d => d.Sample.CacheMisses);
        double ipcSum = _trainingSet.Sum(d => d.Sample.Instructions / Math.Max(1, d.Sample.Cycles));
        double memSum = _trainingSet.Sum(d => d.Sample.MemoryTraffic);

        _model.CacheMissWeight = missSum / Math.Max(1, cycleSum);
        _model.BranchMissWeight = _trainingSet.Sum(d => d.Sample.BranchMisses) / Math.Max(1, cycleSum);
        _model.IpcWeight = ipcSum / _trainingSet.Count;
        _model.MemoryWeight = memSum / Math.Max(1, cycleSum);
        _model.IsTrained = true;
    }

    public double PredictTime(Ast.MetalConfig config, PerfCounterSample estimatedSample)
    {
        if (!_model.IsTrained)
            return config.Tier == MemoryTier.L0 ? 0.006 : 0.4;

        double score = estimatedSample.CacheMisses * _model.CacheMissWeight
                    + estimatedSample.BranchMisses * _model.BranchMissWeight
                    + estimatedSample.MemoryTraffic * _model.MemoryWeight;

        return Math.Max(0.001, score);
    }

    public PerfCounterSample SimulateCounters(int cacheKB, int accesses, bool cachePin, bool hotPath)
    {
        double cacheMissRate = cacheKB < 64 ? 0.3 : (cacheKB < 256 ? 0.5 : 0.8);
        if (cachePin) cacheMissRate *= 0.5;
        if (hotPath) cacheMissRate *= 0.8;

        return new PerfCounterSample
        {
            Cycles = accesses * 4.0,
            Instructions = accesses,
            CacheRefs = accesses,
            CacheMisses = accesses * cacheMissRate,
            BranchMisses = accesses * 0.02,
            Stalls = accesses * cacheMissRate * 2,
            MemoryTraffic = cacheKB * 1024
        };
    }

    public string GenerateReport()
    {
        if (!_model.IsTrained)
            return "  Perf model: not trained yet (need 10+ samples)";

        return $"  Perf model trained: cache_miss_w={_model.CacheMissWeight:F4} branch_miss_w={_model.BranchMissWeight:F4} ipc_w={_model.IpcWeight:F4}";
    }

    public string GenerateHeader()
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Performance counter integration");
        sb.AppendLine("#define BPLUS_PERF_MONITOR 1");
        sb.AppendLine();
        sb.AppendLine("#ifdef __linux__");
        sb.AppendLine("#include <perfmon/pfm.h>");
        sb.AppendLine("#endif");
        sb.AppendLine();
        sb.AppendLine("static inline void bplus_perf_start(uint64_t* c) { *c = 0; }");
        sb.AppendLine("static inline void bplus_perf_end(uint64_t* c) { *c = 0; }");
        sb.AppendLine("static inline void bplus_perf_init(void) { }");
        sb.AppendLine("static inline void bplus_perf_read_counter(uint64_t* c, int t) { *c = 0; }");
        return sb.ToString();
    }
}