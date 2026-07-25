const std = @import("std");
const hir_mod = @import("../hir/arena.zig");
const HirArena = hir_mod.HirArena;
const HirExpr = hir_mod.HirExpr;
const HirStmt = hir_mod.HirStmt;
const type_sys = @import("../type_system/type_system.zig");
const TypeEngine = type_sys.TypeEngine;
const TypeId = type_sys.TypeId;
const TypeData = type_sys.TypeData;
const errors_mod = @import("errors.zig");
const ErrorList = errors_mod.ErrorList;
const SourceSpan = @import("../source/location/span.zig").SourceSpan;

pub const FinalizeError = error{
    UnresolvedType,
    OutOfMemory,
};

pub fn finalizeTypedHIR(
    hir: *HirArena,
    engine: *TypeEngine,
    errors: *ErrorList,
) FinalizeError!void {
    var i: u32 = 0;
    while (i < hir.exprs.items.len) : (i += 1) {
        const expr = hir.exprs.items[i];
        if (!expr.ty.isValid()) continue;

        const resolved = engine.resolve(expr.ty);

        if (engine.get(resolved)) |data| {
            switch (data) {
                .infer_var => {
                    errors.report(
                        .{ .unresolved_inference_var = .{ .expr_id = i } },
                        expr.span,
                    );
                    return error.UnresolvedType;
                },
                else => {},
            }
        }

        hir.exprs.items[i] = .{
            .span = expr.span,
            .ty = resolved,
            .kind = expr.kind,
        };
    }
}

test "finalize: resolves concrete types" {
    const allocator = std.testing.allocator;
    var engine = TypeEngine.init(allocator);
    defer engine.deinit();
    engine.initInference();

    const i32_ty = engine.builtin(.i32_type);
    const resolved = engine.resolve(i32_ty);
    try std.testing.expect(resolved.isValid());
    try std.testing.expect(engine.get(resolved) != null);
    if (engine.get(resolved)) |data| {
        try std.testing.expect(data != .infer_var);
    }
}

test "finalize: resolve keeps concrete type" {
    const allocator = std.testing.allocator;
    var engine = TypeEngine.init(allocator);
    defer engine.deinit();
    engine.initInference();

    const bool_ty = engine.builtin(.bool_type);
    const resolved = engine.resolve(bool_ty);
    try std.testing.expect(resolved.isValid());
    try std.testing.expectEqual(TypeData{ .builtin = .bool_type }, engine.get(resolved).?);
}

test "finalize: inference var detection" {
    const allocator = std.testing.allocator;
    var engine = TypeEngine.init(allocator);
    defer engine.deinit();
    engine.initInference();

    const fresh = engine.freshVar();
    const resolved = engine.resolve(fresh);
    try std.testing.expect(resolved.isValid());
    if (engine.get(resolved)) |data| {
        try std.testing.expect(data == .infer_var);
    }
}
