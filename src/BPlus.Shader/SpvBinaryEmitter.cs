namespace BPlus.Shader.Emit;

public enum SpvOp
{
    Nop = 0,
    Undef = 1,
    SourceContinued = 2,
    Source = 3,
    SourceExtension = 4,
    Name = 5,
    MemberName = 6,
    Extension = 7,
    ExtInstImport = 8,
    ExtInst = 9,
    Annotation = 10,
    TypeVoid = 11,
    TypeBool = 12,
    TypeInt = 14,
    TypeFloat = 15,
    TypeVector = 16,
    TypeMatrix = 17,
    TypeImage = 18,
    TypeSampler = 19,
    TypeSampledImage = 20,
    TypeArray = 21,
    TypeRuntimeArray = 22,
    TypeStruct = 23,
    TypePointer = 24,
    TypeFunction = 25,
    TypeEvent = 26,
    TypeDeviceEvent = 27,
    TypeReserveId = 28,
    TypeQueue = 29,
    TypePipe = 30,
    TypeForwardReference = 31,
    TypePipeStorage = 32,
    TypeNamedBarrier = 33,
    Variable = 36,
    ImageSampleExplicitLod = 41,
    ImageSampleImplicitLod = 42,
    ImageSampleDrefImplicitLod = 43,
    ImageSampleDrefExplicitLod = 44,
    ImageFetch = 45,
    ImageQuerySizeLod = 46,
    ImageQuerySize = 47,
    ImageQueryLod = 48,
    ConvertFToU = 76,
    ConvertFToS = 77,
    ConvertSToF = 78,
    ConvertUToF = 79,
    UConvert = 80,
    SConvert = 81,
    FConvert = 82,
    VectorExtractDynamic = 83,
    VectorInsertDynamic = 84,
    VectorShuffle = 85,
    CompositeConstruct = 86,
    CompositeExtract = 87,
    CompositeInsert = 88,
    CopyObject = 90,
    CopyLogical = 91,
    Branch = 97,
    BranchConditional = 98,
    Switch = 101,
    Return = 102,
    ReturnValue = 103,
    Unreachable = 93,
    Function = 33,
    FunctionEnd = 56,
    FAdd = 129,
    Select = 105,
    SelectCondition = 106,
    SPhi = 109,
    LoopMerge = 111,
    SelectionMerge = 112,
    Label = 248,
    ExtInstInsert = 115,
    ExtInstExtract = 116,
    ControlBarrier = 317,
    MemoryBarrier = 318,
    AtomicLoad = 331,
    AtomicStore = 332,
    AtomicExchange = 333,
    AtomicCompareExchange = 334,
    AtomicIIncrement = 335,
    AtomicIDecrement = 336,
    AtomicIAdd = 337,
    AtomicISub = 338,
    AtomicSMin = 341,
    AtomicUMin = 342,
    AtomicFMin = 345,
    AtomicFAdd = 350,
    FSub = 137,
    FNegate = 136,
    FCeiling = 169,
    FFloor = 139,
    FFract = 140,
    FClamp = 163,
    FMix = 165,
    FMul = 132,
    FDiv = 134,
    FMod = 141,
    FAbs = 167,
    FSqrt = 170,
    FLength = 172,
    FNormalize = 173,
    FMax = 168,
    FMin = 166,
    IAdd = 128,
    ISub = 129,
    IMul = 131,
    IDiv = 133,
    IMod = 144,
    IAbs = 176,
    INeg = 135,
    IMax = 177,
    IMin = 178,
    ShiftLeftLogical = 146,
    ShiftRightLogical = 147,
    ShiftRightArithmetic = 148,
    BitwiseOr = 129,
    BitwiseAnd = 130,
    BitwiseXor = 138,
    BitReverse = 330,
    BitCount = 329,
    Dot = 158,
    IAddCarry = 139,
    ISubBorrow = 140,
    UMulExtended = 141,
    SMulExtended = 142
}

public class SpvOperand
{
    public SpvId Id { get; set; } = new();
    public string Literal { get; set; } = "";
}

public class SpvId
{
    public uint Value { get; set; }
}

public class SpvInstruction
{
    public SpvOp Op { get; set; }
    public List<SpvOperand> Operands { get; } = new();
    public uint ResultId { get; set; }
}

public class SpvBinaryEmitter
{
    readonly List<byte> _bytes = new();
    readonly Dictionary<string, uint> _stringIds = new();
    readonly List<SpvId> _ids = new();
    uint _stringIdCounter = 1;
    uint _idCounter = 1;

    public SpvId GetId(string name) => _ids[(int)_idCounter++];

    public void EmitHeader(int version = 0x00010500)
    {
        _bytes.AddRange(BitConverter.GetBytes(0x07230203u));
        _bytes.AddRange(BitConverter.GetBytes((uint)version));
        _bytes.AddRange(BitConverter.GetBytes(1u));
        _bytes.AddRange(BitConverter.GetBytes(11u));
        _bytes.AddRange(BitConverter.GetBytes(0u));
    }

