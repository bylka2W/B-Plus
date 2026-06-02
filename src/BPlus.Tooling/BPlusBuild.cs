using BPlus.Core;
using BPlus.Core.Ast;
using BPlus.Targets.Generators;
using BPlus.Core.Algorithm.Optimizer;
using BPlus.Core.Parser;
using System.Text.RegularExpressions;

namespace BPlus.Tooling;

public class BPlusConfig
{
    public string Name { get; set; } = "project";
    public string Version { get; set; } = "1.0.0";
    public string Mode { get; set; } = "";
    public string Target { get; set; } = "all";
    public string Output { get; set; } = "./gen";
    public bool Incremental { get; set; }
    public bool Parallel { get; set; } = true;
    public bool Cache { get; set; }
    public List<string> Source { get; set; } = new();
    public List<string> Flags { get; set; } = new();
    public Dictionary<string, string> Deps { get; set; } = new();
    public string? Plugin { get; set; }

    public string[] ToArgs(string input)
    {
        var args = new List<string> { input };
        if (!string.IsNullOrEmpty(Target) && Target != "all")
        { args.Add("--target"); args.Add(Target); }
        if (!string.IsNullOrEmpty(Output) && Output != "./gen")
        { args.Add("--output"); args.Add(Output); }
        if (!string.IsNullOrEmpty(Plugin))
        { args.Add("--plugin"); args.Add(Plugin); }
        args.AddRange(Flags);
        // Mode presets
        if (!string.IsNullOrEmpty(Mode))
        {
            switch (Mode.ToLower())
            {
                case "turbo": args.Add("--turbo"); break;
                case "eco": args.Add("--eco"); break;
                case "balanced": break;
            }
        }
        return args.ToArray();
    }
}

public static class BPlusBuild
{
    private static readonly Regex SectionRegex = new(@"^\[(.+)\]$", RegexOptions.Compiled);
    private static readonly Regex KeyValueRegex = new(@"^(\w[\w\d_]*)\s*=\s*(.+)$", RegexOptions.Compiled);
    private static readonly Regex ListValueRegex = new(@"^(\w[\w\d_]*)\s*=\s*\[(.*)\]$", RegexOptions.Compiled);

    public static int Run(string? configFile, bool dryRun)
    {
        var cfgPath = configFile ?? "bp.toml";
        if (!File.Exists(cfgPath))
        {
            Console.Error.WriteLine($"Файл конфигурации не найден: {cfgPath}");
            Console.Error.WriteLine("Создай bp.toml или укажи путь: bpc build --config ./path/bp.toml");
            return 1;
        }

        var config = LoadConfig(cfgPath);
        if (config == null) return 1;

        if (dryRun)
        {
            Console.WriteLine($"?? Конфигурация: {cfgPath}");
            Console.WriteLine($"  Проект:   {config.Name} v{config.Version}");
            Console.WriteLine($"  Режим:    {(string.IsNullOrEmpty(config.Mode) ? "стандартный" : config.Mode)}");
            Console.WriteLine($"  Цель:     {config.Target}");
            Console.WriteLine($"  Выход:    {config.Output}");
            Console.WriteLine($"  Источники: {string.Join(", ", config.Source)}");
            if (config.Flags.Count > 0)
                Console.WriteLine($"  Флаги:    {string.Join(" ", config.Flags)}");
            if (config.Deps.Count > 0)
                foreach (var (k, v) in config.Deps)
                    Console.WriteLine($"  Зависимость: {k} = {v}");
            Console.WriteLine($"  Инкрементально: {config.Incremental}");
            Console.WriteLine($"  Параллельно:    {config.Parallel}");
            Console.WriteLine($"  Кеш:            {config.Cache}");
            Console.WriteLine();
            Console.WriteLine("  Файлы для сборки:");
            var files = DiscoverFiles(config);
            foreach (var f in files)
                Console.WriteLine($"    {f}");
            Console.WriteLine($"  Всего: {files.Count} файл(ов)");
            Console.WriteLine("  (dry-run: генерация не выполнена)");
            return 0;
        }

        return Build(config);
    }

