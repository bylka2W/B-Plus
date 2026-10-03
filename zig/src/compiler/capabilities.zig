// `bpc capabilities` — the machine-readable contract between the compiler and
// any IDE or tool (Stage 12).
//
// The rule: an extension must never guess what the compiler can do. It asks,
// and gets an answer. Everything reported here must be generated from the
// compiler's own data, not hand-maintained, otherwise the contract rots.
const std = @import("std");
const bplus_builtin = @import("frontend/syntax/builtin.zig");
const keyword = @import("frontend/syntax/token/keyword.zig");
const version = @import("../version.zig");

/// Writes a JSON string literal, escaping per RFC 8259.
/// Used for every string field so a diagnostic message containing a quote,
/// a backslash or a newline can never produce invalid JSON.
pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn writeStringArray(writer: anytype, name: []const u8, items: []const []const u8) !void {
    try writer.print("  {s}: [", .{name});
    for (items, 0..) |it, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, it);
    }
    try writer.writeAll("],\n");
}

/// Keywords straight out of the lexer's table, so the list can never drift.
fn keywordList(allocator: std.mem.Allocator) ![]const []const u8 {
    var list = std.ArrayList([]const u8).init(allocator);
    for (keyword.keywords.keys()) |k| {
        try list.append(k);
    }
    return list.toOwnedSlice();
}

fn writeCommand(
    writer: anytype,
    name_str: []const u8,
    summary: []const u8,
    input: []const u8,
    comptime inputs: usize,
) !void {
    try writer.print(
        "    {{\"command\": ",
        .{},
    );
    try writeJsonString(writer, name_str);
    try writer.writeAll(", \"summary\": ");
    try writeJsonString(writer, summary);
    try writer.writeAll(", \"inputs\": [");
    for (0..inputs) |i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, if (i == 0) input else "");
    }
    try writer.writeAll("]}");
}

