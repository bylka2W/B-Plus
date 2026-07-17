const std = @import("std");
const bc = @import("../../src/compiler/backend/gpu/dxil_bitcode.zig");
const dxil = @import("../../src/compiler/backend/gpu/gpu_dxil.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Generate a DXIL container via gpu_dxil backend,
    // then we'll analyze what types DXC accepts.
    // For now: just test the existing backend.
    _ = alloc;
    _ = dxil;
}