    private static int Build(BPlusConfig config)
    {
        var files = DiscoverFiles(config);
        if (files.Count == 0)
        {
            Console.Error.WriteLine("? BP файлы не найдены");
            return 1;
        }

        Console.WriteLine($"?? Сборка: {config.Name} v{config.Version}");
        Console.WriteLine($"  Файлов: {files.Count}");
        Console.WriteLine($"  Режим:  {(string.IsNullOrEmpty(config.Mode) ? "стандартный" : config.Mode)}");

        var allArgs = new List<string>();
        if (!string.IsNullOrEmpty(config.Target) && config.Target != "all")
        { allArgs.Add("--target"); allArgs.Add(config.Target); }
        if (!string.IsNullOrEmpty(config.Output) && config.Output != "./gen")
        { allArgs.Add("--output"); allArgs.Add(config.Output); }
        if (!string.IsNullOrEmpty(config.Plugin))
        { allArgs.Add("--plugin"); allArgs.Add(config.Plugin); }
        allArgs.AddRange(config.Flags);
        if (!string.IsNullOrEmpty(config.Mode))
        {
            switch (config.Mode.ToLower())
            {
                case "turbo": allArgs.Add("--turbo"); break;
                case "eco": allArgs.Add("--eco"); break;
            }
        }

        var optFlags = OptimizationFlags.Parse(allArgs.ToArray());
        string target = config.Target ?? "all";
        string output = config.Output ?? "./gen";

        int totalFiles = 0;
        var cache = config.Cache ? new Dictionary<string, string>() : null;
        int maxParallel = config.Parallel ? Environment.ProcessorCount : 1;

        foreach (var file in files)
        {
            if (cache != null)
            {
                var hash = File.GetLastWriteTimeUtc(file).Ticks.ToString();
                if (cache.TryGetValue(file, out var cachedHash) && cachedHash == hash)
                {
                    Console.WriteLine($"  ? {Path.GetFileName(file)} (кеш)");
                    continue;
                }
                cache[file] = hash;
            }

            try
            {
                var src = File.ReadAllText(file);
                var parser = new BPlusParser();
                var program = parser.Parse(src);

                if (optFlags.HasAny)
                {
                    if (optFlags.Optimize || optFlags.DeadElim || optFlags.ConstFold || optFlags.Dedup)
                        program = BPlusOptimizer.Optimize(program);
                }

                var generators = new List<ICodeGenerator>
                {
                    new PythonGenerator(), new CppGenerator(), new CSharpGenerator(), new CGenerator()
                };

                if (optFlags.HasAny)
                {
                    generators.Add(new CppOptimizedGenerator(optFlags));
                    target = "cpp_opt";
                }

                if (target != "all" && target != "cpp_opt")
                {
                    generators = generators.Where(g =>
                        g.GetLanguageName().Equals(target, StringComparison.OrdinalIgnoreCase) ||
                        g.GetFileExtension().Equals("." + target, StringComparison.OrdinalIgnoreCase)
                    ).ToList();
                }

                Directory.CreateDirectory(output);
                int fileCount = 0;
                foreach (var gen in generators)
                {
                    foreach (var (name, code) in gen.GenerateFiles(program))
                    {
                        var outPath = Path.Combine(output, name);
                        File.WriteAllText(outPath, code);
                        fileCount++;
                    }
                }
                Console.WriteLine($"  ? {Path.GetFileName(file)} > {fileCount} файл(ов)");
                totalFiles += fileCount;
            }
            catch (ParseException ex)
            {
                Console.WriteLine($"  ? {Path.GetFileName(file)}: ошибка парсинга — {ex.Message}");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"  ? {Path.GetFileName(file)}: {ex.Message}");
            }
        }

        Console.WriteLine();
        Console.WriteLine($"? Готово. Сгенерировано {totalFiles} файл(ов) в {output}");
        return 0;
    }

    private static List<string> DiscoverFiles(BPlusConfig config)
    {
        var files = new List<string>();
        foreach (var src in config.Source)
        {
            if (Directory.Exists(src))
                files.AddRange(Directory.GetFiles(src, "*.bp", SearchOption.AllDirectories));
            else if (File.Exists(src))
                files.Add(src);
        }
        if (files.Count == 0 && Directory.Exists("src"))
            files.AddRange(Directory.GetFiles("src", "*.bp", SearchOption.AllDirectories));
        if (files.Count == 0 && Directory.Exists("examples"))
            files.AddRange(Directory.GetFiles("examples", "*.bp", SearchOption.AllDirectories));
        return files.Distinct().ToList();
    }

    public static BPlusConfig? LoadConfig(string path)
    {
        try
        {
            var text = File.ReadAllText(path);
            return ParseConfig(text);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Ошибка загрузки {path}: {ex.Message}");
            return null;
        }
    }

    internal static BPlusConfig? ParseConfig(string text)
    {
        var config = new BPlusConfig();
        string section = "";

        foreach (var line in text.Split('\n'))
        {
            var trimmed = line.Trim();
            if (string.IsNullOrEmpty(trimmed) || trimmed.StartsWith("#") || trimmed.StartsWith("//"))
                continue;

            var sectionMatch = SectionRegex.Match(trimmed);
            if (sectionMatch.Success)
            {
                section = sectionMatch.Groups[1].Value.Trim().ToLower();
                continue;
            }

            var listMatch = ListValueRegex.Match(trimmed);
            if (listMatch.Success)
            {
                var key = listMatch.Groups[1].Value.Trim();
                var values = listMatch.Groups[2].Value.Split(',')
                    .Select(v => v.Trim().Trim('"').Trim('\''))
                    .Where(v => !string.IsNullOrEmpty(v))
                    .ToList();

                switch (section)
                {
                    case "project":
                        if (key == "source") config.Source = values;
                        break;
                    case "build":
                        if (key == "flags") config.Flags = values;
                        break;
                    case "deps":
                        foreach (var val in values)
                        {
                            var parts = val.Split('=');
                            if (parts.Length == 2)
                                config.Deps[parts[0].Trim()] = parts[1].Trim().Trim('"');
                        }
                        break;
                }
                continue;
            }

            var kvMatch = KeyValueRegex.Match(trimmed);
            if (kvMatch.Success)
            {
                var key = kvMatch.Groups[1].Value.Trim();
                var value = kvMatch.Groups[2].Value.Trim().Trim('"').Trim('\'');

                switch (section)
                {
                    case "project":
                        switch (key)
                        {
                            case "name": config.Name = value; break;
                            case "version": config.Version = value; break;
                        }
                        break;
                    case "build":
                        switch (key)
                        {
                            case "mode": config.Mode = value.ToLower(); break;
                            case "target": config.Target = value.ToLower(); break;
                            case "output": config.Output = value; break;
                            case "incremental": config.Incremental = value == "true"; break;
                            case "parallel": config.Parallel = value == "true"; break;
                            case "cache": config.Cache = value == "true"; break;
                            case "plugin": config.Plugin = value.ToLower(); break;
                        }
                        break;
                    case "deps":
                        config.Deps[key] = value;
                        break;
                }
            }
        }

        if (config.Source.Count == 0)
            config.Source.Add(".");

        return config;
    }
}
