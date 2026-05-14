using System.Text;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

public enum MathOp
{
    Add, Sub, Mul, Div,
    MatMul, MatVec, MatInv, MatDet, MatTranspose,
    QuatMul, QuatConj, QuatNorm, QuatRotate,
    Sin, Cos, Tan, Sincos,
    Sqrt, Rsqrt, Exp, Log, Pow,
    Dot, Cross, Norm, Lerp,
    Fma, Reduce, Scan,
}

public class MathIntrinsics
{
    static string Avx512Op(MathOp op, string type, string a, string b) => op switch
    {
        MathOp.Add => $"_mm512_add_{Suffix(type)}({a}, {b})",
        MathOp.Sub => $"_mm512_sub_{Suffix(type)}({a}, {b})",
        MathOp.Mul => $"_mm512_mul_{Suffix(type)}({a}, {b})",
        MathOp.Div => $"_mm512_div_{Suffix(type)}({a}, {b})",
        MathOp.Fma => $"_mm512_fmadd_{Suffix(type)}({a}, {b}, _mm512_setzero_{Suffix(type)}())",
        MathOp.Sqrt => $"_mm512_sqrt_{Suffix(type)}({a})",
        MathOp.Rsqrt => $"_mm512_rsqrt14_{Suffix(type)}({a})",
        MathOp.Exp => $"bplus_exp_{type}_avx512({a})",
        MathOp.Log => $"bplus_log_{type}_avx512({a})",
        MathOp.Sin => $"bplus_sin_{type}_avx512({a})",
        MathOp.Cos => $"bplus_cos_{type}_avx512({a})",
        MathOp.Tan => $"bplus_tan_{type}_avx512({a})",
        _ => $"// unsupported AVX-512 op: {op}"
    };

    static string Avx2Op(MathOp op, string type, string a, string b) => op switch
    {
        MathOp.Add => $"_mm256_add_{Suffix(type)}({a}, {b})",
        MathOp.Sub => $"_mm256_sub_{Suffix(type)}({a}, {b})",
        MathOp.Mul => $"_mm256_mul_{Suffix(type)}({a}, {b})",
        MathOp.Div => $"_mm256_div_{Suffix(type)}({a}, {b})",
        MathOp.Fma => $"_mm256_fmadd_{Suffix(type)}({a}, {b}, _mm256_setzero_{Suffix(type)}())",
        MathOp.Sqrt => $"_mm256_sqrt_{Suffix(type)}({a})",
        MathOp.Sin => $"bplus_sin_{type}_avx2({a})",
        MathOp.Cos => $"bplus_cos_{type}_avx2({a})",
        _ => $"// unsupported AVX2 op: {op}"
    };

    static string Sse2Op(MathOp op, string type, string a, string b) => op switch
    {
        MathOp.Add => $"_mm_add_{Suffix(type)}({a}, {b})",
        MathOp.Sub => $"_mm_sub_{Suffix(type)}({a}, {b})",
        MathOp.Mul => $"_mm_mul_{Suffix(type)}({a}, {b})",
        MathOp.Div => $"_mm_div_{Suffix(type)}({a}, {b})",
        MathOp.Sqrt => $"_mm_sqrt_{Suffix(type)}({a})",
        _ => $"// unsupported SSE2 op: {op}"
    };

    static string Suffix(string type) => type.ToLower() switch
    {
        "float" or "f32" => "ps",
        "double" or "f64" => "pd",
        "int32" or "i32" or "int" => "epi32",
        "int64" or "i64" or "long" => "epi64",
        _ => "ps"
    };

