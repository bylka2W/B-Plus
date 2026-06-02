namespace BPlus.Shader.Upscaling;

public class ImageSamplingPrimitives
{
    public static string BilinearSample(string tex, string uv, string lod)
    {
        return $@"
float2 sUV = {uv} * float2(texWidth, texHeight);
float2 f = frac(sUV);
int2 i = int2(sUV) - int2(1, 1);

// 4 samples for bilinear
float4 s00 = tex.sample_lod(i + int2(0, 0), {lod});
float4 s10 = tex.sample_lod(i + int2(1, 0), {lod});
float4 s01 = tex.sample_lod(i + int2(0, 1), {lod});
float4 s11 = tex.sample_lod(i + int2(1, 1), {lod});

// Bilinear blend
float2 t = f;
return mix(mix(s00, s10, t.x), mix(s01, s11, t.x), t.y);
";
    }

    public static string LanczosSample(string tex, string uv, int taps = 8)
    {
        var samples = new List<string>();
        for (int j = -taps / 2; j < taps / 2; j++)
        {
            for (int i = -taps / 2; i < taps / 2; i++)
            {
                samples.Add($"tex.sample_linear_clamp({uv} + float2({i}, {j}) * tex.texel_size())");
            }
        }

        return $@"
// Lanczos-{taps} upsampling
float2 sUV = {uv} * tex.size;
float2 f = fract(sUV);
float2 f2 = f * f;
float2 f3 = f2 * f;

// Lanczos window (a={taps / 2})
float L(int x, float a) {{
    if (x == 0) return 1.0;
    float v = x * 3.14159265 / a;
    return a * sin(v) * sin(v / a) / (v * v);
}}

// 8x8 taps
float2 offset = (f - 0.5) * tex.texel_size();
float4 result = float4(0.0);
float totalW = 0.0;
for (int dy = -4; dy < 4; dy++) {{
    for (int dx = -4; dx < 4; dx++) {{
        float2 p = float2(dx, dy);
        float w = L(dx, {taps / 2}) * L(dy, {taps / 2});
        result += tex.sample_linear_clamp({uv} + (p + f) * tex.texel_size()) * w;
        totalW += w;
    }}
}}
return result / totalW;
";
    }

    public static string BicubicSample(string tex, string uv)
    {
        return $@"
// Catmull-Rom bicubic upsampling
float2 sUV = {uv} * tex.size;
float2 f = frac(sUV);
float2 f2 = f * f;
float2 f3 = f2 * f;

// Catmull-Rom coefficients
float2 w0 = -0.5 + f + f2 * 0.5 - f3 * 0.5;
float2 w1 = 1.0 - 2.5 * f2 + 1.5 * f3;
float2 w2 = 0.5 - f + 2.0 * f2 - 1.5 * f3;
float2 w3 = f3 * 0.5;

float2 g0 = w0 + w1;
float2 g1 = w2 + w3;
float2 h0 = -1.0 + w1 + w2;
float2 h1 = w2 - w3;
float2 h2 = w0 - w1 + w3;
float2 h3 = w1 - w3;

int2 base = int2(sUV) - 1;
float2 f00 = float2(g0.x * g0.y, g0.x * g1.y);
float2 f01 = float2(h0.x, h0.y + h1.y);
float2 f10 = float2(h2.x, g1.x * h2.y + h3.y);

int2 i00 = base;
int2 i10 = base + int2(1, 0);
int2 i01 = base + int2(0, 1);
int2 i11 = base + int2(1, 1);

// 4x4 neighborhood
float4 s00 = tex[i00];
float4 s10 = tex[i10];
float4 s20 = tex[base + int2(2, 0)];
float4 s30 = tex[base + int2(3, 0)];
float4 s01 = tex[i01];
float4 s11 = tex[i11];
float4 s21 = tex[base + int2(2, 1)];
float4 s31 = tex[base + int2(3, 1)];
float4 s02 = tex[base + int2(0, 2)];
float4 s12 = tex[base + int2(1, 2)];
float4 s22 = tex[base + int2(2, 2)];
float4 s32 = tex[base + int2(3, 2)];
float4 s03 = tex[base + int2(0, 3)];
float4 s13 = tex[base + int2(1, 3)];
float4 s23 = tex[base + int2(2, 3)];
float4 s33 = tex[base + int2(3, 3)];

// Bicubic blend
float4 c0 = mix(s01, s11, f.x);
float4 c1 = mix(s21, s31, f.x);
float4 c2 = mix(s02, s12, f.x);
float4 c3 = mix(s22, s32, f.x);
float4 c4 = mix(s03, s13, f.x);
float4 c5 = mix(s23, s33, f.x);
return mix(mix(c0, c1, f.y), mix(c2, c3, f.y), f.x);
";
    }

    public static string CatmullRomSample(string tex, string uv)
    {
        return $@"
// 16-tap Catmull-Rom for high-quality upscaling
float2 sUV = {uv} * tex.size;
float2 f = fract(sUV);
float4 result = float4(0.0);

for (int y = -2; y <= 3; y++) {{
    for (int x = -2; x <= 3; x++) {{
        float2 p = float2(x, y);
        // Catmull-Rom weight
        float wx = (x == -2 ? 0.0 : x == -1 ? -0.5 : x == 0 ? 1.0 : x == 1 ? 0.5 : 0.0);
        float wy = (y == -2 ? 0.0 : y == -1 ? -0.5 : y == 0 ? 1.0 : y == 1 ? 0.5 : 0.0);
        float w = wx * wy;
        result += tex.sample_linear_clamp({uv} + p * tex.texel_size()) * w;
    }}
}}
return result;
";
    }

