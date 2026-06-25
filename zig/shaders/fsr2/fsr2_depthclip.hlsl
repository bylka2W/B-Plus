Texture2D<float> g_Depth : register(t0);
Texture2D<float> g_HistoryDepth : register(t1);
RWTexture2D<float> g_DepthClipWeight : register(u0);
RWTexture2D<uint> g_DisocclusionMask : register(u1);

cbuffer DepthClipConstants : register(b0) {
    float2 inputSize;
    float2 inputRcpSize;
    float  depthClipEpsilon;
    float  depthClipTolerance;
};

SamplerState pointClamp : register(s0);

[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID) {
    uint w, h;
    g_Depth.GetDimensions(w, h);
    int2 ipos = int2(tid.xy);
    if (ipos.x >= int(w) || ipos.y >= int(h)) return;

    float uvx = (float(tid.x) + 0.5) * inputRcpSize.x;
    float uvy = (float(tid.y) + 0.5) * inputRcpSize.y;
    float2 uv = float2(uvx, uvy);

    float depth = g_Depth.SampleLevel(pointClamp, uv, 0.0).r;
    float4 histDepths;
    histDepths.x = g_HistoryDepth.SampleLevel(pointClamp, uv, 0.0, int2(0, 0)).r;
    histDepths.y = g_HistoryDepth.SampleLevel(pointClamp, uv, 0.0, int2(1, 0)).r;
    histDepths.z = g_HistoryDepth.SampleLevel(pointClamp, uv, 0.0, int2(0, 1)).r;
    histDepths.w = g_HistoryDepth.SampleLevel(pointClamp, uv, 0.0, int2(1, 1)).r;

    float minHistoryDepth = min(min(histDepths.x, histDepths.y), min(histDepths.z, histDepths.w));
    float maxHistoryDepth = max(max(histDepths.x, histDepths.y), max(histDepths.z, histDepths.w));
    float depthRange = max(maxHistoryDepth - minHistoryDepth, depthClipEpsilon);

    float depthClip = depthClipEpsilon + abs(depth) * 0.05;
    float depthDiff = abs(depth - minHistoryDepth);
    float clipWeight = saturate(depthDiff / depthClip);

    float depthDiffMax = abs(depth - maxHistoryDepth);
    float clipWeightMax = saturate(depthDiffMax / depthClip);
    clipWeight = max(clipWeight, clipWeightMax);

    uint isDisoccluded = (clipWeight > 0.9) ? 1u : 0u;

    g_DepthClipWeight[ipos] = clipWeight;
    g_DisocclusionMask[ipos] = isDisoccluded;
}
