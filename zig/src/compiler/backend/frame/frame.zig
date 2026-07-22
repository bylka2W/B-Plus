const std = @import("std");
const enc = @import("../targets/x64/encoder/x64enc.zig");
const x64 = struct {
    pub usingnamespace enc;
};

pub const Abi = enum {
    win64,
    system_v,
};

pub const UnwindInfo = struct {
    push_count: u32,
    has_frame_pointer: bool,
    xmm_spill_size: u32,
    stack_size: u32,
};

pub const FrameLayout = struct {
    push_area: u32,
    xmm_spill_area: u32,
    spill_area: u32,
    local_area: u32,
    total_frame: u32,
    push_count: u32,
    use_frame_pointer: bool,
};

pub const FrameManager = struct {
    callee_saved_gprs: std.ArrayList(i16),
    callee_saved_xmms: std.ArrayList(u8),
    spill_count: u32,
    local_size: u32,
    abi: Abi,
    use_frame_pointer: bool,
    large_frame_threshold: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, abi: Abi) FrameManager {
        return .{
            .callee_saved_gprs = std.ArrayList(i16).init(allocator),
            .callee_saved_xmms = std.ArrayList(u8).init(allocator),
            .spill_count = 0,
            .local_size = 0,
            .abi = abi,
            .use_frame_pointer = true,
            .large_frame_threshold = 4096,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FrameManager) void {
        self.callee_saved_gprs.deinit();
        self.callee_saved_xmms.deinit();
    }

    pub fn computeLayout(self: *const FrameManager) FrameLayout {
        const push_count: u32 = if (self.use_frame_pointer)
            1 + @as(u32, @intCast(self.callee_saved_gprs.items.len))
        else
            @as(u32, @intCast(self.callee_saved_gprs.items.len));

        const push_area = push_count * 8;
        const xmm_spill_area = @as(u32, @intCast(self.callee_saved_xmms.items.len)) * 16;
        const spill_area = @as(u32, @intCast(self.spill_count)) * 8;
        const raw_local = self.local_size + spill_area;
        const local_area = (raw_local + 15) & ~@as(u32, 15);

        const combined = push_area + xmm_spill_area + local_area;
        const pad: u32 = (16 - (combined % 16)) % 16;
        const total_frame = local_area + pad;

        return .{
            .push_area = push_area,
            .xmm_spill_area = xmm_spill_area,
            .spill_area = spill_area,
            .local_area = local_area,
            .total_frame = total_frame,
            .push_count = push_count,
            .use_frame_pointer = self.use_frame_pointer,
        };
    }

    pub fn spillOffset(self: *const FrameManager, slot: u32) i32 {
        const layout = self.computeLayout();
        return -@as(i32, @intCast(layout.push_area + layout.xmm_spill_area + slot * 8));
    }

    pub fn allocaOffset(self: *const FrameManager, index: u32) i32 {
        const layout = self.computeLayout();
        return -@as(i32, @intCast(layout.push_area + layout.xmm_spill_area + layout.spill_area + index * 8));
    }

    pub fn xmmSpillOffset(self: *const FrameManager, index: u32) i32 {
        const layout = self.computeLayout();
        return -@as(i32, @intCast(layout.push_area + index * 16 + 16));
    }

    pub fn emitPrologue(self: *const FrameManager, code: *std.ArrayList(u8)) !void {
        if (self.use_frame_pointer) {
            try x64.emit(code, .PUSH_R64, &.{enc.Operand.r(5)});
            try x64.emit(code, .MOV_R64_R64, &.{ enc.Operand.r(5), enc.Operand.r(4) });
        }

        for (self.callee_saved_gprs.items) |reg| {
            try x64.emit(code, .PUSH_R64, &.{enc.Operand.r(reg)});
        }

        for (self.callee_saved_xmms.items) |xmm_reg| {
            try x64.emit(code, .SUB_R64_IMM32, &.{ enc.Operand.r(4), enc.Operand.immU32(16) });
            try x64.emit(code, .SSE_MOVUPS_ST, &.{ enc.Operand.xmm(xmm_reg), enc.Operand.mem(4, 0) });
        }

        const layout = self.computeLayout();

        if (layout.total_frame >= self.large_frame_threshold) {
            try emitChkstk(code, layout.total_frame);
        } else if (layout.total_frame > 0) {
            try x64.emit(code, .SUB_R64_IMM32, &.{ enc.Operand.r(4), enc.Operand.immU32(layout.total_frame) });
        }
    }

    pub fn emitEpilogue(self: *const FrameManager, code: *std.ArrayList(u8)) !void {
        const layout = self.computeLayout();

        if (layout.total_frame > 0) {
            try x64.emit(code, .ADD_R64_IMM32, &.{ enc.Operand.r(4), enc.Operand.immU32(layout.total_frame) });
        }

        var i: usize = self.callee_saved_xmms.items.len;
        while (i > 0) {
            i -= 1;
            try x64.emit(code, .SSE_MOVUPS_LD, &.{ enc.Operand.xmm(self.callee_saved_xmms.items[i]), enc.Operand.mem(4, 0) });
            try x64.emit(code, .ADD_R64_IMM32, &.{ enc.Operand.r(4), enc.Operand.immU32(16) });
        }

        i = self.callee_saved_gprs.items.len;
        while (i > 0) {
            i -= 1;
            try x64.emit(code, .POP_R64, &.{enc.Operand.r(self.callee_saved_gprs.items[i])});
        }

        if (self.use_frame_pointer) {
            try x64.emit(code, .POP_R64, &.{enc.Operand.r(5)});
        }
        try x64.emit(code, .RET, &.{});
    }

    pub fn emitCallSetup(self: *const FrameManager, code: *std.ArrayList(u8), arg_count: u32) !void {
        const shadow: u32 = switch (self.abi) {
            .win64 => 32,
            .system_v => 0,
        };
        const register_args: u32 = switch (self.abi) {
            .win64 => 4,
            .system_v => 6,
        };
        const stack_args: u32 = if (arg_count > register_args) (arg_count - register_args) * 8 else 0;
        const raw_total = shadow + stack_args;
        const alloc = (raw_total + 15) & ~@as(u32, 15);
        if (alloc > 0) {
            try x64.emit(code, .SUB_R64_IMM32, &.{ enc.Operand.r(4), enc.Operand.immU32(alloc) });
        }
    }

    pub fn emitCallCleanup(self: *const FrameManager, code: *std.ArrayList(u8), arg_count: u32) !void {
        const shadow: u32 = switch (self.abi) {
            .win64 => 32,
            .system_v => 0,
        };
        const register_args: u32 = switch (self.abi) {
            .win64 => 4,
            .system_v => 6,
        };
        const stack_args: u32 = if (arg_count > register_args) (arg_count - register_args) * 8 else 0;
        const raw_total = shadow + stack_args;
        const alloc = (raw_total + 15) & ~@as(u32, 15);
        if (alloc > 0) {
            try x64.emit(code, .ADD_R64_IMM32, &.{ enc.Operand.r(4), enc.Operand.immU32(alloc) });
        }
    }

    pub fn getUnwindInfo(self: *const FrameManager) UnwindInfo {
        const layout = self.computeLayout();
        return .{
            .push_count = layout.push_count,
            .has_frame_pointer = self.use_frame_pointer,
            .xmm_spill_size = layout.xmm_spill_area,
            .stack_size = layout.total_frame,
        };
    }

    fn emitChkstk(code: *std.ArrayList(u8), frame_size: u32) !void {
        try x64.emit(code, .MOV_R64_IMM64, &.{ enc.Operand.r(10), enc.Operand.immU32(frame_size) });
        try x64.emit(code, .MOV_R64_IMM64, &.{ enc.Operand.r(0), enc.Operand.immU32(frame_size) });
        try x64.emit(code, .CALL_REL32, &.{enc.Operand.immU32(0)});
        try x64.emit(code, .SUB_R64_IMM32, &.{ enc.Operand.r(4), enc.Operand.r(10) });
    }
};
