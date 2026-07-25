const std = @import("std");

pub const PathId = struct {
    index: u32,

    pub const INVALID = PathId{ .index = std.math.maxInt(u32) };

    pub fn new(index: u32) PathId {
        return .{ .index = index };
    }

    pub fn isValid(self: PathId) bool {
        return self.index != std.math.maxInt(u32);
    }
};

pub const SegmentId = struct {
    index: u32,

    pub const INVALID = SegmentId{ .index = std.math.maxInt(u32) };
};

pub const PathSegment = struct {
    name: u32,
    parent: ?PathId,
};

pub const PathInterner = struct {
    segments: std.ArrayList(PathSegment),
    arena: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PathInterner {
        return .{
            .segments = std.ArrayList(PathSegment).init(allocator),
            .arena = allocator,
        };
    }

    pub fn deinit(self: *PathInterner) void {
        self.segments.deinit();
    }

    pub fn push(self: *PathInterner, name: u32, parent: ?PathId) !PathId {
        const id = PathId.new(@intCast(self.segments.items.len));
        try self.segments.append(.{ .name = name, .parent = parent });
        return id;
    }

    pub fn getSegment(self: *const PathInterner, id: PathId) ?PathSegment {
        if (id.index < self.segments.items.len) return self.segments.items[id.index];
        return null;
    }

    pub fn getSegmentName(self: *const PathInterner, id: PathId) u32 {
        if (self.getSegment(id)) |seg| return seg.name;
        return 0;
    }

    pub fn getSegmentParent(self: *const PathInterner, id: PathId) ?PathId {
        if (self.getSegment(id)) |seg| return seg.parent;
        return null;
    }

    pub fn resolveSegments(self: *const PathInterner, id: PathId, symbol_interner: anytype) !std.ArrayList([]const u8) {
        var result = std.ArrayList([]const u8).init(self.arena);
        var current: ?PathId = id;
        while (current) |cid| {
            const seg = self.getSegment(cid) orelse break;
            try result.append(symbol_interner.resolve(seg.name));
            current = seg.parent;
        }
        std.mem.reverse([]const u8, result.items);
        return result;
    }

    pub fn count(self: *const PathInterner) u32 {
        return @intCast(self.segments.items.len);
    }
};
