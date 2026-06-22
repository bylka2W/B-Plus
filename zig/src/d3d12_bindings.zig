const std = @import("std");
const windows = std.os.windows;

pub const HRESULT = windows.HRESULT;
pub const GUID = windows.GUID;
pub const BOOL = windows.BOOL;
pub const UINT = windows.UINT;
pub const ULONG = windows.ULONG;
pub const LPCWSTR = [*:0]const u16;

pub const hresult = windows.HRESULT;

pub const CC: std.builtin.CallingConvention = .{ .x86_64_win = .{} };

// -------------------- IIDs (from d3d12.h / dxgi.h via DEFINE_GUID) --------------------

pub const IID_ID3D12Device = GUID.parse("{189819f1-1db6-4b57-be54-1821339b85f7}");
pub const IID_ID3D12CommandQueue = GUID.parse("{0ec870a6-5d7e-4c22-8cfc-5baae07616ed}");
pub const IID_ID3D12CommandAllocator = GUID.parse("{6102dee4-af59-4b09-b999-b44d73f09b24}");
pub const IID_ID3D12GraphicsCommandList = GUID.parse("{5b160d0f-ac1b-4185-8ba8-b3ae42a5a455}");
pub const IID_ID3D12Fence = GUID.parse("{0a753dcf-c4d8-4b91-adf6-be5a60d95a76}");
pub const IID_ID3D12RootSignature = GUID.parse("{c54a6b66-72df-4ee8-8be5-a946a1429214}");
pub const IID_ID3D12PipelineState = GUID.parse("{765a30f3-f624-4c6f-a828-ace948622445}");
pub const IID_ID3D12DescriptorHeap = GUID.parse("{8efb471d-616c-4f49-90f7-127bb763fa51}");
pub const IID_ID3D12Resource = GUID.parse("{696442be-a72e-4059-bc79-5b5c98040fad}");
pub const IID_ID3D12InfoQueue = GUID.parse("{0742a90b-c387-483f-b946-30a7e4e61458}");
pub const IID_ID3D10Blob = GUID.parse("{8ba5fb08-5195-40e2-ac58-0d989c3a0102}");
pub const IID_IDXGIFactory4 = GUID.parse("{1bc6ea02-ef36-464f-bf5c-21c39449e946}");
pub const IID_IDXGIAdapter1 = GUID.parse("{29038f61-3839-4626-91fd-086879011a05}");

// -------------------- Enums --------------------

pub const D3D12_COMMAND_LIST_TYPE = enum(i32) {
    DIRECT = 0,
    BUNDLE = 1,
    COMPUTE = 2,
    COPY = 3,
};

pub const D3D12_COMMAND_QUEUE_FLAGS = enum(i32) {
    NONE = 0,
    DISABLE_GPU_TIMEOUT = 1,
};

pub const D3D12_RESOURCE_STATES = u32;

pub const D3D12_RESOURCE_STATE_COMMON = @as(u32, 0);
pub const D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER = @as(u32, 0x1);
pub const D3D12_RESOURCE_STATE_INDEX_BUFFER = @as(u32, 0x2);
pub const D3D12_RESOURCE_STATE_RENDER_TARGET = @as(u32, 0x4);
pub const D3D12_RESOURCE_STATE_UNORDERED_ACCESS = @as(u32, 0x8);
pub const D3D12_RESOURCE_STATE_DEPTH_WRITE = @as(u32, 0x10);
pub const D3D12_RESOURCE_STATE_DEPTH_READ = @as(u32, 0x20);
pub const D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE = @as(u32, 0x40);
pub const D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE = @as(u32, 0x80);
pub const D3D12_RESOURCE_STATE_STREAM_OUT = @as(u32, 0x100);
pub const D3D12_RESOURCE_STATE_INDIRECT_ARGUMENT = @as(u32, 0x200);
pub const D3D12_RESOURCE_STATE_COPY_DEST = @as(u32, 0x400);
pub const D3D12_RESOURCE_STATE_COPY_SOURCE = @as(u32, 0x800);
pub const D3D12_RESOURCE_STATE_RESOLVE_DEST = @as(u32, 0x1000);
pub const D3D12_RESOURCE_STATE_RESOLVE_SOURCE = @as(u32, 0x2000);
pub const D3D12_RESOURCE_STATE_PREDICATION = @as(u32, 0x200000);

pub const D3D12_HEAP_TYPE = enum(i32) {
    DEFAULT = 1,
    UPLOAD = 2,
    READBACK = 3,
    CUSTOM = 4,
};

pub const D3D12_HEAP_FLAGS = u32;
pub const D3D12_HEAP_FLAG_NONE = @as(u32, 0);
pub const D3D12_HEAP_FLAG_SHARED = @as(u32, 0x1);
pub const D3D12_HEAP_FLAG_DENY_BUFFERS = @as(u32, 0x4);
pub const D3D12_HEAP_FLAG_ALLOW_DISPLAY_ON = @as(u32, 0x8);
pub const D3D12_HEAP_FLAG_SHARED_LINKED = @as(u32, 0x10);
pub const D3D12_HEAP_FLAG_ALLOW_TEXTURE_DATA_ONLY = @as(u32, 0x20);

pub const D3D12_RESOURCE_FLAGS = u32;
pub const D3D12_RESOURCE_FLAG_NONE = @as(u32, 0);
pub const D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET = @as(u32, 0x1);
pub const D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL = @as(u32, 0x2);
pub const D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS = @as(u32, 0x4);
pub const D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE = @as(u32, 0x8);
pub const D3D12_RESOURCE_FLAG_ALLOW_CROSS_ADAPTER = @as(u32, 0x10);
pub const D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS = @as(u32, 0x20);

pub const D3D12_RESOURCE_DIMENSION = enum(i32) {
    UNKNOWN = 0,
    BUFFER = 1,
    TEXTURE1D = 2,
    TEXTURE2D = 3,
    TEXTURE3D = 4,
};

pub const D3D12_TEXTURE_LAYOUT = enum(i32) {
    UNKNOWN = 0,
    ROW_MAJOR = 1,
    _64KB_UNDEFINED_SWIZZLE = 2,
    _64KB_STANDARD_SWIZZLE = 3,
};

pub const D3D12_DESCRIPTOR_HEAP_TYPE = enum(i32) {
    CBV_SRV_UAV = 0,
    SAMPLER = 1,
    RTV = 2,
    DSV = 3,
};

pub const D3D12_DESCRIPTOR_HEAP_FLAGS = u32;
pub const D3D12_DESCRIPTOR_HEAP_FLAG_NONE = @as(u32, 0);
pub const D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE = @as(u32, 0x1);

