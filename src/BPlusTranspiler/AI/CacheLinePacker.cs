using BPlusTranspiler.Ast;

namespace BPlusTranspiler.AI;

public class CacheLinePacker
{
    public class FieldInfo
    {
        public string Name { get; set; } = "";
        public int SizeBytes { get; set; }
        public int AccessFrequency { get; set; }
        public bool UsedWith { get; set; }
        public string[] FieldGroup { get; set; } = [];
    }

    public class PackingResult
    {
        public List<FieldInfo> PackedFields { get; set; } = new();
        public int OriginalSize { get; set; }
        public int PackedSize { get; set; }
        public int CacheLineCount { get; set; }
        public double EstSpeedup { get; set; }
    }

    private const int CacheLineSize = 64;

    public PackingResult Pack(ProgramNode program)
    {
        var result = new PackingResult();

        foreach (var state in program.States)
        {
            var fields = new List<FieldInfo>();
            foreach (var v in state.Variables)
            {
                int size = EstimateSize(v.Type);
                int freq = state.Transitions.Count + state.Actions.Count;
                fields.Add(new FieldInfo { Name = v.Name, SizeBytes = size, AccessFrequency = freq });
                result.OriginalSize += size;
            }

            var sorted = fields.OrderByDescending(f => f.AccessFrequency).ToList();
            var packed = new List<FieldInfo>();
            int lineOffset = 0;

            foreach (var f in sorted)
            {
                if (lineOffset + f.SizeBytes > CacheLineSize)
                {
                    lineOffset = 0;
                }
                packed.Add(f);
                lineOffset += f.SizeBytes;
            }

            result.PackedFields.AddRange(packed);
        }

        result.PackedSize = result.PackedFields.Sum(f => f.SizeBytes);
        result.CacheLineCount = (int)Math.Ceiling((double)result.PackedSize / CacheLineSize);
        result.EstSpeedup = result.OriginalSize > 0 ? (double)result.OriginalSize / Math.Max(1, result.PackedSize) : 1.0;

        return result;
    }

    private int EstimateSize(string type)
    {
        return type.ToLower() switch
        {
            "int" or "i32" or "float" => 4,
            "long" or "i64" or "double" => 8,
            "byte" or "i8" => 1,
            "short" or "i16" => 2,
            _ => 8
        };
    }

    public string GenerateHeader(PackingResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Cache line packer");
        sb.AppendLine($"#define BPLUS_CACHE_LINE_SIZE {CacheLineSize}");
        sb.AppendLine($"#define BPLUS_PACKED_FIELDS {r.PackedFields.Count}");
        sb.AppendLine($"#define BPLUS_ORIGINAL_SIZE {r.OriginalSize}");
        sb.AppendLine($"#define BPLUS_PACKED_SIZE {r.PackedSize}");
        sb.AppendLine($"// Est speedup: {r.EstSpeedup:F2}x");
        return sb.ToString();
    }
}