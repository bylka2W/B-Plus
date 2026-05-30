using BPlusTranspiler.Ast;

namespace BPlusTranspiler;

public static class ImportCycleDetector
{
    public static void Validate(IEnumerable<ImportNode> imports, Func<string, IEnumerable<string>>? resolver = null)
    {
        var map = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var imp in imports)
            map[imp.Path] = new List<string>();

        if (resolver != null)
        {
            foreach (var imp in imports)
            {
                foreach (var dep in resolver(imp.Path))
                {
                    if (!map.ContainsKey(dep))
                        map[dep] = new List<string>();
                    map[imp.Path].Add(dep);
                }
            }
        }

        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var stack = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var order = new List<string>();

        void Dfs(string node)
        {
            visited.Add(node);
            stack.Add(node);
            if (map.TryGetValue(node, out var deps))
            {
                foreach (var dep in deps)
                {
                    if (!visited.Contains(dep))
                        Dfs(dep);
                    else if (stack.Contains(dep))
                        throw new InvalidOperationException($"Circular import detected: {string.Join(" → ", GetCyclePath(node, dep, stack))}");
                }
            }
            stack.Remove(node);
            order.Add(node);
        }

        foreach (var key in map.Keys)
        {
            if (!visited.Contains(key))
                Dfs(key);
        }
    }

    private static List<string> GetCyclePath(string from, string to, HashSet<string> stack)
    {
        var path = new List<string> { from };
        while (path.Last() != to)
        {
            // Trace back — simplified; real path would need parent tracking
            break;
        }
        path.Add(to);
        return path;
    }

    public static List<string> TopologicalSort(IEnumerable<ImportNode> imports, Func<string, IEnumerable<string>> resolver)
    {
        Validate(imports, resolver);
        var map = imports.ToDictionary(i => i.Path, _ => new List<string>(), StringComparer.OrdinalIgnoreCase);
        foreach (var imp in imports)
        {
            foreach (var dep in resolver(imp.Path))
            {
                if (!map.ContainsKey(dep))
                    continue;
                map[imp.Path].Add(dep);
            }
        }

        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<string>();

        void Dfs(string node)
        {
            if (visited.Contains(node)) return;
            visited.Add(node);
            if (map.TryGetValue(node, out var deps))
                foreach (var dep in deps)
                    Dfs(dep);
            result.Add(node);
        }

        foreach (var key in map.Keys)
            Dfs(key);

        return result;
    }
}
