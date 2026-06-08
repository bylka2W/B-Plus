using BPlus.Core.Ast;
using BPlus.Core.Parser;
using BPlus.Runtime;
using BPlus.Targets.Generators;

namespace BPlus.Cli;

public static class Program
{
    public static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: bpc <command> [options]");
            Console.Error.WriteLine();
            Console.Error.WriteLine("Commands:");
            Console.Error.WriteLine("  build <input.b+> [-o <output.exe>]");
            Console.Error.WriteLine("  run   <input.b+>");
            return 1;
        }

        return args[0] switch
        {
            "build" => Build(args[1..]),
            "run" => Run(args[1..]),
            _ => Unknown(args[0]),
        };
    }

    static int Build(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: bpc build <input.b+> [-o <output.exe>]");
            return 1;
        }

        string inputPath = args[0];
        string outputPath = GuessOutputPath(inputPath, args);

        if (!File.Exists(inputPath))
        {
            Console.Error.WriteLine($"error: file not found '{inputPath}'");
            return 1;
        }

        string source = File.ReadAllText(inputPath);

        ProgramNode program;
        try
        {
            program = new BPlusParser().Parse(source);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"parse error: {ex.Message}");
            return 1;
        }

        if (program.States.Count == 0 && program.Entries.Count == 0)
        {
            Console.Error.WriteLine("error: no states or entries found");
            return 1;
        }

        Console.WriteLine($"  states: {program.States.Count}, entries: {program.Entries.Count}");

        var gen = new X64CodeGen();
        X64Output output;
        try
        {
            output = gen.Generate(program);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"codegen error: {ex.Message}");
            return 1;
        }

        var peBytes = PeWriter.Write(output.Code, output.ImportDirRva, output.IdatSize);
        File.WriteAllBytes(outputPath, peBytes);

        Console.WriteLine($"  output: {outputPath} ({peBytes.Length} bytes)");
        return 0;
    }

    static int Run(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: bpc run <input.b+>");
            return 1;
        }

        string inputPath = args[0];
        string exePath = Path.ChangeExtension(inputPath, ".exe");

        if (Build([inputPath, "-o", exePath]) != 0)
            return 1;

        Console.WriteLine($"  running: {exePath}");
        var psi = new System.Diagnostics.ProcessStartInfo(exePath)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        var proc = System.Diagnostics.Process.Start(psi);
        if (proc == null)
        {
            Console.Error.WriteLine($"error: failed to start '{exePath}'");
            return 1;
        }
        proc.WaitForExit();
        Console.Write(proc.StandardOutput.ReadToEnd());
        var err = proc.StandardError.ReadToEnd();
        if (err.Length > 0)
            Console.Error.Write(err);
        return proc.ExitCode;
    }

    static int Unknown(string cmd)
    {
        Console.Error.WriteLine($"error: unknown command '{cmd}'");
        Console.Error.WriteLine("Usage: bpc <build|run> [options]");
        return 1;
    }

    static string GuessOutputPath(string inputPath, string[] args)
    {
        for (int i = 0; i < args.Length - 1; i++)
            if (args[i] == "-o" || args[i] == "--output")
                return args[i + 1];
        return Path.ChangeExtension(inputPath, ".exe");
    }
}
