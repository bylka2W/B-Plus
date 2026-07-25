const std = @import("std");
const diag_mod = @import("../core/diagnostic.zig");
const severity_mod = @import("../core/severity.zig");

pub const Diagnostic = diag_mod.Diagnostic;
pub const Severity = severity_mod.Severity;

pub fn renderJson(writer: anytype, diagnostics: []const Diagnostic) !void {
    try writer.print("[\n", .{});
    for (diagnostics, 0..) |d, i| {
        if (i > 0) try writer.print(",\n", .{});
        try writer.print("  {{\n", .{});
        try writer.print("    \"severity\": \"{s}\",\n", .{@tagName(d.severity)});
        try writer.print("    \"message\": \"{s}\"", .{d.message});
        if (d.code) |code| {
            try writer.print(",\n    \"code\": {d}", .{code});
        }
        if (d.labels.items.len > 0) {
            try writer.print(",\n    \"labels\": [\n", .{});
            for (d.labels.items, 0..) |l, li| {
                if (li > 0) try writer.print(",\n", .{});
                try writer.print("      {{\n", .{});
                try writer.print("        \"style\": \"{s}\"", .{@tagName(l.style)});
                try writer.print(",\n        \"message\": \"{s}\"", .{l.message});
                if (l.span) |s| {
                    try writer.print(",\n        \"span\": {{ \"file\": {d}, \"start\": {d}, \"end\": {d} }}", .{ s.file_id, s.start, s.end });
                }
                try writer.print("\n      }}", .{});
            }
            try writer.print("\n    ]", .{});
        }
        if (d.notes.items.len > 0) {
            try writer.print(",\n    \"notes\": [\n", .{});
            for (d.notes.items, 0..) |n, ni| {
                if (ni > 0) try writer.print(",\n", .{});
                try writer.print("      {{ \"message\": \"{s}\" }}", .{n.message});
            }
            try writer.print("\n    ]", .{});
        }
        if (d.fix) |f| {
            try writer.print(",\n    \"fix\": \"{s}\"", .{f});
        }
        try writer.print("\n  }}", .{});
    }
    try writer.print("\n]\n", .{});
}
