using Microsoft.VisualStudio.Text.Classification;
using Microsoft.VisualStudio.Utilities;
using System.ComponentModel.Composition;
using System.Windows.Media;

namespace BPlusLanguage.Classification
{
    internal static class BPlusClassificationTypes
    {
        public const string Keyword = "BPlusKeyword";
        public const string Type = "BPlusType";
        public const string Attribute = "BPlusAttribute";
        public const string Comment = "BPlusComment";
        public const string String = "BPlusString";
        public const string Number = "BPlusNumber";
        public const string Operator = "BPlusOperator";
        public const string Function = "BPlusFunction";
    }

    [Export(typeof(ClassificationTypeDefinition))]
    [Name(BPlusClassificationTypes.Keyword)]
    internal static class BPlusKeywordTypeDef { }

    [Export(typeof(ClassificationTypeDefinition))]
    [Name(BPlusClassificationTypes.Type)]
    internal static class BPlusTypeTypeDef { }

    [Export(typeof(ClassificationTypeDefinition))]
    [Name(BPlusClassificationTypes.Attribute)]
    internal static class BPlusAttributeTypeDef { }

    [Export(typeof(ClassificationTypeDefinition))]
    [Name(BPlusClassificationTypes.Comment)]
    internal static class BPlusCommentTypeDef { }

    [Export(typeof(ClassificationTypeDefinition))]
    [Name(BPlusClassificationTypes.String)]
    internal static class BPlusStringTypeDef { }

    [Export(typeof(ClassificationTypeDefinition))]
    [Name(BPlusClassificationTypes.Number)]
    internal static class BPlusNumberTypeDef { }

    [Export(typeof(ClassificationTypeDefinition))]
    [Name(BPlusClassificationTypes.Operator)]
    internal static class BPlusOperatorTypeDef { }

    [Export(typeof(ClassificationTypeDefinition))]
    [Name(BPlusClassificationTypes.Function)]
    internal static class BPlusFunctionTypeDef { }
}

namespace BPlusLanguage.Classification
{
    [Export(typeof(EditorFormatDefinition))]
    [ClassificationType(ClassificationTypeNames = BPlusClassificationTypes.Keyword)]
    [Name("BPlusKeyword")]
    [UserVisible(true)]
    [Order(Before = Priority.Default)]
    internal sealed class BPlusKeywordFormat : ClassificationFormatDefinition
    {
        public BPlusKeywordFormat() => ForegroundColor = Colors.DodgerBlue;
    }

    [Export(typeof(EditorFormatDefinition))]
    [ClassificationType(ClassificationTypeNames = BPlusClassificationTypes.Type)]
    [Name("BPlusType")]
    [UserVisible(true)]
    [Order(Before = Priority.Default)]
    internal sealed class BPlusTypeFormat : ClassificationFormatDefinition
    {
        public BPlusTypeFormat() => ForegroundColor = Colors.MediumTurquoise;
    }

    [Export(typeof(EditorFormatDefinition))]
    [ClassificationType(ClassificationTypeNames = BPlusClassificationTypes.Attribute)]
    [Name("BPlusAttribute")]
    [UserVisible(true)]
    [Order(Before = Priority.Default)]
    internal sealed class BPlusAttributeFormat : ClassificationFormatDefinition
    {
        public BPlusAttributeFormat() => ForegroundColor = Colors.OrangeRed;
    }

    [Export(typeof(EditorFormatDefinition))]
    [ClassificationType(ClassificationTypeNames = BPlusClassificationTypes.Comment)]
    [Name("BPlusComment")]
    [UserVisible(true)]
    [Order(Before = Priority.Default)]
    internal sealed class BPlusCommentFormat : ClassificationFormatDefinition
    {
        public BPlusCommentFormat() => ForegroundColor = Colors.Green;
    }

    [Export(typeof(EditorFormatDefinition))]
    [ClassificationType(ClassificationTypeNames = BPlusClassificationTypes.String)]
    [Name("BPlusString")]
    [UserVisible(true)]
    [Order(Before = Priority.Default)]
    internal sealed class BPlusStringFormat : ClassificationFormatDefinition
    {
        public BPlusStringFormat() => ForegroundColor = Colors.DarkOrange;
    }

    [Export(typeof(EditorFormatDefinition))]
    [ClassificationType(ClassificationTypeNames = BPlusClassificationTypes.Number)]
    [Name("BPlusNumber")]
    [UserVisible(true)]
    [Order(Before = Priority.Default)]
    internal sealed class BPlusNumberFormat : ClassificationFormatDefinition
    {
        public BPlusNumberFormat() => ForegroundColor = Colors.Plum;
    }

    [Export(typeof(EditorFormatDefinition))]
    [ClassificationType(ClassificationTypeNames = BPlusClassificationTypes.Operator)]
    [Name("BPlusOperator")]
    [UserVisible(true)]
    [Order(Before = Priority.Default)]
    internal sealed class BPlusOperatorFormat : ClassificationFormatDefinition
    {
        public BPlusOperatorFormat() => ForegroundColor = Colors.LightGray;
    }

    [Export(typeof(EditorFormatDefinition))]
    [ClassificationType(ClassificationTypeNames = BPlusClassificationTypes.Function)]
    [Name("BPlusFunction")]
    [UserVisible(true)]
    [Order(Before = Priority.Default)]
    internal sealed class BPlusFunctionFormat : ClassificationFormatDefinition
    {
        public BPlusFunctionFormat() => ForegroundColor = Colors.Goldenrod;
    }
}
