const std = @import("std");
const gpu_types = @import("../compiler/backend/gpu/gpu_types.zig");
const frame_graph = @import("frame_graph.zig");
const render_graph = @import("render_graph.zig");
const resource_system = @import("resource_system.zig");
const history_manager = @import("history_manager.zig");
const temporal_pipeline = @import("temporal_pipeline.zig");
const gpu_execution = @import("gpu_execution.zig");



/// FSR 3.1 quality mode.
pub const QualityMode = enum {
    performance, // 2x
    balanced,    // 2x
    quality,     // 2x
    ultra_quality, // 2x
};

/// Frame generation mode: how many frames to interpolate.
pub const GenMode = enum {
    /// Generate 1 frame between each real frame (2x frame rate).
    x2,
    /// Generate 2 frames (3x frame rate).
    x3,
    /// Generate 3 frames (4x frame rate).
    x4,
};

/// Configuration for FSR 3.1 pipeline.
pub const FSR3Config = struct {
    display_width: u32,
    display_height: u32,
    render_width: u32,
    render_height: u32,
    quality: QualityMode = .quality,
    gen_mode: GenMode = .x2,
    enable_optical_flow: bool = true,
    enable_debug: bool = false,
    motion_scale: f32 = 1.0,
    depth_threshold: f32 = 0.05,
};

/// FSR 3.1 pipeline pass IDs.
pub const FSR3Pass = enum(u32) {
    optical_flow = 100,
    disocclusion = 101,
    generate = 102,
    post_process = 103,
};

/// Static dependency arrays for FSR3 pass graph.
/// Module-level const ensures static lifetime (no dangling references).
const empty_deps: []const u32 = &.{};
const disocclusion_deps: []const u32 = &.{@intFromEnum(FSR3Pass.optical_flow)};
const generate_deps: []const u32 = &.{@intFromEnum(FSR3Pass.disocclusion)};
const post_process_deps: []const u32 = &.{@intFromEnum(FSR3Pass.generate)};

/// FSR 3.1 resource IDs (beyond those managed by history).
pub const FSR3Resources = struct {
    optical_flow: gpu_types.ResourceId = 0,
    disocclusion: gpu_types.ResourceId = 0,
    confidence: gpu_types.ResourceId = 0,
    generated_frame: gpu_types.ResourceId = 0,
    debug_output: gpu_types.ResourceId = 0,
};

/// Frame classification determined by policy engine.
/// Canonical definition in gpu_execution.zig.
pub const FrameMode = gpu_execution.FrameMode;

/// Configuration for the frame policy engine.
pub const FramePolicyConfig = struct {
    /// Max consecutive generated frames before forcing a real frame.
    max_generated_frames: u32 = 2,
    /// Min real frames required between generated sequences.
    min_real_frames: u32 = 1,
    /// Motion intensity above this always forces real frame.
    high_motion_threshold: f32 = 0.7,
    /// Motion below this allows generated frames.
    low_motion_threshold: f32 = 0.3,
    /// Max frame budget in microseconds.
    latency_budget_us: u32 = 2000,
    /// Budget for full render when in real mode.
    render_budget_us: u32 = 16000,
};

/// Input context for policy evaluation.
pub const PolicyContext = struct {
    /// Measured frame latency in microseconds.
    frame_latency_us: u32,
    /// Motion intensity estimate (0 = static, 1 = max motion).
    motion_intensity: f32,
    /// Whether history buffers are valid for generation.
    history_valid: bool,
    /// Current frame index.
    frame_index: u64,
};

/// Frame policy engine — state machine that decides real vs generated vs pass_through.
/// Deterministic: same config + context → same decision.
pub const FramePolicy = struct {
    config: FramePolicyConfig,
    generated_count: u32 = 0,
    real_count: u32 = 0,
    last_mode: FrameMode = .real,

    pub fn init(config: FramePolicyConfig) FramePolicy {
        return .{ .config = config };
    }

    /// Evaluate frame policy for current context.
    /// Returns frame mode and updates internal state.
    pub fn evaluate(self: *FramePolicy, ctx: PolicyContext) FrameMode {
        // 1. Budget overflow → skip frame entirely
        if (ctx.frame_latency_us > self.config.latency_budget_us) {
            self.transition(.pass_through);
            return .pass_through;
        }

        // 2. High motion → must render real frame
        if (ctx.motion_intensity >= self.config.high_motion_threshold) {
            self.transition(.real);
            return .real;
        }

        // 3. If currently in real mode: must accumulate min_real_frames before gen
        if (self.last_mode == .real and self.real_count < self.config.min_real_frames) {
            self.transition(.real);
            return .real;
        }

        // 4. Too many generated frames → need real frame
        if (self.generated_count >= self.config.max_generated_frames) {
            self.transition(.real);
            return .real;
        }

        // 5. History invalid → cannot generate
        if (!ctx.history_valid) {
            self.transition(.real);
            return .real;
        }

        // 6. History valid + not high motion → generate
        if (ctx.motion_intensity < self.config.high_motion_threshold) {
            self.transition(.generated);
            return .generated;
        }

        // 7. Default: real frame (high motion or edge case)
        self.transition(.real);
        return .real;
    }

    fn transition(self: *FramePolicy, mode: FrameMode) void {
        if (mode == self.last_mode) {
            switch (mode) {
                .real => self.real_count += 1,
                .generated => self.generated_count += 1,
                .pass_through => {},
            }
            return;
        }
        // Mode switch: reset counters for new mode
        switch (mode) {
            .real => {
                self.real_count = 1;
                self.generated_count = 0;
            },
            .generated => {
                self.generated_count = 1;
                self.real_count = 0;
            },
            .pass_through => {},
        }
        self.last_mode = mode;
    }

    /// Reset policy state (e.g., on config change or resolution switch).
    pub fn reset(self: *FramePolicy) void {
        self.generated_count = 0;
        self.real_count = 0;
        self.last_mode = .real;
    }
};

