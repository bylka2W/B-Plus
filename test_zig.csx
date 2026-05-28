using BPlusTranspiler;
var hello = File.ReadAllText("hello.bp");
var result = BpcBackend.Generate(hello, 0);
Console.WriteLine(result);
