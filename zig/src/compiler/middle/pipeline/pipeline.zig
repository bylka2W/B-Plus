const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../frontend/ast.zig");
const sema_mod = @import("../../frontend/sema/sema.zig");
const hir_arena_mod = @import("../../frontend/hir/arena.zig");
const bir_mod = @import("../bir/bir.zig");
const program_node_to_hir = @import("../../frontend/hir/program_node_to_hir.zig");
const verifier = @import("../../verifier/verifier.zig");
const thir_lower = @import("../thir/lower.zig");
const thir_to_bir = @import("../thir/lowering/thir_to_bir.zig");
const type_sys = @import("../../frontend/type_system/type_system.zig");
const TypeEngine = type_sys.TypeEngine;
const mir = @import("../../backend/mir/mir.zig");
const bir_cpu = @import("../bir/lowering/cpu.zig");
const mir_lower = @import("../../backend/machine/lowering/mir_lower.zig");
const machine = @import("../../backend/machine/machine.zig");
const thir = @import("../thir/thir.zig");
const plan_to_bir = @import("../../plan/lowering/plan_to_bir.zig");

pub const PipelineError = error{
    HIRError,
    BIRError,
    OutOfMemory,
    VerificationFailed,
};

pub const VerifiedPipelineResult = struct {
    bir_module: *bir_mod.Module,
    verified_bir: verifier.VerifiedBIR,
};

pub const FullVerifiedResult = struct {
    verified_bir: verifier.VerifiedBIR,
    verified_mir: verifier.VerifiedMIR,
    verified_machine: verifier.VerifiedMachineIR,
};

pub const CheckReporter = struct {
    ctx: *anyopaque,
    reportFn: *const fn (ctx: *anyopaque, stage: []const u8) void,

    pub fn report(self: *const CheckReporter, stage: []const u8) void {
        self.reportFn(self.ctx, stage);
    }
};

fn reportStage(reporter: ?*const CheckReporter, stage: []const u8) void {
    if (reporter) |r| r.report(stage);
}

pub fn lowerVerifiedBIRtoMIR(allocator: Allocator, verified: *const verifier.VerifiedBIR) !verifier.VerifiedMIR {
    const birm = verified.getModule();
    const mfuncs = try bir_cpu.lowerModuleToMir(birm.allocator, birm);
    var mfuncs_owned = true;
    errdefer if (mfuncs_owned) {
        for (mfuncs) |*mf| mf.deinit();
        birm.allocator.free(mfuncs);
    };

    const mir_module = try allocator.create(mir.MModule);
    mir_module.* = mir.MModule{
        .functions = std.ArrayList(mir.MFunction).init(birm.allocator),
        .allocator = birm.allocator,
    };
    errdefer mir_module.deinit();
    try mir_module.functions.appendSlice(mfuncs);
    birm.allocator.free(mfuncs);
    mfuncs_owned = false;

    var mir_verifier = verifier.mir_verifier.MirVerifier.init(birm.allocator);
    defer mir_verifier.deinit();
    return mir_verifier.verify(mir_module);
}

pub fn lowerVerifiedMIRtoMachine(allocator: Allocator, verified: *const verifier.VerifiedMIR) !verifier.VerifiedMachineIR {
    const mir_mod = verified.getModule();
    const mach_module = try allocator.create(machine.MModule);
    mach_module.* = try mir_lower.lowerModule(mir_mod, mir_mod.allocator);
    errdefer mach_module.deinit();

    var mach_verifier = verifier.machine_ir_verifier.MachineIrVerifier.init(mir_mod.allocator);
    return mach_verifier.verify(mach_module);
}

pub fn runVerifiedPipeline(allocator: Allocator, program: *const ast.ProgramNode, sema_result: *const sema_mod.SemaResult, type_engine: *TypeEngine) !VerifiedPipelineResult {
    return runVerifiedPipelineReport(allocator, program, sema_result, type_engine, null);
}

