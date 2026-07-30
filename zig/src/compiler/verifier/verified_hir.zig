const std = @import("std");
const hir_arena = @import("../frontend/hir/arena.zig");

pub const HirArena = hir_arena.HirArena;

pub const VerifiedHIR = struct {
    arena: *HirArena,

    pub fn getArena(self: *const VerifiedHIR) *const HirArena {
        return self.arena;
    }

    pub fn deinit(self: *VerifiedHIR) void {
        self.arena.deinit();
    }
};
