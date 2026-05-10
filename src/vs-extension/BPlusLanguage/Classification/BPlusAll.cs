using Microsoft.VisualStudio.Text;
using Microsoft.VisualStudio.Text.Classification;
using Microsoft.VisualStudio.Utilities;
using System;
using System.Collections.Generic;
using System.ComponentModel.Composition;
using System.Text.RegularExpressions;
using System.Windows.Media;

namespace BPlusLanguage.Classification
{
    internal static class BPlusTypes
    {
        public const string Keyword = "BPlusKeyword";
        public const string Type = "BPlusType";
        public const string Attribute = "BPlusAttribute";
        public const string Comment = "BPlusComment";
        public const string StringLiteral = "BPlusString";
        public const string Number = "BPlusNumber";
        public const string Operator = "BPlusOperator";
        public const string Function = "BPlusFunction";
    }

    [Export(typeof(ClassificationTypeDefinition)), Name(BPlusTypes.Keyword)]
    internal static class _Keyword { }
    [Export(typeof(ClassificationTypeDefinition)), Name(BPlusTypes.Type)]
    internal static class _Type { }
    [Export(typeof(ClassificationTypeDefinition)), Name(BPlusTypes.Attribute)]
    internal static class _Attr { }
    [Export(typeof(ClassificationTypeDefinition)), Name(BPlusTypes.Comment)]
    internal static class _Comment { }
    [Export(typeof(ClassificationTypeDefinition)), Name(BPlusTypes.StringLiteral)]
    internal static class _String { }
    [Export(typeof(ClassificationTypeDefinition)), Name(BPlusTypes.Number)]
    internal static class _Number { }
    [Export(typeof(ClassificationTypeDefinition)), Name(BPlusTypes.Operator)]
    internal static class _Op { }
    [Export(typeof(ClassificationTypeDefinition)), Name(BPlusTypes.Function)]
    internal static class _Func { }

    [Export(typeof(EditorFormatDefinition)), ClassificationType(ClassificationTypeNames = BPlusTypes.Keyword), Name("BPlusKeyword"), UserVisible(true), Order(Before = Priority.Default)]
    internal sealed class KwFmt : ClassificationFormatDefinition { public KwFmt() => ForegroundColor = Colors.DodgerBlue; }

    [Export(typeof(EditorFormatDefinition)), ClassificationType(ClassificationTypeNames = BPlusTypes.Type), Name("BPlusType"), UserVisible(true), Order(Before = Priority.Default)]
    internal sealed class TyFmt : ClassificationFormatDefinition { public TyFmt() => ForegroundColor = Colors.MediumTurquoise; }

    [Export(typeof(EditorFormatDefinition)), ClassificationType(ClassificationTypeNames = BPlusTypes.Attribute), Name("BPlusAttribute"), UserVisible(true), Order(Before = Priority.Default)]
    internal sealed class AtFmt : ClassificationFormatDefinition { public AtFmt() => ForegroundColor = Colors.OrangeRed; }

    [Export(typeof(EditorFormatDefinition)), ClassificationType(ClassificationTypeNames = BPlusTypes.Comment), Name("BPlusComment"), UserVisible(true), Order(Before = Priority.Default)]
    internal sealed class CmFmt : ClassificationFormatDefinition { public CmFmt() => ForegroundColor = Colors.Green; }

    [Export(typeof(EditorFormatDefinition)), ClassificationType(ClassificationTypeNames = BPlusTypes.StringLiteral), Name("BPlusString"), UserVisible(true), Order(Before = Priority.Default)]
    internal sealed class StFmt : ClassificationFormatDefinition { public StFmt() => ForegroundColor = Colors.DarkOrange; }

    [Export(typeof(EditorFormatDefinition)), ClassificationType(ClassificationTypeNames = BPlusTypes.Number), Name("BPlusNumber"), UserVisible(true), Order(Before = Priority.Default)]
    internal sealed class NuFmt : ClassificationFormatDefinition { public NuFmt() => ForegroundColor = Colors.Plum; }

    [Export(typeof(EditorFormatDefinition)), ClassificationType(ClassificationTypeNames = BPlusTypes.Operator), Name("BPlusOperator"), UserVisible(true), Order(Before = Priority.Default)]
    internal sealed class OpFmt : ClassificationFormatDefinition { public OpFmt() => ForegroundColor = Colors.LightGray; }