    public static string GenerateAvx512MathHeader()
    {
        var sb = new StringBuilder();
        sb.AppendLine("// B+ AVX-512 Math Intrinsics — auto-generated");
        sb.AppendLine("#ifndef BPLUS_MATH_AVX512_H");
        sb.AppendLine("#define BPLUS_MATH_AVX512_H");
        sb.AppendLine();
        sb.AppendLine("#include <immintrin.h>");
        sb.AppendLine("#include <cstdint>");
        sb.AppendLine("#include <cmath>");
        sb.AppendLine();
        sb.AppendLine("// ─── Trigonometric (AVX-512 polynomial approx) ───");
        sb.AppendLine();
        sb.AppendLine("inline __m512 bplus_sin_ps_avx512(__m512 x) {");
        sb.AppendLine("    // Range reduction + 8th-order Taylor series");
        sb.AppendLine("    __m512 x2 = _mm512_mul_ps(x, x);");
        sb.AppendLine("    __m512 x3 = _mm512_mul_ps(x, x2);");
        sb.AppendLine("    __m512 x5 = _mm512_mul_ps(x3, x2);");
        sb.AppendLine("    __m512 x7 = _mm512_mul_ps(x5, x2);");
        sb.AppendLine("    __m512 result = x;");
        sb.AppendLine("    result = _mm512_fmadd_ps(x3, _mm512_set1_ps(-0.16666667f), result);");
        sb.AppendLine("    result = _mm512_fmadd_ps(x5, _mm512_set1_ps(0.00833333f), result);");
        sb.AppendLine("    result = _mm512_fmadd_ps(x7, _mm512_set1_ps(-0.00019841f), result);");
        sb.AppendLine("    return result;");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("inline __m512 bplus_cos_ps_avx512(__m512 x) {");
        sb.AppendLine("    __m512 half_pi = _mm512_set1_ps(1.57079633f);");
        sb.AppendLine("    return bplus_sin_ps_avx512(_mm512_sub_ps(half_pi, x));");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("inline __m512 bplus_tan_ps_avx512(__m512 x) {");
        sb.AppendLine("    __m512 s = bplus_sin_ps_avx512(x);");
        sb.AppendLine("    __m512 c = bplus_cos_ps_avx512(x);");
        sb.AppendLine("    return _mm512_div_ps(s, c);");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("// ─── Exponential / Logarithm (AVX-512) ───");
        sb.AppendLine();
        sb.AppendLine("inline __m512 bplus_exp_ps_avx512(__m512 x) {");
        sb.AppendLine("    // exp(x) ≈ 1 + x + x²/2 + x³/6 + x⁴/24");
        sb.AppendLine("    __m512 x2 = _mm512_mul_ps(x, x);");
        sb.AppendLine("    __m512 x3 = _mm512_mul_ps(x, x2);");
        sb.AppendLine("    __m512 x4 = _mm512_mul_ps(x2, x2);");
        sb.AppendLine("    __m512 result = _mm512_set1_ps(1.0f);");
        sb.AppendLine("    result = _mm512_fmadd_ps(x, _mm512_set1_ps(1.0f), result);");
        sb.AppendLine("    result = _mm512_fmadd_ps(x2, _mm512_set1_ps(0.5f), result);");
        sb.AppendLine("    result = _mm512_fmadd_ps(x3, _mm512_set1_ps(0.16666667f), result);");
        sb.AppendLine("    result = _mm512_fmadd_ps(x4, _mm512_set1_ps(0.04166667f), result);");
        sb.AppendLine("    return result;");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("inline __m512 bplus_log_ps_avx512(__m512 x) {");
        sb.AppendLine("    // log(x) ≈ 2 * (x-1)/(x+1) + 2/3 * ((x-1)/(x+1))³");
        sb.AppendLine("    __m512 one = _mm512_set1_ps(1.0f);");
        sb.AppendLine("    __m512 num = _mm512_sub_ps(x, one);");
        sb.AppendLine("    __m512 den = _mm512_add_ps(x, one);");
        sb.AppendLine("    __m512 y = _mm512_div_ps(num, den);");
        sb.AppendLine("    __m512 y3 = _mm512_mul_ps(y, _mm512_mul_ps(y, y));");
        sb.AppendLine("    return _mm512_add_ps(_mm512_mul_ps(y, _mm512_set1_ps(2.0f)),");
        sb.AppendLine("                       _mm512_mul_ps(y3, _mm512_set1_ps(0.66666667f)));");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("// ─── Matrix 4x4 (AVX-512) ───");
        sb.AppendLine();
        sb.AppendLine("struct mat4x4 { __m512 rows[4]; };");
        sb.AppendLine();
        sb.AppendLine("inline mat4x4 mat4x4_mul_avx512(const mat4x4& a, const mat4x4& b) {");
        sb.AppendLine("    mat4x4 result;");
        sb.AppendLine("    __m512 bt[4] = {");
        sb.AppendLine("        _mm512_set_ps(b.rows[0][3],b.rows[1][3],b.rows[2][3],b.rows[3][3],0,0,0,0),");
        sb.AppendLine("        _mm512_set_ps(b.rows[0][2],b.rows[1][2],b.rows[2][2],b.rows[3][2],0,0,0,0),");
        sb.AppendLine("        _mm512_set_ps(b.rows[0][1],b.rows[1][1],b.rows[2][1],b.rows[3][1],0,0,0,0),");
        sb.AppendLine("        _mm512_set_ps(b.rows[0][0],b.rows[1][0],b.rows[2][0],b.rows[3][0],0,0,0,0),");
        sb.AppendLine("    };");
        sb.AppendLine("    for (int i = 0; i < 4; i++) {");
        sb.AppendLine("        __m512 ar = a.rows[i];");
        sb.AppendLine("        result.rows[i] = _mm512_setzero_ps();");
        sb.AppendLine("        result.rows[i] = _mm512_fmadd_ps(_mm512_set1_ps(ar[0]), bt[0], result.rows[i]);");
        sb.AppendLine("        result.rows[i] = _mm512_fmadd_ps(_mm512_set1_ps(ar[1]), bt[1], result.rows[i]);");
        sb.AppendLine("        result.rows[i] = _mm512_fmadd_ps(_mm512_set1_ps(ar[2]), bt[2], result.rows[i]);");
        sb.AppendLine("        result.rows[i] = _mm512_fmadd_ps(_mm512_set1_ps(ar[3]), bt[3], result.rows[i]);");
        sb.AppendLine("    }");
        sb.AppendLine("    return result;");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("inline mat4x4 mat4x4_identity_avx512() {");
        sb.AppendLine("    mat4x4 m;");
        sb.AppendLine("    m.rows[0] = _mm512_set_ps(0,0,0,1,0,0,0,0);");
        sb.AppendLine("    m.rows[1] = _mm512_set_ps(0,0,1,0,0,0,0,0);");
        sb.AppendLine("    m.rows[2] = _mm512_set_ps(0,1,0,0,0,0,0,0);");
        sb.AppendLine("    m.rows[3] = _mm512_set_ps(1,0,0,0,0,0,0,0);");
        sb.AppendLine("    return m;");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("inline mat4x4 mat4x4_transpose_avx512(const mat4x4& m) {");
        sb.AppendLine("    mat4x4 r;");
        sb.AppendLine("    _MM_TRANSPOSE4_PS(m.rows[0], m.rows[1], m.rows[2], m.rows[3]);");
        sb.AppendLine("    r.rows[0] = m.rows[0]; r.rows[1] = m.rows[1];");
        sb.AppendLine("    r.rows[2] = m.rows[2]; r.rows[3] = m.rows[3];");
        sb.AppendLine("    return r;");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("// ─── Quaternion ───");
        sb.AppendLine();
        sb.AppendLine("struct quat { __m512 v; };  // w,x,y,z in lanes 0-3");
        sb.AppendLine();
        sb.AppendLine("inline quat quat_mul_avx512(const quat& a, const quat& b) {");
        sb.AppendLine("    // (w1*x2 + x1*w2 + y1*z2 - z1*y2,");
        sb.AppendLine("    //  w1*y2 - x1*z2 + y1*w2 + z1*x2,");
        sb.AppendLine("    //  w1*z2 + x1*y2 - y1*x2 + z1*w2,");
        sb.AppendLine("    //  w1*w2 - x1*x2 - y1*y2 - z1*z2)");
        sb.AppendLine("    __m512 aL = a.v, bL = b.v;");
        sb.AppendLine("    __m512 result;");
        sb.AppendLine("    float aw = aL[0], ax = aL[1], ay = aL[2], az = aL[3];");
        sb.AppendLine("    float bw = bL[0], bx = bL[1], by = bL[2], bz = bL[3];");
        sb.AppendLine("    result[0] = aw*bx + ax*bw + ay*bz - az*by;");
        sb.AppendLine("    result[1] = aw*by - ax*bz + ay*bw + az*bx;");
        sb.AppendLine("    result[2] = aw*bz + ax*by - ay*bx + az*bw;");
        sb.AppendLine("    result[3] = aw*bw - ax*bx - ay*by - az*bz;");
        sb.AppendLine("    quat q; q.v = result; return q;");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("// ─── Scalar fallbacks (for non-SIMD targets) ───");
        sb.AppendLine();
        sb.AppendLine("inline float bplus_sin_scalar(float x) { return sinf(x); }");
        sb.AppendLine("inline float bplus_cos_scalar(float x) { return cosf(x); }");
        sb.AppendLine("inline float bplus_tan_scalar(float x) { return tanf(x); }");
        sb.AppendLine("inline float bplus_exp_scalar(float x) { return expf(x); }");
        sb.AppendLine("inline float bplus_log_scalar(float x) { return logf(x); }");
        sb.AppendLine();
        sb.AppendLine("struct mat4_scalar { float m[4][4]; };");
        sb.AppendLine("struct quat_scalar { float w, x, y, z; };");
        sb.AppendLine();
        sb.AppendLine("inline mat4_scalar mat4_mul_scalar(const mat4_scalar& a, const mat4_scalar& b) {");
        sb.AppendLine("    mat4_scalar r = {};");
        sb.AppendLine("    for (int i = 0; i < 4; i++)");
        sb.AppendLine("        for (int j = 0; j < 4; j++)");
        sb.AppendLine("            for (int k = 0; k < 4; k++)");
        sb.AppendLine("                r.m[i][j] += a.m[i][k] * b.m[k][j];");
        sb.AppendLine("    return r;");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("inline quat_scalar quat_mul_scalar(const quat_scalar& a, const quat_scalar& b) {");
        sb.AppendLine("    return {");
        sb.AppendLine("        a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,");
        sb.AppendLine("        a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,");
        sb.AppendLine("        a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,");
        sb.AppendLine("        a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z,");
        sb.AppendLine("    };");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("#endif // BPLUS_MATH_AVX512_H");
        return sb.ToString();
    }

