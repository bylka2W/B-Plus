using System.Text;

namespace BPlusTranspiler.Debugger;

public class GraphicsDebugger
{
    readonly Dictionary<string, object> _memorySnapshots = new();
    readonly List<string> _breakpoints = new();
    readonly Dictionary<string, List<float>> _watchExpressions = new();
    bool _isPaused;
    string _currentShader = "";
    int _pixelX, _pixelY;
    int _frameCount;
    bool _stepMode;

    public void SetPixelBreakpoint(int x, int y, string shader)
    {
        _pixelX = x; _pixelY = y; _currentShader = shader;
        _breakpoints.Add($"pixel:{x},{y}:{shader}");
    }

    public void SetInstructionBreakpoint(string shader, int line)
    {
        _breakpoints.Add($"line:{line}:{shader}");
    }

    public void AddWatch(string expr)
    {
        if (!_watchExpressions.ContainsKey(expr))
            _watchExpressions[expr] = new List<float>();
    }

    public void CaptureFrameBuffer(string name, float[] pixels, int w, int h, int channels)
    {
        _memorySnapshots[$"frame:{_frameCount}:{name}"] = new FrameSnapshot { Pixels = pixels, Width = w, Height = h, Channels = channels, Timestamp = DateTime.UtcNow };
    }

    public void CaptureTexture(string name, float[] data, int w, int h, string format)
    {
        _memorySnapshots[$"tex:{name}"] = new TextureSnapshot { Data = data, Width = w, Height = h, Format = format, Frame = _frameCount };
    }

    public void CaptureDepthBuffer(string name, float[] depth, int w, int h)
    {
        _memorySnapshots[$"depth:{name}"] = new DepthBufferSnapshot { Data = depth, Width = w, Height = h, Frame = _frameCount };
    }

    public void CaptureMotionVectors(string name, float[] vectors, int w, int h)
    {
        _memorySnapshots[$"motion:{name}"] = new MotionVectorSnapshot { Vectors = vectors, Width = w, Height = h, Frame = _frameCount };
    }

    public void BreakOnCondition(Func<float[], bool> condition, string label)
    {
        _breakpoints.Add($"cond:{label}");
    }

    public bool Step()
    {
        _stepMode = true;
        _isPaused = true;
        return true;
    }

    public bool Continue()
    {
        _stepMode = false;
        _isPaused = false;
        return true;
    }

    public string InspectPixel(int x, int y)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"=== Pixel Inspect @ ({x}, {y}) ===");
        foreach (var kvp in _memorySnapshots)
        {
            if (kvp.Value is FrameSnapshot fs && x < fs.Width && y < fs.Height)
            {
                int idx = (y * fs.Width + x) * fs.Channels;
                if (idx >= 0 && idx + fs.Channels <= fs.Pixels.Length)
                {
                    sb.AppendLine($"{kvp.Key}: R={fs.Pixels[idx]}, G={fs.Pixels[idx + 1]}, B={fs.Pixels[idx + 2]}{(fs.Channels > 3 ? $", A={fs.Pixels[idx + 3]}" : "")}");
                }
            }
        }
        return sb.ToString();
    }

    public string InspectState(string shaderName, int line)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"=== Shader: {shaderName}, Line: {line} ===");
        foreach (var kvp in _watchExpressions)
        {
            sb.AppendLine($"watch:{kvp.Key} = [{(kvp.Value.Count > 0 ? string.Join(",", kvp.Value.TakeLast(10)) : "N/A")}]");
        }
        return sb.ToString();
    }

    public string DumpAllResources()
    {
        var sb = new StringBuilder();
        sb.AppendLine($"=== Frame #{_frameCount} Resources ===");
        foreach (var kvp in _memorySnapshots)
            sb.AppendLine(kvp.Key);
        return sb.ToString();
    }

    public float[] ReadPixelHistory(int x, int y, int frames)
    {
        var result = new List<float>();
        for (int f = Math.Max(0, _frameCount - frames); f <= _frameCount; f++)
        {
            var key = $"frame:{f}:main";
            if (_memorySnapshots.TryGetValue(key, out var snap) && snap is FrameSnapshot fs)
            {
                int idx = (y * fs.Width + x) * fs.Channels;
                if (idx >= 0 && idx < fs.Pixels.Length) result.AddRange(fs.Pixels.Skip(idx).Take(fs.Channels));
            }
        }
        return result.ToArray();
    }

    public string GenerateReport()
    {
        var sb = new StringBuilder();
        sb.AppendLine($"B+ Graphics Debugger Report");
        sb.AppendLine($"Frame: {_frameCount}");
        sb.AppendLine($"Paused: {_isPaused}");
        sb.AppendLine($"Breakpoints: {_breakpoints.Count}");
        sb.AppendLine($"Resources captured: {_memorySnapshots.Count}");
        sb.AppendLine($"Watches: {_watchExpressions.Count}");
        return sb.ToString();
    }

    public void NewFrame() => _frameCount++;
    public bool IsPaused => _isPaused;
    public int FrameCount => _frameCount;
    public bool StepMode => _stepMode;
    public List<string> Breakpoints => _breakpoints;
    public Dictionary<string, object> MemorySnapshots => _memorySnapshots;

    class FrameSnapshot
    {
        public float[] Pixels = Array.Empty<float>();
        public int Width, Height, Channels;
        public DateTime Timestamp;
    }
    class TextureSnapshot
    {
        public float[] Data = Array.Empty<float>();
        public int Width, Height;
        public string Format = "";
        public int Frame;
    }
    class DepthBufferSnapshot
    {
        public float[] Data = Array.Empty<float>();
        public int Width, Height;
        public int Frame;
    }
    class MotionVectorSnapshot
    {
        public float[] Vectors = Array.Empty<float>();
        public int Width, Height;
        public int Frame;
    }
}