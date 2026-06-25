Texture2D<float4> g_InputColor : register(t0);
RWTexture2D<float> g_LumaOutput : register(u0);

cbuffer LumaConstants : register(b0) {
    float2 inputSize;
    float2 inputRcpSize;
    int    mipLevel;
};

float Luma(float3 c) {
    return dot(c, float3(0.299, 0.587, 0.114));
}

SamplerState linearClamp : register(s0);

[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID) {
    uint w, h;
    g_LumaOutput.GetDimensions(w, h);
    int2 ipos = int2(tid.xy);
    if (ipos.x >= int(w) || ipos.y >= int(h)) return;

    float2 uv = (float2(tid.xy) + 0.5) * inputRcpSize;

    float3 c = g_InputColor.SampleLevel(linearClamp, uv, 0.0).rgb;
    g_LumaOutput[ipos] = Luma(c);
}
