namespace BPlus.Shader.Platform;

public enum GpuVendor
{
    AMD,
    NVIDIA,
    Intel,
    Unknown
}

public enum Architecture
{
    Unknown = 0,
    RDNA2,
    RDNA3,
    RDNA4,
    GCN,
    Ampere,
    Ada,
    Hopper,
    XeHPG
}

public class PlatformIntrinsics
{
    public GpuVendor Vendor { get; set; }
    public Architecture Arch { get; set; }
    public bool IsAMD => Vendor == GpuVendor.AMD;
    public bool IsNVIDIA => Vendor == GpuVendor.NVIDIA;

    public string GenerateShuffleSync(string value, int lane)
    {
        if (IsNVIDIA)
            return $"__shfl_sync(0xffffffff, {value}, {lane})";
        if (IsAMD)
            return $"ds_bpermute(0, {value})";
        return value;
    }

    public string GenerateShuffleUp(string value, int delta)
    {
        if (IsNVIDIA)
            return $"__shfl_up_sync(0xffffffff, {value}, {delta})";
        return value;
    }

    public string GenerateShuffleDown(string value, int delta)
    {
        if (IsNVIDIA)
            return $"__shfl_down_sync(0xffffffff, {value}, {delta})";
        return value;
    }

    public string GenerateBallot(string predicate)
    {
        if (IsNVIDIA)
            return $"__ballot_sync(0xffffffff, {predicate})";
        if (IsAMD)
            return $"WaveActiveBallot({predicate})";
        return "0u";
    }

    public string GenerateReduceSum(string value)
    {
        if (IsNVIDIA)
            return $"__reduce_add_sync(0xffffffff, {value})";
        if (IsAMD)
            return $"WaveSum({value})";
        return value;
    }

    public string GenerateReduceMin(string value)
    {
        if (IsNVIDIA)
            return $"__reduce_min_sync(0xffffffff, {value})";
        if (IsAMD)
            return $"WaveMin({value})";
        return value;
    }

    public string GenerateReduceMax(string value)
    {
        if (IsNVIDIA)
            return $"__reduce_max_sync(0xffffffff, {value})";
        if (IsAMD)
            return $"WaveMax({value})";
        return value;
    }

    public string GeneratePrefixSum(string value)
    {
        if (IsNVIDIA)
            return $"__scan_add_sync(0xffffffff, {value})";
        if (IsAMD)
            return $"WavePrefixSum({value})";
        return value;
    }

    public string GenerateMatchAny(string value)
    {
        if (IsNVIDIA)
            return $"__match_any_sync(0xffffffff, {value})";
        return "0u";
    }
}

public class AMD_RDNA_Intrinsics
{
    public const int WaveSize32 = 32;
    public const int WaveSize64 = 64;

    public string WaveShift(string v, int amount, bool wave64 = false)
    {
        if (wave64)
            return $"ds_bpermute(0, {v})";
        return $"ds_permute(0, {v})";
    }

    public string WaveRotate(string v, int direction)
    {
        return $"ds_bpermute({direction}, {v})";
    }

    public string WaveSwizzle(string v, int pattern)
    {
        return $"ds_permute({pattern}, {v})";
    }

    public string LdsInit(string ptr) => $"s_mov_b32({ptr}, 0)";
    public string LdsLoad(string ptr, int offset) => $"s_load_dwordx4({ptr}, {offset})";
    public string LdsStore(string ptr, string value, int offset) => $"s_store_dwordx4({ptr}, {value}, {offset})";

    public string BufferLoad(string ptr, int offset) => $"buffer_load_dword({ptr}, {offset})";
    public string BufferStore(string ptr, string value, int offset) => $"buffer_store_dword({ptr}, {value}, {offset})";

    public string FmaF16(string a, string b, string c) => $"v_pk_fma_f16 {a}, {b}, {c}";

    public string DotF16(string a, string b)
    {
        return $@"
// AMD dot product for f16 vectors
v_dot2_f16 acc, {a}.xy, {b}.xy;
v_dot2_f16 acc, {a}.zw, {b}.zw;
";
    }

    public string WaveAllEqual(string value)
    {
        return $"WaveActiveEqual({value})";
    }

    public string WaveAllBitOr(string value)
    {
        return $"WaveActiveBitOr({value})";
    }

    public string WaveAllBitAnd(string value)
    {
        return $"WaveActiveBitAnd({value})";
    }

    public string ReadLane(string value, int lane)
    {
        return $"ds_readlane({value}, {lane})";
    }

