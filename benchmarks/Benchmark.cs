using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Running;
using BPlusTranspiler;
using BPlusTranspiler.Parser;

BenchmarkRunner.Run<BPlusBenchmarks>();

[MemoryDiagnoser]
public class BPlusBenchmarks
{
    private string _source = "";
    private BPlusParser _parser = new();

    [GlobalSetup]
    public void Setup()
    {
        _source = File.ReadAllText("hello.bp");
    }

    [Benchmark]
    public ProgramNode Parse() => _parser.Parse(_source);

    [Benchmark]
    public string SerializeJson()
    {
        var program = _parser.Parse(_source);
        return AstSerializer.Serialize(program);
    }
}
