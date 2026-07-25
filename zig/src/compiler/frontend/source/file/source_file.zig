const std = @import("std");
const span_mod = @import("../location/span.zig");
const line_table_mod = @import("../location/line_table.zig");

pub const SourceSpan = span_mod.SourceSpan;
pub const Position = span_mod.Position;
pub const LineTable = line_table_mod.LineTable;

pub const SourceFile = struct {
    id: u32,
    path: []const u8,
    content: []const u8,
    line_table: LineTable,

    pub fn init(allocator: std.mem.Allocator, id: u32, path: []const u8, content: []const u8) SourceFile {
        var lt = LineTable.init(allocator);
        lt.compute(content);
        return .{
            .id = id,
            .path = path,
            .content = content,
            .line_table = lt,
        };
    }

    pub fn deinit(self: *SourceFile) void {
        self.line_table.deinit();
    }

    pub fn getLine(self: *const SourceFile, line: u32) []const u8 {
        const range = self.line_table.lineRange(line, @intCast(self.content.len));
        if (range.start < range.end and range.end <= self.content.len) {
            return self.content[range.start..range.end];
        }
        return "";
    }

    pub fn spanToText(self: *const SourceFile, s: SourceSpan) []const u8 {
        if (s.end <= self.content.len and s.start <= s.end) {
            return self.content[s.start..s.end];
        }
        return "";
    }

    pub fn spanToPosition(self: *const SourceFile, s: SourceSpan) Position {
        return self.line_table.spanToLineCol(s);
    }

    pub fn spanToLocation(self: *const SourceFile, s: SourceSpan) Location {
        return .{
            .file_id = self.id,
            .pos = self.spanToPosition(s),
        };
    }

    pub const Location = struct {
        file_id: u32,
        pos: Position,
    };
};
