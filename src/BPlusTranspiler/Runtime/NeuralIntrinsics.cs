using System.Text;

namespace BPlusTranspiler.Runtime;

public enum TileConfig
{
    Tmm8x8, Tmm16x16, Tmm32x8, Tmm8x32, Tmm16x32, Tmm32x16
}

public enum MatrixDataType
{
    Fp32, Bf16, Int8
}

public class AmxTileRegisters
{
    public int Rows { get; set; }
    public int Cols { get; set; }
    public MatrixDataType DataType { get; set; } = MatrixDataType.Fp32;
    public int TileCount { get; set; } = 8;
}

public static class NeuralIntrinsics
{
    private static readonly Dictionary<TileConfig, (int rows, int cols)> TileShapes = new()
    {
        [TileConfig.Tmm8x8] = (8, 8),
        [TileConfig.Tmm16x16] = (16, 16),
        [TileConfig.Tmm32x8] = (32, 8),
        [TileConfig.Tmm8x32] = (8, 32),
        [TileConfig.Tmm16x32] = (16, 32),
        [TileConfig.Tmm32x16] = (32, 16),
    };

    public static AmxTileRegisters DetectAmxSupport()
    {
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo("wmic", "cpu get features")
            {
                RedirectStandardOutput = true, UseShellExecute = false,
                CreateNoWindow = true
            };
            using var p = System.Diagnostics.Process.Start(psi);
            var output = p?.StandardOutput.ReadToEnd();
            p?.WaitForExit(500);

            bool hasAMX = output?.Contains("AMX", StringComparison.OrdinalIgnoreCase) == true;
            if (hasAMX)
            {
                return new AmxTileRegisters { Rows = 16, Cols = 64, DataType = MatrixDataType.Bf16, TileCount = 8 };
            }
        }
        catch { }

        return new AmxTileRegisters { Rows = 0, Cols = 0, DataType = MatrixDataType.Fp32, TileCount = 0 };
    }

    public static string EmitTileLoad(string tile, ulong address)
    {
        return $"\ttileloadd {tile}, [{(long)address:X}] ; load tile from memory";
    }

    public static string EmitTileStore(string tile, ulong address)
    {
        return $"\tmov {tile} to [{(long)address:X}] ; store tile to memory";
    }

    public static string EmitTdpBf16ps(string dst, string src1, string src2)
    {
        return $"\ttdpbf16ps {dst}, {src1}, {src2} ; AMX BF16 dot-product";
    }

    public static string EmitTmmMul(string dst, string src1, string src2, TileConfig cfg)
    {
        var (k, n) = TileShapes[cfg];
        return $"\t; AMX tile multiply: {dst} += {src1} × {src2} [{k}x{n}]";
    }

    public static string GenerateAmxKernel(AmxTileRegisters tiles, string kernelName)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"; AMX kernel: {kernelName}");
        sb.AppendLine($"; Tile config: {tiles.Rows}x{tiles.Cols} {tiles.DataType} ({tiles.TileCount} tiles)");
        sb.AppendLine();
        sb.AppendLine($"\t; Tile config load");
        sb.AppendLine($"\t; ldtilecfg [rsp + tile_config_offset]");
        sb.AppendLine();
        sb.AppendLine($"\t; Tile loads");
        sb.AppendLine($"\t; tileloadd tmm0, [rax]");
        sb.AppendLine($"\t; tileloadd tmm1, [rbx]");
        sb.AppendLine($"\t; tileloadd tmm2, [rcx]");
        sb.AppendLine();
        sb.AppendLine($"\t; Matrix multiply (BF16)");
        sb.AppendLine($"\t; tdpbf16ps tmm2, tmm0, tmm1");
        sb.AppendLine();
        sb.AppendLine($"\t; Tile store");
        sb.AppendLine($"\t; tilestore [rdx], tmm2");
        return sb.ToString();
    }

    public static string GenerateAmxHeader()
    {
        return """
#ifndef BPLUS_AMX_H
#define BPLUS_AMX_H

#include <stdint.h>

// Tile register configuration structure (64 bytes)
typedef struct __attribute__((packed)) {
    uint8_t  palette;
    uint8_t  start_row;
    uint8_t  reserved[14];
    uint16_t tile0_colsb;
    uint16_t tile1_colsb;
    uint16_t tile2_colsb;
    uint16_t tile3_colsb;
    uint16_t tile4_colsb;
    uint16_t tile5_colsb;
    uint16_t tile6_colsb;
    uint16_t tile7_colsb;
    uint32_t reserved2[8];
} tile_config_t;

// Tile register state
typedef uint8_t tmm_row_t[64];
typedef struct {
    tmm_row_t row[16];  // up to 16 rows per tile
} tile_t;

#ifdef __cplusplus
extern "C" {
#endif

// Tile operations (AMX intrinsics)
static inline void tile_loadd(void* dst, const void* base, int stride) {
    asm volatile("tileloadd (%1,%2), %0" : "=tmm"(*(tile_t*)dst) : "r"(base), "r"(stride));
}

static inline void tile_stored(void* base, int stride, const void* src) {
    asm volatile("tilestored %2, (%0,%1)" : : "r"(base), "r"(stride), "tmm"(*(tile_t*)src));
}

#ifdef __cplusplus
}
#endif

#endif // BPLUS_AMX_H
""";
    }

    public static string Report(AmxTileRegisters tiles)
    {
        if (tiles.TileCount == 0)
            return "AMX: Not detected on this CPU";
        return $"""
╔══════════════════════════════════════════════╗
║          AMX NEURAL INTRINSICS              ║
╚══════════════════════════════════════════════╝
Tile size:   {tiles.Rows}x{tiles.Cols}
Tile count:  {tiles.TileCount}
Data type:   {tiles.DataType}
Kernel:      AMX TDP BF16 matmul (16x64x16)
""";
    }
}