    public SpvId AllocateId() => new() { Value = _idCounter++ };

    public SpvId EmitTypeVoid()
    {
        var id = AllocateId();
        EmitOp(SpvOp.TypeVoid, new[] { new SpvOperand { Id = id } });
        return id;
    }

    public SpvId EmitTypeBool()
    {
        var id = AllocateId();
        EmitOp(SpvOp.TypeBool, new[] { new SpvOperand { Id = id } });
        return id;
    }

    public SpvId EmitTypeInt(int width, bool signed)
    {
        var id = AllocateId();
        EmitOp(SpvOp.TypeInt, new[]
        {
            new SpvOperand { Id = id },
            new SpvOperand { Literal = width.ToString() },
            new SpvOperand { Literal = signed ? "1" : "0" }
        });
        return id;
    }

    public SpvId EmitTypeFloat(int width)
    {
        var id = AllocateId();
        EmitOp(SpvOp.TypeFloat, new[]
        {
            new SpvOperand { Id = id },
            new SpvOperand { Literal = width.ToString() }
        });
        return id;
    }

    public SpvId EmitTypeVector(SpvId componentType, int count)
    {
        var id = AllocateId();
        EmitOp(SpvOp.TypeVector, new[]
        {
            new SpvOperand { Id = id },
            new SpvOperand { Id = componentType },
            new SpvOperand { Literal = count.ToString() }
        });
        return id;
    }

    public SpvId EmitTypeMatrix(SpvId columnType, int columnCount)
    {
        var id = AllocateId();
        EmitOp(SpvOp.TypeMatrix, new[]
        {
            new SpvOperand { Id = id },
            new SpvOperand { Id = columnType },
            new SpvOperand { Literal = columnCount.ToString() }
        });
        return id;
    }

    public SpvId EmitTypePointer(SpvId storageClass, SpvId pointeeType)
    {
        var id = AllocateId();
        EmitOp(SpvOp.TypePointer, new[]
        {
            new SpvOperand { Id = id },
            new SpvOperand { Literal = storageClass.ToString()! },
            new SpvOperand { Id = pointeeType }
        });
        return id;
    }

    public SpvId EmitTypeImage(SpvId sampledType, int dim, int depth, int array, int ms, int sampled, int format)
    {
        var id = AllocateId();
        EmitOp(SpvOp.TypeImage, new[]
        {
            new SpvOperand { Id = id },
            new SpvOperand { Id = sampledType },
            new SpvOperand { Literal = dim.ToString() },
            new SpvOperand { Literal = depth.ToString() },
            new SpvOperand { Literal = array.ToString() },
            new SpvOperand { Literal = ms.ToString() },
            new SpvOperand { Literal = sampled.ToString() },
            new SpvOperand { Literal = format.ToString() }
        });
        return id;
    }

    public SpvId EmitTypeFunction(SpvId returnType, params SpvId[] paramTypes)
    {
        var id = AllocateId();
        var operands = new List<SpvOperand> { new SpvOperand { Id = id }, new SpvOperand { Id = returnType } };
        operands.AddRange(paramTypes.Select(p => new SpvOperand { Id = p }));
        EmitOp(SpvOp.TypeFunction, operands);
        return id;
    }

    public SpvId EmitFunction(SpvId resultType, SpvId id, int control, SpvId functionType)
    {
        EmitOp(SpvOp.Function, new[]
        {
            new SpvOperand { Id = resultType },
            new SpvOperand { Id = id },
            new SpvOperand { Literal = control.ToString() },
            new SpvOperand { Id = functionType }
        });
        return id;
    }

    public void EmitLabel(SpvId id)
    {
        EmitOp(SpvOp.Label, new[] { new SpvOperand { Id = id } });
    }

    public SpvId EmitVariable(SpvId resultType, SpvId id, int storageClass)
    {
        EmitOp(SpvOp.Variable, new[]
        {
            new SpvOperand { Id = resultType },
            new SpvOperand { Id = id },
            new SpvOperand { Literal = storageClass.ToString() }
        });
        return id;
    }

    public SpvId EmitImageSampleImplicitLod(SpvId resultType, SpvId id, SpvId sampledImage, SpvId coordinate, int operands)
    {
        EmitOp(SpvOp.ImageSampleImplicitLod, new[]
        {
            new SpvOperand { Id = resultType },
            new SpvOperand { Id = id },
            new SpvOperand { Id = sampledImage },
            new SpvOperand { Id = coordinate },
            new SpvOperand { Literal = operands.ToString() }
        });
        return id;
    }

    public SpvId EmitFAdd(SpvId resultType, SpvId id, SpvId operand1, SpvId operand2)
    {
        EmitOp(SpvOp.FAdd, new[]
        {
            new SpvOperand { Id = resultType },
            new SpvOperand { Id = id },
            new SpvOperand { Id = operand1 },
            new SpvOperand { Id = operand2 }
        });
        return id;
    }

