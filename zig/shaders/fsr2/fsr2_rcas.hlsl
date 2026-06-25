Texture2D<float4> g_InputColor : register(t0);
RWTexture2D<float4> g_OutputColor : register(u0);

cbuffer RCASConstants : register(b0) {
    float  sharpness;
    uint   outputWidth;
    uint   outputHeight;
};

float4 RCASPass(float4 col[4][4], float sharp) {
    float4 pix = col[2][2];
    float4 sum = 0.0;
    float4 wsum = 0.0;
    float sharpVal = sharp * 0.25;

    [unroll] for (int dy = 0; dy < 4; ++dy) {
        [unroll] for (int dx = 0; dx < 4; ++dx) {
            float4 tap = col[dy][dx];
            float2 delta = float2(dx - 2, dy - 2);
            float dist2 = dot(delta, delta);
            float w = exp(-dist2 * sharpVal);
            sum += tap * w;
            wsum += w;
        }
    }

    return sum / max(wsum, 1e-6);
}

SamplerState linearClamp : register(s0);

[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID) {
    uint outW, outH;
    g_OutputColor.GetDimensions(outW, outH);
    int2 ipos = int2(tid.xy);
    if (ipos.x >= int(outW) || ipos.y >= int(outH)) return;

    float2 texelSize = 1.0 / float2(outW, outH);
    float2 uv = (float2(tid.xy) + 0.5) * texelSize;

    float4 col[4][4];
    [unroll] for (int dy = -1; dy <= 2; ++dy) {
        [unroll] for (int dx = -1; dx <= 2; ++dx) {
            float2 tapUV = saturate(uv + float2(dx, dy) * texelSize);
            col[dy + 1][dx + 1] = g_InputColor.SampleLevel(linearClamp, tapUV, 0.0);
        }
    }

    g_OutputColor[ipos] = RCASPass(col, sharpness);
}
