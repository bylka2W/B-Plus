const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ItemId = @import("../lower.zig").ItemId;
const BodyId = @import("../lower.zig").BodyId;
const TypeId = @import("../lower.zig").TypeId;
const AstDeclId = @import("../lower.zig").AstDeclId;
const UNK = @import("../lower.zig").UNK;
const std = @import("std");

pub fn lowerImplItem(self: *HirLowering, decl_id: AstDeclId, im: @import("../lower.zig").AstDecl.ImplDecl) LowerError!ItemId {
    const self_type = try self.lowerTypeRefId(im.self_type);
    const trait_ref = if (im.trait_ref) |tr| try self.lowerTypeRefId(tr) else TypeId.INVALID;
    var methods = std.ArrayList(@import("../../item.zig").HirItem.HirItemKind.FnItem).init(self.hir.allocator());
    for (im.methods) |m| {
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
        const body: BodyId = if (m.body) |bid| try self.lowerFnBody(bid) else BodyId.INVALID;
        methods.append(.{
            .name = m.name,
            .def_id = self.resolveName(m.name),
            .params = params.toOwnedSlice() catch return error.OutOfMemory,
            .return_type = ret_ty,
            .body = body,
            .visibility = self.lowerVisibility(m.visibility),
        }) catch return error.OutOfMemory;
    }
    _ = decl_id;
    return self.hir.addItem(.{
        .span = im.span,
        .kind = .{ .impl_item = .{
            .self_type = self_type,
            .trait_ref = trait_ref,
            .methods = methods.toOwnedSlice() catch return error.OutOfMemory,
        } },
    });
}
