const std = @import("std");

pub const Position = struct {
    line: u32,
    col: u32,

    pub fn zero() Position {
        return .{ .line = 1, .col = 1 };
    }

    pub fn advance(self: Position, bytes: u32) Position {
        return .{ .line = self.line, .col = self.col + bytes };
    }

    pub fn newLine(self: Position) Position {
        return .{ .line = self.line + 1, .col = 1 };
    }

    pub fn eql(self: Position, other: Position) bool {
        return self.line == other.line and self.col == other.col;
    }

    pub fn lessThan(self: Position, other: Position) bool {
        if (self.line != other.line) return self.line < other.line;
        return self.col < other.col;
    }

    pub fn format(self: Position, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("{d}:{d}", .{ self.line, self.col });
    }
};

pub const FileId = u32;

pub const SourceSpan = struct {
    file_id: FileId = 0,
    start: u32 = 0,
    end: u32 = 0,

    pub fn len(self: SourceSpan) u32 {
        return self.end - self.start;
    }

    pub fn isNull(self: SourceSpan) bool {
        return self.start == 0 and self.end == 0;
    }

    pub fn merge(a: SourceSpan, b: SourceSpan) SourceSpan {
        if (a.file_id != b.file_id) return a;
        return .{
            .file_id = a.file_id,
            .start = if (a.start < b.start) a.start else b.start,
            .end = if (a.end > b.end) a.end else b.end,
        };
    }

    pub fn contains(self: SourceSpan, offset: u32) bool {
        return offset >= self.start and offset < self.end;
    }

    pub fn toLocation(self: SourceSpan, line_starts: []const u32) Position {
        var line: u32 = 1;
        var last_offset: u32 = 0;
        for (line_starts, 1..) |offset, i| {
            if (self.start < offset) break;
            line = @intCast(i);
            last_offset = offset;
        }
        return .{
            .line = line,
            .col = self.start - last_offset + 1,
        };
    }

    pub fn overlaps(self: SourceSpan, other: SourceSpan) bool {
        if (self.file_id != other.file_id) return false;
        return self.start < other.end and other.start < self.end;
    }

    pub fn format(self: SourceSpan, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("[{d}:{d}..{d}:{d}]", .{ self.file_id, self.start, self.file_id, self.end });
    }
};