    public SpvId EmitFMul(SpvId resultType, SpvId id, SpvId operand1, SpvId operand2)
    {
        EmitOp(SpvOp.FMul, new[] 
        {
            new SpvOperand { Id = resultType },
            new SpvOperand { Id = id },
            new SpvOperand { Id = operand1 },
            new SpvOperand { Id = operand2 }
        });
        return id;
    }

    public SpvId EmitCompositeConstruct(SpvId resultType, SpvId id, params SpvId[] constituents)
    {
        var operands = new List<SpvOperand>
        {
            new SpvOperand { Id = resultType },
            new SpvOperand { Id = id }
        };
        operands.AddRange(constituents.Select(c => new SpvOperand { Id = c }));
        EmitOp(SpvOp.CompositeConstruct, operands);
        return id;
    }

    public SpvId EmitCompositeExtract(SpvId resultType, SpvId id, SpvId composite, uint index)
    {
        EmitOp(SpvOp.CompositeExtract, new[]
        {
            new SpvOperand { Id = resultType },
            new SpvOperand { Id = id },
            new SpvOperand { Id = composite },
            new SpvOperand { Literal = index.ToString() }
        });
        return id;
    }

    public SpvId EmitSelect(SpvId resultType, SpvId id, SpvId condition, SpvId trueValue, SpvId falseValue)
    {
        EmitOp(SpvOp.Select, new[]
        {
            new SpvOperand { Id = resultType },
            new SpvOperand { Id = id },
            new SpvOperand { Id = condition },
            new SpvOperand { Id = trueValue },
            new SpvOperand { Id = falseValue }
        });
        return id;
    }

    public void EmitReturn()
    {
        EmitOp(SpvOp.Return, Array.Empty<SpvOperand>());
    }

    public void EmitFunctionEnd()
    {
        EmitOp(SpvOp.FunctionEnd, Array.Empty<SpvOperand>());
    }

    public void EmitControlBarrier(int execution, int memory, int semantics)
    {
        EmitOp(SpvOp.ControlBarrier, new[]
        {
            new SpvOperand { Literal = execution.ToString() },
            new SpvOperand { Literal = memory.ToString() },
            new SpvOperand { Literal = semantics.ToString() }
        });
    }

    void EmitOp(SpvOp op, IEnumerable<SpvOperand> operands)
    {
        int wordCount = 1;
        foreach (var opnd in operands)
        {
            if (opnd.Id != null)
                wordCount++;
            else if (int.TryParse(opnd.Literal, out _))
                wordCount++;
            else
            {
                if (!_stringIds.ContainsKey(opnd.Literal))
                    _stringIds[opnd.Literal] = _stringIdCounter++;
                wordCount += (int)((_stringIds[opnd.Literal] + 3) / 4);
            }
        }

        _bytes.AddRange(BitConverter.GetBytes(wordCount));
        _bytes.AddRange(BitConverter.GetBytes((uint)op));
        foreach (var opnd in operands)
        {
            if (opnd.Id != null)
                _bytes.AddRange(BitConverter.GetBytes(opnd.Id.Value));
            else if (int.TryParse(opnd.Literal, out int val))
                _bytes.AddRange(BitConverter.GetBytes((uint)val));
        }
    }

    public byte[] ToArray() => _bytes.ToArray();

    public void Save(string path)
    {
        File.WriteAllBytes(path, _bytes.ToArray());
    }

    public static class StorageClass
    {
        public const int UniformConstant = 0;
        public const int Input = 1;
        public const int Uniform = 2;
        public const int Output = 3;
        public const int Workgroup = 4;
        public const int CrossWorkgroup = 5;
        public const int Private = 6;
        public const int Function = 7;
        public const int Generic = 8;
        public const int PushConstant = 9;
        public const int SharedStorage = 10;
        public const int CallableData = 11;
        public const int CallableDataIndirect = 12;
    }

    public static class Dim
    {
        public const int Dim1D = 0;
        public const int Dim2D = 1;
        public const int Dim3D = 2;
        public const int Cube = 3;
        public const int Rect = 4;
        public const int Buffer = 5;
        public const int SubpassData = 6;
    }

    public static class ImageFormat
    {
        public const int Unknown = 0;
        public const int Rgba32f = 1;
        public const int Rgba16f = 2;
        public const int Rgba8 = 6;
        public const int Rg32f = 11;
    }

    public static class ExecutionModel
    {
        public const int Vertex = 0;
        public const int TessellationControl = 1;
        public const int TessellationEvaluation = 2;
        public const int Geometry = 3;
        public const int Fragment = 4;
        public const int GLCompute = 5;
        public const int Kernel = 6;
    }

    public static class ExecutionMode
    {
        public const int OriginLowerLeft = 8;
        public const int LocalSize = 17;
    }
}