const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ItemId = @import("../lower.zig").ItemId;
const BodyId = @import("../lower.zig").BodyId;
const AstDeclId = @import("../lower.zig").AstDeclId;
const UNK = @import("../lower.zig").UNK;
const std = @import("std");

pub fn lowerTraitItem(self: *HirLowering, decl_id: AstDeclId, t: @import("../lower.zig").AstDecl.TraitDecl) LowerError!ItemId {
    var methods = std.ArrayList(@import("../../item.zig").HirItem.HirItemKind.FnItem).init(self.hir.allocator());
    for (t.methods) |m| {
        var params = std.ArrayList(@import("../../item.zig").HirItem.HirItemKind.Param).init(self.hir.allocator());
        for (m.params) |p| {
            const param_ty = if (p.type_ref) |tr| try self.lowerTypeRefId(tr) else UNK;
            params.append(.{
                .name = p.name,
                .def_id = self.resolveName(p.name),
                .ty = param_ty,
                .span = p.span,
            }) catch return error.OutOfMemory;
        }
        const ret_ty = if (m.return_type) |rt| try self.lowerTypeRefId(rt) else UNK;
        methods.append(.{
            .name = m.name,
            .name_bytes = "",
            .def_id = self.resolveName(m.name),
            .params = params.toOwnedSlice() catch return error.OutOfMemory,
            .return_type = ret_ty,
            .body = BodyId.INVALID,
            .visibility = self.lowerVisibility(m.visibility),
        }) catch return error.OutOfMemory;
    }
    _ = decl_id;
    return self.hir.addItem(.{
        .span = t.span,
        .kind = .{ .trait_item = .{
            .name = t.name,
            .def_id = self.resolveName(t.name),
            .methods = methods.toOwnedSlice() catch return error.OutOfMemory,
            .visibility = self.lowerVisibility(t.visibility),
        } },
    });
}