/// FSR 3.1 runtime — manages frame generation pipeline.
pub const FSR3Runtime = struct {
    config: FSR3Config,
    temporal: temporal_pipeline.TemporalPipeline,
    resources: FSR3Resources = .{},
    history: history_manager.HistoryManager = .{},
    render_graph: render_graph.RenderGraph = undefined,
    policy: FramePolicy,
    last_present_frame: u64 = 0,
    generated_frame_count: u64 = 0,

    pub fn init(config: FSR3Config) FSR3Runtime {
        return .{
            .config = config,
            .temporal = temporal_pipeline.TemporalPipeline.init(config.render_width, config.render_height),
            .policy = FramePolicy.init(.{}),
        };
    }

    pub fn initResources(
        self: *FSR3Runtime,
        pool: *resource_system.ResourcePool,
    ) !void {
        const w = self.config.render_width;
        const h = self.config.render_height;

        // History resources
        try self.history.initColor(pool, w, h, .r16g16b16a16_float);
        try self.history.initDepth(pool, w, h, .r32_float);
        try self.history.initMotion(pool, w, h, .r16g16_float);
        try self.history.initExposure(pool, w, h, .r16_float);
        try self.history.initReactive(pool, w, h, .r8_unorm);

        // Optical flow resources
        self.resources.optical_flow = try pool.createTexture2D(.{
            .width = w / 2,
            .height = h / 2,
            .format = .r16g16_float,
        });

        // Confidence buffer
        self.resources.confidence = try pool.createTexture2D(.{
            .width = w / 2,
            .height = h / 2,
            .format = .r16_float,
        });

        // Disocclusion mask
        self.resources.disocclusion = try pool.createTexture2D(.{
            .width = w,
            .height = h,
            .format = .r8_unorm,
        });

        // Generated frame output
        self.resources.generated_frame = try pool.createTexture2D(.{
            .width = w,
            .height = h,
            .format = .r16g16b16a16_float,
        });

        if (self.config.enable_debug) {
            self.resources.debug_output = try pool.createTexture2D(.{
                .width = w,
                .height = h,
                .format = .r16g16b16a16_float,
            });
        }
    }

    /// Build GPU pass descriptors from a frame graph, using this runtime's resources.
    pub fn buildGPUPasses(
        _: *const FSR3Runtime,
        allocator: std.mem.Allocator,
        fg: *const frame_graph.FrameGraph,
    ) ![]frame_graph.GPUPassDesc {
        var gpu_count: usize = 0;
        for (fg.passes) |p| {
            if (p.gpu) gpu_count += 1;
        }
        var passes = try allocator.alloc(frame_graph.GPUPassDesc, gpu_count);
        var idx: usize = 0;
        for (fg.passes) |p| {
            if (!p.gpu) continue;
            passes[idx] = .{
                .pass_id = p.id,
                .queue = .compute,
                .pipeline = .{ .shader = .{ .source = "", .entry = "main" } },
                .grid = .{ .x = 8, .y = 8, .z = 1 },
                .bindings = gpu_types.BindGroup{ .entries = &.{} },
            };
            idx += 1;
        }
        return passes;
    }

    /// Owned compile result: bundles the RenderPlan with heap-allocated passes
    /// so both are freed together, preventing use-after-free.
    pub const FrameCompileResult = struct {
        plan: render_graph.RenderPlan,
        owned_passes: []const frame_graph.Pass,
        owned_gpu_passes: []const frame_graph.GPUPassDesc,

        pub fn deinit(self: *FrameCompileResult, allocator: std.mem.Allocator) void {
            self.plan.deinit(allocator);
            allocator.free(self.owned_passes);
            allocator.free(self.owned_gpu_passes);
        }
    };

    /// End-to-end compile: evaluate policy → build graph → schedule → execution plan.
    /// Connects FramePolicy → ExecutionContext → CostScheduler → GpuExecutionPlan.
    /// Returns a FrameCompileResult that owns all allocations (free with .deinit()).
    pub fn compileFrame(
        self: *FSR3Runtime,
        allocator: std.mem.Allocator,
        rg: *render_graph.RenderGraph,
        ctx: PolicyContext,
        budget_us: u32,
    ) !FrameCompileResult {
        const mode = self.evaluateFramePolicy(ctx);
        const fg = try self.buildFrameGraph(allocator);
        const gpu_passes = try self.buildGPUPasses(allocator, &fg);
        const plan = try rg.compileWithMode(fg.passes, gpu_passes, budget_us, mode);
        return .{
            .plan = plan,
            .owned_passes = fg.passes,
            .owned_gpu_passes = gpu_passes,
        };
    }

    pub fn buildFrameGraph(self: *FSR3Runtime, allocator: std.mem.Allocator) !frame_graph.FrameGraph {
        const interp_t = self.getInterpolationT();
        const passes = try allocator.alloc(frame_graph.Pass, 4);
        passes[0] = .{
            .id = @intFromEnum(FSR3Pass.optical_flow),
            .name = "fsr3_optical_flow",
            .deps = empty_deps,
            .gpu = true,
            .gpu_wait_for = empty_deps,
            .gpu_signal = empty_deps,
            .cost_us = 500,
            .critical = true,
            .history_reads = .{ .color = true, .depth = true },
            .history_writes = .{},
            .fsr3_pass = 0,
            .interp_t = interp_t,
        };
        passes[1] = .{
            .id = @intFromEnum(FSR3Pass.disocclusion),
            .name = "fsr3_disocclusion",
            .deps = disocclusion_deps,
            .gpu = true,
            .gpu_wait_for = empty_deps,
            .gpu_signal = empty_deps,
            .cost_us = 200,
            .critical = true,
            .history_reads = .{ .color = true, .depth = true, .motion = true },
            .history_writes = .{},
            .fsr3_pass = 1,
            .interp_t = interp_t,
        };
        passes[2] = .{
            .id = @intFromEnum(FSR3Pass.generate),
            .name = "fsr3_generate",
            .deps = generate_deps,
            .gpu = true,
            .gpu_wait_for = empty_deps,
            .gpu_signal = empty_deps,
            .cost_us = 1000,
            .critical = true,
            .history_reads = .{ .color = true, .depth = true, .motion = true },
            .history_writes = .{ .color = true },
            .fsr3_pass = 2,
            .interp_t = interp_t,
        };
        passes[3] = .{
            .id = @intFromEnum(FSR3Pass.post_process),
            .name = "fsr3_post",
            .deps = post_process_deps,
            .gpu = true,
            .gpu_wait_for = empty_deps,
            .gpu_signal = empty_deps,
            .cost_us = 300,
            .critical = true,
            .history_reads = .{ .color = true },
            .history_writes = .{},
            .fsr3_pass = 3,
            .interp_t = interp_t,
        };
        return frame_graph.FrameGraph{ .passes = passes };
    }

    pub fn beginFrame(self: *FSR3Runtime) void {
        self.temporal.beginFrame();
        self.history.beginFrame();
    }

    pub fn endFrame(self: *FSR3Runtime) void {
        self.temporal.endFrame();
    }

    pub fn evaluateFramePolicy(self: *FSR3Runtime, ctx: PolicyContext) FrameMode {
        const mode = self.policy.evaluate(ctx);
        if (mode == .generated) {
            self.generated_frame_count += 1;
        }
        return mode;
    }

    pub fn shouldGenerateFrame(self: *FSR3Runtime) bool {
        return self.history.canGenerateFrame();
    }

    pub fn getInterpolationT(self: *const FSR3Runtime) f32 {
        return switch (self.config.gen_mode) {
            .x2 => 0.5,
            .x3 => 0.333,
            .x4 => 0.25,
        };
    }

    pub fn deinit(self: *FSR3Runtime, pool: *resource_system.ResourcePool) void {
        self.history.deinit(pool);
        if (self.resources.optical_flow != 0) {
            if (pool.getResource(self.resources.optical_flow)) |_| {
                _ = pool.resources.remove(self.resources.optical_flow);
            }
        }
        if (self.resources.confidence != 0) {
            if (pool.getResource(self.resources.confidence)) |_| {
                _ = pool.resources.remove(self.resources.confidence);
            }
        }
        if (self.resources.disocclusion != 0) {
            if (pool.getResource(self.resources.disocclusion)) |_| {
                _ = pool.resources.remove(self.resources.disocclusion);
            }
        }
        if (self.resources.generated_frame != 0) {
            if (pool.getResource(self.resources.generated_frame)) |_| {
                _ = pool.resources.remove(self.resources.generated_frame);
            }
        }
    }
};
