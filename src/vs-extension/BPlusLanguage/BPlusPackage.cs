using Microsoft.VisualStudio.Package;
using Microsoft.VisualStudio.TextManager.Interop;
using Microsoft.VisualStudio.Utilities;
using System.ComponentModel.Composition;
using System.Runtime.InteropServices;

namespace BPlusLanguage
{
    [Guid("A1B2C3D4-E5F6-7890-ABCD-EF1234567890")]
    [ComVisible(true)]
    [PackageRegistration(UseManagedResourcesOnly = true, AllowsBackgroundLoading = true)]
    [InstalledProductRegistration("#110", "#112", "1.0", IconResourceID = 400)]
    [ProvideLanguageExtension(typeof(BPlusLanguageService), ".bp")]
    [ProvideLanguageService(typeof(BPlusLanguageService), "B+", 0, RequestStockColors = true)]
    [ContentType("BPlus")]
    [FileExtension(".bp")]
    internal sealed class BPlusPackage : Package
    {
    }

    [Guid("B2C3D4E5-F6A7-8901-BCDE-F12345678901")]
    internal class BPlusLanguageService : LanguageService
    {
        private LanguagePreferences _prefs;

        public override string Name => "B+";

        public override LanguagePreferences GetLanguagePreferences()
        {
            if (_prefs == null)
            {
                _prefs = new LanguagePreferences(Site, typeof(BPlusLanguageService).GUID, Name);
                _prefs.Init();
            }
            return _prefs;
        }

        public override IScanner GetScanner(IVsTextLines buffer) => null;

        public override AuthoringScope ParseSource(ParseRequest req) => new BPlusAuthoringScope();
    }

    internal class BPlusAuthoringScope : AuthoringScope
    {
        public override string GetDataTipText(int line, int col, out TextSpan span)
        {
            span = new TextSpan();
            return null;
        }

        public override Declarations GetDeclarations(IVsTextView view, int line, int col, TokenInfo info, ParseReason reason)
        {
            return null;
        }

        public override Methods GetMethods(int line, int col, string name)
        {
            return null;
        }

        public override string Goto(VSConstants.VSStd97CmdID cmd, IVsTextView view, int line, int col, out TextSpan span)
        {
            span = new TextSpan();
            return null;
        }
    }
}
