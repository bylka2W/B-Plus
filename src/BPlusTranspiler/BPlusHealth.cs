using BPlusTranspiler.Ast;
using BPlusTranspiler.Parser;

namespace BPlusTranspiler;

public static class BPlusHealth
{
    public static int Run(string? input, OptimizationFlags? flags)
    {
        var files = new List<string>();

        // Normalise path to full path if given
        string? dir = null;
        if (input != null)
        {
            var full = Path.GetFullPath(input);
            if (File.Exists(full))
            {
                files.Add(full);
            }
            else if (Directory.Exists(full))
            {
                dir = full;
            }
            else
            {
                // Maybe relative to cwd
                var cwdFull = Path.GetFullPath(Path.Combine(Directory.GetCurrentDirectory(), input));
                if (Directory.Exists(cwdFull))
                    dir = cwdFull;
                else if (File.Exists(cwdFull))
                    files.Add(cwdFull);
                else
                {
                    Console.Error.WriteLine($"Файл или папка не найдены: {input}");
                    return 1;
                }
            }
        }
        else
        {
            dir = Directory.GetCurrentDirectory();
        }

        if (dir != null)
        {
            files.AddRange(Directory.GetFiles(dir, "*.bp", SearchOption.AllDirectories));
            if (files.Count == 0 && dir != Directory.GetCurrentDirectory())
                files.AddRange(Directory.GetFiles(Directory.GetCurrentDirectory(), "*.bp", SearchOption.AllDirectories));
        }

        if (files.Count == 0)
        {
            Console.WriteLine("⚠ BP файлы не найдены");
            return 0;
        }

        Console.WriteLine($"🔍 Анализ здоровья: {files.Count} файл(ов)");
        Console.WriteLine();

        int totalErrors = 0, totalWarnings = 0, totalHints = 0;
        string? primaryInput = null;

        foreach (var file in files)
        {
            string src;
            ProgramNode program;
            try
            {
                src = File.ReadAllText(file);
                program = new BPlusParser().Parse(src);
            }
            catch (ParseException ex)
            {
                Console.WriteLine($"  [{Path.GetFileName(file)}] ❌ Ошибка парсинга: {ex.Message}");
                totalErrors++;
                continue;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"  [{Path.GetFileName(file)}] ❌ {ex.Message}");
                totalErrors++;
                continue;
            }

            var reporter = new BPlusErrorReporter(program, file, flags);
            reporter.RunAll();
            var errCount = reporter.Errors.Count(e => e.Severity == ErrorSeverity.Error);
            var warnCount = reporter.Errors.Count(e => e.Severity == ErrorSeverity.Warning);
            var hintCount = reporter.Errors.Count(e => e.Severity == ErrorSeverity.Hint);

            totalErrors += errCount;
            totalWarnings += warnCount;
            totalHints += hintCount;

            if (file == files[0])
            {
                primaryInput = file;
                foreach (var err in reporter.Errors)
                    Console.WriteLine(err.Render());
            }
            else
            {
                Console.WriteLine($"  [{Path.GetFileName(file)}] {errCount} ошибок, {warnCount} предупреждений, {hintCount} подсказок");
            }
        }

        // Global health metrics
        Console.WriteLine(new string('-', 50));
        Console.WriteLine("📊 Сводка по проекту:");
        Console.WriteLine($"  Файлов:             {files.Count}");
        Console.WriteLine($"  Ошибок:             {totalErrors}");
        Console.WriteLine($"  Предупреждений:     {totalWarnings}");
        Console.WriteLine($"  Подсказок:          {totalHints}");

        if (primaryInput != null)
        {
            var src = File.ReadAllText(primaryInput);
            var prog = new BPlusParser().Parse(src);
            var states = FlatStateCount(prog);
            var trans = FlatTransitionCount(prog);
            var vars = FlatVarCount(prog);

            Console.WriteLine($"  Состояний:          {states}");
            Console.WriteLine($"  Переходов:          {trans}");
            Console.WriteLine($"  Переменных:         {vars}");
            Console.WriteLine($"  Вложенность:        {MaxDepth(prog)} уровней");
        }

        // Estimate state pool memory
        if (primaryInput != null)
        {
            var src = File.ReadAllText(primaryInput);
            var prog = new BPlusParser().Parse(src);
            var states = FlatStateCount(prog);
            var vars = FlatVarCount(prog);

            var estimateBytes = states * 64 + vars * 8;
            Console.WriteLine();
            Console.WriteLine("💾 Статическая оценка памяти:");
            Console.WriteLine($"  State pool ({states} × 64B):          {states * 64 / 1024.0:F1} КБ");
            Console.WriteLine($"  Переменные ({vars} × 8B):             {vars * 8 / 1024.0:F1} КБ");
            Console.WriteLine($"  Всего:                              {estimateBytes / 1024.0:F1} КБ");
            Console.WriteLine($"  С --pack:                           {estimateBytes * 0.5 / 1024.0:F1} КБ (оценка)");
            Console.WriteLine($"  Рекомендация: {(estimateBytes < 65536 ? "⚡ Влезает в L2 кеш" : estimateBytes < 1048576 ? "📦 Влезает в L3 кеш" : "💾 В RAM, используй --pool")}");
        }

        return totalErrors > 0 ? 1 : 0;
    }

    private static int FlatStateCount(ProgramNode prog)
    {
        int count = 0;
        void Collect(StateDefNode s) { count++; foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var s in prog.States) Collect(s);
        foreach (var pb in prog.ParallelBlocks)
            foreach (var s in pb.States) Collect(s);
        return count;
    }

    private static int FlatTransitionCount(ProgramNode prog)
    {
        int count = 0;
        void Collect(StateDefNode s) { count += s.Transitions.Count + s.Timers.Count; foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var s in prog.States) Collect(s);
        foreach (var pb in prog.ParallelBlocks)
            foreach (var s in pb.States) Collect(s);
        return count;
    }

    private static int FlatVarCount(ProgramNode prog)
    {
        int count = 0;
        void Collect(StateDefNode s) { count += s.Variables.Count; foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var s in prog.States) Collect(s);
        foreach (var pb in prog.ParallelBlocks)
            foreach (var s in pb.States) Collect(s);
        if (prog.Context != null) count += prog.Context.Variables.Count;
        return count;
    }

    private static int MaxDepth(ProgramNode prog)
    {
        int Max(StateDefNode s, int d) => Math.Max(d, s.NestedStates.Count > 0 ? s.NestedStates.Max(ns => Max(ns, d + 1)) : d);
        int max = 0;
        foreach (var s in prog.States) max = Math.Max(max, Max(s, 1));
        foreach (var pb in prog.ParallelBlocks)
            foreach (var s in pb.States) max = Math.Max(max, Max(s, 1));
        return max;
    }
}
