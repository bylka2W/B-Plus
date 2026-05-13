using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Parser;

public class MetalParser
{
    private string _src = "";
    private int _pos;

    public List<MetalBlock> ParseMetalBlocks(string source)
    {
        _src = source;
        _pos = 0;
        var blocks = new List<MetalBlock>();

        while (_pos < _src.Length)
        {
            SkipWs();
            if (_pos >= _src.Length) break;

            if (_src[_pos] == '@' && Peek("@metal"))
            {
                _pos += 6; // skip @metal
                SkipWs();
                if (_pos < _src.Length && _src[_pos] == '{')
                {
                    var block = ParseMetalBlock();
                    if (block != null) blocks.Add(block);
                }
                else
                {
                    // @metal on state/kernel — inline annotation
                    var block = ParseInlineMetal();
                    if (block != null) blocks.Add(block);
                }
            }
            else if (_src[_pos] == '@')
            {
                // Process other top-level metal annotations: @tier, @register, etc.
                var annot = ParseMetalAnnotation();
                if (annot != null)
                {
                    var block = new MetalBlock();
                    ApplyAnnotation(block.Config, annot);
                    blocks.Add(block);
                }
            }
            else
            {
                _pos++;
            }
        }

        return blocks;
    }

    private MetalBlock? ParseMetalBlock()
    {
        Expect("{");
        var block = new MetalBlock();
        SkipWs();

        while (_pos < _src.Length && _src[_pos] != '}')
        {
            if (_src[_pos] == '@')
            {
                var annot = ParseMetalAnnotation();
                if (annot != null)
                    ApplyAnnotation(block.Config, annot);
            }
            else if (Peek("state "))
            {
                Expect("state ");
                block.TargetState = ParseWord();
            }
            else if (Peek("kernel "))
            {
                Expect("kernel ");
                block.TargetKernel = ParseWord();
            }
            else
            {
                _pos++;
            }
            SkipWs();
        }

        if (_pos < _src.Length) _pos++; // skip closing }
        return block;
    }

    private MetalBlock? ParseInlineMetal()
    {
        var block = new MetalBlock();
        SkipWs();

        // Parse annotations until state/kernel keyword
        while (_pos < _src.Length && _src[_pos] == '@')
        {
            var annot = ParseMetalAnnotation();
            if (annot != null)
                ApplyAnnotation(block.Config, annot);
            SkipWs();
        }

        if (Peek("state "))
        {
            Expect("state ");
            block.TargetState = ParseWord();
        }
        else if (Peek("kernel "))
        {
            Expect("kernel ");
            block.TargetKernel = ParseWord();
        }

        return block;
    }

    private MetalAnnotation? ParseMetalAnnotation()
    {
        if (_pos >= _src.Length || _src[_pos] != '@')
            return null;

        _pos++;
        var name = ParseWord();
        var annot = new MetalAnnotation { Name = name };

        SkipWs();
        if (_pos < _src.Length && _src[_pos] == '(')
        {
            _pos++;
            SkipWs();

            while (_pos < _src.Length && _src[_pos] != ')')
            {
                // Check for numeric positional value
                if (char.IsDigit(_src[_pos]) || _src[_pos] == '-' || _src[_pos] == '.')
                {
                    var numVal = ParseValue();
                    annot.Args["_val"] = numVal;
                }
                else
                {
                    var key = ParseWord();
                    SkipWs();
                    if (_pos < _src.Length && _src[_pos] == ':')
                    {
                        _pos++;
                        SkipWs();
                        var val = ParseValue();
                        annot.Args[key] = val;
                    }
                    else
                    {
                        annot.Args["_val"] = key;
                    }
                }

                SkipWs();
                if (_pos < _src.Length && _src[_pos] == ',')
                {
                    _pos++;
                    SkipWs();
                }
            }

            if (_pos < _src.Length) _pos++; // skip )
        }

        return annot;
    }