pub fn runVerifiedPipelineReport(allocator: Allocator, program: *const ast.ProgramNode, sema_result: *const sema_mod.SemaResult, type_engine: *TypeEngine, reporter: ?*const CheckReporter) !VerifiedPipelineResult {
    // 1. Build HIR from AST
    var arena = hir_arena_mod.HirArena.init(allocator);
    defer arena.deinit();

    {
        var sema_view = program_node_to_hir.ProgramNodeToHir.SemaView.fromSemaResult(sema_result);
        var converter = program_node_to_hir.ProgramNodeToHir.init(allocator, program, &arena, &sema_view);
        defer converter.deinit();
        try converter.convert();
    }

    // 2. Verify HIR → VerifiedHIR
    const verified_hir = try verifier.hir_verifier.verifyHIR(&arena);
    _ = verified_hir;
    reportStage(reporter, "HIR");

    // 2.5. Inject Plan entry functions into HIR before THIR lowering
    if (plan_to_bir.hasStateItems(&arena)) {
        try plan_to_bir.addEntryFunctions(&arena);
    }

    // 3. Lower HIR → THIR
    var thir_module = thir.ThirModule.init(allocator);
    defer thir_module.deinit();

    const hir = arena;
    var ctx = thir_lower.LowerContext.init(
        allocator,
        &thir_module,
        type_engine,
        &hir.exprs,
        &hir.patterns,
        &hir.stmts,
        &hir.items,
        &hir.bodies,
    );
    defer ctx.deinit();

    for (0..hir.items.items.len) |i| {
        try ctx.lowerItem(@intCast(i));
    }

    // 4. Verify THIR → VerifiedTHIR
    var thir_verifier = verifier.thir_verifier.ThirVerifier.init(allocator);
    defer thir_verifier.deinit();
    var verified_thir = try thir_verifier.verify(&thir_module);
    reportStage(reporter, "THIR");

    // 5. Lower THIR → BIR (reads THIR bodies — ctx arena must be alive)
    const thir_mod = verified_thir.getModule();
    var thir_to_bir_lower = thir_to_bir.ThirToBir.init(allocator, thir_mod, &arena.types, &arena.items);
    defer thir_to_bir_lower.deinit();
    const bir_module = try allocator.create(bir_mod.Module);
    bir_module.* = try thir_to_bir_lower.lower();
    errdefer bir_module.deinit();

    // 5.5. Create Plan runtime main function
    if (plan_to_bir.hasStateItems(&arena)) {
        try plan_to_bir.createRuntimeMain(bir_module);
    }

    // ctx.deinit() and arena.deinit() fire here via defer
    // Order: ctx.deinit() (THIR body arena) → arena.deinit() (HIR arena)

    // 6. Verify BIR → VerifiedBIR
    var bir_verifier = verifier.bir_verifier.BirVerifier.init(allocator);
    const verified_bir = try bir_verifier.verify(bir_module);
    reportStage(reporter, "BIR");

    return VerifiedPipelineResult{
        .bir_module = bir_module,
        .verified_bir = verified_bir,
    };
}

pub fn runFullVerifiedPipeline(allocator: Allocator, program: *const ast.ProgramNode, sema_result: *const sema_mod.SemaResult, type_engine: *TypeEngine) !FullVerifiedResult {
    return runFullVerifiedPipelineReport(allocator, program, sema_result, type_engine, null);
}

pub fn runFullVerifiedPipelineReport(allocator: Allocator, program: *const ast.ProgramNode, sema_result: *const sema_mod.SemaResult, type_engine: *TypeEngine, reporter: ?*const CheckReporter) !FullVerifiedResult {
    const pipeline_result = try runVerifiedPipelineReport(allocator, program, sema_result, type_engine, reporter);

    var verified_mir = try lowerVerifiedBIRtoMIR(allocator, &pipeline_result.verified_bir);
    errdefer verified_mir.deinit();
    reportStage(reporter, "MIR");

    var verified_machine = try lowerVerifiedMIRtoMachine(allocator, &verified_mir);
    errdefer verified_machine.deinit();
    reportStage(reporter, "x64");

    return FullVerifiedResult{
        .verified_bir = pipeline_result.verified_bir,
        .verified_mir = verified_mir,
        .verified_machine = verified_machine,
    };
}
