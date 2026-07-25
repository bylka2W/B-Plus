const std = @import("std");
const HirLowering = @import("lower.zig").HirLowering;
const LowerError = @import("lower.zig").LowerError;
const TypeId = @import("lower.zig").TypeId;
const TypeRefId = @import("lower.zig").AstTypeRefId;
const AstTypeRef = @import("lower.zig").AstTypeRef;
const SymbolId = @import("lower.zig").SymbolId;
const UNK = @import("lower.zig").UNK;

pub fn lowerTypeRef(self: *HirLowering, ast_tr: AstTypeRef) LowerError!TypeId {
    return switch (ast_tr) {
        .named => |n| self.hir.addType(.{ .named = .{ .name = n.name, .args = &.{} } }),
        .pointer => |p| self.hir.addType(.{ .pointer = .{ .mutable = p.mutable, .pointee = try self.lowerTypeRefId(p.pointee) } }),
        .array => |a| self.hir.addType(.{ .array = .{ .element = try self.lowerTypeRefId(a.element), .length = 0 } }),
        .slice => |s| self.hir.addType(.{ .slice = .{ .element = try self.lowerTypeRefId(s.element) } }),
        .tuple => |t| {
            var elements = std.ArrayList(TypeId).init(self.hir.allocator());
            for (t.elements) |elem| {
                elements.append(try self.lowerTypeRefId(elem)) catch return error.OutOfMemory;
            }
            return self.hir.addType(.{ .tuple = .{ .elements = elements.toOwnedSlice() catch return error.OutOfMemory } });
        },
        .fn_type => |f| {
            var params = std.ArrayList(TypeId).init(self.hir.allocator());
            for (f.params) |param| {
                params.append(try self.lowerTypeRefId(param)) catch return error.OutOfMemory;
            }
            return self.hir.addType(.{ .fn_type = .{ .params = params.toOwnedSlice() catch return error.OutOfMemory, .ret = try self.lowerTypeRefId(f.return_type) } });
        },
        .optional => |o| self.hir.addType(.{ .optional = .{ .inner = try self.lowerTypeRefId(o.inner) } }),
        .missing => UNK,
    };
}

pub fn lowerTypeRefId(self: *HirLowering, tr_id: TypeRefId) LowerError!TypeId {
    if (!tr_id.isValid()) return UNK;
    const ast_tr = self.ast.getTypeRef(tr_id) orelse return UNK;
    return self.lowerTypeRef(ast_tr);
}
