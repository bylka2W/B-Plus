const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ItemId = @import("../lower.zig").ItemId;
const BodyId = @import("../lower.zig").BodyId;
const DefId = @import("../lower.zig").DefId;
const UNK = @import("../lower.zig").UNK;
const AstDeclId = @import("../lower.zig").AstDeclId;
const std = @import("std");

pub fn lowerFnItem(self: *HirLowering, decl_id: AstDeclId, f: @import("../lower.zig").AstDecl.FnDecl) LowerError!ItemId {
    const def = self.resolveName(f.name);
    var params = std.ArrayList(@import("../../item.zig").HirItem.HirItemKind.Param).init(self.hir.allocator());
    for (f.params) |p| {
        const param_ty = if (p.type_ref) |tr| try self.lowerTypeRefId(tr) else UNK;
        params.append(.{
            .name = p.name,
            .def_id = self.resolveName(p.name),
            .ty = param_ty,
            .span = p.span,
        }) catch return error.OutOfMemory;
    }
    const ret_ty = if (f.return_type) |rt| try self.lowerTypeRefId(rt) else UNK;
    const body: BodyId = if (f.body) |bid| try self.lowerFnBody(bid) else BodyId.INVALID;
    _ = decl_id;
    return self.hir.addItem(.{
        .span = f.span,
        .kind = .{ .fn_decl = .{
            .name = f.name,
            .def_id = def,
            .params = params.toOwnedSlice() catch return error.OutOfMemory,
            .return_type = ret_ty,
            .body = body,
            .visibility = self.lowerVisibility(f.visibility),
        } },
    });
}
