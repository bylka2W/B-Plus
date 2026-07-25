const std = @import("std");
const source_file_mod = @import("source_file.zig");
const span_mod = @import("../location/span.zig");

pub const SourceFile = source_file_mod.SourceFile;
pub const SourceSpan = span_mod.SourceSpan;

pub const SourceManager = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayList(SourceFile),
    path_index: std.StringHashMap(u32),

    pub fn init(allocator: std.mem.Allocator) SourceManager {
        return .{
            .allocator = allocator,
            .files = std.ArrayList(SourceFile).init(allocator),
            .path_index = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *SourceManager) void {
        for (self.files.items) |*f| f.deinit();
        self.files.deinit();
        self.path_index.deinit();
    }

    pub fn addSource(self: *SourceManager, path: []const u8, content: []const u8) !u32 {
        const id: u32 = @intCast(self.files.items.len);
        const owned_path = try self.allocator.dupe(u8, path);
        const owned_content = try self.allocator.dupe(u8, content);
        try self.files.append(SourceFile.init(self.allocator, id, owned_path, owned_content));
        try self.path_index.put(owned_path, id);
        return id;
    }

    pub fn addSourceFromFile(self: *SourceManager, path: []const u8) !u32 {
        if (self.path_index.get(path)) |existing| return existing;
        const content = try std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024 * 10);
        return self.addSource(path, content);
    }

    pub fn getFile(self: *const SourceManager, id: u32) ?*const SourceFile {
        if (id < self.files.items.len) return &self.files.items[id];
        return null;
    }

    pub fn getFileMut(self: *SourceManager, id: u32) ?*SourceFile {
        if (id < self.files.items.len) return &self.files.items[id];
        return null;
    }

    pub fn getFileByPath(self: *const SourceManager, path: []const u8) ?*const SourceFile {
        const id = self.path_index.get(path) orelse return null;
        return self.getFile(id);
    }

    pub fn spanToText(self: *const SourceManager, s: SourceSpan) ?[]const u8 {
        const file = self.getFile(s.file_id) orelse return null;
        return file.spanToText(s);
    }

    pub fn spanToLocation(self: *const SourceManager, s: SourceSpan) ?SourceFile.Location {
        const file = self.getFile(s.file_id) orelse return null;
        return file.spanToLocation(s);
    }

    pub fn fileCount(self: *const SourceManager) u32 {
        return @intCast(self.files.items.len);
    }
};
