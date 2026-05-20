namespace BPlusTranspiler.Shader.Upscaling;

using BPlusTranspiler.Shader.Types;

public enum PassOrder
{
    EASU,
    RCAS,
    TAA,
    Ghosting,
    FrameGen
}

public class PipelinePass
{
    public string Name { get; set; } = "";
    public string KernelBody { get; set; } = "";
    public PassOrder Order { get; set; }
    public List<string> Inputs { get; } = new();
    public List<string> Outputs { get; } = new();
    public Dictionary<string, string> Bindings { get; } = new();
    public bool IsAsync { get; set; }
    public int QueueIndex { get; set; } = 0;
}

public class RenderPipeline
{
    readonly List<PipelinePass> _passes = new();
    readonly Dictionary<string, HistoryBuffer> _historyBuffers = new();
    readonly Dictionary<string, string> _intermediates = new();

    public void AddPass(PipelinePass pass)
    {
        _passes.Add(pass);
    }

    public void AddHistoryBuffer(string name, HistoryBuffer buffer)
    {
        _historyBuffers[name] = buffer;
    }

    public void AddIntermediate(string name, string binding)
    {
        _intermediates[name] = binding;
    }

    public void ConfigureForFSR2(int inputW, int inputH, int outputW, int outputH, float sharpness = 0.0f)
    {
        var config = new FSR2_Config
        {
            InputWidth = inputW,
            InputHeight = inputH,
            OutputWidth = outputW,
            OutputHeight = outputH,
            Sharpness = sharpness,
            EnableRCAS = true
        };

        var pipeline = new FSR2_Pipeline(config);

        _passes.Clear();
        _historyBuffers.Clear();
        _intermediates.Clear();

        AddPass(new PipelinePass
        {
            Name = "EASU",
            Order = PassOrder.EASU,
            KernelBody = pipeline.GenerateEASU_Kernel(),
            Inputs = { "colorBuffer", "lumaBuffer" },
            Outputs = { "upscaledColor" }
        });

        AddPass(new PipelinePass
        {
            Name = "GhostingDetect",
            Order = PassOrder.Ghosting,
            KernelBody = pipeline.GenerateGhostingDetectionKernel(),
            Inputs = { "upscaledColor", "historyColor", "motionVectors" },
            Outputs = { "disocclusionMask" }
        });

        AddPass(new PipelinePass
        {
            Name = "TC_Filter",
            Order = PassOrder.TAA,
            KernelBody = pipeline.GenerateTC_FilterKernel(),
            Inputs = { "upscaledColor", "historyColor", "motionVectors", "disocclusionMask" },
            Outputs = { "temporalOutput" }
        });

        AddPass(new PipelinePass
        {
            Name = "RCAS",
            Order = PassOrder.RCAS,
            KernelBody = pipeline.GenerateRCAS_Kernel(),
            Inputs = { "temporalOutput" },
            Outputs = { "finalOutput" },
            Bindings = { { "sharpness", sharpness.ToString() } }
        });

        AddHistoryBuffer("colorHistory", new HistoryBuffer("colorHistory", 4) { PingPongIndex = 0 });
        AddHistoryBuffer("motionHistory", new HistoryBuffer("motionHistory", 2) { PingPongIndex = 1 });
    }

    public void ConfigureForFSR3_FrameGen(int w, int h)
    {
        AddPass(new PipelinePass
        {
            Name = "Interpolate",
            Order = PassOrder.FrameGen,
            IsAsync = true,
            QueueIndex = 1,
            KernelBody = GenerateFrameGenKernel(),
            Inputs = { "prevFrame", "currFrame", "motionVectors" },
            Outputs = { "interpolatedFrame" }
        });
    }

    string GenerateFrameGenKernel()
    {
        return @"
kernel FrameGen(
    prev: Image[h, w],
    curr: Image[h, w],
    motion: Image[h, w],
    output: Image[h, w]
)
{
    touches: reads[prev, curr, motion], writes[output]
    body: {
        float2 uv = get_global_id().xy;
        float2 mv = motion[uv].xy;

        // Optical flow based interpolation
        float2 prevUV = uv - mv * 0.5;
        float2 currUV = uv + mv * 0.5;

        // Bidirectional blending
        float3 p = prev.sample_linear_clamp(prevUV);
        float3 c = curr.sample_linear_clamp(currUV);
        
        // Motion vector confidence
        float confidence = length(mv) < 100.0 ? 1.0 : 0.0;
        
        // Blend
        float3 result = confidence > 0.5 ? mix(p, c, 0.5) : c;
        output[uv] = result;
    }
}
";
    }

