const std = @import("std");
const bir = @import("../bir.zig");
const bir_passes = @import("../passes/manager.zig");
const bir_verify = @import("../verify/verifier.zig");
const dead_block = @import("../passes/cleanup/dead_block.zig");
const copy_prop = @import("../passes/scalar/copy_propagation.zig");

pub fn verifyBIR(module: *bir.Module) !void {
    var result = bir_verify.verify(module, .{});
    defer result.deinit();
    if (!result.isValid()) {
        if (@import("builtin").mode == .Debug) {
            for (result.diagnostics.list.items) |d| {
                const code_str = @tagName(d.code);
                const msg = if (d.message) |m| m else "";
                const loc = if (d.block_name) |bn|
                    std.fmt.allocPrint(std.heap.page_allocator, " {s} @block[{s}]", .{ (if (d.func_name) |fn_name| fn_name else "?"), bn }) catch @as([]const u8, "")
                else
                    @as([]const u8, "");
                const vinfo = if (d.value_id) |vid|
                    std.fmt.allocPrint(std.heap.page_allocator, " val#{d}", .{vid}) catch @as([]const u8, "")
                else
                    @as([]const u8, "");
                std.debug.print("VERIFY: [{s}] {s}{s}{s}: {s}\n", .{ code_str, (if (d.func_name) |fn_name| fn_name else "?"), loc, vinfo, msg });
            }
        }
        return error.VerificationFailed;
    }
}

pub const PipelineOptions = struct {
    constant_folding: bool = true,
    constant_propagation: bool = true,
    dead_code_elimination: bool = true,
    dead_block_elimination: bool = true,
    trivial_block_merge: bool = true,
    copy_propagation: bool = true,
    final_dead_code_elimination: bool = true,
};

pub fn runVerifiedPipeline(module: *bir.Module, options: PipelineOptions) !void {
    const allocator = module.allocator;
    module.rebuildUses();

    var am = bir.AnalysisManager.init(allocator, module);
    defer am.deinit();
    var ctx = bir.PassContext{
        .module = module,
        .analysis = &am,
        .allocator = allocator,
    };
    var pm = bir.PassManager.init(allocator);
    defer pm.deinit();

    try pm.addPass(bir_passes.VerifyPass);
    if (options.constant_folding) try pm.addPass(bir_passes.ConstantFoldingPass);
    if (options.constant_propagation) try pm.addPass(bir_passes.SCCPPass);
    if (options.dead_code_elimination) try pm.addPass(bir_passes.DCEPass);
    if (options.dead_block_elimination) try pm.addPass(dead_block.DeadBlockElimPass);
    if (options.trivial_block_merge) try pm.addPass(bir_passes.CFGSimplifyPass);
    if (options.dead_block_elimination) try pm.addPass(dead_block.DeadBlockElimPass);
    if (options.copy_propagation) try pm.addPass(copy_prop.CopyPropagationPass);
    if (options.final_dead_code_elimination) try pm.addPass(bir_passes.DCEPass);
    try pm.addPass(bir_passes.VerifyPass);

    try pm.run(&ctx);
}