    private void ApplyAnnotation(MetalConfig config, MetalAnnotation annot)
    {
        switch (annot.Name)
        {
            case "tier":
                if (annot.Args.TryGetValue("_val", out var tierVal))
                    config.Tier = ParseTier(tierVal);
                break;
            case "register":
                if (annot.Args.TryGetValue("_val", out var regVal))
                    config.Register = regVal;
                break;
            case "zmm":
                if (annot.Args.TryGetValue("_val", out var zmmVal) && int.TryParse(zmmVal, out var zmmI))
                    config.Zmm = zmmI;
                break;
            case "mask":
                if (annot.Args.TryGetValue("_val", out var maskVal))
                    config.Mask = maskVal;
                break;
            case "fusion":
                if (annot.Args.TryGetValue("_val", out var fusionVal))
                    config.FusionPairs.Add(fusionVal);
                break;
            case "section":
                if (annot.Args.TryGetValue("_val", out var sectionVal))
                    config.Section = sectionVal.Trim('"');
                break;
            case "gateway":
                if (annot.Args.TryGetValue("_val", out var gwVal))
                    config.Gateway = ParseTier(gwVal);
                break;
            case "prefetch":
                if (annot.Args.TryGetValue("_val", out var pfVal))
                    config.PrefetchHint = pfVal;
                break;
            case "align":
                if (annot.Args.TryGetValue("_val", out var alignVal) && int.TryParse(alignVal, out var alignI))
                    config.Alignment = alignI;
                break;
            case "packed":
                config.Packed = true;
                break;
            case "data_tier":
                if (annot.Args.TryGetValue("_val", out var dtVal))
                    config.DataTier = ParseTier(dtVal);
                break;
            case "hot_path":
                config.HotPath = true;
                break;
            case "critical_size":
                if (annot.Args.TryGetValue("_val", out var csVal) && int.TryParse(csVal, out var csI))
                    config.CriticalSize = csI;
                break;
            case "byte_pack":
                if (annot.Args.TryGetValue("_val", out var bpVal))
                {
                    foreach (var hex in bpVal.Split(','))
                    {
                        if (byte.TryParse(hex.Trim().TrimStart("0x".ToCharArray()), System.Globalization.NumberStyles.HexNumber, null, out var b))
                            config.BytePack.Add(b);
                    }
                }
                break;
            case "field":
                if (annot.Args.TryGetValue("_val", out var fiVal) && int.TryParse(fiVal, out var fiI))
                    config.FieldIndex = fiI;
                break;
            case "metal":
                config.Enabled = true;
                break;
            case "numa":
                if (annot.Args.TryGetValue("_val", out var numaVal))
                {
                    if (int.TryParse(numaVal, out var numaNode))
                        config.NumaNode = numaNode;
                    else
                        config.NumaPolicy = numaVal;
                }
                break;
            case "store_forward_safe":
                config.StoreForwardSafe = true;
                break;
            case "muarch":
                if (annot.Args.TryGetValue("_val", out var muVal))
                    config.MuarchProfile = muVal;
                break;
            case "ilp_max":
                if (annot.Args.TryGetValue("_val", out var ilpVal) && int.TryParse(ilpVal, out var ilpI))
                    config.IlpMax = ilpI;
                break;
        }
    }

    private static MemoryTier ParseTier(string s)
    {
        return s.ToLower() switch
        {
            "0" or "l0" or "mop" or "ucode" => MemoryTier.L0,
            "1" or "l1" or "l1-i" or "l1-d" => MemoryTier.L1,
            "2" or "l2" => MemoryTier.L2,
            "3" or "l3" => MemoryTier.L3,
            _ => MemoryTier.Ram
        };
    }

    // --- Helpers ---

    private string ParseWord()
    {
        SkipWs();
        int start = _pos;
        while (_pos < _src.Length && (char.IsLetterOrDigit(_src[_pos]) || _src[_pos] == '_' || _src[_pos] == '.' || _src[_pos] == '+'))
            _pos++;
        if (_pos == start) throw new ParseException($"Expected identifier at position {_pos}");
        return _src[start.._pos];
    }

    private string ParseValue()
    {
        if (_pos < _src.Length && _src[_pos] == '"')
        {
            _pos++;
            int start = _pos;
            while (_pos < _src.Length && _src[_pos] != '"')
                _pos++;
            var val = _src[start.._pos];
            if (_pos < _src.Length) _pos++;
            return val;
        }

        int s = _pos;
        if (_pos < _src.Length && _src[_pos] == '-') _pos++;
        while (_pos < _src.Length && (char.IsLetterOrDigit(_src[_pos]) || _src[_pos] == '_' || _src[_pos] == '.' || _src[_pos] == 'x' || _src[_pos] == '+'))
            _pos++;
        return _src[s.._pos];
    }

    private void SkipWs()
    {
        while (_pos < _src.Length && char.IsWhiteSpace(_src[_pos]))
            _pos++;
    }

    private bool Peek(string s)
    {
        if (_pos + s.Length > _src.Length) return false;
        for (int i = 0; i < s.Length; i++)
            if (_src[_pos + i] != s[i]) return false;
        return true;
    }

    private void Expect(string s)
    {
        SkipWs();
        if (_pos + s.Length > _src.Length || _src[_pos..(_pos + s.Length)] != s)
            throw new ParseException($"Expected '{s}' at position {_pos}");
        _pos += s.Length;
    }
}
