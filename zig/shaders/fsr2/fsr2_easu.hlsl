Texture2D<float4> g_InputColor : register(t0);
RWTexture2D<float4> g_OutputColor : register(u0);

cbuffer EASUConstants : register(b0) {
    float2 inputSize;
    float2 outputSize;
    float2 inputRcpSize;
    float2 outputRcpSize;
};

struct EASUSample {
    float3 a;
    float3 b;
    float3 c;
    float3 d;
    float3 e;
    float3 f;
    float3 g;
    float3 h;
    float3 i;
    float3 j;
    float3 k;
    float3 l;
    float3 m;
    float3 n;
    float3 o;
};

float3 RcpLuma(float3 c) {
    float l = dot(c, float3(0.299, 0.587, 0.114));
    return c / max(l, 1e-6);
}

float4 EASU(float2 p, EASUSample s) {
    float2 pp = floor(p);
    float2 fp = p - pp;
    float fx = fp.x;
    float fy = fp.y;

    float2 dir = 0.0;
    float len = 0.0;

    float w1 = (1.0 - fx) * (1.0 - fy);
    float dc = s.g.x - s.f.x;
    float cb = s.f.x - s.e.x;
    float len_xy = max(abs(dc), abs(cb));
    float rcp_len_xy = 1.0 / max(len_xy, 1e-6);
    float dir_diff = s.g.x - s.e.x;
    dir.x += dir_diff * w1;
    len_xy = saturate(abs(dir_diff) * rcp_len_xy);
    len_xy = len_xy * len_xy;
    len += len_xy * w1;

    float ec = s.j.x - s.f.x;
    float ca = s.f.x - s.b.x;
    len_xy = max(abs(ec), abs(ca));
    rcp_len_xy = 1.0 / max(len_xy, 1e-6);
    dir_diff = s.j.x - s.b.x;
    dir.y += dir_diff * w1;
    len_xy = saturate(abs(dir_diff) * rcp_len_xy);
    len_xy = len_xy * len_xy;
    len += len_xy * w1;

    float w2 = fx * (1.0 - fy);
    dc = s.h.x - s.g.x;
    cb = s.g.x - s.f.x;
    len_xy = max(abs(dc), abs(cb));
    rcp_len_xy = 1.0 / max(len_xy, 1e-6);
    dir_diff = s.h.x - s.f.x;
    dir.x += dir_diff * w2;
    len_xy = saturate(abs(dir_diff) * rcp_len_xy);
    len_xy = len_xy * len_xy;
    len += len_xy * w2;

    ec = s.k.x - s.g.x;
    ca = s.g.x - s.c.x;
    len_xy = max(abs(ec), abs(ca));
    rcp_len_xy = 1.0 / max(len_xy, 1e-6);
    dir_diff = s.k.x - s.c.x;
    dir.y += dir_diff * w2;
    len_xy = saturate(abs(dir_diff) * rcp_len_xy);
    len_xy = len_xy * len_xy;
    len += len_xy * w2;

    float w3 = (1.0 - fx) * fy;
    dc = s.k.x - s.j.x;
    cb = s.j.x - s.i.x;
    len_xy = max(abs(dc), abs(cb));
    rcp_len_xy = 1.0 / max(len_xy, 1e-6);
    dir_diff = s.k.x - s.i.x;
    dir.x += dir_diff * w3;
    len_xy = saturate(abs(dir_diff) * rcp_len_xy);
    len_xy = len_xy * len_xy;
    len += len_xy * w3;

    ec = s.n.x - s.j.x;
    ca = s.j.x - s.f.x;
    len_xy = max(abs(ec), abs(ca));
    rcp_len_xy = 1.0 / max(len_xy, 1e-6);
    dir_diff = s.n.x - s.f.x;
    dir.y += dir_diff * w3;
    len_xy = saturate(abs(dir_diff) * rcp_len_xy);
    len_xy = len_xy * len_xy;
    len += len_xy * w3;

    float w4 = fx * fy;
    dc = s.l.x - s.k.x;
    cb = s.k.x - s.j.x;
    len_xy = max(abs(dc), abs(cb));
    rcp_len_xy = 1.0 / max(len_xy, 1e-6);
    dir_diff = s.l.x - s.j.x;
    dir.x += dir_diff * w4;
    len_xy = saturate(abs(dir_diff) * rcp_len_xy);
    len_xy = len_xy * len_xy;
    len += len_xy * w4;

    ec = s.o.x - s.k.x;
    ca = s.k.x - s.g.x;
    len_xy = max(abs(ec), abs(ca));
    rcp_len_xy = 1.0 / max(len_xy, 1e-6);
    dir_diff = s.o.x - s.g.x;
    dir.y += dir_diff * w4;
    len_xy = saturate(abs(dir_diff) * rcp_len_xy);
    len_xy = len_xy * len_xy;
    len += len_xy * w4;

    float dir_len2 = dot(dir, dir);
    if (dir_len2 > 1.0/32768.0) {
        float dir_rcp = rsqrt(dir_len2);
        dir *= dir_rcp;
    } else {
        dir = float2(1.0, 0.0);
    }

    len = len * 0.5;
    len = len * len;
    float stretch = max(abs(dir.x), abs(dir.y));
    float len2_x = 1.0 + (stretch - 1.0) * len;
    float len2_y = 1.0 + (-0.5) * len;
    float lob = 0.5 + (0.21 - 0.5) * len;
    float clp = 1.0 / lob;

    float3 aC = 0.0;
    float aW = 0.0;

    float3 mn = min(min(min(s.f, s.g), s.j), s.k);
    float3 mx = max(max(max(s.f, s.g), s.j), s.k);

    [unroll] for (int tap = 0; tap < 16; ++tap) {
        int tx = tap % 4;
        int ty = tap / 4;
        float2 off = float2(float(tx - 1) - fx, float(ty - 1) - fy);
        float2 rot;
        rot.x = off.x * dir.x + off.y * dir.y;
        rot.y = off.x * (-dir.y) + off.y * dir.x;
        rot.x *= len2_x;
        rot.y *= len2_y;
        float d2 = min(dot(rot, rot), clp);
        float wB = 0.4 * d2 - 1.0;
        float wA = lob * d2 - 1.0;
        wB = wB * wB;
        wA = wA * wA;
        wB = 1.5625 * wB - 0.5625;
        float w = wB * wA;

        float3 tapVal;
        if (tx == 0 && ty == 0) tapVal = s.b;
        else if (tx == 1 && ty == 0) tapVal = s.c;
        else if (tx == 2 && ty == 0) tapVal = s.d;
        else if (tx == 3 && ty == 0) tapVal = s.e;
        else if (tx == 0 && ty == 1) tapVal = s.f;
        else if (tx == 1 && ty == 1) tapVal = s.g;
        else if (tx == 2 && ty == 1) tapVal = s.h;
        else if (tx == 3 && ty == 1) tapVal = s.i;
        else if (tx == 0 && ty == 2) tapVal = s.j;
        else if (tx == 1 && ty == 2) tapVal = s.k;
        else if (tx == 2 && ty == 2) tapVal = s.l;
        else if (tx == 3 && ty == 2) tapVal = s.m;
        else if (tx == 0 && ty == 3) tapVal = s.n;
        else tapVal = s.o;

        aC = mad(tapVal, w, aC);
        aW = mad(w, 1.0, aW);
    }

    float3 result = aC / max(aW, 1e-6);
    result = clamp(result, mn, mx);
    return float4(result, 1.0);
}

