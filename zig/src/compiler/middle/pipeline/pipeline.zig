const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../frontend/ast.zig");
const sema_mod = @import("../../frontend/sema/sema.zig");
const hir = @import("../hir/hir.zig");
const tir = @import("../tir/tir.zig");
const tir_to_bir = @import("../tir/tir_to_bir.zig");
const bir_mod = @import("../bir/bir.zig");

pub const PipelineError = error{
    HIRError,
    TIRError,
    BIRError,
    OutOfMemory,
};

pub const PipelineResult = struct {
    pub const Stage = enum { hir, tir, bir };

    bir_module: bir_mod.Module,
    stage: Stage,
};

pub fn lowerToHIR(allocator: Allocator, program: *const ast.ProgramNode, sema_result: *const sema_mod.SemaResult) !hir.HirModule {
    const ctx = hir.SemaContext.fromResult(sema_result);
    return hir.lowerProgram(allocator, program, ctx) catch |err| {
        std.log.err("HIR lowering failed: {}", .{err});
        return PipelineError.HIRError;
    };
}

pub fn lowerToTIR(allocator: Allocator, hir_module: *const hir.HirModule) !tir.Module {
    _ = allocator;
    return tir.lowerModule(hir_module.allocator, hir_module) catch |err| {
        std.log.err("TIR lowering failed: {}", .{err});
        return PipelineError.TIRError;
    };
}

pub fn lowerTIRtoBIR(tir_module: *const tir.Module) !bir_mod.Module {
    return tir_to_bir.lowerModule(tir_module.allocator, tir_module) catch |err| {
        std.log.err("TIR → BIR lowering failed: {}", .{err});
        return PipelineError.BIRError;
    };
}

pub fn runFullPipeline(allocator: Allocator, program: *const ast.ProgramNode, sema_result: *const sema_mod.SemaResult) !bir_mod.Module {
    var hir_module = try lowerToHIR(allocator, program, sema_result);
    defer hir_module.deinit();

    var tir_module = try lowerToTIR(allocator, &hir_module);
    defer tir_module.deinit();

    return lowerTIRtoBIR(&tir_module);
}