    public string GenerateBakedPipeline()
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Render Pipeline (auto-generated)");
        sb.AppendLine("#version 450");
        sb.AppendLine("#extension GL_KHR_shader_subgroup_arithmetic : enable");
        sb.AppendLine();

        foreach (var kv in _intermediates)
        {
            sb.AppendLine($"layout(binding={kv.Value}) uniform sampler2D {kv.Key};");
        }

        foreach (var kv in _historyBuffers)
        {
            sb.AppendLine($"layout(binding={kv.Value}) uniform image2D {kv.Key};");
        }

        sb.AppendLine();
        sb.AppendLine("void main() {");
        sb.AppendLine("// Multi-pass pipeline");
        sb.AppendLine("// Pass order: EASU -> Ghosting -> TAA -> RCAS");

        foreach (var pass in _passes)
        {
            sb.AppendLine($"    // {pass.Name}");
            if (pass.IsAsync)
            {
                sb.AppendLine($"    // Async on queue {pass.QueueIndex}");
            }
        }

        sb.AppendLine("}");
        return sb.ToString();
    }

    public string GenerateDescriptorSetLayout()
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Descriptor set layout for pipeline");
        sb.AppendLine();

        int binding = 0;
        foreach (var kv in _intermediates)
        {
            sb.AppendLine($"[{binding}] {kv.Key}: sampler2D");
            binding++;
        }

        foreach (var kv in _historyBuffers)
        {
            sb.AppendLine($"[{binding}] {kv.Key}: image2D (ping-pong)");
            binding++;
        }

        sb.AppendLine();
        sb.AppendLine("// Queue synchronization");
        sb.AppendLine("// Compute queue: EASU -> TAA -> RCAS");
        sb.AppendLine("// Copy queue: history update (async)");

        return sb.ToString();
    }

    public string GenerateDispatchInfo()
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Dispatch configuration");
        sb.AppendLine();

        foreach (var pass in _passes)
        {
            var (dispatchW, dispatchH) = pass.Name switch
            {
                "EASU" => (64, 64),
                "GhostingDetect" => (16, 16),
                "TC_Filter" => (16, 16),
                "RCAS" => (8, 8),
                _ => (16, 16)
            };

            sb.AppendLine($"// {pass.Name}: {dispatchW}x{dispatchH} workgroups");
            sb.AppendLine($"vkCmdDispatch(cmd, {dispatchW}, {dispatchH}, 1);");
        }

        return sb.ToString();
    }

    public List<PassOrder> GetPassOrder() => _passes.Select(p => p.Order).ToList();
    public int TotalPassCount => _passes.Count;
    public bool HasAsyncCompute => _passes.Any(p => p.IsAsync);
}

public class FSR3_FrameGenerator
{
    public bool EnableFrameGeneration { get; set; } = true;
    public int MaxInterpolationFrames { get; set; } = 2;
    public float MotionVectorScale { get; set; } = 1.0f;
    public bool EnableDilution { get; set; } = true;

    public string GenerateFrameGenKernel(int w, int h)
    {
        return $@"
kernel FrameGen(
    prev: Image[{h}, {w}],
    curr: Image[{h}, {w}],
    motion: Image[{h}, {w}],
    output: Image[{h}, {w}]
)
{{
    touches: reads[prev, curr, motion], writes[output]
    body: {{
        float2 uv = get_global_id().xy / float2({w}, {h});
        float2 mv = motion[uv].xy * {MotionVectorScale};
        
        // Previous and current UV for blending
        float2 prevUV = uv - mv * 0.5;
        float2 currUV = uv + mv * 0.5;
        
        // Clamp to valid range
        prevUV = clamp(prevUV, float2(0.001), float2(0.999));
        currUV = clamp(currUV, float2(0.001), float2(0.999));
        
        // Sample both frames
        float3 p = prev.sample_linear(prevUV);
        float3 c = curr.sample_linear(currUV);
        
        // Motion confidence: low MV = high confidence
        float len = length(mv);
        float confidence = len < 50.0 ? 1.0 : max(0.0, 1.0 - len / 200.0);
        
        // Dilution on disocclusion
        float3 blended = mix(p, c, 0.5 + len * 0.01);
        
        // Output
        output[uv] = confidence > 0.3 ? blended : c;
    }}
}}
";
    }

    public string GenerateDilutionKernel()
    {
        return @"
kernel Dilution(
    input: Image,
    mask: Image,
    output: Image
)
{
    touches: reads[input, mask], writes[output]
    body: {
        float2 uv = get_global_id().xy;
        float mask = mask[uv].r;
        
        // If masked (disoccluded), use current frame only
        // Otherwise, accumulate
        float3 c = input[uv];
        output[uv] = mask > 0.5 ? c * 1.1 : c;
    }
}
";
    }
}