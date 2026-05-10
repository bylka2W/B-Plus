using Microsoft.VisualStudio.Language.Intellisense;
using Microsoft.VisualStudio.Text;
using System.Collections.Generic;

namespace BPlusLanguage.Completion
{
    internal sealed class BPlusCompletionSource : ICompletionSource
    {
        private static readonly List<Completion> Keywords = new()
        {
            new Completion("fn ", "fn", "Function declaration", null, "fn"),
            new Completion("type ", "type", "Type alias declaration", null, "type"),
            new Completion("let ", "let", "Variable binding", null, "let"),
            new Completion("where ", "where", "Constraint clause", null, "where"),
            new Completion("run ", "run", "Execute a kernel", null, "run"),
            new Completion("entry ", "entry", "Entry point declaration", null, "entry"),
            new Completion("return ", "return", "Return from function", null, "return"),
            new Completion("if ", "if", "Conditional branch", null, "if"),
            new Completion("else ", "else", "Alternative branch", null, "else"),
            new Completion("for ", "for", "For loop", null, "for"),
            new Completion("while ", "while", "While loop", null, "while"),
            new Completion("body:", "body:", "Kernel body block", null, "body:"),
            new Completion("kernel ", "kernel", "Kernel declaration", null, "kernel"),
            new Completion("raise ", "raise", "Raise error", null, "raise"),
            new Completion("pure", "pure", "No side effects", null, "pure"),
            new Completion("reads", "reads", "Read effect", null, "reads"),
            new Completion("writes", "writes", "Write effect", null, "writes"),
            new Completion("ensures ", "ensures", "Postcondition", null, "ensures"),
            new Completion("requires ", "requires", "Precondition", null, "requires"),
            new Completion("effects:", "effects:", "Effects block", null, "effects:"),
        };

        private static readonly List<Completion> Types = new()
        {
            new Completion("f32", "f32", "32-bit float", null, "f32"),
            new Completion("f16", "f16", "16-bit float", null, "f16"),
            new Completion("int8", "int8", "8-bit integer", null, "int8"),
            new Completion("u32", "u32", "32-bit unsigned integer", null, "u32"),
            new Completion("Dim", "Dim", "Dimension type parameter", null, "Dim"),
            new Completion("ExitCode", "ExitCode", "Program exit code", null, "ExitCode"),
            new Completion("tensor", "tensor", "Tensor type", null, "tensor"),
            new Completion("stream", "stream", "Stream type", null, "stream"),
            new Completion("Proof", "Proof", "Proof type for guarantees", null, "Proof"),
            new Completion("RingBuffer", "RingBuffer", "Ring buffer type", null, "RingBuffer"),
            new Completion("KernelQ", "KernelQ", "Quantized kernel weights", null, "KernelQ"),
            new Completion("KernelW", "KernelW", "Float kernel weights", null, "KernelW"),
        };

        private static readonly List<Completion> Attributes = new()
        {
            new Completion("@export", "@export(\"...\")", "Export kernel symbol", null, "@export"),
            new Completion("@vectorized", "@vectorized(...)", "SIMD vectorization", null, "@vectorized"),
            new Completion("@fuse", "@fuse(...)", "Fuse operations", null, "@fuse"),
            new Completion("@guard", "@guard(...)", "Guard condition", null, "@guard"),
            new Completion("@activation", "@activation(...)", "Activation function", null, "@activation"),
            new Completion("@entry_point", "@entry_point(...)", "Entry point", null, "@entry_point"),
            new Completion("@pressure", "@pressure(...)", "Resource budget", null, "@pressure"),
            new Completion("@io_async", "@io_async(...)", "Async IO", null, "@io_async"),
            new Completion("@specialize", "@specialize(...)", "Specialize dims", null, "@specialize"),
            new Completion("@rewrite", "@rewrite(...)", "Rewrite rule", null, "@rewrite"),
            new Completion("@tile", "@tile(...)", "Tiling hint", null, "@tile"),
            new Completion("@temporal_delta", "@temporal_delta(...)", "Temporal delta", null, "@temporal_delta"),
            new Completion("@context_cache", "@context_cache(...)", "Context cache", null, "@context_cache"),
            new Completion("@pin", "@pin(...)", "Pin to VRAM", null, "@pin"),
            new Completion("@quant", "@quant(...)", "Quantization", null, "@quant"),
            new Completion("@pipeline", "@pipeline(...)", "Pipeline depth", null, "@pipeline"),
            new Completion("@dx12_queue", "@dx12_queue(...)", "DX12 queue", null, "@dx12_queue"),
            new Completion("@dx12_resource", "@dx12_resource(...)", "DX12 resource", null, "@dx12_resource"),
            new Completion("@dx12_fence_free", "@dx12_fence_free", "Fence-free", null, "@dx12_fence_free"),
            new Completion("@dx12_hook", "@dx12_hook(...)", "DX12 hook", null, "@dx12_hook"),
            new Completion("@scanout_direct", "@scanout_direct", "Direct scanout", null, "@scanout_direct"),
            new Completion("@barrier_free", "@barrier_free", "No barriers", null, "@barrier_free"),
            new Completion("@frame_extrapolate", "@frame_extrapolate(...)", "Frame extrap.", null, "@frame_extrapolate"),
            new Completion("@decode_overlap", "@decode_overlap(...)", "Decode overlap", null, "@decode_overlap"),
            new Completion("@interleave", "@interleave(...)", "Interleave", null, "@interleave"),
            new Completion("@motion_hint", "@motion_hint(...)", "Motion hint", null, "@motion_hint"),
        };

        public void Dispose() { }

        public void AugmentCompletionSession(ICompletionSession session, IList<CompletionSet> completionSets)
        {
            var snapshot = session.TextView.TextSnapshot;
            var triggerPoint = session.GetTriggerPoint(snapshot);
            if (triggerPoint == null) return;

            var completions = new List<Completion>();
            completions.AddRange(Keywords);
            completions.AddRange(Types);
            completions.AddRange(Attributes);

            var trackingSpan = snapshot.CreateTrackingSpan(triggerPoint.Value.Position, 0, SpanTrackingMode.EdgeInclusive);
            completionSets.Add(new CompletionSet("BPlus", "B+", trackingSpan, completions, new List<Completion>()));
        }
    }
}
