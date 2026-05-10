using Microsoft.VisualStudio.Utilities;
using System.ComponentModel.Composition;

namespace BPlusLanguage
{
    internal static class BPlusContentType
    {
        public const string Name = "BPlus";

        [Export, Name(Name), BaseDefinition("text")]
        internal static ContentTypeDefinition BPlusContentTypeDef = null;

        [Export, ContentType(Name), FileExtension(".bp")]
        internal static FileExtensionToContentTypeDefinition BPlusFileExtension = null;
    }
}
