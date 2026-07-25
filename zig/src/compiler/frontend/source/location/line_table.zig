const std = @import("std");
const span = @import("../location/span.zig");

pub const LineTable = struct {
    starts: std.ArrayList(u32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LineTable {
        return .{
            .starts = std.ArrayList(u32).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LineTable) void {
        self.starts.deinit();
    }

    pub fn compute(self: *LineTable, content: []const u8) void {
        self.starts.clearRetainingCapacity();
        self.starts.append(0) catch return;
        for (content, 0..) |ch, i| {
            if (ch == '\n') {
                self.starts.append(@intCast(i + 1)) catch break;
            }
        }
    }

    pub fn lineCount(self: *const LineTable) u32 {
        return @intCast(self.starts.items.len);
    }

    pub fn offsetToLine(self: *const LineTable, offset: u32) u32 {
        var lo: u32 = 0;
        var hi: u32 = @intCast(self.starts.items.len);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.starts.items[mid] <= offset) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    pub fn lineStart(self: *const LineTable, line: u32) u32 {
        if (line == 0 or line > self.starts.items.len) return 0;
        return self.starts.items[line - 1];
    }

    pub fn lineEnd(self: *const LineTable, line: u32, content_len: u32) u32 {
        if (line >= self.starts.items.len) return content_len;
        return self.starts.items[line];
    }

    pub fn lineRange(self: *const LineTable, line: u32, content_len: u32) struct { start: u32, end: u32 } {
        return .{
            .start = self.lineStart(line),
            .end = self.lineEnd(line, content_len),
        };
    }

    pub fn spanToLineCol(self: *const LineTable, s: span.SourceSpan) span.Position {
        const line = self.offsetToLine(s.start);
        const col = s.start - self.lineStart(line + 1);
        return .{ .line = line + 1, .col = col + 1 };
    }

    pub fn getLineText(self: *const LineTable, line: u32, content: []const u8) []const u8 {
        const start = self.lineStart(line);
        const end = self.lineEnd(line, @intCast(content.len));
        if (start < end and end <= content.len) return content[start..end];
        return "";
    }
};