pub const D3D12_DESCRIPTOR_RANGE_TYPE = enum(i32) {
    SRV = 0,
    UAV = 1,
    CBV = 2,
    SAMPLER = 3,
};

pub const D3D12_ROOT_PARAMETER_TYPE = enum(i32) {
    DESCRIPTOR_TABLE = 0,
    _32BIT_CONSTANTS = 1,
    CBV = 2,
    SRV = 3,
    UAV = 4,
};

pub const D3D12_SHADER_VISIBILITY = enum(i32) {
    ALL = 0,
    VERTEX = 1,
    HULL = 2,
    DOMAIN = 3,
    GEOMETRY = 4,
    PIXEL = 5,
    AMPLIFICATION = 6,
    MESH = 7,
};

pub const D3D12_RESOURCE_BARRIER_TYPE = enum(i32) {
    TRANSITION = 0,
    ALIASING = 1,
    UAV = 2,
};

pub const D3D12_UAV_DIMENSION = enum(i32) {
    UNKNOWN = 0,
    BUFFER = 1,
    TEXTURE1D = 2,
    TEXTURE1DARRAY = 3,
    TEXTURE2D = 4,
    TEXTURE2DARRAY = 5,
    TEXTURE3D = 8,
};

pub const D3D12_SRV_DIMENSION = enum(i32) {
    UNKNOWN = 0,
    BUFFER = 1,
    TEXTURE1D = 2,
    TEXTURE1DARRAY = 3,
    TEXTURE2D = 4,
    TEXTURE2DARRAY = 5,
    TEXTURE3D = 6,
    TEXTURECUBE = 7,
    TEXTURECUBEARRAY = 8,
};

pub const D3D12_RESOURCE_BARRIER_FLAGS = u32;
pub const D3D12_RESOURCE_BARRIER_FLAG_NONE = @as(u32, 0);
pub const D3D12_RESOURCE_BARRIER_FLAG_BEGIN_ONLY = @as(u32, 0x1);
pub const D3D12_RESOURCE_BARRIER_FLAG_END_ONLY = @as(u32, 0x2);

pub const D3D12_FILTER = enum(i32) {
    MIN_MAG_MIP_POINT = 0,
    MIN_MAG_POINT_MIP_LINEAR = 1,
    MIN_POINT_MAG_LINEAR_MIP_POINT = 4,
    MIN_POINT_MAG_MIP_LINEAR = 5,
    MIN_LINEAR_MAG_MIP_POINT = 16,
    MIN_LINEAR_MAG_POINT_MIP_LINEAR = 17,
    MIN_MAG_LINEAR_MIP_POINT = 20,
    MIN_MAG_MIP_LINEAR = 21,
    ANISOTROPIC = 85,
};

pub const D3D12_TEXTURE_ADDRESS_MODE = enum(i32) {
    WRAP = 1,
    MIRROR = 2,
    CLAMP = 3,
    BORDER = 4,
    MIRROR_ONCE = 5,
};

pub const D3D12_COMPARISON_FUNC = enum(i32) {
    NEVER = 1,
    LESS = 2,
    EQUAL = 3,
    LESS_EQUAL = 4,
    GREATER = 5,
    NOT_EQUAL = 6,
    GREATER_EQUAL = 7,
    ALWAYS = 8,
};

pub const D3D12_STATIC_BORDER_COLOR = enum(i32) {
    TRANSPARENT_BLACK = 0,
    OPAQUE_BLACK = 1,
    OPAQUE_WHITE = 2,
};

pub const DXGI_FORMAT = enum(i32) {
    UNKNOWN = 0,
    R32G32B32A32_TYPELESS = 1,
    R32G32B32A32_FLOAT = 2,
    R32G32B32A32_UINT = 3,
    R32G32B32A32_SINT = 4,
    R32G32B32_TYPELESS = 5,
    R32G32B32_FLOAT = 6,
    R32G32B32_UINT = 7,
    R32G32B32_SINT = 8,
    R16G16B16A16_TYPELESS = 9,
    R16G16B16A16_FLOAT = 10,
    R16G16B16A16_UNORM = 11,
    R16G16B16A16_UINT = 12,
    R16G16B16A16_SNORM = 13,
    R16G16B16A16_SINT = 14,
    R32G32_TYPELESS = 15,
    R32G32_FLOAT = 16,
    R32G32_UINT = 17,
    R32G32_SINT = 18,
    R32G8X24_TYPELESS = 19,
    D32_FLOAT_S8X24_UINT = 20,
    R32_FLOAT_X8X24_TYPELESS = 21,
    X32_TYPELESS_G8X24_UINT = 22,
    R10G10B10A2_TYPELESS = 23,
    R10G10B10A2_UNORM = 24,
    R10G10B10A2_UINT = 25,
    R11G11B10_FLOAT = 26,
    R8G8B8A8_TYPELESS = 27,
    R8G8B8A8_UNORM = 28,
    R8G8B8A8_UNORM_SRGB = 29,
    R8G8B8A8_UINT = 30,
    R8G8B8A8_SNORM = 31,
    R8G8B8A8_SINT = 32,
    R16G16_TYPELESS = 33,
    R16G16_FLOAT = 34,
    R16G16_UNORM = 35,
    R16G16_UINT = 36,
    R16G16_SNORM = 37,
    R16G16_SINT = 38,
    R32_TYPELESS = 39,
    D32_FLOAT = 40,
    R32_FLOAT = 41,
    R32_UINT = 42,
    R32_SINT = 43,
    R24G8_TYPELESS = 44,
    D24_UNORM_S8_UINT = 45,
    R24_UNORM_X8_TYPELESS = 46,
    X24_TYPELESS_G8_UINT = 47,
    R8G8_TYPELESS = 48,
    R8G8_UNORM = 49,
    R8G8_UINT = 50,
    R8G8_SNORM = 51,
    R8G8_SINT = 52,
    R16_TYPELESS = 53,
    R16_FLOAT = 54,
    D16_UNORM = 55,
    R16_UNORM = 56,
    R16_UINT = 57,
    R16_SNORM = 58,
    R16_SINT = 59,
    R8_TYPELESS = 60,
    R8_UNORM = 61,
    R8_UINT = 62,
    R8_SNORM = 63,
    R8_SINT = 64,
    A8_UNORM = 65,
    R1_UNORM = 66,
    R9G9B9E5_SHAREDEXP = 67,
    R8G8_B8G8_UNORM = 68,
    G8R8_G8B8_UNORM = 69,
    BC1_TYPELESS = 70,
    BC1_UNORM = 71,
    BC1_UNORM_SRGB = 72,
    BC2_TYPELESS = 73,
    BC2_UNORM = 74,
    BC2_UNORM_SRGB = 75,
    BC3_TYPELESS = 76,
    BC3_UNORM = 77,
    BC3_UNORM_SRGB = 78,
    BC4_TYPELESS = 79,
    BC4_UNORM = 80,
    BC4_SNORM = 81,
    BC5_TYPELESS = 82,
    BC5_UNORM = 83,
    BC5_SNORM = 84,
    B5G6R5_UNORM = 85,
    B5G5R5A1_UNORM = 86,
    B8G8R8A8_UNORM = 87,
    B8G8R8X8_UNORM = 88,
    R10G10B10_XR_BIAS_A2_UNORM = 89,
    B8G8R8A8_TYPELESS = 90,
    B8G8R8A8_UNORM_SRGB = 91,
    B8G8R8X8_TYPELESS = 92,
    B8G8R8X8_UNORM_SRGB = 93,
    A8P8 = 94,
    P8 = 95,
    A8B8G8R8_UNORM = 96,
    A8B8G8R8_UNORM_SRGB = 97,
    B8G8R8A8_UNORM_VERTEX = 98,
    NV12 = 100,
    P010 = 103,
    P016 = 106,
    // ... more omitted for brevity
};

