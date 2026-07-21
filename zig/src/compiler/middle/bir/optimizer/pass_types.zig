const std = @import("std");

/// Analysis identifiers (bitmask-based).
/// Dependencies: cfg → (post_dominators) → dominators → loops → scalar_evolution
pub const AnalysisKind = enum(u8) {
    cfg,
    dominators,
    post_dominators,
    loops,
    scalar_evolution,
    memory_ssa,
    alias,
    call_graph,
    _,

    pub fn fromName(comptime name: []const u8) AnalysisKind {
        return comptime std.meta.stringToEnum(AnalysisKind, name) orelse @compileError("unknown analysis: " ++ name);
    }

    /// Returns true if preserving `this` implies preserving `other`
    /// (e.g. preserving dominators implies preserving cfg).
    pub fn implies(self: AnalysisKind, other: AnalysisKind) bool {
        return switch (self) {
            .call_graph => other == .call_graph,
            .scalar_evolution => other == .scalar_evolution or other == .loops or other == .dominators or other == .cfg,
            .loops => other == .loops or other == .dominators or other == .cfg,
            .dominators => other == .dominators or other == .cfg,
            .post_dominators => other == .post_dominators or other == .cfg,
            .memory_ssa => other == .memory_ssa or other == .alias or other == .cfg,
            .alias => other == .alias,
            .cfg => other == .cfg,
            _ => self == other,
        };
    }
};

const BitMask = u16;

/// PreservedAnalyses bitmask.
pub const PreservedAnalyses = struct {
    mask: BitMask = 0,

    pub fn preserve(self: *PreservedAnalyses, a: AnalysisKind) void {
        self.mask |= @as(BitMask, 1) << @intCast(@intFromEnum(a));
    }

    pub fn isPreserved(self: PreservedAnalyses, a: AnalysisKind) bool {
        return (self.mask & (@as(BitMask, 1) << @intCast(@intFromEnum(a)))) != 0;
    }

    pub fn all() PreservedAnalyses {
        return PreservedAnalyses{ .mask = ~@as(BitMask, 0) };
    }

    pub fn none() PreservedAnalyses {
        return PreservedAnalyses{ .mask = 0 };
    }

    pub fn merge(self: *PreservedAnalyses, other: PreservedAnalyses) void {
        self.mask &= other.mask;
    }
};

/// Legacy ChangeSet (kept for backward compat, new Pass API uses PreservedAnalyses directly).
pub const ChangeSet = struct {
    changed: bool = false,
    preserved: PreservedAnalyses = PreservedAnalyses.none(),
    analyses_cleared: bool = false,

    pub fn none() ChangeSet {
        return ChangeSet{};
    }

    pub fn all() ChangeSet {
        return ChangeSet{ .preserved = PreservedAnalyses.all() };
    }

    pub fn identity() ChangeSet {
        return ChangeSet{ .preserved = PreservedAnalyses.all() };
    }

    pub fn preserve(self: *ChangeSet, a: AnalysisKind) void {
        self.preserved.preserve(a);
    }

    pub fn clearsAll(self: *const ChangeSet) bool {
        return self.analyses_cleared;
    }
};
