const std = @import("std");
const hir_arena_mod = @import("../../frontend/hir/arena.zig");
const hir_item_mod = @import("../../frontend/hir/item.zig");
const bir_mod = @import("../../middle/bir/bir.zig");

pub fn hasStateItems(arena: *const hir_arena_mod.HirArena) bool {
    for (arena.items.items) |item| {
        if (item.kind == .state_item) return true;
    }
    return false;
}

pub fn addEntryFunctions(arena: *hir_arena_mod.HirArena) !void {
    var entry_idx: u32 = 0;
    for (arena.items.items, 0..) |item, i| {
        _ = i;
        if (item.kind != .state_item) continue;
        const state = item.kind.state_item;
        const entry_body = state.entry orelse continue;

        const fn_name = if (entry_idx == 0)
            try arena.allocator().dupe(u8, "__plan_entry")
        else
            try std.fmt.allocPrint(arena.allocator(), "__plan_entry_{d}", .{entry_idx});

        try arena.items.append(.{
            .span = item.span,
            .kind = .{ .fn_decl = .{
                .name = .new(0),
                .name_bytes = fn_name,
                .def_id = .new(0),
                .params = &.{},
                .return_type = .{ .index = std.math.maxInt(u32) },
                .body = entry_body,
                .visibility = .public,
            }},
        });
        entry_idx += 1;
    }
}

pub fn createRuntimeMain(bir_module: *bir_mod.Module) !void {
    const void_ty = try bir_module.types.voidType();
    const main_id = try bir_module.addFunction("main", void_ty, .entry);
    bir_module.entry_point = main_id;

    const entry_block = try bir_module.addBlock(main_id, "entry");

    const callee_name = try bir_module.allocator.dupe(u8, "__plan_entry");
    _ = try bir_module.addInst(main_id, entry_block, .{
        .op = .call,
        .ty = void_ty,
        .result = 0,
        .operands = &.{},
        .data = .{ .named_call = .{ .name = callee_name, .args = &.{} } },
    });

    _ = try bir_module.addInst(main_id, entry_block, .{
        .op = .ret,
        .ty = void_ty,
        .result = 0,
        .operands = &.{},
        .data = .none,
    });
}
