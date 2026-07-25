const std = @import("std");
const source_manager_mod = @import("source_manager.zig");

pub const SourceManager = source_manager_mod.SourceManager;

pub const FileLoader = struct {
    allocator: std.mem.Allocator,
    search_paths: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) FileLoader {
        return .{
            .allocator = allocator,
            .search_paths = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *FileLoader) void {
        self.search_paths.deinit();
    }

    pub fn addSearchPath(self: *FileLoader, path: []const u8) !void {
        try self.search_paths.append(path);
    }

    pub fn loadFile(self: *FileLoader, manager: *SourceManager, path: []const u8) !u32 {
        if (std.fs.path.isAbsolute(path)) {
            return manager.addSourceFromFile(path);
        }
        for (self.search_paths.items) |search| {
            var buf: std.fs.PathBuffer = undefined;
            const full = std.fs.path.join(self.allocator, &.{ search, path }) catch continue;
            defer self.allocator.free(full);
            _ = &buf;
            if (manager.addSourceFromFile(full)) |id| {
                return id;
            } else |_| {}
        }
        return manager.addSourceFromFile(path);
    }

    pub fn readFile(self: *FileLoader, path: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(path)) {
            return std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024 * 10);
        }
        for (self.search_paths.items) |search| {
            const full = std.fs.path.join(self.allocator, &.{ search, path }) catch continue;
            defer self.allocator.free(full);
            if (std.fs.cwd().readFileAlloc(self.allocator, full, 1024 * 1024 * 10)) |content| {
                return content;
            } else |_| {}
        }
        return error.FileNotFound;
    }
};
