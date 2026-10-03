// `bpc diagnose --format json` — the one diagnostic format every consumer uses
// (editor, terminal, CI). Schema: bpc-diagnostics-v1.
//
// Requirements that the earlier prototype in render/json.zig failed:
//   * every string is escaped, so a message containing `"` or `\` cannot
//     produce invalid JSON;
//   * ranges are 1-based line/column *and* carry byte offsets, because an LSP
//     needs UTF-16 units while a terminal wants line/col;
//   * a stable string code (`B+E4001`) sits next to the numeric one.
const std = @import("std");
const collector = @import("../collector.zig");
const capabilities = @import("../../../capabilities.zig");

const Collector = collector.Collector;
const LineTable = collector.LineTable;
const Code = collector.Code;

pub const ErrorKind = enum { @"error", warning, note };

fn severityToLsp(s: collector.Severity) []const u8 {
    return switch (s) {
        .note => "note",
        .warning => "warning",
        .@"error" => "error",
        .fatal => "error",
        .ice => "error",
    };
}

/// byte offset -> 0-based UTF-16 column, which is what LSP positions use.
/// Non-BMP code points count as two units, matching the LSP specification.
fn utf16Col(content: []const u8, line_start: u32, byte_off: u32) u32 {
    const end = @min(byte_off, @as(u32, @intCast(content.len)));
    if (end <= line_start) return 0;
    var units: u32 = 0;
    var i = line_start;
    while (i < end and i < content.len) {
        const c = content[i];
        var size: u32 = 1;
        if (c < 0x80) {
            size = 1;
        } else if (c < 0xE0) {
            size = 2;
        } else if (c < 0xF0) {
            size = 3;
        } else {
            size = 4;
        }
        if (i + size > end) break;
        units += if (size == 4) 2 else 1;
        i += size;
    }
    return units;
}

pub fn render(
    writer: anytype,
    alloc: std.mem.Allocator,
    c: *const Collector,
    file_path: []const u8,
    source: []const u8,
) !void {
    _ = alloc;

    var table = LineTable.init(std.heap.page_allocator);
    defer table.deinit();
    table.compute(source);

    try writer.writeAll("{\n");
    try writer.print("  \"schema\": \"bpc-diagnostics-v1\",\n", .{});
    try writer.print("  \"schemaVersion\": {d},\n", .{capabilities_version()});
    try writer.writeAll("  \"file\": ");
    try capabilities.writeJsonString(writer, file_path);
    try writer.print(",\n  \"errorCount\": {d},\n", .{countErrors(c)});
    try writer.writeAll("  \"diagnostics\": [");

    for (c.items.items, 0..) |d, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n    {\n");

        try writer.writeAll("      \"code\": ");
        if (d.code) |num| {
            try writer.print("\"{s}\"", .{codeIdFor(num)});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\n      \"severity\": ");
        try capabilities.writeJsonString(writer, severityToLsp(d.severity));
        try writer.writeAll(",\n      \"message\": ");
        try capabilities.writeJsonString(writer, d.message);

        if (d.primaryLabel()) |label| {
            if (label.span) |sp| {
                const start_off = @min(sp.start, @as(u32, @intCast(source.len)));
                const end_off = @min(@max(sp.end, sp.start + 1), @as(u32, @intCast(source.len)));
                const sl = table.offsetToLine(start_off);
                const el = table.offsetToLine(end_off);
                const sl_start = table.lineStart(sl);
                const el_start = table.lineStart(el);

                try writer.writeAll(",\n      \"range\": {");
                try writer.writeAll("\"start\": {");
                try writer.print("\"line\": {d}, \"character\": {d}", .{ sl - 1, utf16Col(source, sl_start, start_off) });
                try writer.writeAll("}, \"end\": {");
                try writer.print("\"line\": {d}, \"character\": {d}", .{ el - 1, utf16Col(source, el_start, end_off) });
                try writer.writeAll("}}");

                try writer.writeAll(",\n      \"location\": {");
                try writer.writeAll("\"file\": ");
                try capabilities.writeJsonString(writer, file_path);
                try writer.print(", \"line\": {d}, \"column\": {d}", .{ sl, table.spanToLineCol(sp).col });
                try writer.writeAll("}");
            }
        }

        try writer.writeAll("\n    }");
    }

    try writer.writeAll("\n  ]\n}\n");
}

fn countErrors(c: *const Collector) u32 {
    var n: u32 = 0;
    for (c.items.items) |d| {
        if (d.severity.isError()) n += 1;
    }
    return n;
}

fn capabilities_version() u32 {
    return @import("../../../../version.zig").diagnostics_schema;
}

fn codeIdFor(num: u32) []const u8 {
    inline for (@typeInfo(Code).@"enum".fields) |f| {
        const c: Code = @enumFromInt(f.value);
        if (c.number() == num) return c.id();
    }
    return "B+E0000";
}