pub const DXGI_SAMPLE_DESC = extern struct {
    Count: UINT = 1,
    Quality: UINT = 0,
};

pub const D3D12_SDK_VERSION: u32 = 610;
pub const D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES: u32 = 0xFFFFFFFF;

// -------------------- Structs --------------------

pub const D3D12_COMMAND_QUEUE_DESC = extern struct {
    Type: D3D12_COMMAND_LIST_TYPE,
    Priority: i32 = 0,
    Flags: D3D12_COMMAND_QUEUE_FLAGS = .NONE,
    NodeMask: UINT = 0,
};

pub const D3D12_DESCRIPTOR_HEAP_DESC = extern struct {
    Type: D3D12_DESCRIPTOR_HEAP_TYPE,
    NumDescriptors: UINT,
    Flags: D3D12_DESCRIPTOR_HEAP_FLAGS,
    NodeMask: UINT = 0,
};

pub const D3D12_HEAP_PROPERTIES = extern struct {
    Type: D3D12_HEAP_TYPE,
    CPUPageProperty: UINT = 0,
    MemoryPoolPreference: UINT = 0,
    CreationNodeMask: UINT = 1,
    VisibleNodeMask: UINT = 1,
};

pub const D3D12_RESOURCE_DESC = extern struct {
    Dimension: D3D12_RESOURCE_DIMENSION,
    Alignment: u64 = 0,
    Width: u64,
    Height: UINT,
    DepthOrArraySize: u16,
    MipLevels: u16,
    Format: DXGI_FORMAT,
    SampleDesc: DXGI_SAMPLE_DESC,
    Layout: D3D12_TEXTURE_LAYOUT = .UNKNOWN,
    Flags: D3D12_RESOURCE_FLAGS,
};

pub const D3D12_RANGE = extern struct {
    Begin: usize,
    End: usize,
};

pub const D3D12_CPU_DESCRIPTOR_HANDLE = extern struct {
    ptr: usize,
};

pub const D3D12_GPU_DESCRIPTOR_HANDLE = extern struct {
    ptr: u64,
};

pub const D3D12_DESCRIPTOR_RANGE = extern struct {
    RangeType: D3D12_DESCRIPTOR_RANGE_TYPE,
    NumDescriptors: UINT,
    BaseShaderRegister: UINT,
    RegisterSpace: UINT,
    OffsetInDescriptorsFromTableStart: UINT,
};

pub const D3D12_ROOT_DESCRIPTOR_TABLE = extern struct {
    NumDescriptorRanges: UINT,
    pDescriptorRanges: *const D3D12_DESCRIPTOR_RANGE,
};

pub const D3D12_ROOT_DESCRIPTOR = extern struct {
    ShaderRegister: UINT,
    RegisterSpace: UINT,
};

pub const D3D12_ROOT_PARAMETER = extern struct {
    ParameterType: D3D12_ROOT_PARAMETER_TYPE,
    _u: extern union {
        DescriptorTable: D3D12_ROOT_DESCRIPTOR_TABLE,
        Constants: D3D12_ROOT_DESCRIPTOR,
        Descriptor: D3D12_ROOT_DESCRIPTOR,
    },
    ShaderVisibility: D3D12_SHADER_VISIBILITY,
};

pub const D3D_ROOT_SIGNATURE_VERSION = u32;
pub const D3D_ROOT_SIGNATURE_VERSION_1_0: D3D_ROOT_SIGNATURE_VERSION = 1;
pub const D3D_ROOT_SIGNATURE_VERSION_1_1: D3D_ROOT_SIGNATURE_VERSION = 2;

pub const D3D12_ROOT_SIGNATURE_FLAGS = u32;
pub const D3D12_ROOT_SIGNATURE_FLAG_NONE = @as(u32, 0);
pub const D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT = @as(u32, 0x1);
pub const D3D12_ROOT_SIGNATURE_FLAG_DENY_VERTEX_SHADER_ROOT_ACCESS = @as(u32, 0x2);
pub const D3D12_ROOT_SIGNATURE_FLAG_DENY_HULL_SHADER_ROOT_ACCESS = @as(u32, 0x4);
pub const D3D12_ROOT_SIGNATURE_FLAG_DENY_DOMAIN_SHADER_ROOT_ACCESS = @as(u32, 0x8);
pub const D3D12_ROOT_SIGNATURE_FLAG_DENY_GEOMETRY_SHADER_ROOT_ACCESS = @as(u32, 0x10);
pub const D3D12_ROOT_SIGNATURE_FLAG_DENY_PIXEL_SHADER_ROOT_ACCESS = @as(u32, 0x20);
pub const D3D12_ROOT_SIGNATURE_FLAG_ALLOW_STREAM_OUTPUT = @as(u32, 0x40);
pub const D3D12_ROOT_SIGNATURE_FLAG_DENY_AMPLIFICATION_SHADER_ROOT_ACCESS = @as(u32, 0x80);
pub const D3D12_ROOT_SIGNATURE_FLAG_DENY_MESH_SHADER_ROOT_ACCESS = @as(u32, 0x100);
pub const D3D12_ROOT_SIGNATURE_FLAG_CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED = @as(u32, 0x200);
pub const D3D12_ROOT_SIGNATURE_FLAG_SAMPLER_HEAP_DIRECTLY_INDEXED = @as(u32, 0x400);

