using Microsoft.VisualStudio.Language.Intellisense;
using Microsoft.VisualStudio.Utilities;
using System;
using System.ComponentModel.Composition;

namespace BPlusLanguage.Completion
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
}
