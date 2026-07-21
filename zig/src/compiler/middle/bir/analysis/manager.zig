const std = @import("std");
const Allocator = std.mem.Allocator;
const bir_cfg = @import("cfg/cfg.zig");
const bir_dominators = @import("dominator/dominator.zig");
const bir_loops = @import("loops/loops.zig");
const PreservedAnalyses = @import("../optimizer/pass_types.zig").PreservedAnalyses;
const AnalysisKind = @import("../optimizer/pass_types.zig").AnalysisKind;

const ir = @import("../core/module.zig");
const Module = ir.Module;
const FunctionId = @import("../core/value.zig").FunctionId;

/// Per-function cached analysis results.
const PerFunctionEntry = struct {
    allocator: Allocator,
    cfg: ?bir_cfg.CFG = null,
    dom: ?DominanceAnalysis = null,
    loop: ?LoopAnalysis = null,

    fn deinit(self: *PerFunctionEntry) void {
        if (self.cfg) |*c| c.deinit();
        if (self.dom) |*d| {
            d.tree.deinit();
            d.frontier.deinit();
        }
        if (self.loop) |*l| l.info.deinit(self.allocator);
    }
};

pub const DominanceAnalysis = struct {
    tree: bir_dominators.DominatorTree,
    frontier: bir_dominators.DominanceFrontier,
};

pub const LoopAnalysis = struct {
    info: bir_loops.LoopInfo,
};

pub const AnalysisManager = struct {
    gpa: Allocator,
    module: *Module,
    cache: std.AutoHashMap(FunctionId, *PerFunctionEntry),

    pub fn init(allocator: Allocator, module: *Module) AnalysisManager {
        return AnalysisManager{
            .gpa = allocator,
            .module = module,
            .cache = std.AutoHashMap(FunctionId, *PerFunctionEntry).init(allocator),
        };
    }

    pub fn deinit(self: *AnalysisManager) void {
        var it = self.cache.valueIterator();
        while (it.next()) |entry| {
            entry.*.deinit();
            self.gpa.destroy(entry.*);
        }
        self.cache.deinit();
    }

    pub fn getAllocator(self: *const AnalysisManager) Allocator {
        return self.gpa;
    }

    fn getOrCreateEntry(self: *AnalysisManager, func_id: FunctionId) !*PerFunctionEntry {
        if (self.cache.get(func_id)) |entry| return entry;
        const alloc = self.gpa;
        const entry = try alloc.create(PerFunctionEntry);
        entry.* = PerFunctionEntry{ .allocator = alloc };
        try self.cache.put(func_id, entry);
        return entry;
    }

    /// Ensure CFG is built for the given function. Returns cached if available.
    fn ensureCFG(self: *AnalysisManager, entry: *PerFunctionEntry, func_id: FunctionId) !*const bir_cfg.CFG {
        if (entry.cfg) |*c| return c;
        const func = self.module.getFunctionMut(func_id);
        entry.cfg = try bir_cfg.buildCFG(self.gpa, func);
        return &entry.cfg.?;
    }

    /// Ensure DominatorTree + DominanceFrontier for the given function.
    fn ensureDom(self: *AnalysisManager, entry: *PerFunctionEntry, func_id: FunctionId) !*const DominanceAnalysis {
        if (entry.dom) |*d| return d;
        const cfg = try self.ensureCFG(entry, func_id);
        const func = self.module.getFunction(func_id);
        const tree = try bir_dominators.buildDominators(self.gpa, cfg, func);
        const frontier = try bir_dominators.buildDominanceFrontiers(self.gpa, cfg, func, &tree);
        entry.dom = DominanceAnalysis{ .tree = tree, .frontier = frontier };
        return &entry.dom.?;
    }

    /// Ensure LoopInfo for the given function.
    fn ensureLoop(self: *AnalysisManager, entry: *PerFunctionEntry, func_id: FunctionId) !*const LoopAnalysis {
        if (entry.loop) |*l| return l;
        const dom = try self.ensureDom(entry, func_id);
        const cfg = try self.ensureCFG(entry, func_id);
        const func = self.module.getFunction(func_id);
        const info = try bir_loops.findLoops(self.gpa, cfg, func, &dom.tree);
        entry.loop = LoopAnalysis{ .info = info };
        return &entry.loop.?;
    }

    // ─── Public query API ───

    pub fn getCFG(self: *AnalysisManager, func_id: FunctionId) !*const bir_cfg.CFG {
        const entry = try self.getOrCreateEntry(func_id);
        return self.ensureCFG(entry, func_id);
    }

    pub fn getDomTree(self: *AnalysisManager, func_id: FunctionId) !*const bir_dominators.DominatorTree {
        const entry = try self.getOrCreateEntry(func_id);
        const dom = try self.ensureDom(entry, func_id);
        return &dom.tree;
    }

    pub fn getDomFrontier(self: *AnalysisManager, func_id: FunctionId) !*const bir_dominators.DominanceFrontier {
        const entry = try self.getOrCreateEntry(func_id);
        const dom = try self.ensureDom(entry, func_id);
        return &dom.frontier;
    }

    pub fn getLoopInfo(self: *AnalysisManager, func_id: FunctionId) !*const bir_loops.LoopInfo {
        const entry = try self.getOrCreateEntry(func_id);
        const loop = try self.ensureLoop(entry, func_id);
        return &loop.info;
    }

    // ─── Invalidation ───

    /// Invalidate all cached analyses for a single function.
    pub fn invalidate(self: *AnalysisManager, func_id: FunctionId) void {
        if (self.cache.fetchRemove(func_id)) |kv| {
            kv.value.deinit();
            self.gpa.destroy(kv.value);
        }
    }

    /// Invalidate all cached analyses across all functions.
    pub fn invalidateAll(self: *AnalysisManager) void {
        var it = self.cache.valueIterator();
        while (it.next()) |entry| {
            entry.*.deinit();
            self.gpa.destroy(entry.*);
        }
        self.cache.clearRetainingCapacity();
    }

    /// Selective invalidation based on PreservedAnalyses.
    /// Respects analysis dependencies:
    ///   - invalidating .cfg invalidates .dominators and .loops
    ///   - invalidating .dominators invalidates .loops
    ///   - invalidating .loops does NOT invalidate .dominators or .cfg
    pub fn invalidatePreserved(self: *AnalysisManager, preserved: PreservedAnalyses) void {
        const invalid_cfg = !preserved.isPreserved(.cfg);
        const invalid_dom = !preserved.isPreserved(.dominators);
        const invalid_loop = !preserved.isPreserved(.loops);

        if (!invalid_cfg and !invalid_dom and !invalid_loop) return;

        var it = self.cache.valueIterator();
        while (it.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            if (invalid_cfg) {
                if (entry.cfg) |*c| c.deinit();
                entry.cfg = null;
                if (entry.dom) |*d| {
                    d.tree.deinit();
                    d.frontier.deinit();
                }
                entry.dom = null;
                if (entry.loop) |*l| l.info.deinit(entry.allocator);
                entry.loop = null;
            } else if (invalid_dom) {
                if (entry.dom) |*d| {
                    d.tree.deinit();
                    d.frontier.deinit();
                }
                entry.dom = null;
                if (entry.loop) |*l| l.info.deinit(entry.allocator);
                entry.loop = null;
            } else if (invalid_loop) {
                if (entry.loop) |*l| l.info.deinit(entry.allocator);
                entry.loop = null;
            }
        }
    }
};