pub const D3D12_ROOT_SIGNATURE_DESC = extern struct {
    NumParameters: UINT,
    pParameters: ?*const D3D12_ROOT_PARAMETER,
    NumStaticSamplers: UINT,
    pStaticSamplers: ?*const D3D12_STATIC_SAMPLER_DESC,
    Flags: D3D12_ROOT_SIGNATURE_FLAGS,
};


pub const D3D12_STATIC_SAMPLER_DESC = extern struct {
    Filter: D3D12_FILTER,
    AddressU: D3D12_TEXTURE_ADDRESS_MODE,
    AddressV: D3D12_TEXTURE_ADDRESS_MODE,
    AddressW: D3D12_TEXTURE_ADDRESS_MODE,
    MipLODBias: f32,
    MaxAnisotropy: UINT,
    ComparisonFunc: D3D12_COMPARISON_FUNC,
    BorderColor: D3D12_STATIC_BORDER_COLOR,
    MinLOD: f32,
    MaxLOD: f32,
    ShaderRegister: UINT,
    RegisterSpace: UINT,
    ShaderVisibility: D3D12_SHADER_VISIBILITY,
};

pub const D3D12_VERSIONED_ROOT_SIGNATURE_DESC = extern struct {
    Version: D3D_ROOT_SIGNATURE_VERSION,
    Desc_1_0: D3D12_ROOT_SIGNATURE_DESC,
};

pub extern "d3d12" fn D3D12SerializeVersionedRootSignature(
    pRootSignature: *const D3D12_VERSIONED_ROOT_SIGNATURE_DESC,
    ppBlob: *?*anyopaque,
    ppErrorBlob: ?*?*anyopaque,
) callconv(CC) HRESULT;

pub const D3D12_SHADER_BYTECODE = extern struct {
    pShaderBytecode: ?*const anyopaque,
    BytecodeLength: usize,
};

pub const D3D12_CACHED_PIPELINE_STATE = extern struct {
    pCachedBlob: ?*const anyopaque,
    CachedBlobSizeInBytes: usize,
};

pub const D3D12_PIPELINE_STATE_FLAGS = UINT;
pub const D3D12_PIPELINE_STATE_FLAG_NONE = @as(UINT, 0);

pub const D3D12_COMPUTE_PIPELINE_STATE_DESC = extern struct {
    pRootSignature: ?*anyopaque,
    CS: D3D12_SHADER_BYTECODE,
    NodeMask: UINT = 0,
    CachedPSO: D3D12_CACHED_PIPELINE_STATE = .{ .pCachedBlob = null, .CachedBlobSizeInBytes = 0 },
    Flags: D3D12_PIPELINE_STATE_FLAGS = D3D12_PIPELINE_STATE_FLAG_NONE,
};
comptime {
    if (@sizeOf(D3D12_COMPUTE_PIPELINE_STATE_DESC) != 56) {
        @compileError("D3D12_COMPUTE_PIPELINE_STATE_DESC size mismatch");
    }
}

pub const D3D12_TEX2D_UAV = extern struct {
    MipSlice: UINT = 0,
    PlaneSlice: UINT = 0,
};

pub const D3D12_UNORDERED_ACCESS_VIEW_DESC = extern struct {
    Format: DXGI_FORMAT,
    ViewDimension: D3D12_UAV_DIMENSION,
    _u: extern union {
        Buffer: extern struct {
            FirstElement: u64,
            NumElements: UINT,
            StructureByteStride: UINT,
            CounterOffsetInBytes: u64,
            Flags: UINT,
        },
        Texture2D: D3D12_TEX2D_UAV,
        Texture2DArray: extern struct {
            MipSlice: UINT,
            FirstArraySlice: UINT,
            ArraySize: UINT,
            PlaneSlice: UINT,
        },
    },
};

pub const D3D12_SHADER_RESOURCE_VIEW_DESC = extern struct {
    Format: DXGI_FORMAT,
    ViewDimension: D3D12_SRV_DIMENSION,
    Shader4ComponentMapping: UINT = 0x1608,
    _u: extern union {
        Buffer: extern struct {
            FirstElement: u64 = 0,
            NumElements: UINT,
            StructureByteStride: UINT = 0,
            Flags: UINT = 0,
        },
        Texture2D: extern struct {
            MostDetailedMip: UINT = 0,
            MipLevels: UINT = 1,
            PlaneSlice: UINT = 0,
            ResourceMinLODClamp: f32 = 0,
        },
    },
};

pub const D3D12_RESOURCE_TRANSITION_BARRIER = extern struct {
    pResource: ?*anyopaque,
    Subresource: UINT = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
    StateBefore: D3D12_RESOURCE_STATES,
    StateAfter: D3D12_RESOURCE_STATES,
};

pub const D3D12_RESOURCE_UAV_BARRIER = extern struct {
    pResource: ?*anyopaque,
};

pub const D3D12_RESOURCE_BARRIER = extern struct {
    Type: D3D12_RESOURCE_BARRIER_TYPE,
    Flags: D3D12_RESOURCE_BARRIER_FLAGS,
    _u: extern union {
        Transition: D3D12_RESOURCE_TRANSITION_BARRIER,
        Aliasing: extern struct { pResourceBefore: ?*anyopaque, pResourceAfter: ?*anyopaque },
        UAV: D3D12_RESOURCE_UAV_BARRIER,
    },
};

pub const D3D12_DEPTH_STENCIL_VALUE = extern struct {
    Depth: f32,
    Stencil: u8,
};

pub const D3D12_CLEAR_VALUE = extern struct {
    Format: DXGI_FORMAT,
    _u: extern union {
        Color: [4]f32,
        DepthStencil: D3D12_DEPTH_STENCIL_VALUE,
    },
};

pub const D3D12_BOX = extern struct {
    left: UINT,
    top: UINT,
    front: UINT,
    right: UINT,
    bottom: UINT,
    back: UINT,
};

pub const D3D12_PLACED_SUBRESOURCE_FOOTPRINT = extern struct {
    Offset: u64,
    Footprint: D3D12_SUBRESOURCE_FOOTPRINT,
};

pub const D3D12_SUBRESOURCE_FOOTPRINT = extern struct {
    Format: DXGI_FORMAT,
    Width: UINT,
    Height: UINT,
    Depth: UINT,
    RowPitch: UINT,
};

pub const D3D12_TEXTURE_COPY_TYPE = enum(i32) {
    SUBRESOURCE_INDEX = 0,
    PLACED_FOOTPRINT = 1,
};

pub const D3D12_TEXTURE_COPY_LOCATION = extern struct {
    pResource: ?*anyopaque,
    Type: D3D12_TEXTURE_COPY_TYPE,
    _u: extern union {
        PlacedFootprint: D3D12_PLACED_SUBRESOURCE_FOOTPRINT,
        SubresourceIndex: UINT,
    },
};

