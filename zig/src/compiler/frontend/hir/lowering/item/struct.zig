const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ItemId = @import("../lower.zig").ItemId;
const HirItem = @import("../lower.zig").HirItem;
const DefId = @import("../lower.zig").DefId;
const AstDeclId = @import("../lower.zig").AstDeclId;
const std = @import("std");

pub fn lowerStructItem(self: *HirLowering, decl_id: AstDeclId, s: @import("../lower.zig").AstDecl.StructDecl) LowerError!ItemId {
    const def = self.resolveName(s.name);
    var fields = std.ArrayList(HirItem.HirItemKind.Field).init(self.hir.allocator());
    for (s.fields) |f| {
        const field_ty = try self.lowerTypeRefId(f.type_ref);
        fields.append(.{
            .name = f.name,
            .ty = field_ty,
            .visibility = self.lowerVisibility(f.visibility),
            .span = f.span,
        }) catch return error.OutOfMemory;
    }
    _ = decl_id;
    _ = def;
    return self.hir.addItem(.{
        .span = s.span,
        .kind = .{ .struct_item = .{
            .name = s.name,
            .def_id = self.resolveName(s.name),
            .fields = fields.toOwnedSlice() catch return error.OutOfMemory,
            .visibility = self.lowerVisibility(s.visibility),
        } },
    });
}
