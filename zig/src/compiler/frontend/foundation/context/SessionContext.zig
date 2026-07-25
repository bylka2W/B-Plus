const std = @import("std");

pub const SessionContext = struct {
    allocator: std.mem.Allocator,
    global: *GlobalContext,
    file_id: u32,
    diagnostics: std.ArrayList(DiagnosticInfo),

    const GlobalContext = @import("GlobalContext.zig").GlobalContext;

    pub const DiagnosticInfo = struct {
        message: []const u8,
        file_id: u32,
        start: u32,
        end: u32,
        severity: Severity,
    };

    pub const Severity = enum { note, warning, @"error", fatal };

    pub fn init(allocator: std.mem.Allocator, global: *GlobalContext, file_id: u32) SessionContext {
        return .{
            .allocator = allocator,
            .global = global,
            .file_id = file_id,
            .diagnostics = std.ArrayList(DiagnosticInfo).init(allocator),
        };
    }

    pub fn deinit(self: *SessionContext) void {
        self.diagnostics.deinit();
    }

    pub fn reportError(self: *SessionContext, msg: []const u8, start: u32, end: u32) void {
        self.diagnostics.append(.{
            .message = msg,
            .file_id = self.file_id,
            .start = start,
            .end = end,
            .severity = .@"error",
        }) catch {};
    }

    pub fn reportWarning(self: *SessionContext, msg: []const u8, start: u32, end: u32) void {
        self.diagnostics.append(.{
            .message = msg,
            .file_id = self.file_id,
            .start = start,
            .end = end,
            .severity = .warning,
        }) catch {};
    }

    pub fn hasErrors(self: *const SessionContext) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .@"error" or d.severity == .fatal) return true;
        }
        return false;
    }

    pub fn errorCount(self: *const SessionContext) u32 {
        var count: u32 = 0;
        for (self.diagnostics.items) |d| {
            if (d.severity == .@"error" or d.severity == .fatal) count += 1;
        }
        return count;
    }
};
