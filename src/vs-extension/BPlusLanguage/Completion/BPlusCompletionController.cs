using Microsoft.VisualStudio.Language.Intellisense;
using Microsoft.VisualStudio.Text;
using Microsoft.VisualStudio.Utilities;
using System.Collections.Generic;
using System.ComponentModel.Composition;

namespace BPlusLanguage.Completions
{
    [Export(typeof(ICompletionSourceProvider))]
    [ContentType("BPlus")]
    [Name("BPlus Completion")]
    internal class BPlusCompletionController : ICompletionSourceProvider
    {
        public ICompletionSource TryCreateCompletionSource(ITextBuffer textBuffer)
        {
            return new BPlusCompletionSource();
        }
    }

    internal sealed class BPlusCompletionSource : ICompletionSource
    {
        private static readonly List<Microsoft.VisualStudio.Language.Intellisense.Completion> Keywords = new()
        {
            new Microsoft.VisualStudio.Language.Intellisense.Completion("fn ", "fn", "Function declaration", null, "fn"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("type ", "type", "Type alias declaration", null, "type"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("let ", "let", "Variable binding", null, "let"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("where ", "where", "Constraint clause", null, "where"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("run ", "run", "Execute a kernel", null, "run"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("entry ", "entry", "Entry point", null, "entry"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("return ", "return", "Return", null, "return"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("if ", "if", "Conditional", null, "if"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("else ", "else", "Alternative", null, "else"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("for ", "for", "For loop", null, "for"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("while ", "while", "While loop", null, "while"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("body:", "body:", "Kernel body", null, "body:"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("kernel ", "kernel", "Kernel decl", null, "kernel"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("raise ", "raise", "Raise error", null, "raise"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("pure", "pure", "No side effects", null, "pure"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("reads", "reads", "Read effect", null, "reads"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("writes", "writes", "Write effect", null, "writes"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("ensures ", "ensures", "Postcondition", null, "ensures"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("requires ", "requires", "Precondition", null, "requires"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("effects:", "effects:", "Effects block", null, "effects:"),
        };

        private static readonly List<Microsoft.VisualStudio.Language.Intellisense.Completion> Types = new()
        {
            new Microsoft.VisualStudio.Language.Intellisense.Completion("f32", "f32", "32-bit float", null, "f32"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("f16", "f16", "16-bit float", null, "f16"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("int8", "int8", "8-bit integer", null, "int8"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("u32", "u32", "32-bit unsigned", null, "u32"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("Dim", "Dim", "Dimension type param", null, "Dim"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("ExitCode", "ExitCode", "Exit code", null, "ExitCode"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("tensor", "tensor", "Tensor type", null, "tensor"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("stream", "stream", "Stream type", null, "stream"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("Proof", "Proof", "Proof type", null, "Proof"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("RingBuffer", "RingBuffer", "Ring buffer", null, "RingBuffer"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("KernelQ", "KernelQ", "Quantized weights", null, "KernelQ"),
        };

        private static readonly List<Microsoft.VisualStudio.Language.Intellisense.Completion> Attributes = new()
        {
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@export(\"...\")", "@export", "Export symbol", null, "@export"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@vectorized(...)", "@vectorized", "SIMD vectorize", null, "@vectorized"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@fuse(...)", "@fuse", "Fuse ops", null, "@fuse"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@guard(...)", "@guard", "Guard condition", null, "@guard"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@activation(...)", "@activation", "Activation fn", null, "@activation"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@entry_point(...)", "@entry_point", "Entry point", null, "@entry_point"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@pressure(...)", "@pressure", "Resource budget", null, "@pressure"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@io_async(...)", "@io_async", "Async IO", null, "@io_async"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@specialize(...)", "@specialize", "Specialize dims", null, "@specialize"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@rewrite(...)", "@rewrite", "Rewrite rule", null, "@rewrite"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@tile(...)", "@tile", "Tiling hint", null, "@tile"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@temporal_delta(...)", "@temporal_delta", "Temporal delta", null, "@temporal_delta"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@context_cache(...)", "@context_cache", "Context cache", null, "@context_cache"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@pin(...)", "@pin", "Pin to VRAM", null, "@pin"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@quant(...)", "@quant", "Quantization", null, "@quant"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@pipeline(...)", "@pipeline", "Pipeline depth", null, "@pipeline"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@dx12_queue(...)", "@dx12_queue", "DX12 queue", null, "@dx12_queue"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@dx12_resource(...)", "@dx12_resource", "DX12 resource", null, "@dx12_resource"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@dx12_fence_free", "@dx12_fence_free", "Fence-free", null, "@dx12_fence_free"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@dx12_hook(...)", "@dx12_hook", "DX12 hook", null, "@dx12_hook"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@scanout_direct", "@scanout_direct", "Direct scanout", null, "@scanout_direct"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@barrier_free", "@barrier_free", "No barriers", null, "@barrier_free"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@frame_extrapolate(...)", "@frame_extrapolate", "Frame extrap.", null, "@frame_extrapolate"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@interleave(...)", "@interleave", "Interleave", null, "@interleave"),
            new Microsoft.VisualStudio.Language.Intellisense.Completion("@motion_hint(...)", "@motion_hint", "Motion hint", null, "@motion_hint"),
        };

        public void Dispose() { }

        public void AugmentCompletionSession(ICompletionSession session, IList<CompletionSet> completionSets)
        {
            var snapshot = session.TextView.TextSnapshot;
            var triggerPoint = session.GetTriggerPoint(snapshot);
            if (triggerPoint == null) return;

            var completions = new List<Microsoft.VisualStudio.Language.Intellisense.Completion>();
            completions.AddRange(Keywords);
            completions.AddRange(Types);
            completions.AddRange(Attributes);

            var trackingSpan = snapshot.CreateTrackingSpan(triggerPoint.Value.Position, 0, SpanTrackingMode.EdgeInclusive);
            completionSets.Add(new CompletionSet("BPlus", "B+", trackingSpan, completions, new List<Microsoft.VisualStudio.Language.Intellisense.Completion>()));
        }
    }
}
