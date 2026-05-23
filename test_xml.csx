#r "System.Xml.Linq.dll"
using System.Xml.Linq;

try {
    var doc = XDocument.Load(@"C:\B+ v1.0\src\vs-extension\BPlusLanguage\source.extension.vsixmanifest");
    Console.WriteLine("OK");
} catch (Exception ex) {
    var msg = ex.Message;
    var bytes = System.Text.Encoding.UTF8.GetBytes(msg);
    Console.WriteLine(Convert.ToBase64String(bytes));
}
