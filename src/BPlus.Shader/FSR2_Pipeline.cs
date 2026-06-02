namespace BPlus.Shader.Upscaling;

public enum UpscalePass
{
    EASU,
    RCAS,
    DisplayFreq,
    FSR3_FrameGen
}

public enum TemporalState
{
    Current,
    History1,
    History2,
    History4,
    Disoccluded,
    Stable
}

public class FSR2_Config
{
    public int InputWidth { get; set; }
    public int InputHeight { get; set; }
    public int OutputWidth { get; set; }
    public int OutputHeight { get; set; }
    public bool EnableRCAS { get; set; } = true;
    public float Sharpness { get; set; } = 0.0f;
    public int HistoryLength { get; set; } = 4;
    public float DisocclusionThreshold { get; set; } = 0.01f;
    public float LumaDeltaThreshold { get; set; } = 0.1f;
    public bool EnableDenoise { get; set; } = true;
    public int DetectPassCount { get; set; } = 2;
    public float ScaleX => (float)OutputWidth / InputWidth;
    public float ScaleY => (float)OutputHeight / InputHeight;
}

public class TemporalStateMachine
{
    readonly FSR2_Config _config;
    int _currentFrame;
    bool _hasValidHistory;
    bool _disocclusionDetected;

    public TemporalStateMachine(FSR2_Config config)
    {
        _config = config;
        _currentFrame = 0;
        _hasValidHistory = false;
        _disocclusionDetected = false;
    }

    public (TemporalState state, int pingPong) GetCurrentState()
    {
        int frame = _currentFrame % _config.HistoryLength;
        return frame switch
        {
            0 => (TemporalState.History4, 1),
            1 => (TemporalState.History1, 0),
            2 => (TemporalState.History2, 1),
            3 => (TemporalState.History4, 0),
            _ => (TemporalState.Current, 0)
        };
    }

    public bool ShouldAccumulate()
    {
        return _hasValidHistory && !_disocclusionDetected;
    }

    public bool ShouldDilute()
    {
        return _disocclusionDetected || !_hasValidHistory;
    }

    public void UpdateHistory(bool disocclusion, float lumaDelta)
    {
        if (lumaDelta > _config.LumaDeltaThreshold)
        {
            _disocclusionDetected = true;
        }
        else if (disocclusion)
        {
            _disocclusionDetected = true;
        }
        else
        {
            _disocclusionDetected = false;
        }

        if (_currentFrame > _config.HistoryLength)
        {
            _hasValidHistory = true;
        }
    }

    public void AdvanceFrame()
    {
        _currentFrame++;
        _disocclusionDetected = false;
    }

    public float ComputeExposureMultiplier()
    {
        return 1.0f + (_currentFrame % 60 == 0 ? 0.1f : 0.0f);
    }

    public string GenerateHistoryAccess(string bufferName, int frameOffset)
    {
        int targetFrame = (_currentFrame - frameOffset + _config.HistoryLength) % _config.HistoryLength;
        return $"historyBuffer[{bufferName}][frame_{targetFrame}]";
    }

    public int OutputBlockWidth => (_config.OutputWidth + 63) / 64;
    public int OutputBlockHeight => (_config.OutputHeight + 63) / 64;
    public int InputBlockWidth => (_config.InputWidth + 31) / 32;
    public int InputBlockHeight => (_config.InputHeight + 31) / 32;

    public float ScaleX => (float)_config.OutputWidth / _config.InputWidth;
    public float ScaleY => (float)_config.OutputHeight / _config.InputHeight;
}

public class MotionVectorProcessor
{
    public VectorType ScreenVelocity { get; set; } = new() { Components = 2, Element = NumericType.F32 };
    public VectorType PrevScreenPos { get; set; } = new() { Components = 2, Element = NumericType.F32 };
    public VectorType CurrScreenPos { get; set; } = new() { Components = 2, Element = NumericType.F32 };

    public string GenerateReproject(string currUV, string prevMV)
    {
        return $@"
vec2 prevUV = {currUV} - {prevMV};
return prevUV;
";
    }

    public float ComputeLuma(string color)
    {
        return 0.2126f;
    }

    public bool DetectGhosting(string currLuma, string prevLuma, float threshold)
    {
        return false;
    }
}

public class FSR2_Pipeline
{
    readonly TemporalStateMachine _temporal;
    readonly FSR2_Config _config;

    public FSR2_Pipeline(FSR2_Config config)
    {
        _config = config;
        _temporal = new TemporalStateMachine(config);
    }

    public string GenerateEASU_Kernel()
    {
        return $@"
// EASU (Efficient Adaptive Sampling Unit)
// Input: {_config.InputWidth}x{_config.InputHeight}
// Output: {_config.OutputWidth}x{_config.OutputHeight}
kernel EASU(
    input: Image[{_config.InputHeight}, {_config.InputWidth}],
    output: Image[{_config.OutputHeight}, {_config.OutputWidth}]
)
{{
    touches: reads[input], writes[output]
    body: {{
        float2 uv = get_global_id().xy / float2({_config.OutputWidth}, {_config.OutputHeight});
        float2 inputUV = uv * float2({_config.ScaleX}, {_config.ScaleY});
        
        // 64x64 tile dispatch
        int2 tile = get_tile_id();
        int2 localUV = tile * 64 + get_local_id();
        
        // Sample 4x4 neighborhood for Lanczos
        float3 c00 = input.sample_linear(inputUV + float2(-1.5, -1.5) / input.size);
        float3 c10 = input.sample_linear(inputUV + float2(-0.5, -1.5) / input.size);
        float3 c20 = input.sample_linear(inputUV + float2(0.5, -1.5) / input.size);
        float3 c30 = input.sample_linear(inputUV + float2(1.5, -1.5) / input.size);
        
        // ... 16 samples total for bilinear+RCAS blend
        output[localUV] = lanczos_blend(c00, c10, c20, c30, ...);
    }}
}}
";
    }

