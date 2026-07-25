const std = @import("std");
const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ItemId = @import("../lower.zig").ItemId;
const UNK = @import("../lower.zig").UNK;
const AstDeclId = @import("../lower.zig").AstDeclId;

pub fn lowerModuleItem(self: *HirLowering, decl_id: AstDeclId, m: @import("../lower.zig").AstDecl.ModuleDecl) LowerError!ItemId {
    _ = self;
    _ = decl_id;
    _ = m;
    return ItemId.INVALID;
}

pub fn lowerTypeAliasItem(self: *HirLowering, decl_id: AstDeclId, ta: @import("../lower.zig").AstDecl.TypeAliasDecl) LowerError!ItemId {
    const target = try self.lowerTypeRefId(ta.target_type);
    _ = decl_id;
    return self.hir.addItem(.{
        .span = ta.span,
        .kind = .{ .type_alias = .{
            .name = ta.name,
            .def_id = self.resolveName(ta.name),
            .target = target,
            .visibility = self.lowerVisibility(ta.visibility),
        } },
    });
}

pub fn lowerExternFnItem(self: *HirLowering, decl_id: AstDeclId, ef: @import("../lower.zig").AstDecl.ExternFnDecl) LowerError!ItemId {
    var params = std.ArrayList(@import("../../item.zig").HirItem.HirItemKind.Param).init(self.hir.allocator());
    for (ef.params) |p| {
        const param_ty = if (p.type_ref) |tr| try self.lowerTypeRefId(tr) else UNK;
        params.append(.{
            .name = p.name,
            .def_id = self.resolveName(p.name),
            .ty = param_ty,
            .span = p.span,
        }) catch return error.OutOfMemory;
    }
    const ret_ty = if (ef.return_type) |rt| try self.lowerTypeRefId(rt) else UNK;
    _ = decl_id;
    return self.hir.addItem(.{
        .span = ef.span,
        .kind = .{ .extern_fn = .{
            .name = ef.name,
            .def_id = self.resolveName(ef.name),
            .params = params.toOwnedSlice() catch return error.OutOfMemory,
            .return_type = ret_ty,
            .visibility = .private,
        } },
    });
}
