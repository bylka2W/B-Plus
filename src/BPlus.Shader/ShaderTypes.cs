namespace BPlus.Shader.Types;

public enum NumericType
{
    F16,
    F32,
    F64,
    BF16,
    I8,
    I16,
    I32,
    I64,
    U8,
    U16,
    U32,
    U64
}

public class VectorType
{
    public int Components { get; set; }
    public NumericType ElementType { get; set; }
    public string GLSL => ElementType switch
    {
        NumericType.F16 => $"f16vec{Components}",
        NumericType.F32 => $"vec{Components}",
        NumericType.F64 => $"dvec{Components}",
        NumericType.BF16 => $"f16vec{Components}",
        NumericType.I32 => $"ivec{Components}",
        NumericType.U32 => $"uvec{Components}",
        _ => $"vec{Components}"
    };
    public string HLSL => ElementType switch
    {
        NumericType.F16 => $"half{Components}",
        NumericType.F32 => $"float{Components}",
        NumericType.BF16 => $"min16float{Components}",
        NumericType.I32 => $"int{Components}",
        NumericType.U32 => $"uint{Components}",
        _ => $"float{Components}"
    };
    public string SPIRV => ElementType switch
    {
        NumericType.F16 => Components switch { 2 => "Vec2", 3 => "Vec3", 4 => "Vec4", _ => "Float" },
        NumericType.F32 => Components switch { 2 => "Vec2", 3 => "Vec3", 4 => "Vec4", _ => "Float" },
        NumericType.BF16 => "Float",
        _ => "Float"
    };

    public static VectorType F16V2 => new() { ElementType = NumericType.F16, Components = 2 };
    public static VectorType F16V3 => new() { ElementType = NumericType.F16, Components = 3 };
    public static VectorType F16V4 => new() { ElementType = NumericType.F16, Components = 4 };
    public static VectorType F32V2 => new() { ElementType = NumericType.F32, Components = 2 };
    public static VectorType F32V3 => new() { ElementType = NumericType.F32, Components = 3 };
    public static VectorType F32V4 => new() { ElementType = NumericType.F32, Components = 4 };
}

public class MatrixType
{
    public int Rows { get; set; }
    public int Cols { get; set; }
    public NumericType ElementType { get; set; }
    public string GLSL => ElementType switch
    {
        NumericType.F16 => "f16mat" + (Rows <= Cols ? Rows + "x" + Cols : Cols + "x" + Rows),
        NumericType.F32 => "mat" + (Rows <= Cols ? Rows + "x" + Cols : Cols + "x" + Rows),
        _ => "mat" + Rows + "x" + Cols
    };
    public string HLSL => $"matrix<float,{Rows},{Cols}>";
}

public class TextureType
{
    public string Format { get; set; } = "rgba32f";
    public int Channels { get; set; } = 4;
    public NumericType ComponentType { get; set; } = NumericType.F32;
    public bool IsDepth { get; set; }
    public bool IsStorage { get; set; }
    public int ArrayLayers { get; set; } = 1;
    public int MipLevels { get; set; } = 1;

    public string SPIRVBinding => IsStorage ? "StorageBuffer" : "SampledImage";
}

public class MotionVector
{
    public VectorType ScreenVelocity { get; set; } = VectorType.F32V2;
    public int HistoryLength { get; set; } = 4;
    public bool HasPrevFrame { get; set; }
}

public class HistoryBuffer
{
    public string Name { get; set; } = "";
    public TextureType TextureFormat { get; set; } = new();
    public int FrameIndex { get; set; }
    public int PingPongIndex { get; set; }
    public bool IsLocked { get; set; }
    public Dictionary<string, VectorType> Channels { get; } = new();

    public HistoryBuffer(string name, int channels)
    {
        Name = name;
        TextureFormat = new TextureType { Channels = channels };
    }
}

public class SamplingFilter
{
    public static SamplingFilter Bilinear { get; } = new("bilinear", 2);
    public static SamplingFilter Bicubic { get; } = new("bicubic", 4);
    public static SamplingFilter Lanczos { get; } = new("lanczos", 8);
    public static SamplingFilter CatmullRom { get; } = new("catmull_rom", 16);
    public static SamplingFilter Barycentric { get; } = new("barycentric", 4);
    public static SamplingFilter RCAS { get; } = new("rcas", 1);

    public string Name { get; }
    public int SampleCount { get; }

    private SamplingFilter(string name, int samples)
    {
        Name = name;
        SampleCount = samples;
    }

    public string GLSLKernel(int idx)
    {
        return Name switch
        {
            "bilinear" => BilinearSamples[idx],
            "bicubic" => BicubicSamples[idx],
            "lanczos" => LanczosSamples[idx],
            "catmull_rom" => CatmullRomSamples[idx],
            "rcas" => $"rcas_weight({idx})",
            _ => "vec4(0)"
        };
    }

    static readonly string[] BilinearSamples = { "weight0", "weight1" };
    static readonly string[] BicubicSamples = { "w00", "w10", "w01", "w11" };
    static readonly string[] LanczosSamples = { "l0", "l1", "l2", "l3", "l4", "l5", "l6", "l7" };
    static readonly string[] CatmullRomSamples = { "c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8", "c9", "c10", "c11", "c12", "c13", "c14", "c15" };
}