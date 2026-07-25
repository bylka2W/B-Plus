const std = @import("std");

pub const QueryContext = struct {
    allocator: std.mem.Allocator,
    cache: std.AutoHashMap(u64, QueryResult),
    dependencies: std.AutoHashMap(u64, std.ArrayList(u64)),

    pub const QueryResult = struct {
        data: ?*anyopaque,
        fingerprint: u64,
        valid: bool,
    };

    pub fn init(allocator: std.mem.Allocator) QueryContext {
        return .{
            .allocator = allocator,
            .cache = std.AutoHashMap(u64, QueryResult).init(allocator),
            .dependencies = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
        };
    }

    pub fn deinit(self: *QueryContext) void {
        var it = self.dependencies.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.dependencies.deinit();
        self.cache.deinit();
    }

    pub fn lookup(self: *const QueryContext, key: u64) ?QueryResult {
        return self.cache.get(key);
    }

    pub fn insert(self: *QueryContext, key: u64, result: QueryResult) !void {
        try self.cache.put(key, result);
    }

    pub fn invalidate(self: *QueryContext, key: u64) void {
        if (self.cache.getPtr(key)) |entry| {
            entry.valid = false;
        }
    }

    pub fn addDependency(self: *QueryContext, query: u64, depends_on: u64) !void {
        var deps = self.dependencies.getOrPut(query) catch return error.OutOfMemory;
        if (!deps.found_existing) {
            deps.value_ptr.* = std.ArrayList(u64).init(self.allocator);
        }
        try deps.value_ptr.append(depends_on);
    }

    pub fn invalidateTransitive(self: *QueryContext, key: u64) void {
        self.invalidate(key);
        if (self.dependencies.get(key)) |deps| {
            for (deps.items) |dep| {
                self.invalidateTransitive(dep);
            }
        }
    }
};
