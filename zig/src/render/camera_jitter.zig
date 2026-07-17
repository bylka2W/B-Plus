const std = @import("std");

pub fn halton(index: u32, base: u32) f32 {
    var f: f32 = 1;
    var r: f32 = 0;
    var i = index;
    while (i > 0) {
        f /= @as(f32, @floatFromInt(base));
        r += f * @as(f32, @floatFromInt(i % base));
        i /= base;
    }
    return r;
}

pub fn getJitter(frame: u32) struct { x: f32, y: f32 } {
    return .{
        .x = halton(frame, 2) - 0.5,
        .y = halton(frame, 3) - 0.5,
    };
}

pub const JitteredProjection = struct {
    jitter_x: f32,
    jitter_y: f32,
    width: f32,
    height: f32,

    pub fn init(width: u32, height: u32, frame: u32) JitteredProjection {
        const j = getJitter(frame);
        return .{
            .jitter_x = j.x / @as(f32, @floatFromInt(width)),
            .jitter_y = j.y / @as(f32, @floatFromInt(height)),
            .width = @as(f32, @floatFromInt(width)),
            .height = @as(f32, @floatFromInt(height)),
        };
    }

    pub fn toHLSLConstants(self: *const JitteredProjection) [4]f32 {
        return .{ self.jitter_x, self.jitter_y, 1.0 / self.width, 1.0 / self.height };
    }
};
