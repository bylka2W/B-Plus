const span = @import("../../source/location/span.zig");

pub const SourceSpan = span.SourceSpan;

pub const Note = struct {
    message: []const u8,
    span: ?SourceSpan,
    labels: ?[]const Label = null,

    const Label = @import("label.zig").Label;

    pub fn simple(msg: []const u8) Note {
        return .{ .message = msg, .span = null };
    }

    pub fn withSpan(msg: []const u8, s: SourceSpan) Note {
        return .{ .message = msg, .span = s };
    }
};