    public static string BarycentricSample(string tex, string uv)
    {
        return $@"
// Barycentric sampling for edge-preserving upscale
float2 p = {uv};
float2 d00 = dFdx(p);
float2 d01 = dFdy(p);

// Triangle barycentrics
float2 uv0 = float2(0.0, 0.0);
float2 uv1 = float2(1.0, 0.0);
float2 uv2 = float2(0.0, 1.0);

float2 v0 = uv1 - uv0;
float2 v1 = uv2 - uv0;
float2 v2 = p - uv0;

float d = v0.x * v1.y - v1.x * v0.y;
float a = (v2.x * v1.y - v1.x * v2.y) / d;
float b = (v0.x * v2.y - v2.x * v0.y) / d;
float c = 1.0 - a - b;

// Sample 3 corners and blend
float4 s0 = tex.sample_linear(uv0);
float4 s1 = tex.sample_linear(uv1);
float4 s2 = tex.sample_linear(uv2);
return a * s0 + b * s1 + c * s2;
";
    }

    public static string CAS_Sharpening(string color, float sharpness)
    {
        return $@"
// CAS (Contrast Adaptive Sharpening)
// Input: 3x3 neighborhood
// Output: sharpened color
float sharp = {sharpness};  // 0.0 = off, 1.0 = max

float3 c = {color};
float3 s0 = tex[uv + int2(-1, -1)];
float3 s1 = tex[uv + int2( 0, -1)];
float3 s2 = tex[uv + int2( 1, -1)];
float3 s3 = tex[uv + int2(-1,  0)];
// float4 s4 = c;  // center
float3 s5 = tex[uv + int2( 1,  0)];
float3 s6 = tex[uv + int2(-1,  1)];
float3 s7 = tex[uv + int2( 0,  1)];
float3 s8 = tex[uv + int2( 1,  1)];

// Soft min/max for contrast
float3 max4 = max(max(max(s0, s1), max(s2, s3)), max(s5, max(s6, max(s7, s8))));
float3 min4 = min(min(min(s0, s1), min(s2, s3)), min(s5, min(s6, min(s7, s8))));

// Amplitude
float3 amp = clamp(abs(max4 - min4) / max(max4, 1e-5), 0.0, 1.0);
float3 ampg = max(amp.r, max(amp.g, amp.b));

// CAS blend
float3 blur = (s0 + s1 + s2 + s3 + s5 + s6 + s7 + s8) / 8.0;
float3 cas = c + (c - blur) * ampg * sharp;
return clamp(cas, 0.0, 1.0);
";
    }
}

public class AsyncComputeQueue
{
    public bool EnableAsyncCompute { get; set; }
    public int CopyQueueIndex { get; set; } = 1;
    public int ComputeQueueIndex { get; set; } = 0;

    public string GenerateBarrier()
    {
        return @"
// Async compute barrier
if (EnableAsyncCompute) {
    // Wait for copy queue to finish
    // vkCmdWaitEvents(cmd, copyFinished, 1, &copyEvent, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, 0, nullptr, 0, nullptr, 0);
    // Or use vkDeviceWaitIdle for queue sync
}
";
    }

    public string GenerateOverlap(string src, string dst)
    {
        return $@"
// Overlap src->dst copy with compute
// Copy queue: src -> staging
// Compute queue: staging -> dst (async)
";
    }
}

public class WaveOps
{
    public bool IsAMD { get; set; }
    public bool IsNVIDIA { get; set; }

    public string WaveShift(string v, int amount)
    {
        if (IsAMD) return $"__ds_bpermute(0, {v})"; // RDNA wave shift
        if (IsNVIDIA) return $"__shfl_up_sync(0xffffffff, {v}, {amount})";
        return v;
    }

    public string WaveBallot(string predicate)
    {
        if (IsNVIDIA) return $"__ballot_sync(0xffffffff, {predicate})";
        return $"WaveActiveBitOr({predicate})";
    }

    public string WaveReduceSum(string v)
    {
        if (IsNVIDIA) return $"__reduce_add_sync(0xffffffff, {v})";
        return $"WaveSum({v})";
    }

    public string WavePrefixSum(string v)
    {
        if (IsNVIDIA) return $"__scan_add_sync(0xffffffff, {v})";
        return $"WavePrefixSum({v})";
    }

    public string Shuffle(string v, int srcLane)
    {
        if (IsNVIDIA) return $"__shfl_sync(0xffffffff, {v}, {srcLane})";
        return v;
    }
}

public class WMMAGenerator
{
    public bool SupportsWMMA { get; set; }
    public int MatrixBlockSize { get; set; } = 16;

    public string GenerateMma(string aId, string bId, string dId)
    {
        if (SupportsWMMA)
        {
            return @"
// Cooperative matrix MMA
fragment #require __fragCoord.x < 16 && __fragCoord.y < 16;
{
    // AMD WMMA or NVIDIA wmma
    wmma::load_matrix_sync(A, aId, wmma::RowMajor);
    wmma::load_matrix_sync(B, bId, wmma::RowMajor);
    wmma::mma_sync(D, A, B, D);
    wmma::store_matrix_sync(dId, D, wmma::RowMajor);
}
";
        }

        return @"
// Fallback to tiled multiplication
const int TILE = 16;
for (int m = 0; m < TILE; m += 16) {
    for (int n = 0; n < TILE; n += 16) {
        for (int k = 0; k < TILE; k += 16) {
            dId[m + tid.x][n + tid.y] += aId[m + tid.x][k] * bId[k][n + tid.y];
        }
    }
}
";
    }
}