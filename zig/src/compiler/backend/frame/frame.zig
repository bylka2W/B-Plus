const std = @import("std");
const x64 = @import("../targets/x64/encoder.zig");

pub const Abi = enum {
    win64,
    system_v,
};

pub const FrameLayout = struct {
    push_area: u32,
    local_area: u32,
    total_frame: u32,
    push_count: u32,
};

pub const FrameManager = struct {
    callee_saved_gprs: std.ArrayList(i16),
    spill_count: u32,
    local_size: u32,
    abi: Abi,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, abi: Abi) FrameManager {
        return .{
            .callee_saved_gprs = std.ArrayList(i16).init(allocator),
            .spill_count = 0,
            .local_size = 0,
            .abi = abi,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FrameManager) void {
        self.callee_saved_gprs.deinit();
    }

    pub fn computeLayout(self: *const FrameManager) FrameLayout {
        const push_count = 1 + @as(u32, @intCast(self.callee_saved_gprs.items.len));
        const push_area = push_count * 8;
        const unaligned_local = self.local_size + @as(u32, @intCast(self.spill_count)) * 8;
        const aligned_local = (unaligned_local + 15) & ~@as(u32, 15);
        const total = push_area + aligned_local;
        const aligned_total = if (total % 16 == 0) total else total + 8;
        return .{
            .push_area = push_area,
            .local_area = aligned_local,
            .total_frame = aligned_total - push_area,
            .push_count = push_count,
        };
    }

    pub fn spillBaseOffset(_: *const FrameManager) i32 {
        return -8;
    }

    pub fn spillOffset(_: *const FrameManager, slot: u32) i32 {
        return -@as(i32, @intCast(@as(u32, 8) * (slot + 1)));
    }

    pub fn emitPrologue(self: *const FrameManager, code: *std.ArrayList(u8)) !void {
        try x64.emit(code, .PUSH_R64, &.{.{ .reg = 5 }});
        for (self.callee_saved_gprs.items) |reg| {
            try x64.emit(code, .PUSH_R64, &.{.{ .reg = reg }});
        }
        try x64.emit(code, .MOV_R64_R64, &.{ .{ .reg = 5 }, .{ .reg = 4 } });
        const layout = self.computeLayout();
        if (layout.total_frame > 0) {
            try x64.emit(code, .SUB_R64_IMM32, &.{ .{ .reg = 4 }, .{ .imm64 = layout.total_frame } });
        }
    }

    pub fn emitEpilogue(self: *const FrameManager, code: *std.ArrayList(u8)) !void {
        try x64.emit(code, .MOV_R64_R64, &.{ .{ .reg = 4 }, .{ .reg = 5 } });
        var i: usize = self.callee_saved_gprs.items.len;
        while (i > 0) {
            i -= 1;
            try x64.emit(code, .POP_R64, &.{.{ .reg = self.callee_saved_gprs.items[i] }});
        }
        try x64.emit(code, .POP_R64, &.{.{ .reg = 5 }});
        try x64.emit(code, .RET, &.{});
    }

    pub fn emitCallSetup(self: *const FrameManager, code: *std.ArrayList(u8), arg_count: u32) !void {
        _ = self;
        const shadow: u32 = 32;
        const extra: u32 = if (arg_count > 4) ((arg_count - 4 + 1) & ~@as(u32, 1)) * 8 else 0;
        const alloc = shadow + extra;
        if (alloc > 0) {
            try x64.emit(code, .SUB_R64_IMM32, &.{ .{ .reg = 4 }, .{ .imm64 = alloc } });
        }
    }

    pub fn emitCallCleanup(self: *const FrameManager, code: *std.ArrayList(u8), arg_count: u32) !void {
        _ = self;
        const shadow: u32 = 32;
        const extra: u32 = if (arg_count > 4) ((arg_count - 4 + 1) & ~@as(u32, 1)) * 8 else 0;
        const alloc = shadow + extra;
        if (alloc > 0) {
            try x64.emit(code, .ADD_R64_IMM32, &.{ .{ .reg = 4 }, .{ .imm64 = alloc } });
        }
    }

    pub fn allocaOffset(self: *const FrameManager, index: u32) i32 {
        const layout = self.computeLayout();
        return -@as(i32, @intCast(layout.local_area - index * 8));
    }
};
