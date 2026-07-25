const std = @import("std");

pub fn typedId(comptime Tag: type) type {
    return struct {
        index: u32,

        const Self = @This();

        pub const INVALID = Self{ .index = std.math.maxInt(u32) };

        pub fn new(index: u32) Self {
            return .{ .index = index };
        }

        pub fn isValid(self: Self) bool {
            return self.index != std.math.maxInt(u32);
        }

        pub fn eql(self: Self, other: Self) bool {
            return self.index == other.index;
        }

        pub fn hash(self: Self) u32 {
            return std.hash_map.getAutoHashFn(u32)(undefined, self.index);
        }

        pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            try writer.print("{s}({d})", .{ @typeName(Tag), self.index });
        }
    };
}

pub const HirExprId = typedId(struct {});
pub const HirStmtId = typedId(struct {});
pub const HirItemId = typedId(struct {});
pub const HirBodyId = typedId(struct {});
pub const HirPatId = typedId(struct {});
pub const HirTypeId = typedId(struct {});
pub const HirDefId = typedId(struct {});
pub const HirSymbolId = typedId(struct {});
pub const HirLabelId = typedId(struct {});
pub const HirOwnerId = typedId(struct {});
pub const HirParamId = typedId(struct {});

pub const DefId = typedId(struct {});
pub const SymbolId = typedId(struct {});
