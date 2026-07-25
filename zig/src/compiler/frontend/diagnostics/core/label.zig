const span = @import("../../source/location/span.zig");

pub const SourceSpan = span.SourceSpan;

pub const Label = struct {
    span: ?SourceSpan,
    message: []const u8,
    style: Style,

    pub const Style = enum {
        primary,
        secondary,
        help,
        note,
    };

    pub fn primary(span_: SourceSpan, msg: []const u8) Label {
        return .{ .span = span_, .message = msg, .style = .primary };
    }

    pub fn secondary(span_: SourceSpan, msg: []const u8) Label {
        return .{ .span = span_, .message = msg, .style = .secondary };
    }

    pub fn help(span_: ?SourceSpan, msg: []const u8) Label {
        return .{ .span = span_, .message = msg, .style = .help };
    }

    pub fn note(span_: ?SourceSpan, msg: []const u8) Label {
        return .{ .span = span_, .message = msg, .style = .note };
    }
};
