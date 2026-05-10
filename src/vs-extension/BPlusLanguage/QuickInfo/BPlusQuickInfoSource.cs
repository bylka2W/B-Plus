using Microsoft.VisualStudio.Language.Intellisense;
using Microsoft.VisualStudio.Text;
using Microsoft.VisualStudio.Utilities;
using System.Collections.Generic;
using System.ComponentModel.Composition;
using System.Text.RegularExpressions;

namespace BPlusLanguage.QuickInfo
{
    [Export(typeof(IQuickInfoSourceProvider))]
    [ContentType("BPlus")]
    [Name("BPlus QuickInfo")]
    internal class BPlusQuickInfoProvider : IQuickInfoSourceProvider
    {
        public IQuickInfoSource TryCreateQuickInfoSource(ITextBuffer textBuffer)
        {
            return new BPlusQuickInfo();
        }
    }

    internal class BPlusQuickInfo : IQuickInfoSource
    {
        private static readonly Dictionary<string, string> Hints = new()
        {
            ["@export"] = "Export kernel symbol for external linkage.\nUsage: @export(\"name\")",
            ["@vectorized"] = "SIMD vectorization hint.\nUsage: @vectorized(width: 512, fma: true)",
            ["@fuse"] = "Fuse operations into single pass.\nUsage: @fuse(spatial)",
            ["@guard"] = "Guard condition with error raising.\nUsage: @guard(cond, raise: Error(...))",
            ["@activation"] = "Activation function.\nUsage: @activation(relu)",
            ["@entry_point"] = "Declare program entry point.\nUsage: @entry_point(abi: \"platform_default\")",
            ["@pressure"] = "Resource budget constraint.\nUsage: @pressure(cpu: 20%, ram: 512mb)",
            ["@io_async"] = "Async IO prefetching.\nUsage: @io_async(prefetch: 4)",
            ["@specialize"] = "Specialize kernel for concrete dimensions.",
            ["@rewrite"] = "Rewrite rule for convolution implementation.\nUsage: @rewrite(fft_conv)",
            ["@tile"] = "Tiling hint for cache-aware execution.\nUsage: @tile(axis: spatial, hint: cache_fit)",
            ["@temporal_delta"] = "Temporal delta: skip recomputation where motion < threshold.",
            ["@context_cache"] = "Context cache for long input windows.\nUsage: @context_cache(strategy: lru, max_tokens: N)",
            ["@pin"] = "Pin resource to VRAM (eviction immune).\nUsage: @pin(vram, priority: eviction_immune)",
            ["@quant"] = "Quantization to int8 with calibration.\nUsage: @quant(int8, calibrate: percentile(99.9))",
            ["@pipeline"] = "Pipeline depth for double/triple buffering.\nUsage: @pipeline(depth: 3)",
            ["@dx12_queue"] = "DirectX 12 queue type (direct/compute/copy).",
            ["@dx12_resource"] = "DirectX 12 resource declaration with heap and state.",
            ["@dx12_fence_free"] = "Fence-free execution - runtime proves no CPU stall.",
            ["@dx12_hook"] = "Hook into DX12 present chain.\nUsage: @dx12_hook(intercept: present)",
            ["@scanout_direct"] = "Direct scanout buffer - no present blit, no swapchain copy.",
            ["@barrier_free"] = "No resource barriers needed - proven by effect system.",
            ["@frame_extrapolate"] = "Frame extrapolation (predictive mode kills input lag).\nUsage: @frame_extrapolate(mode: predictive)",
            ["@decode_overlap"] = "CPU decode overlaps GPU inference.\nUsage: @decode_overlap(codec: auto, buffers: 3)",
            ["@interleave"] = "Interleave queue execution.\nUsage: @interleave(ratio: 1:1)",
            ["fn"] = "Function/kernel declaration:\nfn name[T: Dim](params) -> ReturnType",
            ["type"] = "Type alias with constraints:\ntype Name[P: Dim] = @attrs tensor<...> where constraint",
            ["let"] = "Immutable variable binding:\nlet name = value",
            ["kernel"] = "Kernel declaration (alias for fn with GPU execution context).",
            ["entry"] = "Entry point declaration:\nentry name(params) -> ExitCode",
            ["run"] = "Execute a kernel:\nrun kernel_name[args](params)",
            ["stream"] = "Infinite data stream:\nstream<Type, shape:[...]>",
            ["tensor"] = "Multi-dimensional array:\ntensor<f32, shape:[H, W, C]>",
            ["Dim"] = "Dimension type parameter for shape polymorphism.",
            ["ExitCode"] = "Program exit code. ExitCode::Ok or ExitCode::Error.",
            ["f32"] = "32-bit IEEE 754 floating point.",
            ["f16"] = "16-bit half-precision float.",
            ["int8"] = "8-bit signed integer (quantized weights).",
            ["u32"] = "32-bit unsigned integer.",
        };

        private bool _disposed;

        public void Dispose() => _disposed = true;

        public void AugmentQuickInfoSession(IQuickInfoSession session, IList<object> quickInfoContent, out ITrackingSpan applicableSpan)
        {
            applicableSpan = null;
            if (_disposed) return;

            var snapshot = session.TextView.TextSnapshot;
            var triggerPoint = session.GetTriggerPoint(snapshot);
            if (triggerPoint == null) return;

            var line = triggerPoint.Value.GetContainingLine();
            string text = line.GetText();
            int pos = triggerPoint.Value.Position - line.Start.Position;

            foreach (Match m in Regex.Matches(text, @"@?\b[a-zA-Z_]\w*\b"))
            {
                if (pos >= m.Index && pos <= m.Index + m.Length && Hints.TryGetValue(m.Value, out string hint))
                {
                    quickInfoContent.Add(hint);
                    applicableSpan = snapshot.CreateTrackingSpan(
                        line.Start.Position + m.Index, m.Length, SpanTrackingMode.EdgeInclusive);
                    return;
                }
            }
        }
    }
}
