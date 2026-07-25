const std = @import("std");
const diag_mod = @import("../core/diagnostic.zig");
const severity_mod = @import("../core/severity.zig");

pub const Diagnostic = diag_mod.Diagnostic;
pub const Severity = severity_mod.Severity;

pub fn renderTerminal(writer: anytype, diagnostics: []const Diagnostic, files: anytype) !void {
    for (diagnostics) |d| {
        try writer.print("\x1b[0m{s}: ", .{d.severity.label()});
        try writer.print("{s}\x1b[0m\n", .{d.message});

        if (d.code) |code| {
            try writer.print("  code E{d:04}\n", .{code});
        }

        for (d.labels.items) |l| {
            if (l.span) |s| {
                const file = files.getFile(s.file_id);
                const line_text = if (file) |f| f.getLine(file.spanToLineCol(s).line) else "";
                if (file) |f| {
                    const pos = f.spanToPosition(s);
                    try writer.print("  --> {s}:{d}:{d}\n", .{ f.path, pos.line, pos.col });
                }
                try writer.print("  |\n", .{});
                try writer.print("  | {s}\n", .{line_text});
                const pos = if (file) |f| f.spanToPosition(s) else .{ .line = 0, .col = 0 };
                try writer.print("  | ", .{});
                var i: u32 = 0;
                while (i < pos.col - 1 and i < 200) : (i += 1) {
                    try writer.print(" ", .{});
                }
                const style: []const u8 = if (l.style == .primary) "\x1b[31m" else "\x1b[36m";
                try writer.print("{s}^", .{style});
                if (l.message.len > 0) {
                    try writer.print(" {s}", .{l.message});
                }
                try writer.print("\x1b[0m\n", .{});
            }
        }

        for (d.notes.items) |n| {
            try writer.print("  \x1b[36mnote\x1b[0m: {s}\n", .{n.message});
        }

        if (d.fix) |f| {
            try writer.print("  \x1b[32mhelp\x1b[0m: {s}\n", .{f});
        }

        try writer.print("\n", .{});
    }
}