pub const D3D12_RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const D3D12_VIEWPORT = extern struct {
    TopLeftX: f32,
    TopLeftY: f32,
    Width: f32,
    Height: f32,
    MinDepth: f32,
    MaxDepth: f32,
};

// ==================== COM VTable definitions ====================
// All VTBLs match the exact method order from d3d12.h
// Unused methods are `usize` placeholders (same size as fn pointer on x64)

// ---------- IUnknown base (3 entries) ----------
// Used by non-D3D12 COM interfaces like ID3D10Blob
pub const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(CC) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(CC) ULONG,
    Release: *const fn (*anyopaque) callconv(CC) ULONG,
};

// ---------- ID3D12Object base (IUnknown + 4) ----------
// Used by all D3D12 interfaces
pub const D3D12BaseVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(CC) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(CC) ULONG,
    Release: *const fn (*anyopaque) callconv(CC) ULONG,
    GetPrivateData: *const fn (*anyopaque, *const GUID, *UINT, ?*anyopaque) callconv(CC) HRESULT,
    SetPrivateData: *const fn (*anyopaque, *const GUID, UINT, *const anyopaque) callconv(CC) HRESULT,
    SetPrivateDataInterface: *const fn (*anyopaque, *const GUID, *const anyopaque) callconv(CC) HRESULT,
    SetName: *const fn (*anyopaque, [*:0]const u16) callconv(CC) HRESULT,
};

// ---------- ID3D12Device ----------
// Full vtbl: 8 (base) + 37 (device-specific) = 45 entries
pub const ID3D12DeviceVtbl = extern struct {
    // IUnknown (3) + ID3D12Object (5)
    base: D3D12BaseVtbl,
    // ID3D12Device-specific (37 methods in order from d3d12.h COBJMACROS)
    GetNodeCount: *const fn (*anyopaque) callconv(CC) UINT,
    CreateCommandQueue: *const fn (*anyopaque, *const D3D12_COMMAND_QUEUE_DESC, *const GUID, *?*anyopaque) callconv(CC) HRESULT,
    CreateCommandAllocator: *const fn (*anyopaque, D3D12_COMMAND_LIST_TYPE, *const GUID, *?*anyopaque) callconv(CC) HRESULT,
    CreateGraphicsPipelineState: *const fn (*anyopaque, *const anyopaque, *const GUID, *?*anyopaque) callconv(CC) HRESULT,
    CreateComputePipelineState: *const fn (*anyopaque, *const D3D12_COMPUTE_PIPELINE_STATE_DESC, *const GUID, *?*anyopaque) callconv(CC) HRESULT,
    CreateCommandList: *const fn (*anyopaque, UINT, D3D12_COMMAND_LIST_TYPE, ?*anyopaque, ?*anyopaque, *const GUID, *?*anyopaque) callconv(CC) HRESULT,
    CheckFeatureSupport: *const fn (*anyopaque, UINT, *anyopaque, UINT) callconv(CC) HRESULT,
    CreateDescriptorHeap: *const fn (*anyopaque, *const D3D12_DESCRIPTOR_HEAP_DESC, *const GUID, *?*anyopaque) callconv(CC) HRESULT,
    GetDescriptorHandleIncrementSize: *const fn (*anyopaque, D3D12_DESCRIPTOR_HEAP_TYPE) callconv(CC) UINT,
    CreateRootSignature: *const fn (*anyopaque, UINT, *const anyopaque, usize, *const GUID, *?*anyopaque) callconv(CC) HRESULT,
    _10: usize, // CreateConstantBufferView
    CreateShaderResourceView: *const fn (*anyopaque, ?*anyopaque, ?*const D3D12_SHADER_RESOURCE_VIEW_DESC, D3D12_CPU_DESCRIPTOR_HANDLE) callconv(CC) void,
    CreateUnorderedAccessView: *const fn (*anyopaque, ?*anyopaque, ?*anyopaque, ?*const D3D12_UNORDERED_ACCESS_VIEW_DESC, D3D12_CPU_DESCRIPTOR_HANDLE) callconv(CC) void,
    _13: usize, // CreateRenderTargetView
    _14: usize, // CreateDepthStencilView
    _15: usize, // CreateSampler
    _16: usize, // CopyDescriptors
    CopyDescriptorsSimple: *const fn (*anyopaque, UINT, D3D12_CPU_DESCRIPTOR_HANDLE, D3D12_CPU_DESCRIPTOR_HANDLE, D3D12_DESCRIPTOR_HEAP_TYPE) callconv(CC) void,
    _18: usize, // GetResourceAllocationInfo
    _19: usize, // GetCustomHeapProperties
    CreateCommittedResource: *const fn (*anyopaque, *const D3D12_HEAP_PROPERTIES, D3D12_HEAP_FLAGS, *const D3D12_RESOURCE_DESC, D3D12_RESOURCE_STATES, ?*const D3D12_CLEAR_VALUE, *const GUID, *?*anyopaque) callconv(CC) HRESULT,
    _21: usize, // CreateHeap
    _22: usize, // CreatePlacedResource
    _23: usize, // CreateReservedResource
    _24: usize, // CreateSharedHandle
    _25: usize, // OpenSharedHandle
    _26: usize, // OpenSharedHandleByName
    _27: usize, // MakeResident
    _28: usize, // Evict
    CreateFence: *const fn (*anyopaque, u64, UINT, *const GUID, *?*anyopaque) callconv(CC) HRESULT,
    GetDeviceRemovedReason: *const fn (*anyopaque) callconv(CC) HRESULT,
    _31: usize, // GetCopyableFootprints
    _32: usize, // CreateQueryHeap
    _33: usize, // SetStablePowerState
    _34: usize, // CreateCommandSignature
    _35: usize, // GetResourceTiling
    _36: usize, // GetAdapterLuid
};

pub fn getDeviceVtbl(obj: *anyopaque) *const ID3D12DeviceVtbl {
    return @as(*const *const ID3D12DeviceVtbl, @ptrCast(@alignCast(obj))).*;
}

