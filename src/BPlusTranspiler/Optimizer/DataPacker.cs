using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Optimizer;

public class DataSection
{
    public string Section { get; set; } = ".data";
    public int Alignment { get; set; } = 64;
    public int TotalSize { get; set; }
    public List<DataField> Fields { get; } = new();
}

public class DataField
{
    public string Name { get; set; } = "";
    public string Type { get; set; } = "";
    public int Size { get; set; } = 8;
    public int Offset { get; set; }
    public int UsageOrder { get; set; }
}

public static class DataPacker
{
    public static List<DataSection> Pack(ProgramNode program, List<MetalBlock> blocks)
    {
        var sections = new List<DataSection>();

        var l1Section = new DataSection
        {
            Section = ".data.hot.L1",
            Alignment = 64
        };
        var l2Section = new DataSection
        {
            Section = ".data.warm.L2",
            Alignment = 128
        };
        var l3Section = new DataSection
        {
            Section = ".data.cold.L3",
            Alignment = 256
        };

        var blockMap = new Dictionary<string, MetalConfig>();
        foreach (var b in blocks)
        {
            if (b.TargetState != null)
                blockMap[b.TargetState] = b.Config;
        }

        foreach (var state in program.States)
        {
            if (blockMap.TryGetValue(state.Name, out var cfg))
            {
                var tier = cfg.DataTier ?? MemoryTier.L2;
                var section = tier switch
                {
                    MemoryTier.L1 => l1Section,
                    MemoryTier.L2 => l2Section,
                    _ => l3Section
                };

                int order = 0;
                foreach (var v in state.Variables)
                {
                    int size = EstimateTypeSize(v.Type);
                    section.Fields.Add(new DataField
                    {
                        Name = $"{state.Name}_{v.Name}",
                        Type = v.Type,
                        Size = size,
                        UsageOrder = cfg.FieldIndex ?? order,
                        Offset = section.TotalSize
                    });
                    section.TotalSize += PadToAlign(size, 8);
                    section.TotalSize = PadToAlign(section.TotalSize, section.Alignment);
                    order++;
                }
            }
            else
            {
                foreach (var v in state.Variables)
                {
                    int size = EstimateTypeSize(v.Type);
                    l2Section.Fields.Add(new DataField
                    {
                        Name = $"{state.Name}_{v.Name}",
                        Type = v.Type,
                        Size = size,
                        UsageOrder = 0,
                        Offset = l2Section.TotalSize
                    });
                    l2Section.TotalSize += PadToAlign(size, 8);
                }
            }
        }

        // Sort by usage order
        l1Section.Fields.Sort((a, b) => a.UsageOrder.CompareTo(b.UsageOrder));
        l2Section.Fields.Sort((a, b) => a.UsageOrder.CompareTo(b.UsageOrder));
        l3Section.Fields.Sort((a, b) => a.UsageOrder.CompareTo(b.UsageOrder));

        sections.Add(l1Section);
        sections.Add(l2Section);
        sections.Add(l3Section);

        return sections;
    }

    private static int EstimateTypeSize(string type)
    {
        return type.ToLower() switch
        {
            "int" or "float" or "u32" => 4,
            "double" or "i64" or "u64" or "int64" => 8,
            "bool" or "byte" or "u8" or "i8" => 1,
            "short" or "i16" or "u16" => 2,
            _ => 8 // pointer-sized default
        };
    }

    private static int PadToAlign(int offset, int align)
    {
        int rem = offset % align;
        return rem == 0 ? offset : offset + (align - rem);
    }
}
