using Microsoft.VisualStudio.Text;
using Microsoft.VisualStudio.Text.Classification;
using Microsoft.VisualStudio.Utilities;
using System.ComponentModel.Composition;

namespace BPlusLanguage.Classification
{
    [Export(typeof(IClassifierProvider))]
    [ContentType("BPlus")]
    [Name("BPlus Classifier")]
    internal sealed class BPlusClassifierProvider : IClassifierProvider
    {
        [Import]
        private IClassificationTypeRegistryService Registry { get; set; }

        public IClassifier GetClassifier(ITextBuffer buffer)
        {
            return buffer.Properties.GetOrCreateSingletonProperty(() => new BPlusClassifier(Registry));
        }
    }
}
