Texture2D<float2> g_MotionVectors : register(t0);
RWTexture2D<float2> g_DilatedMotion : register(u0);

cbuffer DilateConstants : register(b0) {
    float2 inputSize;
    float2 inputRcpSize;
};

SamplerState pointClamp : register(s0);

float2 MaxMag(float2 a, float2 b) {
    return (dot(a, a) >= dot(b, b)) ? a : b;
}

[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID) {
    uint w, h;
    g_DilatedMotion.GetDimensions(w, h);
    int2 ipos = int2(tid.xy);
    if (ipos.x >= int(w) || ipos.y >= int(h)) return;

    float2 uv = (float2(tid.xy) + 0.5) * inputRcpSize;

    float2 center = g_MotionVectors.SampleLevel(pointClamp, uv, 0.0);
    float2 mx = center;
    mx = MaxMag(mx, g_MotionVectors.SampleLevel(pointClamp, uv, 0.0, int2(-1,  0)));
    mx = MaxMag(mx, g_MotionVectors.SampleLevel(pointClamp, uv, 0.0, int2( 1,  0)));
    mx = MaxMag(mx, g_MotionVectors.SampleLevel(pointClamp, uv, 0.0, int2( 0, -1)));
    mx = MaxMag(mx, g_MotionVectors.SampleLevel(pointClamp, uv, 0.0, int2( 0,  1)));
    mx = MaxMag(mx, g_MotionVectors.SampleLevel(pointClamp, uv, 0.0, int2(-1, -1)));
    mx = MaxMag(mx, g_MotionVectors.SampleLevel(pointClamp, uv, 0.0, int2( 1, -1)));
    mx = MaxMag(mx, g_MotionVectors.SampleLevel(pointClamp, uv, 0.0, int2(-1,  1)));
    mx = MaxMag(mx, g_MotionVectors.SampleLevel(pointClamp, uv, 0.0, int2( 1,  1)));

    g_DilatedMotion[ipos] = mx;
}