// ---------- ID3D12CommandQueue ----------
// Total: 7 (IUnk+Obj) + 1 (DeviceChild) + 0 (Pageable) + 9 (Queue) = 17
pub const ID3D12CommandQueueVtbl = extern struct {
    base: D3D12BaseVtbl,
    _07: usize, // ID3D12DeviceChild::GetDevice
    _08: usize, // ID3D12CommandQueue::UpdateTileMappings
    _09: usize, // ID3D12CommandQueue::CopyTileMappings
    ExecuteCommandLists: *const fn (*anyopaque, UINT, [*]?*anyopaque) callconv(CC) void,
    _11: usize, // SetMarker
    _12: usize, // BeginEvent
    _13: usize, // EndEvent
    Signal: *const fn (*anyopaque, ?*anyopaque, u64) callconv(CC) HRESULT,
    Wait: *const fn (*anyopaque, ?*anyopaque, u64) callconv(CC) HRESULT,
    _16: usize, // GetTimestampFrequency
    _17: usize, // GetClockCalibration
    GetDesc: *const fn (*anyopaque, *D3D12_COMMAND_QUEUE_DESC) callconv(CC) *D3D12_COMMAND_QUEUE_DESC,
};

pub fn getQueueVtbl(obj: *anyopaque) *const ID3D12CommandQueueVtbl {
    return @as(*const *const ID3D12CommandQueueVtbl, @ptrCast(@alignCast(obj))).*;
}

// ---------- ID3D12GraphicsCommandList ----------
// Total: 7 (IUnk+Obj) + 1 (DevChild) + 1 (CmdList) + ~50 (GraphicsCmdList)
pub const ID3D12GraphicsCommandListVtbl = extern struct {
    base: D3D12BaseVtbl,
    _07: usize, // ID3D12DeviceChild::GetDevice
    GetType: *const fn (*anyopaque) callconv(CC) D3D12_COMMAND_LIST_TYPE,
    Close: *const fn (*anyopaque) callconv(CC) HRESULT,
    Reset: *const fn (*anyopaque, ?*anyopaque, ?*anyopaque) callconv(CC) HRESULT,
    _11: usize, // ClearState
    _12: usize, // DrawInstanced
    _13: usize, // DrawIndexedInstanced
    Dispatch: *const fn (*anyopaque, u32, u32, u32) callconv(CC) void,
    _15: usize, // CopyBufferRegion
    _16: usize, // CopyTextureRegion
    CopyResource: *const fn (*anyopaque, ?*anyopaque, ?*anyopaque) callconv(CC) void,
    _18: usize, // CopyTiles
    _19: usize, // ResolveSubresource
    _20: usize, // IASetPrimitiveTopology
    _21: usize, // RSSetViewports
    _22: usize, // RSSetScissorRects
    _23: usize, // OMSetBlendFactor
    _24: usize, // OMSetStencilRef
    SetPipelineState: *const fn (*anyopaque, ?*anyopaque) callconv(CC) void,
    ResourceBarrier: *const fn (*anyopaque, UINT, *const D3D12_RESOURCE_BARRIER) callconv(CC) void,
    _27: usize, // ExecuteBundle
    SetDescriptorHeaps: *const fn (*anyopaque, UINT, [*]?*anyopaque) callconv(CC) void,
    SetComputeRootSignature: *const fn (*anyopaque, ?*anyopaque) callconv(CC) void,
    SetGraphicsRootSignature: *const fn (*anyopaque, ?*anyopaque) callconv(CC) void,
    SetComputeRootDescriptorTable: *const fn (*anyopaque, UINT, D3D12_GPU_DESCRIPTOR_HANDLE) callconv(CC) void,
    _32: usize, // SetGraphicsRootDescriptorTable
    _33: usize, // SetComputeRoot32BitConstant
    _34: usize, // SetGraphicsRoot32BitConstant
    _35: usize, // SetComputeRoot32BitConstants
    _36: usize, // SetGraphicsRoot32BitConstants
    _37: usize, // SetComputeRootConstantBufferView
    _38: usize, // SetGraphicsRootConstantBufferView
    _39: usize, // SetComputeRootShaderResourceView
    _40: usize, // SetGraphicsRootShaderResourceView
    _41: usize, // SetComputeRootUnorderedAccessView
    _42: usize, // SetGraphicsRootUnorderedAccessView
    _43: usize, // IASetIndexBuffer
    _44: usize, // IASetVertexBuffers
    _45: usize, // SOSetTargets
    _46: usize, // OMSetRenderTargets
    _47: usize, // ClearDepthStencilView
    _48: usize, // ClearRenderTargetView
    _49: usize, // ClearUnorderedAccessViewUint
    _50: usize, // ClearUnorderedAccessViewFloat
    _51: usize, // DiscardResource
    _52: usize, // BeginQuery
    _53: usize, // EndQuery
    _54: usize, // ResolveQueryData
    _55: usize, // SetPredication
    _56: usize, // SetMarker
    _57: usize, // BeginEvent
    _58: usize, // EndEvent
    _59: usize, // ExecuteIndirect
};

pub fn getCmdListVtbl(obj: *anyopaque) *const ID3D12GraphicsCommandListVtbl {
    return @as(*const *const ID3D12GraphicsCommandListVtbl, @ptrCast(@alignCast(obj))).*;
}

// ---------- ID3D12Fence ----------
// Chain: Fence -> Pageable -> DeviceChild -> Object -> IUnknown
// Base: 3+4+1 = 8 (Pageable adds 0 methods). Specific: GetCompletedValue(0), SetEventOnCompletion(1), Signal(2)
pub const ID3D12FenceVtbl = extern struct {
    base: D3D12BaseVtbl,
    _07: usize, // ID3D12DeviceChild::GetDevice
    GetCompletedValue: *const fn (*anyopaque) callconv(CC) u64,
    SetEventOnCompletion: *const fn (*anyopaque, u64, ?*anyopaque) callconv(CC) HRESULT,
    Signal: *const fn (*anyopaque, u64) callconv(CC) HRESULT,
};

pub fn getFenceVtbl(obj: *anyopaque) *const ID3D12FenceVtbl {
    return @as(*const *const ID3D12FenceVtbl, @ptrCast(@alignCast(obj))).*;
}

// ---------- ID3D12CommandAllocator ----------
// Chain: CommandAllocator -> Pageable -> DeviceChild -> Object -> IUnknown
// Base: 8 (Pageable adds 0). Specific: Reset(8)
pub const ID3D12CommandAllocatorVtbl = extern struct {
    base: D3D12BaseVtbl,
    _07: usize, // ID3D12DeviceChild::GetDevice
    Reset: *const fn (*anyopaque) callconv(CC) HRESULT,
};

pub fn getAllocatorVtbl(obj: *anyopaque) *const ID3D12CommandAllocatorVtbl {
    return @as(*const *const ID3D12CommandAllocatorVtbl, @ptrCast(@alignCast(obj))).*;
}