SamplerState linearClamp : register(s0);

[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID) {
    uint outW, outH;
    g_OutputColor.GetDimensions(outW, outH);
    int2 ipos = int2(tid.xy);
    if (ipos.x >= int(outW) || ipos.y >= int(outH)) return;

    float2 outputPixel = float2(tid.xy) + 0.5;
    float2 pp = outputPixel * outputSize * inputRcpSize;
    float2 fp = frac(pp);
    float2 p = pp - fp;

    EASUSample s;
    s.a = g_InputColor.SampleLevel(linearClamp, (float2(-1, -1) + p) * inputRcpSize, 0.0).rgb;
    s.b = g_InputColor.SampleLevel(linearClamp, (float2( 0, -1) + p) * inputRcpSize, 0.0).rgb;
    s.c = g_InputColor.SampleLevel(linearClamp, (float2( 1, -1) + p) * inputRcpSize, 0.0).rgb;
    s.d = g_InputColor.SampleLevel(linearClamp, (float2( 2, -1) + p) * inputRcpSize, 0.0).rgb;
    s.e = g_InputColor.SampleLevel(linearClamp, (float2(-1,  0) + p) * inputRcpSize, 0.0).rgb;
    s.f = g_InputColor.SampleLevel(linearClamp, (float2( 0,  0) + p) * inputRcpSize, 0.0).rgb;
    s.g = g_InputColor.SampleLevel(linearClamp, (float2( 1,  0) + p) * inputRcpSize, 0.0).rgb;
    s.h = g_InputColor.SampleLevel(linearClamp, (float2( 2,  0) + p) * inputRcpSize, 0.0).rgb;
    s.i = g_InputColor.SampleLevel(linearClamp, (float2(-1,  1) + p) * inputRcpSize, 0.0).rgb;
    s.j = g_InputColor.SampleLevel(linearClamp, (float2( 0,  1) + p) * inputRcpSize, 0.0).rgb;
    s.k = g_InputColor.SampleLevel(linearClamp, (float2( 1,  1) + p) * inputRcpSize, 0.0).rgb;
    s.l = g_InputColor.SampleLevel(linearClamp, (float2( 2,  1) + p) * inputRcpSize, 0.0).rgb;
    s.m = g_InputColor.SampleLevel(linearClamp, (float2(-1,  2) + p) * inputRcpSize, 0.0).rgb;
    s.n = g_InputColor.SampleLevel(linearClamp, (float2( 0,  2) + p) * inputRcpSize, 0.0).rgb;
    s.o = g_InputColor.SampleLevel(linearClamp, (float2( 1,  2) + p) * inputRcpSize, 0.0).rgb;

    g_OutputColor[ipos] = EASU(pp, s);
}
