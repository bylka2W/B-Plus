Texture2D<float> g_DepthClipWeight : register(t0);
Texture2D<float> g_LumaInput : register(t1);
Texture2D<float> g_LumaHistory : register(t2);
RWTexture2D<uint> g_LockOutput : register(u0);

cbuffer LockConstants : register(b0) {
    float2 inputSize;
    float  lockThreshold;
    float  lockBias;
    float  temporalLumaStability;
};

SamplerState pointClamp : register(s0);

[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID) {
    uint w, h;
    g_LockOutput.GetDimensions(w, h);
    int2 ipos = int2(tid.xy);
    if (ipos.x >= int(w) || ipos.y >= int(h)) return;

    float uvx = (float(tid.x) + 0.5) / float(w);
    float uvy = (float(tid.y) + 0.5) / float(h);
    float2 uv = float2(uvx, uvy);

    float depthClipVal = g_DepthClipWeight.SampleLevel(pointClamp, uv, 0.0).r;
    float lumaInput  = g_LumaInput.SampleLevel(pointClamp, uv, 0.0).r;
    float lumaHistory = g_LumaHistory.SampleLevel(pointClamp, uv, 0.0).r;

    float lumaDiff = abs(lumaInput - lumaHistory);
    float lumaStability = saturate(1.0 - lumaDiff * temporalLumaStability);
    float lockedness = saturate(1.0 - depthClipVal * 2.0) * lumaStability;
    uint isLocked = (lockedness > lockThreshold) ? 1u : 0u;

    g_LockOutput[ipos] = isLocked;
}
