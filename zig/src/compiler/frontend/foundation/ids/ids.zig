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

pub const NodeId = typedId(struct {});
pub const TokenId = typedId(struct {});
pub const AstId = typedId(struct {});
pub const ExprId = typedId(struct {});
pub const StmtId = typedId(struct {});
pub const ItemId = typedId(struct {});
pub const HirId = typedId(struct {});
pub const ThirId = typedId(struct {});
pub const DefId = typedId(struct {});
pub const BodyId = typedId(struct {});
pub const OwnerId = typedId(struct {});
pub const TypeId = typedId(struct {});
pub const TraitId = typedId(struct {});
pub const ModuleId = typedId(struct {});
pub const PackageId = typedId(struct {});
pub const FileId = typedId(struct {});
pub const ScopeId = typedId(struct {});
pub const SymbolId = typedId(struct {});
pub const LabelId = typedId(struct {});
pub const ParamId = typedId(struct {});
pub const FieldId = typedId(struct {});
pub const VariantId = typedId(struct {});
pub const PathId = typedId(struct {});
pub const DeclId = typedId(struct {});
pub const PatId = typedId(struct {});
pub const TypeRefId = typedId(struct {});
