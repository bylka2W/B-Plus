const std = @import("std");

const BPlusContext = struct {
    rpm: i32 = 1000,
    temp: i32 = 80,
    current_state: StateFn = Parking_enter,
};

const StateFn = *const fn (ctx: *BPlusContext, event: []const u8) void;

fn Parking_enter(ctx: *BPlusContext, event: []const u8) void {
    if (std.mem.eql(u8, event, "__always__")) {
        if (ctx.rpm + 500 > 1200) {
            ctx.current_state = Drive_enter;
            ctx.current_state(ctx, "enter");
            return;
        }
    }
}

fn Drive_enter(ctx: *BPlusContext, event: []const u8) void {
    if (std.mem.eql(u8, event, "__always__")) {
        if (ctx.temp > 90) {
            ctx.current_state = Drive_enter;
            ctx.current_state(ctx, "enter");
            return;
        }
        if (ctx.rpm < 500) {
            ctx.current_state = Parking_enter;
            ctx.current_state(ctx, "enter");
            return;
        }
    }
}

pub fn main() !void {
    var ctx = BPlusContext{};
    ctx.current_state(&ctx, "enter");
}
