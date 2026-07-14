const std = @import("std");
const gpu_types = @import("gpu_types.zig");
const history_manager = @import("history_manager.zig");
const camera_jitter = @import("camera_jitter.zig");

/// Camera matrices for reprojection.
pub const CameraMatrices = struct {
    view: [16]f32 = undefined,
    projection: [16]f32 = undefined,
    view_projection: [16]f32 = undefined,
    inverse_view: [16]f32 = undefined,
    inverse_projection: [16]f32 = undefined,
    inverse_view_projection: [16]f32 = undefined,
    prev_view_projection: [16]f32 = undefined,

    pub fn update(self: *CameraMatrices, view: *const [16]f32, proj: *const [16]f32) void {
        self.view = view.*;
        self.projection = proj.*;
        matMul(view, proj, &self.view_projection);
        matInverse(view, &self.inverse_view);
        matInverse(proj, &self.inverse_projection);
        matInverse(&self.view_projection, &self.inverse_view_projection);
    }

    pub fn advanceFrame(self: *CameraMatrices) void {
        self.prev_view_projection = self.view_projection;
    }
};

/// Per-frame constants for temporal reprojection shader.
pub const TemporalConstants = struct {
    jitter_x: f32,
    jitter_y: f32,
    prev_jitter_x: f32,
    prev_jitter_y: f32,
    viewport_width: f32,
    viewport_height: f32,
    inv_width: f32,
    inv_height: f32,
    near_plane: f32,
    far_plane: f32,
    frame_index: u32,
    reset_history: u32,
    pad: [2]u32 = undefined,
};

/// Motion vector generation constants.
pub const MotionVectorConstants = struct {
    viewport_width: f32,
    viewport_height: f32,
    inv_viewport_width: f32,
    inv_viewport_height: f32,
    near_plane: f32,
    far_plane: f32,
    reprojection_matrix: [16]f32, // prev_view_proj * inv_current_view_proj
};

/// Temporal accumulation constants.
pub const AccumulationConstants = struct {
    jitter_x: f32,
    jitter_y: f32,
    prev_jitter_x: f32,
    prev_jitter_y: f32,
    viewport_width: f32,
    viewport_height: f32,
    inv_width: f32,
    inv_height: f32,
    feedback: f32, // temporal feedback factor (0.0-1.0)
    motion_scale: f32,
    depth_threshold: f32,
    frame_index: u32,
    reset_history: u32,
};

/// Disocclusion detection constants.
pub const DisocclusionConstants = struct {
    depth_threshold: f32 = 0.05,
    motion_amplitude: f32 = 0.02,
    normal_threshold: f32 = 0.3,
    neighbourhood: u32 = 2,
};

/// Temporal pipeline — manages reprojection, motion vectors, and accumulation.
pub const TemporalPipeline = struct {
    width: u32,
    height: u32,
    camera: CameraMatrices = .{},
    jitter: camera_jitter.JitteredProjection = undefined,
    prev_jitter: camera_jitter.JitteredProjection = undefined,
    history: history_manager.HistoryManager = .{},
    frame_index: u32 = 0,
    reset_history: bool = true,
    disocclusion: DisocclusionConstants = .{},

    pub fn init(width: u32, height: u32) TemporalPipeline {
        return .{
            .width = width,
            .height = height,
            .jitter = camera_jitter.JitteredProjection.init(width, height, 0),
            .prev_jitter = camera_jitter.JitteredProjection.init(width, height, 0),
        };
    }

    pub fn beginFrame(self: *TemporalPipeline) void {
        self.frame_index += 1;
        self.jitter = camera_jitter.JitteredProjection.init(self.width, self.height, self.frame_index);
        self.history.beginFrame();
    }

    pub fn endFrame(self: *TemporalPipeline) void {
        self.camera.advanceFrame();
        self.prev_jitter = self.jitter;
        self.reset_history = false;
    }

    pub fn getTemporalConstants(self: *const TemporalPipeline) TemporalConstants {
        return .{
            .jitter_x = self.jitter.jitter_x,
            .jitter_y = self.jitter.jitter_y,
            .prev_jitter_x = self.prev_jitter.jitter_x,
            .prev_jitter_y = self.prev_jitter.jitter_y,
            .viewport_width = @as(f32, @floatFromInt(self.width)),
            .viewport_height = @as(f32, @floatFromInt(self.height)),
            .inv_width = 1.0 / @as(f32, @floatFromInt(self.width)),
            .inv_height = 1.0 / @as(f32, @floatFromInt(self.height)),
            .near_plane = 0.1,
            .far_plane = 1000.0,
            .frame_index = self.frame_index,
            .reset_history = @intFromBool(self.reset_history),
        };
    }

    pub fn getMotionConstants(self: *const TemporalPipeline) MotionVectorConstants {
        var reproj_mat: [16]f32 = undefined;
        matMul(&self.camera.prev_view_projection, &self.camera.inverse_view_projection, &reproj_mat);
        return .{
            .viewport_width = @as(f32, @floatFromInt(self.width)),
            .viewport_height = @as(f32, @floatFromInt(self.height)),
            .inv_viewport_width = 1.0 / @as(f32, @floatFromInt(self.width)),
            .inv_viewport_height = 1.0 / @as(f32, @floatFromInt(self.height)),
            .near_plane = 0.1,
            .far_plane = 1000.0,
            .reprojection_matrix = reproj_mat,
        };
    }

    pub fn getAccumulationConstants(self: *const TemporalPipeline) AccumulationConstants {
        return .{
            .jitter_x = self.jitter.jitter_x,
            .jitter_y = self.jitter.jitter_y,
            .prev_jitter_x = self.prev_jitter.jitter_x,
            .prev_jitter_y = self.prev_jitter.jitter_y,
            .viewport_width = @as(f32, @floatFromInt(self.width)),
            .viewport_height = @as(f32, @floatFromInt(self.height)),
            .inv_width = 1.0 / @as(f32, @floatFromInt(self.width)),
            .inv_height = 1.0 / @as(f32, @floatFromInt(self.height)),
            .feedback = 0.9,
            .motion_scale = 1.0,
            .depth_threshold = 0.05,
            .frame_index = self.frame_index,
            .reset_history = @intFromBool(self.reset_history),
        };
    }
};