    public string WriteLane(string value, int lane, string newValue)
    {
        return $"ds_writelane({value}, {lane}, {newValue})";
    }

    public string SwizzleLane(string value, int mask)
    {
        return $"ds_swizzle({value}, {mask})";
    }

    public string PermuteLane(string value, int sel0, int sel1, int sel2, int sel3)
    {
        int perm = (sel0 & 0x3) | ((sel1 & 0x3) << 2) | ((sel2 & 0x3) << 4) | ((sel3 & 0x3) << 6);
        return $"ds_permute({perm}, {value})";
    }

    public string BpermuteLane(string value, int sel0, int sel1, int sel2, int sel3)
    {
        int perm = (sel0 & 0x3) | ((sel1 & 0x3) << 2) | ((sel2 & 0x3) << 4) | ((sel3 & 0x3) << 6);
        return $"ds_bpermute({perm}, {value})";
    }

    public string CvtF32ToF16(string f32) => $"v_cvt_f16_f32 {f32}";
    public string CvtF16ToF32(string f16) => $"v_cvt_f32_f16 {f16}";

    public string V_INTERP_PAIR_LD(float p1, float p2, int lane, string attr, int attrChan)
    {
        return $"v_interp_p2_f32 {p1}, {p2}, m0, {attr}.{attrChan}[{lane}]";
    }

    public string GenerateRDNA4_16bitPack(string lo, string hi)
    {
        return $"v_pack_b32_f16 {lo}, {hi}";
    }
}

public class NVIDIA_Warp_Intrinsics
{
    public const int WarpSize = 32;

    public string ShuffleSync(string value, int lane)
    {
        return $"__shfl_sync(0xffffffff, {value}, {lane})";
    }

    public string ShuffleUpSync(string value, int delta)
    {
        return $"__shfl_up_sync(0xffffffff, {value}, {delta})";
    }

    public string ShuffleDownSync(string value, int delta)
    {
        return $"__shfl_down_sync(0xffffffff, {value}, {delta})";
    }

    public string ShuffleXorSync(string value, int mask)
    {
        return $"__shfl_xor_sync(0xffffffff, {value}, {mask})";
    }

    public string BallotSync(string predicate)
    {
        return $"__ballot_sync(0xffffffff, {predicate})";
    }

    public string AllSync(string predicate)
    {
        return $"__all_sync(0xffffffff, {predicate})";
    }

    public string AnySync(string predicate)
    {
        return $"__any_sync(0xffffffff, {predicate})";
    }

    public string ReduceAddSync(string value)
    {
        return $"__reduce_add_sync(0xffffffff, {value})";
    }

    public string ReduceMinSync(string value)
    {
        return $"__reduce_min_sync(0xffffffff, {value})";
    }

    public string ReduceMaxSync(string value)
    {
        return $"__reduce_max_sync(0xffffffff, {value})";
    }

    public string ReduceAndSync(string value)
    {
        return $"__reduce_and_sync(0xffffffff, {value})";
    }

    public string ReduceOrSync(string value)
    {
        return $"__reduce_or_sync(0xffffffff, {value})";
    }

    public string PrefixSumSync(string value)
    {
        return $"__scan_add_sync(0xffffffff, {value})";
    }

    public string PrefixProductSync(string value)
    {
        return $"__scan_mul_sync(0xffffffff, {value})";
    }

    public string MatchAnySync(string value)
    {
        return $"__match_any_sync(0xffffffff, {value})";
    }

    public string ElectSync()
    {
        return $"__nvvm_elect_sync()";
    }

    public string Fence(int scope)
    {
        return $"__nvvm_mem_bar_sync({scope})";
    }

    public string RegRead(string reg)
    {
        return $"__nvvm_read_ptx_special_reg({reg})";
    }

    public string LaneId() => "threadIdx.x % 32";
    public string WarpId() => "threadIdx.x / 32";
    public string LaneCount() => "32";

    public string GenerateTensorCoreLoad(string ptr, string layout, int m, int n)
    {
        return $@"
// WMMA load for tensor core (m={m}, n={n})
if (threadIdx.x < {m} && threadIdx.y < {n}) {{
    ldmatrix.sync.aligned.m8n8.x4.shared::cluster::cta.legacy::{layout}(
        A, [{ptr}], {ptr}_stride);
}}
";
    }