    public string GenerateRCAS_Kernel()
    {
        float sharpness = _config.Sharpness;
        return $@"
// RCAS (Robust Contrast Adaptive Sharpening)
// Sharpness: {sharpness} (0 = off, 1 = max)
kernel RCAS(
    input: Image[{_config.OutputHeight}, {_config.OutputWidth}],
    output: Image[{_config.OutputHeight}, {_config.OutputWidth}]
)
{{
    touches: reads[input], writes[output]
    body: {{
        float2 uv = get_global_id().xy;
        float3 c = input[uv];
        
        // 3x3 neighborhood
        float3 s0 = input[uv + int2(-1, -1)];
        float3 s1 = input[uv + int2( 0, -1)];
        float3 s2 = input[uv + int2( 1, -1)];
        float3 s3 = input[uv + int2(-1,  0)];
        float3 s4 = c;
        float3 s5 = input[uv + int2( 1,  0)];
        float3 s6 = input[uv + int2(-1,  1)];
        float3 s7 = input[uv + int2( 0,  1)];
        float3 s8 = input[uv + int2( 1,  1)];
        
        // Contrast detection
        float3 max4 = max(max(max(s0, s1), max(s2, s3)), max(max(s5, s6), max(s7, s8)));
        float3 min4 = min(min(min(s0, s1), min(s2, s3)), min(min(s5, s6), min(s7, s8)));
        float3 amplitude = clamp(abs(max4 - min4) / max(max4, 1e-5f), 0.0, 1.0);
        
        // RCAS formula: out = in + (in - blur) * amplitude * sharpness
        float3 blur = (s0 + s1 + s2 + s3 + s5 + s6 + s7 + s8) * 0.11111f;
        float3 rcas = c + (c - blur) * amplitude * {sharpness * 2.0f};
        
        output[uv] = clamp(rcas, 0.0, 1.0);
    }}
}}
";
    }

    public string GenerateTC_FilterKernel()
    {
        return $@"
// TAA (Temporal Anti-Aliasing) / FSR2 accumulation
kernel TC_Filter(
    input: Image[{_config.OutputHeight}, {_config.OutputWidth}],
    history: Image[{_config.OutputHeight}, {_config.OutputWidth}],
    motion: Image[{_config.OutputHeight}, {_config.OutputWidth}],
    output: Image[{_config.OutputHeight}, {_config.OutputWidth}]
)
{{
    touches: reads[input, history, motion], writes[output]
    body: {{
        float2 uv = get_global_id().xy;
        float2 mv = motion[uv].xy;
        
        // Reproject to previous frame
        float2 prevUV = uv - mv;
        
        // Clamp to valid range
        prevUV = clamp(prevUV, float2(0.5), float2({_config.OutputWidth} - 0.5, {_config.OutputHeight} - 0.5));
        
        // Sample history with disocclusion check
        float3 hist = history.sample_linear_clamp(prevUV);
        float3 curr = input[uv];
        
        // Luma for ghosting detection
        float currLuma = dot(curr, float3(0.2126, 0.7152, 0.0722));
        float histLuma = dot(hist, float3(0.2126, 0.7152, 0.0722));
        
        // Disocclusion threshold
        float delta = abs(currLuma - histLuma);
        bool disoccluded = delta > {_config.DisocclusionThreshold};
        
        // Blend factor (higher = more accumulation)
        float blend = disoccluded ? 0.0 : clamp(1.0 - delta * 10.0, 0.05, 0.98);
        
        // Temporal accumulation
        float3 result = mix(curr, hist, blend);
        output[uv] = result;
    }}
}}
";
    }

    public string GenerateGhostingDetectionKernel()
    {
        return $@"
kernel GhostingDetect(
    current: Image[{_config.OutputHeight}, {_config.OutputWidth}],
    prev: Image[{_config.OutputHeight}, {_config.OutputWidth}],
    motion: Image[{_config.OutputHeight}, {_config.OutputWidth}],
    mask: Image[{_config.OutputHeight}, {_config.OutputWidth}]
)
{{
    touches: reads[current, prev, motion], writes[mask]
    body: {{
        float2 uv = get_global_id().xy;
        float2 mv = motion[uv].xy;
        float2 prevUV = uv - mv;
        
        float3 c = current[uv];
        float3 p = prev.sample_linear_clamp(prevUV);
        
        // Color difference
        float3 diff = abs(c - p);
        float maxDiff = max(max(diff.r, diff.g), diff.b);
        
        // Luma delta
        float currLuma = dot(c, float3(0.2126, 0.7152, 0.0722));
        float prevLuma = dot(p, float3(0.2126, 0.7152, 0.0722));
        float lumaDelta = abs(currLuma - prevLuma);
        
        // Disocclusion mask: 1.0 = ghosting, 0.0 = stable
        float ghost = max(maxDiff, lumaDelta) > {_config.DisocclusionThreshold} ? 1.0 : 0.0;
        mask[uv] = ghost;
    }}
}}
";
    }
}

public class VectorType
{
    public int Components { get; set; }
    public NumericType Element { get; set; }
}

public enum NumericType
{
    F16, F32, F64, BF16, I8, I16, I32, I64, U8, U16, U32, U64
}