    public static string GenerateMathOpsSource(List<StateDefNode> states)
    {
        var sb = new StringBuilder();
        sb.AppendLine("// B+ Math Operations — auto-generated per state");
        sb.AppendLine("#include \"bplus_math.h\"");
        sb.AppendLine("#include <cmath>");
        sb.AppendLine();
        sb.AppendLine("// Per-state math dispatch table");
        sb.AppendLine("struct MathOpEntry {");
        sb.AppendLine("    const char* state;");
        sb.AppendLine("    void (*fn_scalar)(void* ctx);");
        sb.AppendLine("    void (*fn_avx512)(void* ctx);");
        sb.AppendLine("};");

        foreach (var st in states)
        {
            bool hasMath = st.Variables.Any(v =>
                v.Type is "mat4" or "quat" or "float" or "double");
            if (!hasMath) continue;

            sb.AppendLine();
            sb.AppendLine($"// Math operations for state: {st.Name}");
            sb.AppendLine($"void math_{st.Name}_scalar(void* ctx);");
            sb.AppendLine($"void math_{st.Name}_avx512(void* ctx);");
        }
        sb.AppendLine();
        sb.AppendLine("MathOpEntry math_dispatch[] = {");
        foreach (var st in states)
        {
            bool hasMath = st.Variables.Any(v =>
                v.Type is "mat4" or "quat" or "float" or "double");
            if (!hasMath) continue;
            sb.AppendLine($"    {{ \"{st.Name}\", math_{st.Name}_scalar, math_{st.Name}_avx512 }},");
        }
        sb.AppendLine("    { nullptr, nullptr, nullptr }");
        sb.AppendLine("};");

        return sb.ToString();
    }
}