/// Truthful capability report. A flag is only `true` when the corresponding
/// code path actually exists and is wired into main().
pub fn render(writer: anytype, allocator: std.mem.Allocator) !void {
    const kws = try keywordList(allocator);
    defer allocator.free(kws);

    const t = @import("builtin").target;

    try writer.writeAll("{\n");

    try writer.print("  \"schemaVersion\": {d},\n", .{version.capabilities_schema});

    try writer.writeAll("  \"compiler\": {");
    try writeJsonString(writer, "name");
    try writer.writeAll(": ");
    try writeJsonString(writer, version.name);
    try writer.writeAll(", ");
    try writeJsonString(writer, "version");
    try writer.writeAll(": ");
    try writeJsonString(writer, version.version);
    try writer.writeAll(", ");
    try writeJsonString(writer, "zigVersion");
    try writer.writeAll(": ");
    try writeJsonString(writer, @import("builtin").zig_version_string);
    try writer.writeAll("},\n");

    try writer.writeAll("  \"target\": {");
    try writeJsonString(writer, "os");
    try writer.writeAll(": ");
    try writeJsonString(writer, @tagName(t.os.tag));
    try writer.writeAll(", ");
    try writeJsonString(writer, "arch");
    try writer.writeAll(": ");
    try writeJsonString(writer, @tagName(t.cpu.arch));
    try writer.print(", \"pointerBits\": {d}, ", .{@bitSizeOf(usize)});
    try writeJsonString(writer, "endian");
    try writer.writeAll(": ");
    try writeJsonString(writer, @tagName(t.cpu.arch.endian()));
    try writer.writeAll(", ");
    try writeJsonString(writer, "abi");
    try writer.writeAll(": ");
    try writeJsonString(writer, @tagName(t.abi));
    try writer.writeAll("},\n");

    try writer.writeAll("  \"language\": {\n");
    try writeStringArray(writer, "fileExtensions", &bplus_builtin.file_extensions);
    try writeStringArray(writer, "keywords", kws);
    try writeStringArray(writer, "planKeywords", &bplus_builtin.plan_keywords);
    try writeStringArray(writer, "scalarTypes", &bplus_builtin.scalar_types);
    try writeStringArray(writer, "builtins", &bplus_builtin.builtin_functions);
    try writer.writeAll("    \"supportsRussianKeywords\": true\n");
    try writer.writeAll("  },\n");

    try writer.writeAll("  \"diagnostics\": {\n");
    try writer.writeAll("    \"schema\": ");
    try writeJsonString(writer, "bpc-diagnostics-v1");
    try writer.print(",\n    \"schemaVersion\": {d},\n", .{version.diagnostics_schema});
    try writeJsonString(writer, "command");
    try writer.writeAll(": ");
    try writeJsonString(writer, "diagnose");
    try writer.writeAll(", ");
    try writeJsonString(writer, "formats");
    try writer.writeAll(": [\"human\", \"json\"]\n");
    try writer.writeAll("  },\n");

    try writer.writeAll("  \"commands\": [\n");
    try writeCommand(writer, "build", "compile to object/executable", "file", 1);
    try writer.writeAll(",\n");
    try writeCommand(writer, "check", "run every IR verifier without codegen", "file", 1);
    try writer.writeAll(",\n");
    try writeCommand(writer, "run", "build and execute", "file", 1);
    try writer.writeAll(",\n");
    try writeCommand(writer, "link", "link an object file", "obj", 1);
    try writer.writeAll(",\n");
    try writeCommand(writer, "test", "run a .bpt test descriptor", "file", 1);
    try writer.writeAll(",\n");
    try writeCommand(writer, "doctor", "compiler health check", "", 0);
    try writer.writeAll("\n  ],\n");

    try writer.writeAll("  \"capabilities\": {\n");

    try writer.writeAll("    \"commands\": {");
    try writeJsonString(writer, "build");
    try writer.writeAll(": true, ");
    try writeJsonString(writer, "check");
    try writer.writeAll(": true, ");
    try writeJsonString(writer, "run");
    try writer.writeAll(": true, ");
    try writeJsonString(writer, "link");
    try writer.writeAll(": true, ");
    try writeJsonString(writer, "test");
    try writer.writeAll(": true, ");
    try writeJsonString(writer, "doctor");
    try writer.writeAll(": true, ");
    try writeJsonString(writer, "diagnose");
    try writer.writeAll(": true, ");
    try writeJsonString(writer, "format");
    try writer.writeAll(": false, ");
    try writeJsonString(writer, "lsp");
    try writer.writeAll(": false, ");
    try writeJsonString(writer, "debug");
    try writer.writeAll(": false, ");
    try writeJsonString(writer, "profile");
    try writer.writeAll(": false, ");
    try writeJsonString(writer, "project");
    try writer.writeAll(": false\n");
    try writer.writeAll("    },\n");

    // Frontend / language features. `false` here is a known bug, and an IDE
    // is expected to tell the user rather than silently misbehave.
    try writer.writeAll("    \"language\": {");
    try writeJsonString(writer, "spanInformation");
    try writer.writeAll(": false, ");
    try writeJsonString(writer, "spansOnAst");
    try writer.writeAll(": false, ");
    try writeJsonString(writer, "matchStatement");
    try writer.writeAll(": false, ");
    try writeJsonString(writer, "rangeFor");
    try writer.writeAll(": false, ");
    try writeJsonString(writer, "emptyEntryBlock");
    try writer.writeAll(": false, ");
    try writeJsonString(writer, "structFieldPerLine");
    try writer.writeAll(": true\n");
    try writer.writeAll("    },\n");

    try writer.writeAll("    \"limits\": {");
    try writeJsonString(writer, "diagnosticsPerRun");
    try writer.writeAll(": 1\n");
    try writer.writeAll("    }\n");

    try writer.writeAll("  }\n");
    try writer.writeAll("}\n");
}