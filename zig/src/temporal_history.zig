const std = @import("std");
const history_manager = @import("history_manager.zig");

/// Per-frame confidence score (0.0 = useless, 1.0 = perfect).
pub const FrameConfidence = struct {
    overall: f32 = 1.0,
    reprojection: f32 = 1.0,
    motion_coherence: f32 = 1.0,
    depth_stability: f32 = 1.0,
    exposure_match: f32 = 1.0,
};

/// Per-slot metadata for history ring tracking.
pub const HistorySlotMeta = struct {
    frame_index: u64 = 0,
    confidence: FrameConfidence = .{},
    rejected: bool = false,
};

/// Validation configuration.
pub const ValidationConfig = struct {
    /// Minimum overall confidence to use a frame for temporal accumulation.
    confidence_threshold: f32 = 0.3,
    /// Per-frame confidence decay for old frames (0-1).
    decay_rate: f32 = 0.95,
    /// Max reprojection error before rejection (pixels).
    reprojection_error_max: f32 = 4.0,
    /// Motion magnitude above this triggers rejection.
    motion_discontinuity_threshold: f32 = 0.5,
    /// Depth change ratio above this triggers disocclusion rejection.
    depth_disocclusion_threshold: f32 = 0.2,
};

/// Temporal history validation engine.
/// Tracks per-slot confidence, rejection state, and computes blend weights.
pub const TemporalHistory = struct {
    config: ValidationConfig = .{},
    slot_meta: [history_manager.HISTORY_DEPTH]HistorySlotMeta = [_]HistorySlotMeta{.{}} ** history_manager.HISTORY_DEPTH,
    write_idx: u32 = 0,
    count: u32 = 0,

    /// Call after HistoryRing.push with the current frame index.
    pub fn pushFrame(self: *TemporalHistory, frame_index: u64) void {
        self.write_idx = (self.write_idx + 1) % history_manager.HISTORY_DEPTH;
        if (self.count < history_manager.HISTORY_DEPTH) self.count += 1;

        const slot = &self.slot_meta[self.write_idx];
        slot.frame_index = frame_index;
        slot.confidence = .{}; // starts at 1.0
        slot.rejected = false;
    }

    /// Get metadata slot at offset (0 = current, 1 = previous, etc).
    fn getSlot(self: *const TemporalHistory, offset: u32) HistorySlotMeta {
        if (offset >= self.count) {
            return .{
                .frame_index = 0,
                .confidence = .{ .overall = 0 },
                .rejected = true,
            };
        }
        const read_idx = (self.write_idx + history_manager.HISTORY_DEPTH - offset) % history_manager.HISTORY_DEPTH;
        return self.slot_meta[read_idx];
    }

    /// Get overall confidence for a frame at offset. Applies decay for older frames.
    pub fn getConfidence(self: *const TemporalHistory, offset: u32) f32 {
        const slot = self.getSlot(offset);
        if (slot.rejected) return 0.0;
        const decay = std.math.pow(f32, self.config.decay_rate, @as(f32, @floatFromInt(offset)));
        return slot.confidence.overall * decay;
    }

    /// Whether the frame at offset is usable for temporal accumulation.
    pub fn isFrameValid(self: *const TemporalHistory, offset: u32) bool {
        return self.getConfidence(offset) >= self.config.confidence_threshold;
    }

    /// Compute blend weight for a frame at offset, given a base factor.
    /// Higher confidence → higher weight. Older frames get decayed.
    pub fn getBlendWeight(self: *const TemporalHistory, offset: u32, base_weight: f32) f32 {
        return base_weight * self.getConfidence(offset);
    }

    /// Reject a frame at offset (e.g., due to ghosting, disocclusion).
    pub fn rejectFrame(self: *TemporalHistory, offset: u32) void {
        if (offset >= self.count) return;
        const read_idx = @as(usize, (self.write_idx + history_manager.HISTORY_DEPTH - offset) % history_manager.HISTORY_DEPTH);
        self.slot_meta[read_idx].rejected = true;
        self.slot_meta[read_idx].confidence.overall = 0;
    }

    /// Update reprojection confidence for current frame.
    pub fn setReprojectionConfidence(self: *TemporalHistory, error_pixels: f32) void {
        const slot = &self.slot_meta[self.write_idx];
        const ratio = 1.0 - (error_pixels / self.config.reprojection_error_max);
        slot.confidence.reprojection = @max(@as(f32, 0), @min(@as(f32, 1), ratio));
        slot.confidence.overall = self.computeOverall(slot.confidence);
    }

    /// Update motion coherence confidence for current frame.
    pub fn setMotionCoherence(self: *TemporalHistory, motion_magnitude: f32) void {
        const slot = &self.slot_meta[self.write_idx];
        if (motion_magnitude > self.config.motion_discontinuity_threshold) {
            slot.confidence.motion_coherence = 0;
            slot.rejected = true;
        } else {
            slot.confidence.motion_coherence = 1.0 - (motion_magnitude / self.config.motion_discontinuity_threshold);
        }
        slot.confidence.overall = self.computeOverall(slot.confidence);
    }

    /// Update depth stability confidence for current frame.
    pub fn setDepthStability(self: *TemporalHistory, depth_change_ratio: f32) void {
        const slot = &self.slot_meta[self.write_idx];
        if (depth_change_ratio > self.config.depth_disocclusion_threshold) {
            slot.confidence.depth_stability = 0;
            slot.rejected = true;
        } else {
            slot.confidence.depth_stability = 1.0 - (depth_change_ratio / self.config.depth_disocclusion_threshold);
        }
        slot.confidence.overall = self.computeOverall(slot.confidence);
    }

    /// Reject current frame entirely (e.g., on camera cut, full-screen disocclusion).
    pub fn rejectCurrentFrame(self: *TemporalHistory) void {
        const slot = &self.slot_meta[self.write_idx];
        slot.rejected = true;
        slot.confidence.overall = 0;
    }

    /// Mark current frame as valid (after validation passes).
    pub fn validateCurrentFrame(self: *TemporalHistory) void {
        const slot = &self.slot_meta[self.write_idx];
        slot.rejected = false;
        slot.confidence.overall = self.computeOverall(slot.confidence);
    }

    fn computeOverall(_: *const TemporalHistory, c: FrameConfidence) f32 {
        // Weighted combination: reprojection is most important for temporal stability
        return c.reprojection * 0.4 +
            c.motion_coherence * 0.3 +
            c.depth_stability * 0.2 +
            c.exposure_match * 0.1;
    }

    /// Reset all metadata (on history reset or camera cut).
    pub fn reset(self: *TemporalHistory) void {
        self.write_idx = 0;
        self.count = 0;
        for (&self.slot_meta) |*slot| {
            slot.* = .{};
        }
    }

    /// Number of valid (non-rejected, confident) frames in the ring.
    pub fn validFrameCount(self: *const TemporalHistory) u32 {
        var n: u32 = 0;
        for (0..self.count) |i| {
            if (self.isFrameValid(@intCast(i))) n += 1;
        }
        return n;
    }

    /// Whether we have enough valid history for frame generation.
    pub fn canGenerate(self: *const TemporalHistory) bool {
        // FSR 3.1 needs at least 2 valid frames (N-1 and N) for interpolation
        var valid_count: u32 = 0;
        for (0..self.count) |i| {
            if (self.isFrameValid(@intCast(i))) {
                valid_count += 1;
                if (valid_count >= 2) return true;
            }
        }
        return false;
    }
};
