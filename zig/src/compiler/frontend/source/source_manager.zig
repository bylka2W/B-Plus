const span_mod = @import("location/span.zig");
const std = @import("std");

pub const FileId = span_mod.FileId;
pub const SourceSpan = span_mod.SourceSpan;

pub const SourceLocation = struct {
    file_id: FileId,
    line: u32,
    col: u32,

    pub fn format(self: SourceLocation, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("{d}:{d}", .{ self.line, self.col });
    }
};

pub const SourceFile = struct {
    id: FileId,
    path: []const u8,
    content: []const u8,
    line_starts: std.ArrayList(u32),

    pub fn init(allocator: std.mem.Allocator, id: FileId, path: []const u8, content: []const u8) SourceFile {
        var lf = SourceFile{
            .id = id,
            .path = path,
            .content = content,
            .line_starts = std.ArrayList(u32).init(allocator),
        };
        lf.computeLineStarts();
        return lf;
    }

    pub fn deinit(self: *SourceFile) void {
        self.line_starts.deinit();
    }

    pub fn getLine(self: SourceFile, line_num: u32) ?[]const u8 {
        if (line_num == 0 or line_num > self.line_starts.items.len) return null;
        const start = self.line_starts.items[line_num - 1];
        const end = if (line_num < self.line_starts.items.len)
            self.line_starts.items[line_num]
        else
            @as(u32, @intCast(self.content.len));
        return self.content[start..end];
    }

    pub fn spanToText(self: SourceFile, span: SourceSpan) []const u8 {
        if (span.end <= self.content.len and span.start <= span.end) {
            return self.content[span.start..span.end];
        }
        return "";
    }

    pub fn spanToLocation(self: SourceFile, span: SourceSpan) SourceLocation {
        return span.toLocation(self.line_starts.items);
    }

    fn computeLineStarts(self: *SourceFile) void {
        self.line_starts.append(0) catch return;
        for (self.content, 0..) |ch, i| {
            if (ch == '\n') {
                const next: u32 = @intCast(i + 1);
                self.line_starts.append(next) catch break;
            }
        }
    }
};

pub const SourceManager = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayList(SourceFile),
    next_file_id: FileId,

    pub fn init(allocator: std.mem.Allocator) SourceManager {
        return .{
            .allocator = allocator,
            .files = std.ArrayList(SourceFile).init(allocator),
            .next_file_id = 0,
        };
    }

    pub fn deinit(self: *SourceManager) void {
        for (self.files.items) |*f| f.deinit();
        self.files.deinit();
    }

    pub fn addSource(self: *SourceManager, path: []const u8, content: []const u8) FileId {
        const id = self.next_file_id;
        self.next_file_id += 1;
        const owned_path = self.allocator.dupe(u8, path) catch return id;
        const owned_content = self.allocator.dupe(u8, content) catch return id;
        self.files.append(SourceFile.init(self.allocator, id, owned_path, owned_content)) catch return id;
        return id;
    }

    pub fn addSourceFromFile(self: *SourceManager, path: []const u8) !FileId {
        const content = try std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024 * 10);
        return self.addSource(path, content);
    }

    pub fn getFile(self: *const SourceManager, id: FileId) ?*const SourceFile {
        if (id < self.files.items.len) return &self.files.items[id];
        return null;
    }

    pub fn getFileMut(self: *SourceManager, id: FileId) ?*SourceFile {
        if (id < self.files.items.len) return &self.files.items[id];
        return null;
    }

    pub fn spanToLocation(self: *const SourceManager, span: SourceSpan) ?SourceLocation {
        const file = self.getFile(span.file_id) orelse return null;
        return file.spanToLocation(span);
    }

    pub fn spanToText(self: *const SourceManager, span: SourceSpan) ?[]const u8 {
        const file = self.getFile(span.file_id) orelse return null;
        return file.spanToText(span);
    }

    pub fn fileCount(self: *const SourceManager) usize {
        return self.files.items.len;
    }
};