    [Export(typeof(EditorFormatDefinition)), ClassificationType(ClassificationTypeNames = BPlusTypes.Function), Name("BPlusFunction"), UserVisible(true), Order(Before = Priority.Default)]
    internal sealed class FnFmt : ClassificationFormatDefinition { public FnFmt() => ForegroundColor = Colors.Goldenrod; }

    [Export(typeof(IClassifierProvider)), ContentType("BPlus"), Name("BPlus Classifier")]
    internal sealed class BPlusProvider : IClassifierProvider
    {
        [Import] internal IClassificationTypeRegistryService Registry = null;

        public IClassifier GetClassifier(ITextBuffer buffer)
        {
            return buffer.Properties.GetOrCreateSingletonProperty(() => new BPlusClassifier(Registry));
        }
    }

    internal sealed class BPlusClassifier : IClassifier
    {
        private readonly IClassificationType _kw, _ty, _at, _cm, _st, _nu, _op, _fn;

        private static readonly HashSet<string> Kws = new(StringComparer.OrdinalIgnoreCase)
        { "fn","type","let","where","run","entry","return","if","else","for","while","in","as","is",
          "kernel","body","raise","pure","reads","writes","ensures","requires","effects" };
        private static readonly HashSet<string> Tys = new(StringComparer.OrdinalIgnoreCase)
        { "f32","f16","int8","u32","u64","Dim","ExitCode","tensor","stream","RingBuffer","KernelQ","KernelW",
          "Proof","NoiseBuffer","Image","ContextWindow","MotionBuffer","DepthBuffer","OutputFrame","GameFrame","DX12Device" };
        private static readonly HashSet<string> Bif = new(StringComparer.OrdinalIgnoreCase)
        { "conv2d","relu","tanh","sin","cos","clamp","pixel_shuffle","warp_forward","warp_backward",
          "extrapolate_motion","sliding_window","ring_buffer","zip","map","concat" };
        private static readonly Regex Rx = new(
          @"(@\w+(?:\([^)]*\))?)|(--[^\n]*)|(""[^""]*"")|(\b\d+\.?\d*(?:mb|gb|%|ms)?\b)|(\b[a-zA-Z_]\w*\b)|(>>|<<|\|\>|->|\|\||&&|==|!=|<=|>=|[+\-*/=%!^|&:;,.()\[\]{}<>])",
          RegexOptions.Compiled);

        public BPlusClassifier(IClassificationTypeRegistryService r) =>
            (_kw, _ty, _at, _cm, _st, _nu, _op, _fn) = (
                r.GetClassificationType(BPlusTypes.Keyword), r.GetClassificationType(BPlusTypes.Type),
                r.GetClassificationType(BPlusTypes.Attribute), r.GetClassificationType(BPlusTypes.Comment),
                r.GetClassificationType(BPlusTypes.StringLiteral), r.GetClassificationType(BPlusTypes.Number),
                r.GetClassificationType(BPlusTypes.Operator), r.GetClassificationType(BPlusTypes.Function));

        public event EventHandler<ClassificationChangedEventArgs> ClassificationChanged { add { } remove { } }

        public IList<ClassificationSpan> GetClassificationSpans(SnapshotSpan span)
        {
            var list = new List<ClassificationSpan>();
            string text = span.GetText();
            int start = span.Start.Position;

            foreach (Match m in Rx.Matches(text))
            {
                var sn = new SnapshotSpan(span.Snapshot, start + m.Index, m.Length);
                if (m.Groups[1].Success) list.Add(new ClassificationSpan(sn, _at));
                else if (m.Groups[2].Success) list.Add(new ClassificationSpan(sn, _cm));
                else if (m.Groups[3].Success) list.Add(new ClassificationSpan(sn, _st));
                else if (m.Groups[4].Success) list.Add(new ClassificationSpan(sn, _nu));
                else if (m.Groups[5].Success)
                {
                    string w = m.Value;
                    if (Kws.Contains(w)) list.Add(new ClassificationSpan(sn, _kw));
                    else if (Tys.Contains(w)) list.Add(new ClassificationSpan(sn, _ty));
                    else if (Bif.Contains(w)) list.Add(new ClassificationSpan(sn, _fn));
                }
                else if (m.Groups[6].Success) list.Add(new ClassificationSpan(sn, _op));
            }
            return list;
        }
    }
}
