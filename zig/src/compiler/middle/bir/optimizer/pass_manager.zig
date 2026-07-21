const std = @import("std");
const Allocator = std.mem.Allocator;

const Module = @import("../core/module.zig").Module;
const AnalysisManager = @import("../analysis/manager.zig").AnalysisManager;
const PreservedAnalyses = @import("pass_types.zig").PreservedAnalyses;

pub usingnamespace @import("pass_types.zig");

pub const PassContext = struct {
    module: *Module,
    analysis: *AnalysisManager,
    allocator: Allocator,
};

pub const Pass = struct {
    name: []const u8,
    run: *const fn (ctx: *PassContext) anyerror!PreservedAnalyses,
};

pub const PassManager = struct {
    passes: std.ArrayList(Pass),
    allocator: Allocator,

    pub fn init(allocator: Allocator) PassManager {
        return .{
            .passes = std.ArrayList(Pass).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PassManager) void {
        self.passes.deinit();
    }

    pub fn addPass(self: *PassManager, pass: Pass) !void {
        try self.passes.append(pass);
    }

    pub fn run(self: *const PassManager, ctx: *PassContext) !void {
        for (self.passes.items) |pass| {
            const preserved = try pass.run(ctx);
            ctx.analysis.invalidatePreserved(preserved);
        }
    }
};
