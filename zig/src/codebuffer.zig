const std = @import("std");
const x64 = @import("x64enc.zig");
const Allocator = std.mem.Allocator;

pub const LabelId = u32;

pub const Fixup = struct {
    offset: usize,
    disp_size: u32,
    label_id: LabelId,
};

pub const EntryAddrFixup = struct {
    code_offset: usize,
    entry_name: []const u8,
};

pub const CodeBuffer = struct {
    bytes: std.ArrayList(u8),
    fixups: std.ArrayList(Fixup),
    entry_fixups: std.ArrayList(EntryAddrFixup),
    label_offsets: std.ArrayList(?usize),
    label_names: std.ArrayList([]const u8),
    label_name_map: std.StringHashMap(u32),
    allocator: Allocator,

    pub fn init(allocator: Allocator) CodeBuffer {
        return .{
            .bytes = std.ArrayList(u8).init(allocator),
            .fixups = std.ArrayList(Fixup).init(allocator),
            .entry_fixups = std.ArrayList(EntryAddrFixup).init(allocator),
            .label_offsets = std.ArrayList(?usize).init(allocator),
            .label_names = std.ArrayList([]const u8).init(allocator),
            .label_name_map = std.StringHashMap(u32).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CodeBuffer) void {
        self.bytes.deinit();
        self.fixups.deinit();
        for (self.entry_fixups.items) |fx| self.allocator.free(fx.entry_name);
        self.entry_fixups.deinit();
        for (self.label_names.items) |n| self.allocator.free(n);
        self.label_offsets.deinit();
        self.label_names.deinit();
        self.label_name_map.deinit();
    }

    pub fn allocLabel(self: *CodeBuffer, comptime fmt: []const u8, args: anytype) !LabelId {
        var buf: [128]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, fmt, args);
        if (self.label_name_map.get(name)) |id| return id;
        const owned = try self.allocator.dupe(u8, name);
        try self.label_names.append(owned);
        try self.label_offsets.append(null);
        const id = @as(LabelId, @intCast(self.label_offsets.items.len - 1));
        try self.label_name_map.put(owned, id);
        return id;
    }

    pub fn setLabel(self: *CodeBuffer, id: LabelId) !void {
        self.label_offsets.items[id] = self.bytes.items.len;
    }

    pub fn setLabelAt(self: *CodeBuffer, id: LabelId, off: usize) void {
        self.label_offsets.items[id] = off;
    }

    pub fn getLabel(self: *const CodeBuffer, id: LabelId) ?usize {
        return self.label_offsets.items[id];
    }

    pub fn addFixup(self: *CodeBuffer, offset: usize, disp_size: u32, label_id: LabelId) !void {
        try self.fixups.append(.{ .offset = offset, .disp_size = disp_size, .label_id = label_id });
    }

    pub fn addEntryFixup(self: *CodeBuffer, code_offset: usize, entry_name: []const u8) !void {
        try self.entry_fixups.append(.{ .code_offset = code_offset, .entry_name = entry_name });
    }

    pub fn emitByte(self: *CodeBuffer, byte: u8) !void {
        try self.bytes.append(byte);
    }

    pub fn emitSlice(self: *CodeBuffer, slice: []const u8) !void {
        try self.bytes.appendSlice(slice);
    }

    pub fn emitRipRelativeStore64(self: *CodeBuffer, reg: i16) !usize {
        try x64.emit(&self.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(255, 0), x64.Operand.r(reg) });
        return self.bytes.items.len - 4;
    }

    pub fn emitRipRelativeStore32(self: *CodeBuffer, reg: i16) !usize {
        try x64.emit(&self.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(255, 0), x64.Operand.r(reg) });
        return self.bytes.items.len - 4;
    }

    pub fn emitRipRelativeLoad64(self: *CodeBuffer, reg: i16) !usize {
        try x64.emit(&self.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(reg), x64.Operand.mem(255, 0) });
        return self.bytes.items.len - 4;
    }

    pub fn emitRipRelativeLoad32(self: *CodeBuffer, reg: i16) !usize {
        try x64.emit(&self.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(reg), x64.Operand.mem(255, 0) });
        return self.bytes.items.len - 4;
    }

    pub fn applyFixups(self: *CodeBuffer) !void {
        for (self.fixups.items) |f| {
            const target = self.label_offsets.items[f.label_id] orelse return error.UnresolvedFixup;
            const disp = @as(i64, @intCast(target)) - @as(i64, @intCast(f.offset + f.disp_size));
            if (f.disp_size == 4) {
                self.bytes.items[f.offset..][0..4].* = @as([4]u8, @bitCast(@as(i32, @truncate(disp))));
            } else if (f.disp_size == 2) {
                self.bytes.items[f.offset..][0..2].* = @as([2]u8, @bitCast(@as(i16, @truncate(disp))));
            } else if (f.disp_size == 1) {
                self.bytes.items[f.offset] = @as(u8, @bitCast(@as(i8, @truncate(disp))));
            }
        }
    }
};