    public string GenerateTensorCoreMma()
    {
        return @"
// WMMA matrix multiply-accumulate
wmma::load_matrix_sync(A, a, wmma::RowMajor);
wmma::load_matrix_sync(B, b, wmma::RowMajor);
wmma::mma_sync(D, A, B, D);
wmma::store_matrix_sync(d, D, wmma::RowMajor);
";
    }

    public string GenerateHFMA(string a, string b, string acc)
    {
        return $"hfma({a}, {b}, {acc})";
    }

    public string GenerateBFMA(string a, string b, string acc)
    {
        return $"bfma({a}, {b}, {acc})";
    }

    public string GenerateDP4A(string a, string b, string acc)
    {
        return $"dp4a({a}, {b}, {acc})";
    }

    public string GeneratePRMT(string src, int sel0, int sel1, int sel2, int sel3)
    {
        int sel = (sel0 & 0xF) | ((sel1 & 0xF) << 4) | ((sel2 & 0xF) << 8) | ((sel3 & 0xF) << 12);
        return $"prmt({src}, 0, {sel})";
    }
}

public class GCN_Intrinsics
{
    public const int WaveSize = 64;

    public string V_READLANE(string v, int lane) => $"v_readlane_b32 {v}, {lane}";
    public string V_WRITELANE(string v, int lane, string val) => $"v_writelane_b32 {v}, {lane}, {val}";

    public string V_ICMP(string dest, string a, string b, string cond)
    {
        return $"v_cmp_{cond}_f32 {dest}, {a}, {b}";
    }

    public string V_CMP(string dest, string a, string b, string cond)
    {
        return $"v_cmp_{cond}_f32 {dest}, {a}, {b}";
    }

    public string V_ADD_F32(string dest, string a, string b) => $"v_add_f32 {dest}, {a}, {b}";
    public string V_SUB_F32(string dest, string a, string b) => $"v_sub_f32 {dest}, {a}, {b}";
    public string V_MUL_F32(string dest, string a, string b) => $"v_mul_f32 {dest}, {a}, {b}";
    public string V_MAD_F32(string dest, string a, string b, string c) => $"v_mac_f32 {dest}, {a}, {b}";

    public string V_MUL_LO_I32(string dest, string a, string b) => $"v_mul_lo_i32 {dest}, {a}, {b}";
    public string V_ADD_CO_U32(string dest, string a, string b) => $"v_add_co_u32 {dest}, {a}, {b}";

    public string S_BFE(string dest, string src, int offset, int width)
    {
        int enc = (offset << 8) | (width - 1);
        return $"s_bfe_u32 {dest}, {src}, {enc}";
    }

    public string S_BFI(string dest, string src, string bits, string pos)
    {
        return $"s_bfi {dest}, {src}, {bits}, {pos}";
    }

    public string S_BCARRY(string a, string b)
    {
        return $"s_cselect_b64 {a}, 1, 0; s_bcnt1_i32_b64 {b}, {a}";
    }

    public string WaveShift1(string v) => $"ds_bpermute(0, {v})";
    public string WaveShiftRight(string v, int n) => $"ds_bpermute({n}, {v})";
    public string WaveShiftLeft(string v, int n) => $"ds_bpermute(64-{n}, {v})";

    public string Permute16(string v, int idx)
    {
        return $"ds_permute_i16({idx}, {v})";
    }

    public string Bpermute16(string v, int idx)
    {
        return $"ds_bpermute_i16({idx}, {v})";
    }
}

public class Console_Intrinsics
{
    public string Xbox_RdNAW(string ptr, int offset) => $"load2({ptr}, {offset})";
    public string Xbox_WrNAW(string ptr, string value, int offset) => $"store2({ptr}, {value}, {offset})";

    public string PS5_WavefrontSize() => "64";
    public string PS5_LdsSize() => "65536";

    public string PS5_DS_BPERMUTE(int sel, string v) => $"ds_bpermute({sel}, {v})";
    public string PS5_DS_PERMUTE(int sel, string v) => $"ds_permute({sel}, {v})";

    public string Nintendo_Switch_WarpSize() => "32";
    public string Nintendo_Switch_LdsSize() => "32768";
}

public class IntrinsicSelector
{
    public static PlatformIntrinsics CreateForVendor(GpuVendor vendor, Architecture arch)
    {
        return new PlatformIntrinsics { Vendor = vendor, Arch = arch };
    }

    public static string DetectVendorAndGenerate(string code, GpuVendor detected)
    {
        var intrin = CreateForVendor(detected, Architecture.Unknown);
        return code;
    }

    public static Architecture AutoDetectArchitecture()
    {
        return Architecture.Unknown;
    }
}