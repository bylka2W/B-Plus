const std = @import("std");
const Allocator = std.mem.Allocator;
const gpu_ast = @import("gpu_ast.zig");

pub const Severity = enum { @"error", warning, };

pub const Diagnostic = struct {
    severity: Severity,
    message: []const u8,
    kind: Kind,

    pub const Kind = union(enum) {
        duplicate_binding: struct { resource: []const u8, existing: []const u8, reg: u32 },
        duplicate_cbuffer_slot: struct { member: []const u8, reg: u32 },
        numthreads_limit: struct { dim: []const u8, value: u32, max: u32 },
        numthreads_total_limit: struct { total: u32, max: u32 },
        missing_entry: void,
        missing_resource: []const u8,
        invalid_register: struct { resource: []const u8, reg: u32 },
        resource_limit: struct { prefix: u8, count: u32, max: u32 },
        type_mismatch: struct { name: []const u8, expected: []const u8, got: []const u8 },
    };
};

pub const GpuSema = struct {
    allocator: Allocator,
    diagnostics: std.ArrayList(Diagnostic),

    pub fn init(allocator: Allocator) GpuSema {
        return .{ .allocator = allocator, .diagnostics = std.ArrayList(Diagnostic).init(allocator) };
    }

    pub fn deinit(self: *GpuSema) void {
        self.diagnostics.deinit();
    }

    pub fn analyze(self: *GpuSema, module: *const gpu_ast.GpuModule) void {
        for (module.kernels.items) |*kernel| {
            self.analyzeKernel(kernel);
        }
    }

    fn analyzeKernel(self: *GpuSema, kernel: *const gpu_ast.GpuKernel) void {
        self.checkResourceBindings(kernel);
        self.checkCbufferBindings(kernel);
        self.checkResourceLimits(kernel);
        self.checkNumthreads(kernel);
        self.checkEntries(kernel);
    }

    fn checkResourceTypes(_: *GpuSema, _: *const gpu_ast.GpuKernel) void {}

    fn checkResourceBindings(self: *GpuSema, kernel: *const gpu_ast.GpuKernel) void {
        var seen = std.AutoHashMap(u64, usize).init(self.allocator);
        defer seen.deinit();

        for (kernel.resources.items, 0..) |res, i| {
            const prefix: u8 = switch (res.gpu_type.kind) {
                .resource_typed => |rt| if (rt.kind == .rw_texture2d) 'u' else 't',
                .resource => |rk| if (rk == .sampler_state) 's' else 't',
                else => 't',
            };
            const key: u64 = (@as(u64, prefix) << 32) | res.binding.reg;
            if (seen.get(key)) |prev_idx| {
                const prev = kernel.resources.items[prev_idx];
                self.diagnostics.append(.{
                    .severity = .@"error",
                    .message = "duplicate register binding",
                    .kind = .{ .duplicate_binding = .{ .resource = res.name, .existing = prev.name, .reg = res.binding.reg } },
                }) catch {};
            }
            seen.put(key, i) catch {};
        }
    }

    fn checkCbufferBindings(self: *GpuSema, kernel: *const gpu_ast.GpuKernel) void {
        for (kernel.cbuffer_members.items, 0..) |a, i| {
            for (kernel.cbuffer_members.items[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.name, b.name)) {
                    self.diagnostics.append(.{
                        .severity = .@"error",
                        .message = "duplicate cbuffer member name",
                        .kind = .{ .duplicate_cbuffer_slot = .{ .member = a.name, .reg = a.slot.reg } },
                    }) catch {};
                }
            }
        }
    }

    fn checkResourceLimits(self: *GpuSema, kernel: *const gpu_ast.GpuKernel) void {
        var t_count: u32 = 0;
        var u_count: u32 = 0;
        var s_count: u32 = 0;

        for (kernel.resources.items) |res| {
            switch (res.gpu_type.kind) {
                .resource_typed => |rt| {
                    if (rt.kind == .rw_texture2d) u_count += 1 else t_count += 1;
                },
                .resource => |rk| {
                    switch (rk) {
                        .sampler_state => s_count += 1,
                        else => t_count += 1,
                    }
                },
                else => {},
            }
        }

        if (t_count > 128) {
            self.diagnostics.append(.{ .severity = .@"error", .message = "too many t-register resources", .kind = .{ .resource_limit = .{ .prefix = 't', .count = t_count, .max = 128 } } }) catch {};
        }
        if (u_count > 64) {
            self.diagnostics.append(.{ .severity = .@"error", .message = "too many u-register resources", .kind = .{ .resource_limit = .{ .prefix = 'u', .count = u_count, .max = 64 } } }) catch {};
        }
        if (s_count > 16) {
            self.diagnostics.append(.{ .severity = .@"error", .message = "too many s-register resources", .kind = .{ .resource_limit = .{ .prefix = 's', .count = s_count, .max = 16 } } }) catch {};
        }
    }

    fn checkNumthreads(self: *GpuSema, kernel: *const gpu_ast.GpuKernel) void {
        for (kernel.entries.items) |entry| {
            const nt = entry.numthreads;
            if (nt.x == 0 or nt.x > 1024) {
                self.diagnostics.append(.{ .severity = .@"error", .message = "numthreads X out of range", .kind = .{ .numthreads_limit = .{ .dim = "X", .value = nt.x, .max = 1024 } } }) catch {};
            }
            if (nt.y == 0 or nt.y > 1024) {
                self.diagnostics.append(.{ .severity = .@"error", .message = "numthreads Y out of range", .kind = .{ .numthreads_limit = .{ .dim = "Y", .value = nt.y, .max = 1024 } } }) catch {};
            }
            if (nt.z == 0 or nt.z > 64) {
                self.diagnostics.append(.{ .severity = .@"error", .message = "numthreads Z out of range", .kind = .{ .numthreads_limit = .{ .dim = "Z", .value = nt.z, .max = 64 } } }) catch {};
            }
            const total = nt.x * nt.y * nt.z;
            if (total > 1024) {
                self.diagnostics.append(.{ .severity = .@"error", .message = "numthreads total exceeds 1024", .kind = .{ .numthreads_total_limit = .{ .total = total, .max = 1024 } } }) catch {};
            }
        }
    }

    fn checkEntries(self: *GpuSema, kernel: *const gpu_ast.GpuKernel) void {
        if (kernel.entries.items.len == 0) {
            self.diagnostics.append(.{ .severity = .@"error", .message = "kernel has no entry function", .kind = .{ .missing_entry = {} } }) catch {};
        }
    }

    pub fn hasErrors(self: *const GpuSema) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }

    pub fn printDiagnostics(self: *const GpuSema, writer: anytype) !void {
        for (self.diagnostics.items) |d| {
            const tag = if (d.severity == .@"error") "error" else "warning";
            try writer.print("[{s}] {s}\n", .{ tag, d.message });
        }
    }
};
