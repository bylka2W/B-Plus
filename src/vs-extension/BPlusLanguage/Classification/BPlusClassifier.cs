using Microsoft.VisualStudio.Text;
using Microsoft.VisualStudio.Text.Classification;
using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace BPlusLanguage.Classification
{
    internal sealed class BPlusClassifier : IClassifier
    {
        private readonly IClassificationType _keywordType;
        private readonly IClassificationType _typeType;
        private readonly IClassificationType _attributeType;
        private readonly IClassificationType _commentType;
        private readonly IClassificationType _stringType;
        private readonly IClassificationType _numberType;
        private readonly IClassificationType _operatorType;
        private readonly IClassificationType _functionType;

        private static readonly HashSet<string> Keywords = new(StringComparer.OrdinalIgnoreCase)
        {
            "fn", "type", "let", "where", "run", "entry", "return",
            "if", "else", "for", "while", "in", "as", "is",
            "kernel", "body", "raise", "pure", "reads", "writes",
            "ensures", "requires", "effects"
        };

        private static readonly HashSet<string> TypeNames = new(StringComparer.OrdinalIgnoreCase)
        {
            "f32", "f16", "int8", "u32", "u64", "Dim", "ExitCode",
            "tensor", "stream", "RingBuffer", "KernelQ", "KernelW",
            "Proof", "NoiseBuffer", "Image", "ContextWindow",
            "MotionBuffer", "DepthBuffer", "OutputFrame", "GameFrame",
            "DX12Device"
        };

        private static readonly HashSet<string> BuiltinFunctions = new(StringComparer.OrdinalIgnoreCase)
        {
            "conv2d", "relu", "tanh", "sin", "cos", "clamp",
            "pixel_shuffle", "warp_forward", "warp_backward",
            "extrapolate_motion", "sliding_window", "ring_buffer",
            "zip", "map", "concat", "conv2d"
        };

        private static readonly Regex TokenRegex = new(
            @"(@\w+(?:\([^)]*\))?)" +
            @"|(--[^\n]*)" +
            @"|(""[^""]*"")" +
            @"|(\b\d+\.?\d*(?:mb|gb|%|ms)?\b)" +
            @"|(\b[a-zA-Z_]\w*\b)" +
            @"|(>>|<<|\|\>|->|\|\||&&|==|!=|<=|>=|[+\-*/=%!^|&:;,.()\[\]{}<>])",
            RegexOptions.Compiled | RegexOptions.Multiline);

        public event EventHandler<ClassificationChangedEventArgs> ClassificationChanged
        {
            add { }
            remove { }
        }

        public BPlusClassifier(IClassificationTypeRegistryService registry)
        {
            _keywordType = registry.GetClassificationType(BPlusClassificationTypes.Keyword);
            _typeType = registry.GetClassificationType(BPlusClassificationTypes.Type);
            _attributeType = registry.GetClassificationType(BPlusClassificationTypes.Attribute);
            _commentType = registry.GetClassificationType(BPlusClassificationTypes.Comment);
            _stringType = registry.GetClassificationType(BPlusClassificationTypes.String);
            _numberType = registry.GetClassificationType(BPlusClassificationTypes.Number);
            _operatorType = registry.GetClassificationType(BPlusClassificationTypes.Operator);
            _functionType = registry.GetClassificationType(BPlusClassificationTypes.Function);
        }

        public IList<ClassificationSpan> GetClassificationSpans(SnapshotSpan span)
        {
            var list = new List<ClassificationSpan>();
            string text = span.GetText();
            int start = span.Start.Position;

            foreach (Match m in TokenRegex.Matches(text))
            {
                if (m.Groups[1].Success)
                    list.Add(new ClassificationSpan(new SnapshotSpan(span.Snapshot, start + m.Index, m.Length), _attributeType));
                else if (m.Groups[2].Success)
                    list.Add(new ClassificationSpan(new SnapshotSpan(span.Snapshot, start + m.Index, m.Length), _commentType));
                else if (m.Groups[3].Success)
                    list.Add(new ClassificationSpan(new SnapshotSpan(span.Snapshot, start + m.Index, m.Length), _stringType));
                else if (m.Groups[4].Success)
                    list.Add(new ClassificationSpan(new SnapshotSpan(span.Snapshot, start + m.Index, m.Length), _numberType));
                else if (m.Groups[5].Success)
                {
                    string word = m.Value;
                    if (Keywords.Contains(word))
                        list.Add(new ClassificationSpan(new SnapshotSpan(span.Snapshot, start + m.Index, m.Length), _keywordType));
                    else if (TypeNames.Contains(word))
                        list.Add(new ClassificationSpan(new SnapshotSpan(span.Snapshot, start + m.Index, m.Length), _typeType));
                    else if (BuiltinFunctions.Contains(word))
                        list.Add(new ClassificationSpan(new SnapshotSpan(span.Snapshot, start + m.Index, m.Length), _functionType));
                }
                else if (m.Groups[6].Success)
                    list.Add(new ClassificationSpan(new SnapshotSpan(span.Snapshot, start + m.Index, m.Length), _operatorType));
            }

            return list;
        }
    }
}
