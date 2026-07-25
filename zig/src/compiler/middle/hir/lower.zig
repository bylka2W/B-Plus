const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../frontend/ast.zig");
const hir = @import("node.zig");

const common_mod = @import("lower/common.zig");
const plan_mod = @import("lower/plan.zig");
const metal_mod = @import("lower/metal.zig");

pub const SemaContext = common_mod.SemaContext;
pub const LowerError = error{ ParseError, TypeNotFound, OutOfMemory };

pub fn lowerProgram(allocator: Allocator, program: *const ast.ProgramNode, sema_ctx: SemaContext) !hir.HirModule {
    var module = hir.HirModule.init(allocator);
    errdefer module.deinit();

    for (program.common.func_defs.items) |func| {
        const hir_func = try common_mod.lowerFunction(allocator, func, sema_ctx);
        try module.functions.append(hir_func);
    }
    for (program.plan.states.items) |state| {
        const hir_state = try plan_mod.lowerState(allocator, state, sema_ctx);
        try module.states.append(hir_state);
    }
    for (program.metal.kernels.items) |kernel| {
        const hir_kernel = try metal_mod.lowerKernel(allocator, kernel, sema_ctx);
        try module.kernels.append(hir_kernel);
    }
    return module;
}
