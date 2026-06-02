using System.Text.Json;

namespace BPlus.Tooling;

public static class Bpm
{
    private static string BpmDir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ".bpm", "packages");

    public static int Init(string name)
    {
        var dir = Path.GetFullPath(name);
        Directory.CreateDirectory(dir);

        var manifest = new BpmManifest
        {
            name = Path.GetFileName(dir),
            version = "1.0.0",
            description = "",
            author = "",
            files = new[] { "*.bp", "bpm.json" }
        };

        var manifestPath = Path.Combine(dir, "bpm.json");
        File.WriteAllText(manifestPath, JsonSerializer.Serialize(manifest, JsonOpts));
        Console.WriteLine($"Initialized B+ package at {dir}");
        Console.WriteLine($"  name: {manifest.name}");
        Console.WriteLine($"  version: {manifest.version}");
        Console.WriteLine();
        Console.WriteLine("Add your .bp files and edit bpm.json, then publish:");
        Console.WriteLine("  bpm publish <dir>");
        return 0;
    }

    public static int Install(string source)
    {
        var packagesDir = BpmDir;
        Directory.CreateDirectory(packagesDir);

        // Source can be a local path or a registry URL (simplified: local path)
        var srcDir = source;
        if (!Directory.Exists(srcDir))
        {
            // Check if it's a package name in the local registry
            var registryPath = Path.Combine(packagesDir, source);
            if (Directory.Exists(registryPath))
                srcDir = registryPath;
            else
            {
                Console.Error.WriteLine($"Package not found: {source}");
                Console.Error.WriteLine("Try: bpm install <path-to-package>");
                return 1;
            }
        }

        var manifestPath = Path.Combine(srcDir, "bpm.json");
        if (!File.Exists(manifestPath))
        {
            Console.Error.WriteLine($"Not a B+ package (no bpm.json): {source}");
            return 1;
        }

        var manifest = JsonSerializer.Deserialize<BpmManifest>(File.ReadAllText(manifestPath), JsonOpts);
        if (manifest == null) { Console.Error.WriteLine("Invalid bpm.json"); return 1; }

        var targetDir = Path.Combine(packagesDir, manifest.name);
        Directory.CreateDirectory(targetDir);

        // Copy package files
        var files = Directory.GetFiles(srcDir, "*.bp");
        foreach (var f in files)
            File.Copy(f, Path.Combine(targetDir, Path.GetFileName(f)), true);

        File.Copy(manifestPath, Path.Combine(targetDir, "bpm.json"), true);

        Console.WriteLine($"Installed package '{manifest.name}' v{manifest.version}");
        Console.WriteLine($"  from: {srcDir}");
        Console.WriteLine($"  to:   {targetDir}");
        Console.WriteLine($"  files: {files.Length} .bp file(s)");
        return 0;
    }

    public static int List()
    {
        var packagesDir = BpmDir;
        if (!Directory.Exists(packagesDir))
        {
            Console.WriteLine("No packages installed.");
            return 0;
        }

        var dirs = Directory.GetDirectories(packagesDir);
        if (dirs.Length == 0)
        {
            Console.WriteLine("No packages installed.");
            return 0;
        }

        Console.WriteLine("Installed B+ packages:");
        Console.WriteLine();
        foreach (var dir in dirs)
        {
            var manifestPath = Path.Combine(dir, "bpm.json");
            if (!File.Exists(manifestPath))
            {
                Console.WriteLine($"  {Path.GetFileName(dir)} (no manifest)");
                continue;
            }
            var manifest = JsonSerializer.Deserialize<BpmManifest>(File.ReadAllText(manifestPath), JsonOpts);
            if (manifest != null)
            {
                Console.WriteLine($"  {manifest.name,-20} v{manifest.version,-8} {manifest.description}");
                var bpFiles = Directory.GetFiles(dir, "*.bp");
                foreach (var f in bpFiles)
                    Console.WriteLine($"      {Path.GetFileName(f)}");
            }
        }
        return 0;
    }

    public static int Search(string term)
    {
        var packagesDir = BpmDir;
        if (!Directory.Exists(packagesDir))
        {
            Console.WriteLine("No packages found.");
            return 0;
        }

        var results = new List<BpmManifest>();
        foreach (var dir in Directory.GetDirectories(packagesDir))
        {
            var manifestPath = Path.Combine(dir, "bpm.json");
            if (!File.Exists(manifestPath)) continue;
            var manifest = JsonSerializer.Deserialize<BpmManifest>(File.ReadAllText(manifestPath), JsonOpts);
            if (manifest != null && (manifest.name.Contains(term, StringComparison.OrdinalIgnoreCase)
                || manifest.description.Contains(term, StringComparison.OrdinalIgnoreCase)))
                results.Add(manifest);
        }

        if (results.Count == 0)
        {
            Console.WriteLine($"No packages matching '{term}'.");
            Console.WriteLine();
            Console.WriteLine("To publish a package:");
            Console.WriteLine("  bpm init my-package");
            Console.WriteLine("  cd my-package");
            Console.WriteLine("  ... add .bp files ...");
            Console.WriteLine("  bpm publish .");
            return 0;
        }

        Console.WriteLine($"Found {results.Count} package(s):");
        foreach (var r in results)
            Console.WriteLine($"  {r.name,-20} v{r.version,-8} {r.description}");
        return 0;
    }

    public static int Publish(string dir)
    {
        var srcDir = Path.GetFullPath(dir);
        var manifestPath = Path.Combine(srcDir, "bpm.json");

        if (!File.Exists(manifestPath))
        {
            Console.Error.WriteLine($"No bpm.json found in {srcDir}");
            Console.Error.WriteLine("Run 'bpm init' first");
            return 1;
        }

        var manifest = JsonSerializer.Deserialize<BpmManifest>(File.ReadAllText(manifestPath), JsonOpts);
        if (manifest == null) { Console.Error.WriteLine("Invalid bpm.json"); return 1; }

        var packagesDir = BpmDir;
        Directory.CreateDirectory(packagesDir);
        var targetDir = Path.Combine(packagesDir, manifest.name);
        Directory.CreateDirectory(targetDir);

        var bpFiles = Directory.GetFiles(srcDir, "*.bp");
        foreach (var f in bpFiles)
            File.Copy(f, Path.Combine(targetDir, Path.GetFileName(f)), true);

        File.Copy(manifestPath, Path.Combine(targetDir, "bpm.json"), true);

        Console.WriteLine($"Published '{manifest.name}' v{manifest.version}");
        Console.WriteLine($"  {bpFiles.Length} .bp file(s) copied to local registry");
        Console.WriteLine($"  Install with: bpm install {manifest.name}");
        return 0;
    }

    public static int Create(string template)
    {
        var name = template.Contains('/') ? template.Split('/')[1] : template;
        var dir = Path.GetFullPath(name);
        Directory.CreateDirectory(dir);

        // Create a sample state machine
        var bpContent = $@"import ""bpm://{template}""

state {name} {{
    var count: int = 0

    on start -> Running {{
        init()
    }}
}}

state Running {{
    on tick -> Running {{
        process()
    }}

    on stop -> {name}
}}
";
        File.WriteAllText(Path.Combine(dir, $"{name}.bp"), bpContent);

        var manifest = new BpmManifest
        {
            name = name,
            version = "1.0.0",
            description = $"B+ template: {template}",
            author = "",
            files = new[] { "*.bp", "bpm.json" }
        };
        File.WriteAllText(Path.Combine(dir, "bpm.json"),
            JsonSerializer.Serialize(manifest, JsonOpts));

        Console.WriteLine($"Created template '{template}' in {dir}/");
        Console.WriteLine($"  {name}.bp");
        Console.WriteLine($"  bpm.json");
        return 0;
    }

    private class BpmManifest
    {
        public string name { get; set; } = "";
        public string version { get; set; } = "1.0.0";
        public string description { get; set; } = "";
        public string author { get; set; } = "";
        public string[] files { get; set; } = Array.Empty<string>();
    }

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };
}
