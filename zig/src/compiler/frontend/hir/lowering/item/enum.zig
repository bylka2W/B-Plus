const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ItemId = @import("../lower.zig").ItemId;
const AstDeclId = @import("../lower.zig").AstDeclId;
const std = @import("std");

pub fn lowerEnumItem(self: *HirLowering, decl_id: AstDeclId, e: @import("../lower.zig").AstDecl.EnumDecl) LowerError!ItemId {
    var variants = std.ArrayList(@import("../../item.zig").HirItem.HirItemKind.Variant).init(self.hir.allocator());
    for (e.variants) |v| {
        variants.append(.{
            .name = v.name,
            .fields = &.{},
        }) catch return error.OutOfMemory;
    }
    _ = decl_id;
    return self.hir.addItem(.{
        .span = e.span,
        .kind = .{ .enum_item = .{
            .name = e.name,
            .def_id = self.resolveName(e.name),
            .variants = variants.toOwnedSlice() catch return error.OutOfMemory,
            .visibility = self.lowerVisibility(e.visibility),
        } },
    });
}
