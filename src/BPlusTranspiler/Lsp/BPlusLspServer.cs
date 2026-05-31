using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Parser;

namespace BPlusTranspiler.Lsp;

public partial class BPlusLspServer
{
    private readonly Dictionary<string, DocState> _docs = new();
    private volatile bool _shutdown;

    public void Run()
    {
        var port = 5000;
        var listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        Console.Error.WriteLine($"LSP server listening on port {port}");

        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            _shutdown = true;
            try { listener.Stop(); } catch { }
        };

        while (!_shutdown)
        {
            TcpClient? client = null;
            try
            {
                client = listener.AcceptTcpClient();
                client.ReceiveTimeout = 1000;
                Console.Error.WriteLine("LSP: client connected");
                HandleClient(client);
            }
            catch (ObjectDisposedException) { break; }
            catch (SocketException) when (_shutdown) { break; }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"LSP error: {ex.Message}");
                client?.Close();
            }
        }

        listener.Stop();
        Console.Error.WriteLine("LSP server stopped");
    }

    private void HandleClient(TcpClient client)
    {
        using (client)
        using (var stream = client.GetStream())
        {
            var buffer = new byte[1024 * 64];
            var localShutdown = false;

            while (!_shutdown && !localShutdown)
            {
                var json = ReadMessage(stream, buffer);
                if (json == null) break;

                using var doc = JsonDocument.Parse(json);
                var root = doc.RootElement;

                var method = root.TryGetProperty("method", out var m) ? m.GetString() : null;
                var id = root.TryGetProperty("id", out var i) ? i : default;

                switch (method)
                {
                    case "initialize":
                        Send(stream, id, new
                        {
                            capabilities = new
                            {
                                textDocumentSync = new { openClose = true, change = 1 },
                                completionProvider = new { triggerCharacters = new[] { ".", ":", " " } },
                                definitionProvider = true,
                                hoverProvider = true,
                                documentFormattingProvider = true,
                            },
                            serverInfo = new { name = "bpc-lsp", version = "4.0.0" }
                        });
                        break;

                    case "initialized":
                        break;

                    case "textDocument/didOpen":
                        HandleOpen(root, stream);
                        break;

                    case "textDocument/didChange":
                        HandleChange(root, stream);
                        break;

                    case "textDocument/completion":
                        HandleCompletion(root, stream, id);
                        break;

                    case "textDocument/definition":
                        HandleDefinition(root, stream, id);
                        break;

                    case "textDocument/hover":
                        HandleHover(root, stream, id);
                        break;

                    case "textDocument/formatting":
                        HandleFormatting(root, stream, id);
                        break;

                    case "shutdown":
                        Send(stream, id, null);
                        localShutdown = true;
                        _shutdown = true;
                        break;

                    case "exit":
                        localShutdown = true;
                        _shutdown = true;
                        break;

                    default:
                        if (id.ValueKind != JsonValueKind.Undefined)
                            Send(stream, id, null);
                        break;
                }
            }
        }
    }

    private static string? ReadMessage(Stream stream, byte[] buffer)
    {
        string? header = null;
        while (true)
        {
            header = ReadLine(stream, buffer);
            if (header == null) return null;
            if (!header.StartsWith("Content-Length: ")) continue;
            if (!int.TryParse(header.AsSpan("Content-Length: ".Length), out var len)) continue;

            if (ReadLine(stream, buffer) == null) return null;

            var body = new byte[len];
            var offset = 0;
            while (offset < len)
            {
                var read = stream.Read(body, offset, len - offset);
                if (read == 0) return null;
                offset += read;
            }
            return Encoding.UTF8.GetString(body);
        }
    }

    private static string? ReadLine(Stream stream, byte[] buffer)
    {
        using var ms = new MemoryStream();
        while (true)
        {
            var b = stream.ReadByte();
            if (b == -1) return ms.Length > 0 ? Encoding.UTF8.GetString(ms.ToArray()) : null;
            if (b == '\r') continue;
            if (b == '\n') break;
            ms.WriteByte((byte)b);
        }
        return Encoding.UTF8.GetString(ms.ToArray());
    }

    private void HandleOpen(JsonElement root, Stream stream)
    {
        var @params = root.GetProperty("params");
        var td = @params.GetProperty("textDocument");
        var uri = td.GetProperty("uri").GetString()!;
        var text = td.GetProperty("text").GetString()!;
        ParseAndPublish(uri, text, stream);
    }

    private void HandleChange(JsonElement root, Stream stream)
    {
        var @params = root.GetProperty("params");
        var uri = @params.GetProperty("textDocument").GetProperty("uri").GetString()!;
        var text = @params.GetProperty("contentChanges")[0].GetProperty("text").GetString()!;
        ParseAndPublish(uri, text, stream);
    }

    private void ParseAndPublish(string uri, string text, Stream stream)
    {
        var diags = new List<LspDiagnostic>();
        ProgramNode? ast = null;

        try
        {
            ast = new BPlusParser().Parse(text);
        }
        catch (ParseException ex)
        {
            diags.Add(MakeDiagnostic(ex.Message));
        }
        catch (Exception ex)
        {
            diags.Add(MakeDiagnostic(ex.Message));
        }

        _docs[uri] = new DocState { Text = text, Ast = ast, Diagnostics = diags };
        Notify(stream, "textDocument/publishDiagnostics", new { uri, diagnostics = diags });
    }

    private static LspDiagnostic MakeDiagnostic(string message)
    {
        var posMatch = Regex.Match(message, @"position (\d+)");
        var line = posMatch.Success && int.TryParse(posMatch.Groups[1].Value, out var l) ? Math.Max(0, l - 1) : 0;
        return new LspDiagnostic
        {
            range = new LspRange
            {
                start = new LspPosition { line = line, character = 0 },
                end = new LspPosition { line = line, character = 9999 }
            },
            severity = 1,
            message = message,
            source = "bpc"
        };
    }

    private void HandleCompletion(JsonElement root, Stream stream, JsonElement id)
    {
        var @params = root.GetProperty("params");
        var uri = @params.GetProperty("textDocument").GetProperty("uri").GetString()!;
        if (!_docs.TryGetValue(uri, out var doc) || doc.Ast == null)
        {
            Send(stream, id, new { isIncomplete = false, items = Array.Empty<object>() });
            return;
        }

        var items = new List<object>();
        var seen = new HashSet<string>();

        void AddKeywords()
        {
            foreach (var kw in new[] { "state", "base", "var", "on", "after", "enter", "exit",
                "always", "async", "import", "context", "enum", "parallel", "true", "false" })
                AddItem(kw, 14, "keyword");
            foreach (var t in new[] { "int", "float", "string", "bool", "void", "double", "long" })
                AddItem(t, 22, "type");
        }

        void AddStates(IEnumerable<StateDefNode> states)
        {
            foreach (var s in states)
            {
                AddItem(s.Name, 7, "state");
                foreach (var v in s.Variables)
                    AddItem(v.Name, 6, $"{v.Type}");
                AddStates(s.NestedStates);
            }
        }

        void AddEvents(IEnumerable<StateDefNode> states)
        {
            foreach (var s in states)
            {
                foreach (var t in s.Transitions)
                    if (!string.IsNullOrEmpty(t.EventName) && !t.IsAlways && !t.IsEnterAuto)
                        AddItem(t.EventName, 3, "event");
                AddEvents(s.NestedStates);
            }
        }

        void AddItem(string label, int kind, string detail)
        {
            if (seen.Add(label))
                items.Add(new { label, kind, detail });
        }

        AddKeywords();
        AddStates(doc.Ast.States);
        foreach (var pb in doc.Ast.ParallelBlocks)
            AddStates(pb.States);
        AddEvents(doc.Ast.States);
        foreach (var pb in doc.Ast.ParallelBlocks)
            AddEvents(pb.States);

        Send(stream, id, new { isIncomplete = false, items });
    }

    private void HandleDefinition(JsonElement root, Stream stream, JsonElement id)
    {
        var @params = root.GetProperty("params");
        var uri = @params.GetProperty("textDocument").GetProperty("uri").GetString()!;
        if (!_docs.TryGetValue(uri, out var doc) || doc.Ast == null || doc.Text == null)
        {
            Send(stream, id, null); return;
        }

        var pos = @params.GetProperty("position");
        var word = GetWordAt(doc.Text, pos.GetProperty("line").GetInt32(), pos.GetProperty("character").GetInt32());
        if (string.IsNullOrEmpty(word)) { Send(stream, id, null); return; }

        var pattern = $@"\bstate\s+{Regex.Escape(word)}\b";
        var match = Regex.Match(doc.Text, pattern);
        if (!match.Success)
        {
            Send(stream, id, null); return;
        }

        var line = doc.Text[..match.Index].Count(c => c == '\n');
        var colInLine = match.Index - doc.Text[..match.Index].LastIndexOf('\n') - 1;
        var col = colInLine < 0 ? match.Value.IndexOf(word) : colInLine + match.Value.IndexOf(word);

        Send(stream, id, new
        {
            uri,
            range = new LspRange
            {
                start = new LspPosition { line = line, character = col },
                end = new LspPosition { line = line, character = col + word.Length }
            }
        });
    }

    private void HandleHover(JsonElement root, Stream stream, JsonElement id)
    {
        var @params = root.GetProperty("params");
        var uri = @params.GetProperty("textDocument").GetProperty("uri").GetString()!;
        if (!_docs.TryGetValue(uri, out var doc) || doc.Ast == null || doc.Text == null)
        {
            Send(stream, id, null); return;
        }

        var pos = @params.GetProperty("position");
        var word = GetWordAt(doc.Text, pos.GetProperty("line").GetInt32(), pos.GetProperty("character").GetInt32());
        if (string.IsNullOrEmpty(word)) { Send(stream, id, null); return; }

        string? detail = null;

        StateDefNode? Find(IEnumerable<StateDefNode> states)
        {
            foreach (var s in states)
            {
                if (s.Name == word) return s;
                var f = Find(s.NestedStates);
                if (f != null) return f;
            }
            return null;
        }

        var state = Find(doc.Ast.States) ?? Find(doc.Ast.ParallelBlocks.SelectMany(pb => pb.States).ToList());
        if (state != null)
        {
            var sb = new StringBuilder();
            sb.AppendLine($"**state `{state.Name}`**");
            if (state.Variables.Count > 0)
            {
                sb.AppendLine("---");
                sb.AppendLine("| Var | Type | Default |");
                sb.AppendLine("|-----|------|---------|");
                foreach (var v in state.Variables)
                    sb.AppendLine($"| `{v.Name}` | `{v.Type}` | {v.DefaultValue ?? "-"} |");
            }
            if (state.Transitions.Count > 0)
            {
                sb.AppendLine("---");
                sb.AppendLine($"**Transitions ({state.Transitions.Count}):**");
                foreach (var t in state.Transitions)
                    sb.AppendLine($"- `{t.EventName}` → `{t.Target}`{(t.Guard != null ? $" [{t.Guard}]" : "")}{(t.Body != null ? " {…}" : "")}");
            }
            detail = sb.ToString();
        }
        else
        {
            detail = word switch
            {
                "state" => "Define a state. Syntax: `state Name { ... }`",
                "base" => "Mark as base class for generics: `base state Name<T> { ... }`",
                "var" => "Declare state variable: `var name: type = default`",
                "on" => "Event transition: `on event(params) [guard] -> Target { body }`",
                "after" => "Timer: `after 30s [guard] -> Target`",
                "enter" => "Enter action: `enter { code }`",
                "exit" => "Exit action: `exit { code }`",
                "always" => "Always transition: `always -> Target`",
                "async" => "Async modifier: `on async event -> Target`",
                "import" => "Import: `import \"path\"`",
                "context" => "Global context: `context { var x: int }`",
                "enum" => "Enum: `enum Name { A, B, C }`",
                "parallel" => "Parallel block: `parallel Name { state … }`",
                _ => null
            };
        }

        if (detail != null)
            Send(stream, id, new { contents = new { kind = "markdown", value = detail } });
        else
            Send(stream, id, null);
    }

    private void HandleFormatting(JsonElement root, Stream stream, JsonElement id)
    {
        var @params = root.GetProperty("params");
        var uri = @params.GetProperty("textDocument").GetProperty("uri").GetString()!;
        if (!_docs.TryGetValue(uri, out var doc) || doc.Text == null)
        {
            Send(stream, id, Array.Empty<object>()); return;
        }

        var formatted = FormatCode(doc.Text);
        var lines = doc.Text.Count(c => c == '\n') + 1;
        Send(stream, id, new[]
        {
            new
            {
                range = new LspRange
                {
                    start = new LspPosition { line = 0, character = 0 },
                    end = new LspPosition { line = lines, character = 0 }
                },
                newText = formatted
            }
        });
    }

    internal static string FormatCode(string code)
    {
        var lines = code.Split('\n');
        var sb = new StringBuilder();
        var depth = 0;

        foreach (var raw in lines)
        {
            var t = raw.Trim();
            if (t == "") { sb.AppendLine(); continue; }

            var opens = t.Count(c => c == '{');
            var closes = t.Count(c => c == '}');

            var writeDepth = depth;
            if (t.Length > 0 && t[0] == '}' && writeDepth > 0)
                writeDepth--;

            sb.Append(' ', writeDepth * 4);
            sb.AppendLine(t);

            depth += opens - closes;
            if (depth < 0) depth = 0;
        }

        return sb.ToString();
    }

    private static string GetWordAt(string text, int line, int col)
    {
        var lines = text.Split('\n');
        if (line >= lines.Length) return "";
        var l = lines[line];
        if (col > l.Length) return "";
        var start = col; while (start > 0 && char.IsLetterOrDigit(l[start - 1])) start--;
        var end = col; while (end < l.Length && char.IsLetterOrDigit(l[end])) end++;
        return start < end ? l[start..end] : "";
    }

    private void Send(Stream stream, JsonElement id, object? result)
    {
        var json = JsonSerializer.Serialize(new { jsonrpc = "2.0", id, result }, JsonOpts);
        Write(stream, json);
    }

    private void Notify(Stream stream, string method, object? @params)
    {
        var json = JsonSerializer.Serialize(new { jsonrpc = "2.0", method, @params }, JsonOpts);
        Write(stream, json);
    }

    private static void Write(Stream stream, string json)
    {
        var bytes = Encoding.UTF8.GetBytes(json);
        var header = Encoding.UTF8.GetBytes($"Content-Length: {bytes.Length}\r\n\r\n");
        stream.Write(header, 0, header.Length);
        stream.Write(bytes, 0, bytes.Length);
        stream.Flush();
    }

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private class DocState
    {
        public string Text { get; set; } = "";
        public ProgramNode? Ast { get; set; }
        public List<LspDiagnostic> Diagnostics { get; set; } = new();
    }

    private class LspPosition
    {
        [JsonPropertyName("line")] public int line { get; set; }
        [JsonPropertyName("character")] public int character { get; set; }
    }

    private class LspRange
    {
        [JsonPropertyName("start")] public LspPosition start { get; set; } = new();
        [JsonPropertyName("end")] public LspPosition end { get; set; } = new();
    }

    private class LspDiagnostic
    {
        [JsonPropertyName("range")] public LspRange range { get; set; } = new();
        [JsonPropertyName("severity")] public int severity { get; set; }
        [JsonPropertyName("message")] public string message { get; set; } = "";
        [JsonPropertyName("source")] public string source { get; set; } = "";
    }
}
