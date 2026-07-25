const std = @import("std");
const sev = @import("severity.zig");
const label_mod = @import("label.zig");
const note_mod = @import("note.zig");

pub const Severity = sev.Severity;
pub const Label = label_mod.Label;
pub const Note = note_mod.Note;

pub const Diagnostic = struct {
    severity: Severity,
    message: []const u8,
    code: ?u32,
    labels: std.ArrayList(Label),
    notes: std.ArrayList(Note),
    fix: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, severity: Severity, message: []const u8) Diagnostic {
        return .{
            .severity = severity,
            .message = message,
            .code = null,
            .labels = std.ArrayList(Label).init(allocator),
            .notes = std.ArrayList(Note).init(allocator),
            .fix = null,
        };
    }

    pub fn deinit(self: *Diagnostic) void {
        self.labels.deinit();
        self.notes.deinit();
    }

    pub fn withCode(self: *Diagnostic, code: u32) *Diagnostic {
        self.code = code;
        return self;
    }

    pub fn withLabel(self: *Diagnostic, label: Label) *Diagnostic {
        self.labels.append(label) catch return self;
        return self;
    }

    pub fn withNote(self: *Diagnostic, note: Note) *Diagnostic {
        self.notes.append(note) catch return self;
        return self;
    }

    pub fn withFix(self: *Diagnostic, fix: []const u8) *Diagnostic {
        self.fix = fix;
        return self;
    }

    pub fn primaryLabel(self: *const Diagnostic) ?Label {
        for (self.labels.items) |l| {
            if (l.style == .primary) return l;
        }
        return null;
    }
};
