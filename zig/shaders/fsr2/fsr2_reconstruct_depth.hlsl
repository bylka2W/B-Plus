Texture2D<float> g_DepthInput : register(t0);
RWTexture2D<float> g_DepthOutput : register(u0);

cbuffer DepthConstants : register(b0) {
    float2 inputSize;
    float2 inputRcpSize;
    int    mipLevel;
};

SamplerState pointClamp : register(s0);

float Reduce4(float a, float b, float c, float d) {
    float mn = min(min(a, b), min(c, d));
    float mx = max(max(a, b), max(c, d));
    return (a + b + c + d) * 0.25;
}

[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID) {
    uint w, h;
    g_DepthOutput.GetDimensions(w, h);
    int2 ipos = int2(tid.xy);
    if (ipos.x >= int(w) || ipos.y >= int(h)) return;

    int2 srcPos = ipos * 2;
    float d0 = g_DepthInput.Load(int3(srcPos.x,     srcPos.y,     0)).r;
    float d1 = g_DepthInput.Load(int3(srcPos.x + 1, srcPos.y,     0)).r;
    float d2 = g_DepthInput.Load(int3(srcPos.x,     srcPos.y + 1, 0)).r;
    float d3 = g_DepthInput.Load(int3(srcPos.x + 1, srcPos.y + 1, 0)).r;

    g_DepthOutput[ipos] = Reduce4(d0, d1, d2, d3);
}
