using System.Text.Json;
using BPlusTranspiler;
using BPlusTranspiler.Parser;
using BPlusTranspiler.Ast;

var src = @"
context { var a: int = 1 }
state Test {
    enter { print(""hello"") }
    on ev -> Test { }
}
";
var parser = new BPlusParser(src);
var prog = parser.ParseProgram();
var json = AstSerializer.Serialize(prog);
File.WriteAllText("debug.json", json);
