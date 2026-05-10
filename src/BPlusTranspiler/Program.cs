using BPlusTranspiler.Ast;
using BPlusTranspiler.Generators;
using BPlusTranspiler.Parser;

var target = "all";
var output = "./gen";
var optimize = false;
string? input = null;

for (int i = 0; i < args.Length; i++)
{
    if (args[i] == "--target" && i + 1 < args.Length)
        target = args[++i];
    else if (args[i] == "--output" && i + 1 < args.Length)
        output = args[++i];
    else if (args[i] == "--optimize")
        optimize = true;
    else if (!args[i].StartsWith("-"))
        input = args[i];
}

if (input == null)
{
    Console.Error.WriteLine("Usage: bpc <input.bp> [--target python|cpp|csharp|c|all] [--optimize] [--output ./dir]");
    return 1;
}

if (!File.Exists(input))
{
    Console.Error.WriteLine($"File not found: {input}");
    return 1;
}

var source = File.ReadAllText(input);
var parser = new BPlusParser();
ProgramNode program;
try
{
    program = parser.Parse(source);
}
catch (ParseException ex)
{
    Console.Error.WriteLine($"Parse error: {ex.Message}");
    return 1;
}

var generators = new List<ICodeGenerator>
{
    new PythonGenerator(),
    new CppGenerator(),
    new CSharpGenerator(),
    new CGenerator()
};

if (optimize)
{
    generators.Add(new CppOptimizedGenerator());
    target = "cpp_opt";
}

if (target != "all" && target != "cpp_opt")
{
    generators = generators.Where(g =>
        g.GetLanguageName().Equals(target, StringComparison.OrdinalIgnoreCase) ||
        g.GetFileExtension().Equals("." + target, StringComparison.OrdinalIgnoreCase)
    ).ToList();

    if (generators.Count == 0)
    {
        Console.Error.WriteLine($"Unknown target: {target}. Use: python, cpp, csharp, c, all");
        return 1;
    }
}

Directory.CreateDirectory(output);
int count = 0;

foreach (var gen in generators)
{
    var files = gen.GenerateFiles(program);
    foreach (var (name, code) in files)
    {
        var outputFile = Path.Combine(output, name);
        File.WriteAllText(outputFile, code);
        Console.WriteLine($"  [{gen.GetLanguageName(),-10}] {outputFile}");
        count++;
    }
}

Console.WriteLine($"Done. Generated {count} file(s) to {output}");
return 0;