// ── Matrix math helpers ──

fn matMul(a: *const [16]f32, b: *const [16]f32, out: *[16]f32) void {
    for (0..4) |row| {
        for (0..4) |col| {
            var sum: f32 = 0;
            for (0..4) |k| {
                sum += a[row * 4 + k] * b[k * 4 + col];
            }
            out[row * 4 + col] = sum;
        }
    }
}

fn matInverse(m: *const [16]f32, out: *[16]f32) void {
    const a = m[0];
    const b = m[1];
    const c = m[2];
    const d = m[3];
    const e = m[4];
    const f = m[5];
    const g = m[6];
    const h = m[7];
    const i = m[8];
    const j = m[9];
    const k = m[10];
    const l = m[11];
    const m0 = m[12];
    const m1 = m[13];
    const m2 = m[14];
    const m3 = m[15];

    const s0 = a * f - b * e;
    const s1 = a * g - c * e;
    const s2 = a * h - d * e;
    const s3 = b * g - c * f;
    const s4 = b * h - d * f;
    const s5 = c * h - d * g;
    const s6 = i * m1 - j * m0;
    const s7 = i * m2 - k * m0;
    const s8 = i * m3 - l * m0;
    const s9 = j * m2 - k * m1;
    const s10 = j * m3 - l * m1;
    const s11 = k * m3 - l * m2;

    const det = s0 * s11 - s1 * s10 + s2 * s9 + s3 * s8 - s4 * s7 + s5 * s6;
    if (det == 0) {
        @memcpy(out, m);
        return;
    }
    const inv_det = 1.0 / det;

    out[0] = (f * s11 - g * s10 + h * s9) * inv_det;
    out[1] = (-b * s11 + c * s10 - d * s9) * inv_det;
    out[2] = (m1 * s5 - m2 * s4 + m3 * s3) * inv_det;
    out[3] = (-j * s5 + k * s4 - l * s3) * inv_det;
    out[4] = (-e * s11 + g * s8 - h * s7) * inv_det;
    out[5] = (a * s11 - c * s8 + d * s7) * inv_det;
    out[6] = (-m0 * s5 + m2 * s2 - m3 * s1) * inv_det;
    out[7] = (i * s5 - k * s2 + l * s1) * inv_det;
    out[8] = (e * s10 - f * s8 + h * s6) * inv_det;
    out[9] = (-a * s10 + b * s8 - d * s6) * inv_det;
    out[10] = (m0 * s4 - m1 * s2 + m3 * s0) * inv_det;
    out[11] = (-i * s4 + j * s2 - l * s0) * inv_det;
    out[12] = (-e * s9 + f * s7 - g * s6) * inv_det;
    out[13] = (a * s9 - b * s7 + c * s6) * inv_det;
    out[14] = (-m0 * s3 + m1 * s1 - m2 * s0) * inv_det;
    out[15] = (i * s3 - j * s1 + k * s0) * inv_det;
}
