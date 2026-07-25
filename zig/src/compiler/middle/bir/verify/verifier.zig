const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("../bir.zig");
const bir_cfg = @import("../analysis/cfg/cfg.zig");
const bir_dominators = @import("../analysis/dominator/dominator.zig");

const diagnostics_mod = @import("diagnostics.zig");
const Diagnostic = diagnostics_mod.Diagnostic;
const DiagnosticList = diagnostics_mod.DiagnosticList;
const module_mod = @import("module.zig");
const function_mod = @import("function.zig");
const cfg_mod = @import("cfg.zig");
const ssa_mod = @import("ssa.zig");
const types_mod = @import("types.zig");
const instruction_mod = @import("instruction.zig");
const memory_mod = @import("memory.zig");
const calls_mod = @import("calls.zig");

pub const VerifyOptions = struct {
    check_cfg: bool = true,
    check_ssa: bool = true,
    check_types: bool = true,
    check_memory: bool = true,
    check_calls: bool = true,
    strict: bool = true,
};

pub const VerifyResult = struct {
    diagnostics: DiagnosticList,
    allocator: Allocator,

    pub fn deinit(self: *VerifyResult) void {
        self.diagnostics.deinit();
    }

    pub fn isValid(self: *const VerifyResult) bool {
        return !self.diagnostics.hasErrors();
    }

    pub fn expectValid(self: *const VerifyResult) !void {
        if (!self.isValid()) {
            return error.VerificationFailed;
        }
    }

    pub fn errorCount(self: *const VerifyResult) usize {
        return self.diagnostics.len();
    }

    pub fn printErrors(self: *const VerifyResult, writer: anytype, module: ?*const bir.Module) !void {
        try self.diagnostics.printAll(writer, module);
    }
};

pub fn verify(module: *bir.Module, options: VerifyOptions) VerifyResult {
    return verifyInternal(module, options) catch |err| {
        var result = VerifyResult{
            .diagnostics = DiagnosticList.init(module.allocator),
            .allocator = module.allocator,
        };
        result.diagnostics.push(.{
            .code = .duplicate_function_name,
            .message = @errorName(err),
        }) catch {};
        return result;
    };
}

fn verifyInternal(module: *bir.Module, options: VerifyOptions) !VerifyResult {
    var result = VerifyResult{
        .diagnostics = DiagnosticList.init(module.allocator),
        .allocator = module.allocator,
    };

    try module_mod.verifyModule(module, &result.diagnostics);

    for (module.functions.items, 0..) |*func, fid| {
        const func_id = @as(bir.FunctionId, @intCast(fid));

        if (func.blocks.items.len == 0) continue;

        try function_mod.verifyFunction(func, func_id, &result.diagnostics);

        if (options.check_cfg) {
            var cfg = try bir_cfg.buildCFG(module.allocator, func);
            defer cfg.deinit();

            try cfg_mod.verifyCFG(func, &cfg, func_id, &result.diagnostics);

            if (options.check_ssa) {
                var dom_tree = try bir_dominators.buildDominators(module.allocator, &cfg, func);
                defer dom_tree.deinit();

                try ssa_mod.verifySSA(module, func, func_id, &cfg, &dom_tree, &result.diagnostics);
                try ssa_mod.verifyPhis(module, func, func_id, &cfg, &dom_tree, &result.diagnostics);
            }
        }

        if (options.check_types) {
            try types_mod.verifyTypes(module, func, func_id, &result.diagnostics);
        }

        try instruction_mod.verifyInstructions(module, func, func_id, &result.diagnostics);

        if (options.check_memory) {
            try memory_mod.verifyMemory(module, func, func_id, &result.diagnostics);
        }

        if (options.check_calls) {
            try calls_mod.verifyCalls(module, func, func_id, &result.diagnostics);
        }
    }

    return result;
}

pub fn verifyModule(module: *bir.Module, _: Allocator) !VerifyResult {
    return verify(module, .{});
}
