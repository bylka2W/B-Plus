const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("bir.zig");
const bir_cfg = @import("bir_cfg.zig");
const bir_dominators = @import("bir_dominators.zig");
const bir_loops = @import("bir_loops.zig");
const INVALID_ID = bir.INVALID_ID;
const BlockId = bir.BlockId;

pub const FunctionAnalysis = struct {
    allocator: Allocator,
    func_id: bir.FunctionId,
    cfg: bir_cfg.CFG,
    dom_tree: bir_dominators.DominatorTree,
    dom_frontiers: bir_dominators.DominanceFrontier,
    loops: []const bir_loops.Loop,

    pub fn deinit(self: *FunctionAnalysis) void {
        self.cfg.deinit();
        self.dom_tree.deinit();
        self.dom_frontiers.deinit();
        for (self.loops) |*lp| {
            self.allocator.free(lp.back_edges);
            self.allocator.free(lp.body);
        }
        self.allocator.free(self.loops);
    }

    pub fn analyze(allocator: Allocator, func_id: bir.FunctionId, func: *const bir.Function) !FunctionAnalysis {
        var cfg = try bir_cfg.buildCFG(allocator, func);

        var dom_tree = try bir_dominators.buildDominators(allocator, &cfg);

        const dom_frontiers = try bir_dominators.buildDominanceFrontiers(allocator, &cfg, &dom_tree);

        const loops_raw = try bir_loops.findLoops(allocator, &cfg, &dom_tree);

        return FunctionAnalysis{
            .allocator = allocator,
            .func_id = func_id,
            .cfg = cfg,
            .dom_tree = dom_tree,
            .dom_frontiers = dom_frontiers,
            .loops = loops_raw,
        };
    }

    pub fn analyzeModule(allocator: Allocator, module: *const bir.Module) !std.ArrayList(FunctionAnalysis) {
        var results = std.ArrayList(FunctionAnalysis).init(allocator);
        for (module.functions.items, 0..) |*func, fid| {
            if (func.blocks.items.len < 2) continue;
            const func_id = @as(bir.FunctionId, @intCast(fid));
            const analysis = try analyze(allocator, func_id, func);
            try results.append(analysis);
        }
        return results;
    }

    pub fn dump(self: *const FunctionAnalysis, func: *const bir.Function, writer: anytype) !void {
        try writer.print("; Analysis for {s}\n", .{func.name});
        try writer.print("; Blocks: {d}, Entry: {d}\n", .{ func.blocks.items.len, self.cfg.entry });
        try bir_cfg.dumpCFG(&self.cfg, writer);
        try self.dom_tree.dump(writer, self.cfg.blocks.items.len);
        try self.dom_frontiers.dump(writer);
        try bir_loops.dumpLoops(self.loops, writer);
    }
};

pub const ModuleAnalysis = struct {
    allocator: Allocator,
    analyses: std.ArrayList(FunctionAnalysis),

    pub fn deinit(self: *ModuleAnalysis) void {
        for (self.analyses.items) |*a| a.deinit();
        self.analyses.deinit();
    }

    pub fn analyze(allocator: Allocator, module: *const bir.Module) !ModuleAnalysis {
        return ModuleAnalysis{
            .allocator = allocator,
            .analyses = try FunctionAnalysis.analyzeModule(allocator, module),
        };
    }

    pub fn getFor(self: *const ModuleAnalysis, func_id: bir.FunctionId) ?*const FunctionAnalysis {
        for (self.analyses.items) |*a| {
            if (a.func_id == func_id) return a;
        }
        return null;
    }

    pub fn dump(self: *const ModuleAnalysis, module: *const bir.Module, writer: anytype) !void {
        try writer.writeAll("; ═══ Module Analysis ═══\n\n");
        for (self.analyses.items) |*a| {
            const func = module.getFunction(a.func_id);
            try a.dump(func, writer);
            try writer.writeAll("\n");
        }
    }
};
