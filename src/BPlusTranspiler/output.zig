const std = @import("std");

const BPlusContext = struct {
    current_rpm: i32 = 1500,
    target_gear: i32 = 1,
    current_state: StateFn = Parking_enter,
};

const StateFn = *const fn (ctx: *BPlusContext, event: []const u8) void;

fn Parking_enter(ctx: *BPlusContext, event: []const u8) void {
    if (std.mem.eql(u8, event, "enter")) {
        std.debug.print("Статус: Инициализация PARKING...\\n\n", .{});
        return;
    }
    if (std.mem.eql(u8, event, "__always__")) {
        if (ctx.current_rpm > 1200) {
            ctx.current_state = Drive_enter;
            ctx.current_state(ctx, "enter");
            return;
        }
    }
}

fn Drive_enter(ctx: *BPlusContext, event: []const u8) void {
    if (std.mem.eql(u8, event, "enter")) {
        std.debug.print("Статус: Обороты > 1200! Коробка перешла в DRIVE.\\n\n", .{});
        return;
    }
    _ = ctx;
}

pub fn main() !void {
    var ctx = BPlusContext{};
    ctx.current_state(&ctx, "enter");
}
