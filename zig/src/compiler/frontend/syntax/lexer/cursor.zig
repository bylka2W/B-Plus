const std = @import("std");

pub const Cursor = struct {
    source: []const u8,
    pos: u32,
    start: u32,

    pub fn init(source: []const u8) Cursor {
        return .{ .source = source, .pos = 0, .start = 0 };
    }

    pub fn advance(self: *Cursor) ?u8 {
        if (self.pos >= self.source.len) return null;
        const ch = self.source[self.pos];
        self.pos += 1;
        return ch;
    }

    pub fn peek(self: *const Cursor) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    pub fn peekAt(self: *const Cursor, offset: u32) ?u8 {
        const idx = self.pos + offset;
        if (idx >= self.source.len) return null;
        return self.source[idx];
    }

    pub fn peekAhead(self: *const Cursor, distance: u32) ?u8 {
        const idx = self.pos + distance;
        if (idx >= self.source.len) return null;
        return self.source[idx];
    }

    pub fn matches(self: *const Cursor, text: []const u8) bool {
        if (self.pos + text.len > self.source.len) return false;
        return std.mem.eql(u8, self.source[self.pos .. self.pos + text.len], text);
    }

    pub fn matchesOneOf(self: *const Cursor, comptime texts: []const []const u8) bool {
        inline for (texts) |text| {
            if (self.matches(text)) return true;
        }
        return false;
    }

    pub fn skipWhitespace(self: *Cursor) void {
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                ' ', '\t', '\r' => self.pos += 1,
                else => break,
            }
        }
    }

    pub fn skipNewline(self: *Cursor) bool {
        if (self.pos >= self.source.len) return false;
        if (self.source[self.pos] == '\n') {
            self.pos += 1;
            return true;
        }
        if (self.source[self.pos] == '\r' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '\n') {
            self.pos += 2;
            return true;
        }
        return false;
    }

    pub fn skipLineComment(self: *Cursor) void {
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
    }

    pub fn skipBlockComment(self: *Cursor) void {
        var depth: u32 = 1;
        while (self.pos < self.source.len and depth > 0) {
            if (self.source[self.pos] == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '*') {
                depth += 1;
                self.pos += 2;
            } else if (self.source[self.pos] == '*' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
                depth -= 1;
                self.pos += 2;
            } else {
                self.pos += 1;
            }
        }
    }

    pub fn mark(self: *const Cursor) u32 {
        return self.pos;
    }

    pub fn restore(self: *Cursor, pos: u32) void {
        self.pos = pos;
    }

    pub fn startSlice(self: *Cursor) void {
        self.start = self.pos;
    }

    pub fn getSlice(self: *const Cursor) []const u8 {
        return self.source[self.start..self.pos];
    }

    pub fn remaining(self: *const Cursor) []const u8 {
        if (self.pos >= self.source.len) return "";
        return self.source[self.pos..];
    }

    pub fn isEof(self: *const Cursor) bool {
        return self.pos >= self.source.len;
    }

    pub fn isDigit(self: *const Cursor) bool {
        if (self.peek()) |ch| return ch >= '0' and ch <= '9';
        return false;
    }

    pub fn isAlpha(self: *const Cursor) bool {
        if (self.peek()) |ch| return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
        return false;
    }

    pub fn isAlphaNum(self: *const Cursor) bool {
        if (self.peek()) |ch| return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
        return false;
    }
};
