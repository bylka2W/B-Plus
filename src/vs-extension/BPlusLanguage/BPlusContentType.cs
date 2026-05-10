using Microsoft.VisualStudio.Utilities;
using System.ComponentModel.Composition;

namespace BPlusLanguage
{
    internal static class BPlusContentType
    {
        public const string Name = "BPlus";

        [Export(typeof(ContentTypeDefinition))]
        [Name(Name)]
        [BaseDefinition("text")]
        internal static ContentTypeDefinition BPlusContentTypeDef = null;

        [Export(typeof(FileExtensionToContentTypeDefinition))]
        [ContentType(Name)]
        [FileExtension(".bp")]
        internal static FileExtensionToContentTypeDefinition BPlusFileExtension = null;
    }
}