// ---------- ID3D12Resource ----------
// Chain: Resource -> Pageable -> DeviceChild -> Object -> IUnknown
// Base: 3+4+1 = 8 (Pageable adds 0 methods). Specific: Map(0), Unmap(1), GetDesc(2), GetGPUVirtualAddress(3), etc.
pub const ID3D12ResourceVtbl = extern struct {
    base: D3D12BaseVtbl,
    _07: usize, // ID3D12DeviceChild::GetDevice
    Map: *const fn (*anyopaque, UINT, ?*const D3D12_RANGE, ?**anyopaque) callconv(CC) HRESULT,
    Unmap: *const fn (*anyopaque, UINT, ?*const D3D12_RANGE) callconv(CC) void,
    _10: usize, // GetDesc (Windows out-param, unused)
    GetGPUVirtualAddress: *const fn (*anyopaque) callconv(CC) u64,
    _12: usize, // WriteToSubresource
    _13: usize, // ReadFromSubresource
};

pub fn getResourceVtbl(obj: *anyopaque) *const ID3D12ResourceVtbl {
    return @as(*const *const ID3D12ResourceVtbl, @ptrCast(@alignCast(obj))).*;
}

// ---------- ID3D12RootSignature ----------
// Chain: RootSignature -> DeviceChild -> Object -> IUnknown. Base: 8. No specific methods.
pub const ID3D12RootSignatureVtbl = extern struct {
    base: D3D12BaseVtbl,
    _07: usize, // ID3D12DeviceChild::GetDevice
    _08: usize, // past vtable (safety)
};

pub fn getRootSigVtbl(obj: *anyopaque) *const ID3D12RootSignatureVtbl {
    return @as(*const *const ID3D12RootSignatureVtbl, @ptrCast(@alignCast(obj))).*;
}

// ---------- ID3D12PipelineState ----------
// Chain: PipelineState -> DeviceChild -> Object -> IUnknown. Base: 8. Specific: GetCachedBlob(1).
pub const ID3D12PipelineStateVtbl = extern struct {
    base: D3D12BaseVtbl,
    _07: usize, // ID3D12DeviceChild::GetDevice
    _08: usize, // GetCachedBlob
};

pub fn getPSOVtbl(obj: *anyopaque) *const ID3D12PipelineStateVtbl {
    return @as(*const *const ID3D12PipelineStateVtbl, @ptrCast(@alignCast(obj))).*;
}

// ---------- ID3D12DescriptorHeap ----------
// Chain: DescriptorHeap -> Pageable -> DeviceChild -> Object -> IUnknown
// Base: 3+4+1 = 8 (Pageable adds 0 methods). Specific: GetDesc(0), GetCPUDescriptorHandleForHeapStart(1), GetGPUDescriptorHandleForHeapStart(2).
// Windows COM ABI: struct-return methods use out-param (RetVal pointer).
pub const ID3D12DescriptorHeapVtbl = extern struct {
    base: D3D12BaseVtbl,
    _07: usize, // ID3D12DeviceChild::GetDevice
    _08: usize, // GetDesc (unused)
    GetCPUDescriptorHandleForHeapStart: *const fn (*anyopaque, *D3D12_CPU_DESCRIPTOR_HANDLE) callconv(CC) *D3D12_CPU_DESCRIPTOR_HANDLE,
    GetGPUDescriptorHandleForHeapStart: *const fn (*anyopaque, *D3D12_GPU_DESCRIPTOR_HANDLE) callconv(CC) *D3D12_GPU_DESCRIPTOR_HANDLE,
};

pub fn getHeapVtbl(obj: *anyopaque) *const ID3D12DescriptorHeapVtbl {
    return @as(*const *const ID3D12DescriptorHeapVtbl, @ptrCast(@alignCast(obj))).*;
}

// ---------- ID3D10Blob (for serialized data) ----------
pub const ID3D10BlobVtbl = extern struct {
    base: IUnknownVtbl,
    GetBufferPointer: *const fn (*anyopaque) callconv(CC) *anyopaque,
    GetBufferSize: *const fn (*anyopaque) callconv(CC) usize,
};

pub fn getBlobVtbl(obj: *anyopaque) *const ID3D10BlobVtbl {
    return @as(*const *const ID3D10BlobVtbl, @ptrCast(@alignCast(obj))).*;
}

// ---------- DXGI Factory (IDXGIFactory4) ----------
// Inheritance: IDXGIFactory4 -> IDXGIFactory3 -> IDXGIFactory2 -> IDXGIFactory1 -> IDXGIFactory -> IDXGIObject -> IUnknown
// IUnk(3) + IDXGIObject(3) + IDXGIFactory(5) + IDXGIFactory1(1) + IDXGIFactory2(~8) + IDXGIFactory3(1) + IDXGIFactory4(1)
// For simplicity, just define enough entries to reach EnumAdapters

pub const IDXGIFactory4Vtbl = extern struct {
    base: D3D12BaseVtbl,
    _7: usize,  // IDXGIObject: SetPrivateData
    _8: usize,  // IDXGIObject: SetPrivateDataInterface
    _9: usize,  // IDXGIObject: GetPrivateData
    _10: usize, // IDXGIObject: GetParent
    EnumAdapters: *const fn (*anyopaque, UINT, *?*anyopaque) callconv(CC) HRESULT, // IDXGIFactory: EnumAdapters
    _12: usize, // IDXGIFactory: MakeWindowAssociation
    _13: usize, // IDXGIFactory: GetWindowAssociation
    _14: usize, // IDXGIFactory: CreateSwapChain
    _15: usize, // IDXGIFactory: CreateSoftwareAdapter
    EnumAdapters1: *const fn (*anyopaque, UINT, *?*anyopaque) callconv(CC) HRESULT,
    // IDXGIFactory2+ methods (not used)
};

pub fn getFactoryVtbl(obj: *anyopaque) *const IDXGIFactory4Vtbl {
    return @as(*const *const IDXGIFactory4Vtbl, @ptrCast(@alignCast(obj))).*;
}

// ---------- ID3D12InfoQueue (from d3d12sdklayers.h) ----------
pub const D3D12_MESSAGE_SEVERITY = enum(i32) {
    CORRUPTION = 0,
    ERROR = 1,
    WARNING = 2,
    INFO = 3,
    MESSAGE = 4,
};

pub const D3D12_MESSAGE_CATEGORY = enum(i32) {
    APPLICATION_DEFINED = 0,
    MISCELLANEOUS = 1,
    INITIALIZATION = 2,
    CLEANUP = 3,
    COMPILATION = 4,
    STATE_CREATION = 5,
    STATE_SETTING = 6,
    STATE_GETTING = 7,
    RESOURCE_MANIPULATION = 8,
    EXECUTION = 9,
    SHADER = 10,
};

pub const D3D12_MESSAGE_ID = i32;

