using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

public interface ICodeGenerator
{
    Dictionary<string, string> GenerateFiles(ProgramNode program);
    string GetFileExtension();
    string GetLanguageName();
}