namespace BPlusTranspiler.Algorithm;

public class SoftwarePipeline
{
    public enum StageType { Load, Compute, Store }

    public class PipelineStage
    {
        public StageType Type { get; set; }
        public string Code { get; set; } = "";
        public int Latency { get; set; }
        public int Iteration { get; set; }
    }

    public class PipelineResult
    {
        public List<PipelineStage> Stages { get; set; } = new();
        public int II { get; set; }
        public int TotalStages { get; set; }
        public double EstSpeedup { get; set; }
    }

    public PipelineResult GeneratePipeline(int loopLength, int numStages = 3)
    {
        var result = new PipelineResult();

        int ii = Math.Max(1, loopLength / numStages);
        result.II = ii;

        string[] stageNames = { "load", "compute", "store" };
        for (int iter = 0; iter < numStages; iter++)
        {
            result.Stages.Add(new PipelineStage
            {
                Type = (StageType)(iter % 3),
                Iteration = iter,
                Latency = 4,
                Code = $"    ; stage {iter}: {stageNames[iter % 3]}"
            });
        }

        result.TotalStages = numStages;
        result.EstSpeedup = 2.0 + (numStages / 3.0);

        return result;
    }

    public string UnrollLoop(string asm, int factor = 2)
    {
        var lines = asm.Split('\n').ToList();
        var result = new List<string>();

        int i = 0;
        while (i < lines.Count)
        {
            string line = lines[i].Trim();

            if (line.StartsWith("for") || line.StartsWith("while"))
            {
                result.Add(line);
                result.Add("{");
                for (int f = 0; f < factor; f++)
                {
                    int j = i + 1;
                    int depth = 1;
                    while (j < lines.Count && depth > 0)
                    {
                        string inner = lines[j].Trim();
                        if (inner.Contains("{")) depth++;
                        if (inner.Contains("}")) depth--;
                        if (depth == 0) break;
                        result.Add($"    {inner.Replace("i++", $"i+={factor}")}");
                        j++;
                    }
                    result.Add($"    i += {factor};");
                    i = j;
                }
                if (i < lines.Count && lines[i].Trim() == "}")
                    result.Add("}");
                i++;
            }
            else
            {
                result.Add(line);
                i++;
            }
        }

        return string.Join("\n", result);
    }

    public string GenerateHeader()
    {
        return @"// Software pipeline optimizations
#pragma once

#define BPLUS_SWPipeline_Stages 3
#define BPLUS_SWPipeline_II 4

static inline void bplus_swpipeline_init(void) { }
static inline void bplus_swpipeline_stage_load(void* ptr, size_t n) { }
static inline void bplus_swpipeline_stage_compute(void* ptr, size_t n) { }
static inline void bplus_swpipeline_stage_store(void* ptr, size_t n) { }

static inline void bplus_swpipeline_run(void* data, size_t count) {
    for (size_t i = 0; i < count; i += BPLUS_SWPipeline_II) {
        bplus_swpipeline_stage_load(data, i);
        bplus_swpipeline_stage_compute(data, i);
        bplus_swpipeline_stage_store(data, i);
    }
}

#define BPLUS_LOOP_UNROLL 2
#define BPLUS_LOOP_UNROLL_FACTOR 2

static inline void bplus_unroll2(void* ptr, size_t count) {
    size_t i = 0;
    for (; i + 1 < count; i += BPLUS_LOOP_UNROLL_FACTOR) {
        ((int*)ptr)[i] = ((int*)ptr)[i] * 2;
        ((int*)ptr)[i + 1] = ((int*)ptr)[i + 1] * 2;
    }
    for (; i < count; i++) {
        ((int*)ptr)[i] = ((int*)ptr)[i] * 2;
    }
}
";
    }

    public PipelineResult OptimizeForTarget(string cpuMicroarch)
    {
        int numStages = 3;
        int ii = 4;

        if (cpuMicroarch.Contains("skylake") || cpuMicroarch.Contains("icelake"))
        {
            numStages = 4;
            ii = 3;
        }

        return GeneratePipeline(ii, numStages);
    }
}