pub const D3D12_MESSAGE = extern struct {
    Category: D3D12_MESSAGE_CATEGORY,
    Severity: D3D12_MESSAGE_SEVERITY,
    ID: D3D12_MESSAGE_ID,
    pDescription: ?*const u8,
    DescriptionByteLength: usize,
};

pub const D3D12_INFO_QUEUE_FILTER_DESC = extern struct {
    NumCategories: u32,
    pCategoryList: ?*D3D12_MESSAGE_CATEGORY,
    NumSeverities: u32,
    pSeverityList: ?*D3D12_MESSAGE_SEVERITY,
    NumIDs: u32,
    pIDList: ?*D3D12_MESSAGE_ID,
};

pub const D3D12_INFO_QUEUE_FILTER = extern struct {
    AllowList: D3D12_INFO_QUEUE_FILTER_DESC,
    DenyList: D3D12_INFO_QUEUE_FILTER_DESC,
};

// vtbl slots verified against d3d12sdklayers.h lines 3516-3703
pub const ID3D12InfoQueueVtbl = extern struct {
    base: IUnknownVtbl,
    // slot 3
    SetMessageCountLimit: *const fn (*anyopaque, u64) callconv(CC) HRESULT,
    // slot 4
    ClearStoredMessages: *const fn (*anyopaque) callconv(CC) void,
    // slot 5
    GetMessage: *const fn (*anyopaque, u64, ?*D3D12_MESSAGE, *usize) callconv(CC) HRESULT,
    // slot 6
    GetNumMessagesAllowedByStorageFilter: *const fn (*anyopaque) callconv(CC) u64,
    // slot 7
    GetNumMessagesDeniedByStorageFilter: *const fn (*anyopaque) callconv(CC) u64,
    // slot 8
    GetNumStoredMessages: *const fn (*anyopaque) callconv(CC) u64,
    // slot 9
    GetNumStoredMessagesAllowedByRetrievalFilter: *const fn (*anyopaque) callconv(CC) u64,
    // slot 10
    GetNumMessagesDiscardedByMessageCountLimit: *const fn (*anyopaque) callconv(CC) u64,
    // slot 11
    GetMessageCountLimit: *const fn (*anyopaque) callconv(CC) u64,
    // slot 12
    AddStorageFilterEntries: *const fn (*anyopaque, *const D3D12_INFO_QUEUE_FILTER) callconv(CC) HRESULT,
    // slot 13
    GetStorageFilter: *const fn (*anyopaque, ?*D3D12_INFO_QUEUE_FILTER, *usize) callconv(CC) HRESULT,
    // slot 14
    ClearStorageFilter: *const fn (*anyopaque) callconv(CC) void,
    // slot 15
    PushEmptyStorageFilter: *const fn (*anyopaque) callconv(CC) HRESULT,
    // slot 16
    PushCopyOfStorageFilter: *const fn (*anyopaque) callconv(CC) HRESULT,
    // slot 17
    PushStorageFilter: *const fn (*anyopaque, *const D3D12_INFO_QUEUE_FILTER) callconv(CC) HRESULT,
    // slot 18
    PopStorageFilter: *const fn (*anyopaque) callconv(CC) void,
    // slot 19
    GetStorageFilterStackSize: *const fn (*anyopaque) callconv(CC) u32,
    // slot 20
    AddRetrievalFilterEntries: *const fn (*anyopaque, *const D3D12_INFO_QUEUE_FILTER) callconv(CC) HRESULT,
    // slot 21
    GetRetrievalFilter: *const fn (*anyopaque, ?*D3D12_INFO_QUEUE_FILTER, *usize) callconv(CC) HRESULT,
    // slot 22
    ClearRetrievalFilter: *const fn (*anyopaque) callconv(CC) void,
    // slot 23
    PushEmptyRetrievalFilter: *const fn (*anyopaque) callconv(CC) HRESULT,
    // slot 24
    PushCopyOfRetrievalFilter: *const fn (*anyopaque) callconv(CC) HRESULT,
    // slot 25
    PushRetrievalFilter: *const fn (*anyopaque, *const D3D12_INFO_QUEUE_FILTER) callconv(CC) HRESULT,
    // slot 26
    PopRetrievalFilter: *const fn (*anyopaque) callconv(CC) void,
    // slot 27
    GetRetrievalFilterStackSize: *const fn (*anyopaque) callconv(CC) u32,
    // slot 28
    AddMessage: *const fn (*anyopaque, D3D12_MESSAGE_CATEGORY, D3D12_MESSAGE_SEVERITY, D3D12_MESSAGE_ID, ?*const u8) callconv(CC) HRESULT,
    // slot 29
    AddApplicationMessage: *const fn (*anyopaque, D3D12_MESSAGE_SEVERITY, ?*const u8) callconv(CC) HRESULT,
    // slot 30
    SetBreakOnCategory: *const fn (*anyopaque, D3D12_MESSAGE_CATEGORY, BOOL) callconv(CC) HRESULT,
    // slot 31
    SetBreakOnSeverity: *const fn (*anyopaque, D3D12_MESSAGE_SEVERITY, BOOL) callconv(CC) HRESULT,
    // slot 32
    SetBreakOnID: *const fn (*anyopaque, D3D12_MESSAGE_ID, BOOL) callconv(CC) HRESULT,
    // slot 33
    GetBreakOnCategory: *const fn (*anyopaque, D3D12_MESSAGE_CATEGORY) callconv(CC) BOOL,
    // slot 34
    GetBreakOnSeverity: *const fn (*anyopaque, D3D12_MESSAGE_SEVERITY) callconv(CC) BOOL,
    // slot 35
    GetBreakOnID: *const fn (*anyopaque, D3D12_MESSAGE_ID) callconv(CC) BOOL,
    // slot 36
    SetMuteDebugOutput: *const fn (*anyopaque, BOOL) callconv(CC) void,
    // slot 37
    GetMuteDebugOutput: *const fn (*anyopaque) callconv(CC) BOOL,
};

// ---------- Typed vtbl accessors ----------
pub fn getInfoQueueVtbl(obj: *anyopaque) *const ID3D12InfoQueueVtbl {
    return @as(*const *const ID3D12InfoQueueVtbl, @ptrCast(@alignCast(obj))).*;
}

// ---------- Generic object (for IUnknown::Release only) ----------
pub fn release(obj: ?*anyopaque) void {
    if (obj) |o| _ = getBaseVtbl(o).Release(o);
}

fn getBaseVtbl(obj: *anyopaque) *const D3D12BaseVtbl {
    return @as(*const *const D3D12BaseVtbl, @ptrCast(@alignCast(obj))).*;
}
