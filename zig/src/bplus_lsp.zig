const std = @import("std");
const parser = @import("compiler/frontend/parser/parser.zig");
const sema_mod = @import("compiler/frontend/sema/sema.zig");
const ast = @import("compiler/frontend/ast.zig");

pub const std_options: std.Options = .{
    .logFn = captureLogFn,
};

var g_allocator: std.mem.Allocator = undefined;
var g_capture_on: bool = false;
var g_captured: std.ArrayList([]const u8) = undefined;

const Document = struct {
    text: []const u8,
};

fn captureLogFn(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    _ = level;
    _ = scope;
    if (!g_capture_on) return;
    const msg = std.fmt.allocPrint(g_allocator, format, args) catch return;
    g_captured.append(msg) catch return;
}

const Frame = struct {
    body: []const u8,
};

fn readFrame(reader: anytype, alloc: std.mem.Allocator) !Frame {
    var content_length: usize = 0;
    var saw_header = false;
    while (true) {
        var line_buf: [4096]u8 = undefined;
        const line = try reader.readUntilDelimiterOrEof(&line_buf, '\n');
        if (line == null) return error.Eof;
        var l = line.?;
        if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
        if (l.len == 0) break;
        saw_header = true;
        if (std.ascii.startsWithIgnoreCase(l, "Content-Length:")) {
            const v = std.mem.trim(u8, l["Content-Length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, v, 10) catch continue;
        }
    }
    if (!saw_header) return error.NoHeader;
    const body = try alloc.alloc(u8, content_length);
    const n = try reader.readAll(body);
    if (n != content_length) return error.Truncated;
    return .{ .body = body };
}

fn sendFrame(writer: anytype, value: std.json.Value) !void {
    var buf = std.ArrayList(u8).init(g_allocator);
    defer buf.deinit();
    try std.json.stringify(value, .{}, buf.writer());
    try writer.print("Content-Length: {d}\r\n\r\n", .{buf.items.len});
    try writer.writeAll(buf.items);
}

fn sendResponse(writer: anytype, id: i64, result: std.json.Value) !void {
    var obj = std.json.ObjectMap.init(g_allocator);
    try obj.put("jsonrpc", .{ .string = "2.0" });
    try obj.put("id", .{ .integer = id });
    try obj.put("result", result);
    try sendFrame(writer, .{ .object = obj });
}

fn sendNotify(writer: anytype, method: []const u8, params: std.json.Value) !void {
    var obj = std.json.ObjectMap.init(g_allocator);
    try obj.put("jsonrpc", .{ .string = "2.0" });
    try obj.put("method", .{ .string = method });
    try obj.put("params", params);
    try sendFrame(writer, .{ .object = obj });
}

fn stripFileScheme(uri: []const u8) []const u8 {
    if (std.mem.startsWith(u8, uri, "file://")) return uri["file://".len..];
    return uri;
}

const Diag = struct {
    file: []const u8,
    line: u32,
    message: []const u8,
};

fn parseDiag(msg: []const u8) ?Diag {
    const marker = " error: ";
    const idx = std.mem.lastIndexOf(u8, msg, marker) orelse return null;
    const rest = msg[idx + marker.len ..];
    if (idx < 2 or msg[idx - 1] != ':') return null;
    var j = idx - 1;
    while (j > 0 and std.ascii.isDigit(msg[j - 1])) j -= 1;
    if (j == idx - 1 or j == 0 or msg[j - 1] != ':') return null;
    const line = std.fmt.parseInt(u32, msg[j .. idx - 1], 10) catch return null;
    return .{ .file = msg[0 .. j - 1], .line = line, .message = rest };
}

fn lineLength(text: []const u8, line0: usize) usize {
    var pos: usize = 0;
    var line: usize = 0;
    while (pos < text.len) {
        if (line == line0) {
            const end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
            var l = end - pos;
            if (l > 0 and text[end - 1] == '\r') l -= 1;
            return l;
        }
        pos = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse break;
        pos += 1;
        line += 1;
    }
    return 0;
}

fn analyzeDocument(alloc: std.mem.Allocator, uri: []const u8, text: []const u8) std.json.Value {
    const file_path = stripFileScheme(uri);

    g_capture_on = true;
    g_captured.clearRetainingCapacity();
    defer g_capture_on = false;

    var src: []const u8 = text;
    if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) src = src[3..];

    var p = parser.Parser.init(alloc, src, file_path);
    var program: ?ast.ProgramNode = null;
    if (p.parse()) |pgm| {
        program = pgm;
    } else |err| {
        g_captured.append(std.fmt.allocPrint(alloc, "{s}:1: error: parse error: {s}", .{ file_path, @errorName(err) }) catch return emptyDiags(uri)) catch {};
        return buildDiagnostics(uri, text);
    }

    defer program.?.deinit();
    _ = sema_mod.analyze(alloc, program.?, src, file_path) catch {};

    return buildDiagnostics(uri, text);
}

fn emptyDiags(uri: []const u8) std.json.Value {
    return buildDiagnostics(uri, "");
}

fn buildDiagnostics(uri: []const u8, text: []const u8) std.json.Value {
    var items = std.json.Array.init(g_allocator);
    for (g_captured.items) |msg| {
        const d = parseDiag(msg) orelse continue;
        const line0: usize = if (d.line > 0) d.line - 1 else 0;
        const ll = lineLength(text, line0);

        var start = std.json.ObjectMap.init(g_allocator);
        start.put("line", .{ .integer = @intCast(line0) }) catch continue;
        start.put("character", .{ .integer = 0 }) catch continue;
        var end = std.json.ObjectMap.init(g_allocator);
        end.put("line", .{ .integer = @intCast(line0) }) catch continue;
        end.put("character", .{ .integer = @intCast(ll) }) catch continue;
        var range = std.json.ObjectMap.init(g_allocator);
        range.put("start", .{ .object = start }) catch continue;
        range.put("end", .{ .object = end }) catch continue;

        var item = std.json.ObjectMap.init(g_allocator);
        item.put("range", .{ .object = range }) catch continue;
        item.put("severity", .{ .integer = 1 }) catch continue;
        item.put("message", .{ .string = d.message }) catch continue;
        items.append(.{ .object = item }) catch continue;
    }

    var params = std.json.ObjectMap.init(g_allocator);
    params.put("uri", .{ .string = uri }) catch {};
    params.put("diagnostics", .{ .array = items }) catch {};

    return .{ .object = params };
}

fn freeCaptured() void {
    for (g_captured.items) |m| g_allocator.free(m);
    g_captured.clearRetainingCapacity();
}

fn handleMessage(writer: anytype, docs: *std.StringHashMap([]const u8), value: std.json.Value) !void {
    const obj = value.object;
    const method = if (obj.get("method")) |m| if (m == .string) m.string else "" else "";
    const id_val = obj.get("id");
    const id: i64 = if (id_val != null) id_val.?.integer else 0;
    const has_id = id_val != null;

    if (std.mem.eql(u8, method, "initialize")) {
        var caps = std.json.ObjectMap.init(g_allocator);
        caps.put("textDocumentSync", .{ .integer = 1 }) catch {};
        var server = std.json.ObjectMap.init(g_allocator);
        server.put("name", .{ .string = "bplus-lsp" }) catch {};
        server.put("version", .{ .string = "0.1.0" }) catch {};
        var result = std.json.ObjectMap.init(g_allocator);
        result.put("capabilities", .{ .object = caps }) catch {};
        result.put("serverInfo", .{ .object = server }) catch {};
        try sendResponse(writer, id, .{ .object = result });
        return;
    }

    if (std.mem.eql(u8, method, "shutdown")) {
        try sendResponse(writer, id, .null);
        return;
    }

    if (std.mem.eql(u8, method, "exit")) {
        std.process.exit(0);
    }

    if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        const td = obj.get("params").?.object.get("textDocument").?.object;
        const uri = td.get("uri").?.string;
        const text = td.get("text").?.string;
        try upsert(docs, uri, text);
        const diags_value = analyzeDocument(g_allocator, uri, text);
        defer freeCaptured();
        try sendNotify(writer, "textDocument/publishDiagnostics", diags_value);
        return;
    }

    if (std.mem.eql(u8, method, "textDocument/didChange")) {
        const td = obj.get("params").?.object.get("textDocument").?.object;
        const uri = td.get("uri").?.string;
        const changes = obj.get("params").?.object.get("contentChanges").?.array;
        const last = changes.items[changes.items.len - 1];
        const text = last.object.get("text").?.string;
        try upsert(docs, uri, text);
        const diags_value = analyzeDocument(g_allocator, uri, text);
        defer freeCaptured();
        try sendNotify(writer, "textDocument/publishDiagnostics", diags_value);
        return;
    }

    if (std.mem.eql(u8, method, "textDocument/didSave")) {
        const td = obj.get("params").?.object.get("textDocument").?.object;
        const uri = td.get("uri").?.string;
        if (docs.get(uri)) |text| {
            const diags_value = analyzeDocument(g_allocator, uri, text);
            defer freeCaptured();
            try sendNotify(writer, "textDocument/publishDiagnostics", diags_value);
        }
        return;
    }

    if (std.mem.eql(u8, method, "textDocument/didClose")) {
        const td = obj.get("params").?.object.get("textDocument").?.object;
        const uri = td.get("uri").?.string;
        if (docs.fetchRemove(uri)) |kv| g_allocator.free(kv.value);
        const diags_value = emptyDiags(uri);
        try sendNotify(writer, "textDocument/publishDiagnostics", diags_value);
        return;
    }

    if (has_id) {
        try sendResponse(writer, id, .null);
    }
}

fn upsert(docs: *std.StringHashMap([]const u8), uri: []const u8, text: []const u8) !void {
    if (docs.get(uri)) |old| g_allocator.free(old);
    const u = try g_allocator.dupe(u8, uri);
    const t = try g_allocator.dupe(u8, text);
    try docs.put(u, t);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    g_allocator = alloc;
    g_captured = std.ArrayList([]const u8).init(alloc);
    defer g_captured.deinit();

    var docs = std.StringHashMap([]const u8).init(alloc);
    defer docs.deinit();

    const stdin = std.io.getStdIn();
    var reader = std.io.bufferedReader(stdin.reader());
    const stdout = std.io.getStdOut();
    const writer = stdout.writer();

    while (true) {
        const frame = readFrame(reader.reader(), alloc) catch break;
        defer alloc.free(frame.body);
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, frame.body, .{}) catch continue;
        defer parsed.deinit();
        handleMessage(writer, &docs, parsed.value) catch continue;
    }
}
