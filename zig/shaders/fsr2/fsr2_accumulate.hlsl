Texture2D<float4> g_InputColor : register(t0);
Texture2D<float> g_Depth : register(t1);
Texture2D<float2> g_MotionVectors : register(t2);
Texture2D<float4> g_HistoryColor : register(t3);
Texture2D<float> g_HistoryDepth : register(t4);
Texture2D<uint> g_HistoryLock : register(t5);

RWTexture2D<float4> g_OutputColor : register(u0);
RWTexture2D<float4> g_OutHistoryColor : register(u1);
RWTexture2D<float> g_OutHistoryDepth : register(u2);
RWTexture2D<uint> g_OutHistoryLock : register(u3);

cbuffer FSR2Constants : register(b0) {
    float4 jitterOffset;
    float2 inputSize;
    float2 outputSize;
    float2 inputRcpSize;
    float2 outputRcpSize;
    float4 viewportJitter;
    float4 projectionParams;
    float2 motionScale;
    float  depthScale;
    uint   frameIndex;
    float  lockThreshold;
    float  lockBias;
    float  newPixelWeight;
    float  depthClipEpsilon;
    float  depthClipTolerance;
};

SamplerState linearClamp : register(s0);
SamplerState pointClamp : register(s1);
static const float FLT_EPS = 1.192092896e-07;

float3 RGBToYCoCg(float3 c) {
    float Y  = dot(c, float3(0.25, 0.5, 0.25));
    float Co = dot(c, float3(0.5, 0.0, -0.5)) + 0.5;
    float Cg = dot(c, float3(-0.25, 0.5, -0.25)) + 0.5;
    return float3(Y, Co, Cg);
}

float3 YCoCgToRGB(float3 c) {
    float Y  = c.x;
    float Co = c.y - 0.5;
    float Cg = c.z - 0.5;
    return float3(Y + Co - Cg, Y + Cg, Y - Co - Cg);
}

float Luma(float3 c) {
    return dot(c, float3(0.299, 0.587, 0.114));
}

float GetMinClipBox(float3 center, float3 history, float luma_center, float luma_history, float depth, float new_pixel) {
    float new_w = newPixelWeight;
    float lock_w = 1.0 - new_w;
    float clip_val = depthClipEpsilon + abs(depth) * 0.01;
    clip_val = max(clip_val, depthClipEpsilon);
    float Ydiff = abs(luma_history - luma_center);
    float h = luma_history;
    float c = luma_center;
    float diff_scale = 1.0 + abs(c) * 0.1;
    clip_val = max(clip_val, Ydiff * depthClipTolerance * diff_scale);
    return clip_val;
}

float4 ClipAABB(float3 box_center, float3 box_half, float3 color) {
    float3 r = color - box_center;
    float3 half_inv = 1.0 / max(abs(box_half), FLT_EPS.xxx);
    float3 t = r * half_inv;
    float max_t = max(max(t.x, t.y), t.z);
    if (max_t > 1.0) {
        return float4(box_center + r / max_t, max_t);
    }
    return float4(color, max_t);
}

[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID) {
    uint outW, outH;
    g_OutputColor.GetDimensions(outW, outH);
    int2 ipos = int2(tid.xy);
    if (ipos.x >= int(outW) || ipos.y >= int(outH)) return;

    float2 outputPixel = float2(tid.xy) + 0.5;
    float2 outputUV = outputPixel * outputRcpSize;
    float2 inputUV = outputUV + jitterOffset.xy;

    float depth = g_Depth.SampleLevel(linearClamp, inputUV, 0.0).r;
    float2 motion = g_MotionVectors.SampleLevel(linearClamp, inputUV, 0.0).xy * motionScale;

    float2 historyUV = outputUV + motion;
    float4 historyColor = g_HistoryColor.SampleLevel(linearClamp, historyUV, 0.0);
    float historyDepth = g_HistoryDepth.SampleLevel(linearClamp, historyUV, 0.0).r;
    uint2 lockSize;
    g_HistoryLock.GetDimensions(lockSize.x, lockSize.y);
    int2 lockPos = int2(historyUV * float2(lockSize));
    uint historyLock = g_HistoryLock.Load(int3(lockPos, 0)).r;

    float4 inputColor = g_InputColor.SampleLevel(linearClamp, inputUV, 0.0);

    float3 inputYCoCg = RGBToYCoCg(inputColor.rgb);
    float3 historyYCoCg = RGBToYCoCg(historyColor.rgb);
    float  lumaInput  = Luma(inputColor.rgb);
    float  lumaHistory = Luma(historyColor.rgb);

    float2 uvOff = inputRcpSize;
    float3 cTL = RGBToYCoCg(g_InputColor.SampleLevel(linearClamp, inputUV + float2(-uvOff.x, -uvOff.y), 0.0).rgb);
    float3 cTR = RGBToYCoCg(g_InputColor.SampleLevel(linearClamp, inputUV + float2( uvOff.x, -uvOff.y), 0.0).rgb);
    float3 cBL = RGBToYCoCg(g_InputColor.SampleLevel(linearClamp, inputUV + float2(-uvOff.x,  uvOff.y), 0.0).rgb);
    float3 cBR = RGBToYCoCg(g_InputColor.SampleLevel(linearClamp, inputUV + float2( uvOff.x,  uvOff.y), 0.0).rgb);

    float3 boxCenter = (cTL + cTR + cBL + cBR) * 0.25;
    float3 boxHalf = 0.0;
    boxHalf = max(boxHalf, abs(inputYCoCg - cTL));
    boxHalf = max(boxHalf, abs(inputYCoCg - cTR));
    boxHalf = max(boxHalf, abs(inputYCoCg - cBL));
    boxHalf = max(boxHalf, abs(inputYCoCg - cBR));
    boxHalf = max(boxHalf, abs(cTL - cTR));
    boxHalf = max(boxHalf, abs(cTL - cBL));
    boxHalf = max(boxHalf, abs(cTR - cBR));
    boxHalf = max(boxHalf, abs(cBL - cBR));

    float3 boxMin = boxCenter - boxHalf;
    float3 boxMax = boxCenter + boxHalf;
    float3 clampedHistory = clamp(historyYCoCg, boxMin, boxMax);

    float depthDiff = abs(depth - historyDepth);
    float depthClip = depthClipEpsilon + abs(depth) * 0.05;
    float depthWeight = saturate(depthDiff / depthClip);
    float blendWeight = saturate(1.0 - depthWeight);

    float newPixelDiff = length(clampedHistory - inputYCoCg);
    float newPixel = saturate((newPixelDiff - lockBias) / max(0.001, lockThreshold - lockBias));

    float finalBlend = lerp(newPixelWeight, 0.95, blendWeight);
    finalBlend = lerp(finalBlend, 1.0, newPixel);

    if (historyLock > 0 && depthWeight < 0.1) {
        finalBlend = max(finalBlend, 0.98);
    }

    float3 resultYCoCg = lerp(inputYCoCg, clampedHistory, finalBlend);
    float4 result = float4(YCoCgToRGB(resultYCoCg), 1.0);
    result.rgb = max(0.0, result.rgb);

    g_OutputColor[ipos] = result;
    g_OutHistoryColor[ipos] = result;
    g_OutHistoryDepth[ipos] = depth;
    uint newLock = (depthWeight < 0.1 && newPixel < 0.5) ? 1u : 0u;
    g_OutHistoryLock[ipos] = newLock;
}
