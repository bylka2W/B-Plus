const std = @import("std");
const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ItemId = @import("../lower.zig").ItemId;
const BodyId = @import("../lower.zig").BodyId;
const DefId = @import("../lower.zig").DefId;
const SymbolId = @import("../lower.zig").SymbolId;
const UNK = @import("../lower.zig").UNK;
const AstDeclId = @import("../lower.zig").AstDeclId;
const hir_item = @import("../../item.zig");
const HirItemKind = hir_item.HirItem.HirItemKind;

pub fn lowerStateItem(self: *HirLowering, decl_id: AstDeclId, s: @import("../lower.zig").AstDecl.StateDecl) LowerError!ItemId {
    const def = self.resolveName(s.name);

    var fields = std.ArrayList(HirItemKind.StateVar).init(self.hir.allocator());
    for (s.variables) |v| {
        var vname: SymbolId = SymbolId.INVALID;
        if (self.ast.getPattern(v.pattern)) |pat| {
            switch (pat) {
                .identifier => |i| vname = i.name,
                else => {},
            }
        }
        const ty = if (v.type_annotation) |tr| try self.lowerTypeRefId(tr) else UNK;
        const default = if (v.init) |eid| try self.lowerExpr(eid) else null;
        fields.append(.{
            .name = vname,
            .def_id = self.resolveNameInOwner(vname, def),
            .ty = ty,
            .default = default,
        }) catch return error.OutOfMemory;
    }

    var transitions = std.ArrayList(HirItemKind.Transition).init(self.hir.allocator());
    for (s.transitions) |t| {
        transitions.append(.{
            .event = t.event,
            .target = self.resolveName(t.target),
            .guard = null,
            .priority = 0,
            .attrs = &.{},
        }) catch return error.OutOfMemory;
    }

    const entry: ?BodyId = if (s.entry) |bid| try self.lowerFnBody(bid) else null;
    const exit: ?BodyId = if (s.exit) |bid| try self.lowerFnBody(bid) else null;
    _ = decl_id;

    return self.hir.addItem(.{
        .span = s.span,
        .kind = .{ .state_item = .{
            .name = s.name,
            .def_id = def,
            .attrs = &.{},
            .fields = fields.toOwnedSlice() catch return error.OutOfMemory,
            .entry = entry,
            .exit = exit,
            .transitions = transitions.toOwnedSlice() catch return error.OutOfMemory,
            .parent = null,
            .visibility = .public,
        } },
    });
}
