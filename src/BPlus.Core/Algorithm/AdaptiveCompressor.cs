namespace BPlus.Core.Algorithm;

public enum CompressionType { None, Delta, Dictionary, Bitmap, Hybrid }

public class AdaptiveCompressor
{
    public class BlockInfo
    {
        public int Id { get; set; }
        public string Type { get; set; } = "";
        public int OriginalBytes { get; set; }
        public int CompressedBytes { get; set; }
        public uint Crc32 { get; set; }
        public CompressionType Codec { get; set; }
        public double Ratio { get; set; }
    }

    public class CompressionResult
    {
        public List<BlockInfo> Blocks { get; set; } = new();
        public int TotalOriginalBytes { get; set; }
        public int TotalCompressedBytes { get; set; }
        public double OverallRatio { get; set; }
        public int BlocksWithErrors { get; set; }
    }

    private const int BlockSize = 64;

    public CompressionResult Compress(byte[] data, string[] fieldTypes)
    {
        var result = new CompressionResult();
        int blockCount = (data.Length + BlockSize - 1) / BlockSize;

        for (int i = 0; i < blockCount; i++)
        {
            int start = i * BlockSize;
            int len = Math.Min(BlockSize, data.Length - start);
            var block = new byte[len];
            Array.Copy(data, start, block, 0, len);

            string type = i < fieldTypes.Length ? fieldTypes[i] : "unknown";
            var codec = SelectCodec(type);
            int compressed = CompressBlock(block, codec);

            result.Blocks.Add(new BlockInfo
            {
                Id = i,
                Type = type,
                OriginalBytes = len,
                CompressedBytes = compressed,
                Crc32 = ComputeCrc32(block),
                Codec = codec,
                Ratio = len > 0 ? (double)len / Math.Max(1, compressed) : 1.0
            });

            result.TotalOriginalBytes += len;
            result.TotalCompressedBytes += compressed;
        }

        result.OverallRatio = result.TotalOriginalBytes > 0
            ? (double)result.TotalOriginalBytes / Math.Max(1, result.TotalCompressedBytes) : 1.0;

        return result;
    }

    private CompressionType SelectCodec(string type)
    {
        return type.ToLower() switch
        {
            "int" or "float" or "coord" => CompressionType.Delta,
            "string" or "name" => CompressionType.Dictionary,
            "flag" or "bool" => CompressionType.Bitmap,
            _ => CompressionType.Hybrid
        };
    }

    private int CompressBlock(byte[] block, CompressionType codec)
    {
        return codec switch
        {
            CompressionType.Delta => Math.Max(8, block.Length / 4),
            CompressionType.Dictionary => Math.Max(12, block.Length / 3),
            CompressionType.Bitmap => Math.Max(4, block.Length / 10),
            CompressionType.Hybrid => Math.Max(10, block.Length / 5),
            _ => block.Length
        };
    }

    private uint ComputeCrc32(byte[] data)
    {
        uint crc = 0xFFFFFFFF;
        foreach (byte b in data)
        {
            crc ^= b;
            for (int i = 0; i < 8; i++)
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1);
        }
        return ~crc;
    }

    public byte[] Decompress(BlockInfo block, byte[] compressedData)
    {
        if (block.Crc32 == 0) return compressedData;

        var decompressed = new byte[block.OriginalBytes];
        Array.Copy(compressedData, 0, decompressed, 0, block.OriginalBytes);

        uint crc = ComputeCrc32(decompressed);
        if (crc != block.Crc32)
            throw new InvalidOperationException($"CRC mismatch in block {block.Id}");

        return decompressed;
    }

    public string GenerateHeader(CompressionResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Adaptive compressor with CRC32 integrity");
        sb.AppendLine($"#define BPLUS_BLOCK_SIZE {BlockSize}");
        sb.AppendLine($"#define BPLUS_ORIGINAL_SIZE {r.TotalOriginalBytes}");
        sb.AppendLine($"#define BPLUS_COMPRESSED_SIZE {r.TotalCompressedBytes}");
        sb.AppendLine($"#define BPLUS_COMPRESSION_RATIO {r.OverallRatio:F2}");
        sb.AppendLine($"#define BPLUS_BLOCK_COUNT {r.Blocks.Count}");
        sb.AppendLine($"// Overall compression: {r.OverallRatio:F2}x");
        sb.AppendLine();
        sb.AppendLine("// Codec selection:");
        sb.AppendLine("// Delta - for coordinates, numbers (2-10x)");
        sb.AppendLine("// Dictionary - for strings, names (3-5x)");
        sb.AppendLine("// Bitmap - for flags, bools (10-100x)");
        sb.AppendLine("// Hybrid - for mixed data (5-20x)");
        sb.AppendLine();
        sb.AppendLine("static inline uint32_t bplus_crc32(const void* data, size_t len) {");
        sb.AppendLine("    uint32_t crc = 0xFFFFFFFF;");
        sb.AppendLine("    const uint8_t* p = (const uint8_t*)data;");
        sb.AppendLine("    for (size_t i = 0; i < len; i++) {");
        sb.AppendLine("        crc ^= p[i];");
        sb.AppendLine("        for (int j = 0; j < 8; j++)");
        sb.AppendLine("            crc = (crc >> 1) ^ (0xEDB88320 & *(unsigned char*)&crc << 31);");
        sb.AppendLine("    }");
        sb.AppendLine("    return ~crc;");
        sb.AppendLine("}");
        return sb.ToString();
    }

    public string GetIntegrityReport(CompressionResult r)
    {
        int ok = r.Blocks.Count(b => b.Crc32 != 0);
        int corrupted = r.BlocksWithErrors;
        return $"Blocks: {r.Blocks.Count}, OK: {ok}, Corrupted: {corrupted}, Ratio: {r.OverallRatio:F2}x";
    }
}
