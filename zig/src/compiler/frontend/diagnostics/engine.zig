const std = @import("std");
const diag_mod = @import("core/diagnostic.zig");
const severity_mod = @import("core/severity.zig");
const source_mod = @import("../../source/file/source_file.zig");

pub const Diagnostic = diag_mod.Diagnostic;
pub const Severity = severity_mod.Severity;

pub const DiagnosticsEngine = struct {
    allocator: std.mem.Allocator,
    diagnostics: std.ArrayList(Diagnostic),

    pub fn init(allocator: std.mem.Allocator) DiagnosticsEngine {
        return .{
            .allocator = allocator,
            .diagnostics = std.ArrayList(Diagnostic).init(allocator),
        };
    }

    pub fn deinit(self: *DiagnosticsEngine) void {
        for (self.diagnostics.items) |*d| d.deinit();
        self.diagnostics.deinit();
    }

    pub fn push(self: *DiagnosticsEngine, diag: Diagnostic) void {
        self.diagnostics.append(diag) catch {};
    }

    pub fn error_(self: *DiagnosticsEngine, msg: []const u8) void {
        self.push(Diagnostic.init(self.allocator, .@"error", msg));
    }

    pub fn warning(self: *DiagnosticsEngine, msg: []const u8) void {
        self.push(Diagnostic.init(self.allocator, .warning, msg));
    }

    pub fn note(self: *DiagnosticsEngine, msg: []const u8) void {
        self.push(Diagnostic.init(self.allocator, .note, msg));
    }

    pub fn fatal(self: *DiagnosticsEngine, msg: []const u8) void {
        self.push(Diagnostic.init(self.allocator, .fatal, msg));
    }

    pub fn ice(self: *DiagnosticsEngine, msg: []const u8) void {
        self.push(Diagnostic.init(self.allocator, .ice, msg));
    }

    pub fn hasErrors(self: *const DiagnosticsEngine) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity.isError()) return true;
        }
        return false;
    }

    pub fn errorCount(self: *const DiagnosticsEngine) u32 {
        var n: u32 = 0;
        for (self.diagnostics.items) |d| {
            if (d.severity.isError()) n += 1;
        }
        return n;
    }

    pub fn warningCount(self: *const DiagnosticsEngine) u32 {
        var n: u32 = 0;
        for (self.diagnostics.items) |d| {
            if (d.severity == .warning) n += 1;
        }
        return n;
    }

    pub fn count(self: *const DiagnosticsEngine) u32 {
        return @intCast(self.diagnostics.items.len);
    }

    pub fn formatTerminal(self: *const DiagnosticsEngine, writer: anytype, files: anytype) void {
        const render = @import("render/terminal.zig");
        render.renderTerminal(writer, self.diagnostics.items, files) catch {};
    }

    pub fn formatJson(self: *const DiagnosticsEngine, writer: anytype) void {
        const render = @import("render/json.zig");
        render.renderJson(writer, self.diagnostics.items) catch {};
    }
};
