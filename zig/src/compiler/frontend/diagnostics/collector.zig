// Structured diagnostic collection (Stage 3).
//
// Goal: the compiler emits machine-readable diagnostics with stable codes and
// real ranges, so no IDE ever has to scrape stderr.
//
// The existing semantic pass predates this module and still logs through
// std.log.err; `report()` keeps that human output *and* mirrors the message
// into the active collector. When every call site is converted, `report` is the
// only funnel and the human path can be dropped.
const std = @import("std");
const diag_core = @import("core/diagnostic.zig");
const severity = @import("core/severity.zig");
const span_mod = @import("../source/location/span.zig");
const line_table = @import("../source/location/line_table.zig");

pub const Severity = severity.Severity;
pub const Diagnostic = diag_core.Diagnostic;
pub const Label = diag_core.Label;
pub const Note = diag_core.Note;
pub const SourceSpan = span_mod.SourceSpan;
pub const Position = span_mod.Position;
pub const LineTable = line_table.LineTable;

/// Stable diagnostic identifiers. Numbers are part of the public contract:
/// never renumber an existing entry, only append.
pub const Code = enum(u32) {
    parse_error = 1,
    backend_error = 2,
    safety_error = 3,
    internal_error = 4,

    undefined_variable = 4001,
    undefined_function = 4002,
    undefined_state = 4003,
    undefined_type = 4004,
    invalid_enum_value = 4005,
    invalid_struct_field = 4006,
    arity_mismatch = 4007,
    arg_type_mismatch = 4008,
    type_mismatch = 4009,
    binary_type_mismatch = 4010,
    import_not_found = 4011,
    duplicate_definition = 4012,
    break_outside_loop = 4013,
    continue_outside_loop = 4014,
    return_type_mismatch = 4015,
    negative_array_index = 4016,

    pub fn number(self: Code) u32 {
        return @intFromEnum(self);
    }

    /// Stable string form, e.g. `B+E4001`. Safe to key on in tests and CI.
    pub fn id(self: Code) []const u8 {
        return switch (self) {
            .parse_error => "B+E0001",
            .backend_error => "B+E0002",
            .safety_error => "B+E0003",
            .internal_error => "B+E0004",
            .undefined_variable => "B+E4001",
            .undefined_function => "B+E4002",
            .undefined_state => "B+E4003",
            .undefined_type => "B+E4004",
            .invalid_enum_value => "B+E4005",
            .invalid_struct_field => "B+E4006",
            .arity_mismatch => "B+E4007",
            .arg_type_mismatch => "B+E4008",
            .type_mismatch => "B+E4009",
            .binary_type_mismatch => "B+E4010",
            .import_not_found => "B+E4011",
            .duplicate_definition => "B+E4012",
            .break_outside_loop => "B+E4013",
            .continue_outside_loop => "B+E4014",
            .return_type_mismatch => "B+E4015",
            .negative_array_index => "B+E4016",
        };
    }
};

pub const Collector = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic),
    /// Source text of the file currently being compiled, used to turn a byte
    /// offset into a 1-based line/column range.
    file_path: []const u8 = "",
    source: []const u8 = "",
    table: LineTable,
    file_id: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Collector {
        return .{
            .allocator = allocator,
            .items = std.ArrayList(Diagnostic).init(allocator),
            .table = LineTable.init(allocator),
        };
    }

    pub fn deinit(self: *Collector) void {
        for (self.items.items) |*d| d.deinit();
        self.items.deinit();
        self.table.deinit();
    }

    pub fn setSource(self: *Collector, file_path: []const u8, source: []const u8, file_id: u32) void {
        self.file_path = file_path;
        self.source = source;
        self.file_id = file_id;
        self.table.compute(source);
    }

    /// Resolves a byte offset to a 1-based line/column. Falls back to 1:1 when
    /// the offset is out of range so a diagnostic is never dropped.
    pub fn positionAt(self: *const Collector, offset: u32) Position {
        if (self.source.len == 0) return .{ .line = 1, .col = 1 };
        const clamped = @min(offset, @as(u32, @intCast(self.source.len)));
        return self.table.spanToLineCol(SourceSpan{ .file_id = self.file_id, .start = clamped, .end = clamped });
    }

    /// Finds `needle` in the source and returns the span covering it.
    /// Returns null when the needle is absent, which happens for generated or
    /// whitespace-only names; callers then fall back to a whole-line span.
    pub fn spanOf(self: *const Collector, needle: []const u8) ?SourceSpan {
        if (needle.len == 0 or self.source.len == 0) return null;
        const at = std.mem.indexOf(u8, self.source, needle) orelse return null;
        const start: u32 = @intCast(at);
        return SourceSpan{
            .file_id = self.file_id,
            .start = start,
            .end = start + @as(u32, @intCast(needle.len)),
        };
    }

    /// Fallback span: the whole line containing `line`.
    pub fn spanOfLine(self: *const Collector, line: u32) SourceSpan {
        const start = self.table.lineStart(line);
        const end = @min(self.table.lineEnd(line, @intCast(self.source.len)), start);
        return SourceSpan{ .file_id = self.file_id, .start = start, .end = end };
    }

    pub fn add(
        self: *Collector,
        code: Code,
        sev: Severity,
        message: []const u8,
        span: ?SourceSpan,
    ) void {
        var d = Diagnostic.init(self.allocator, sev, self.allocator.dupe(u8, message) catch return);
        d.code = code.number();
        if (span) |s| {
            d.labels.append(Label.primary(s, "")) catch {};
        }
        self.items.append(d) catch {};
    }

    pub fn hasErrors(self: *const Collector) bool {
        for (self.items.items) |d| {
            if (d.severity.isError()) return true;
        }
        return false;
    }
};

/// The collector every compiler stage reports into for the current run.
/// null outside `bpc diagnose`, which is why reporting is optional.
pub var active: ?*Collector = null;

/// Mirrors a semantic-pass message into `active`, and keeps writing it to
/// stderr so existing CLI behaviour and users' scripts do not change.
///
/// `needle` is the source text the message is about; it is used to point the
/// diagnostic at a real range instead of a guessed line number.
pub fn report(
    code: Code,
    file_path: []const u8,
    needle: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    _ = file_path;
    std.log.err(fmt, args);
    const collector = active orelse return;
    const msg = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
    const span = collector.spanOf(needle) orelse SourceSpan{
        .file_id = collector.file_id,
        .start = 0,
        .end = 0,
    };
    collector.add(code, .@"error", msg, span);
}

/// Anonymous-struct form used by the (minified) semantic pass, which cannot
/// afford long argument lists at 20 call sites.
pub fn reportFields(a: anytype) void {
    std.log.err(a.fmt, a.rest);
    const collector = active orelse return;
    const msg = std.fmt.allocPrint(std.heap.page_allocator, a.fmt, a.rest) catch return;
    const span = collector.spanOf(a.needle) orelse SourceSpan{
        .file_id = collector.file_id,
        .start = 0,
        .end = 0,
    };
    collector.add(a.code, .@"error", msg, span);
}

/// Reports a failure that has no source location (backend, linker, internal).
pub fn reportGlobal(code: Code, message: []const u8) void {
    std.log.err("{s}", .{message});
    const collector = active orelse return;
    collector.add(code, .@"error", message, null);
}

test "code ids are stable and unique" {
    var seen = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer seen.deinit();
    inline for (@typeInfo(Code).@"enum".fields) |f| {
        const c: Code = @enumFromInt(f.value);
        try std.testing.expect(!seen.contains(c.number()));
        try seen.put(c.number(), {});
        try std.testing.expect(std.mem.startsWith(u8, c.id(), "B+E"));
    }
}

test "spanOf finds a needle and reports 1-based positions" {
    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    const src = "fn main()\n{\n    print(unknown_variable)\n}\n";
    c.setSource("t.b+", src, 0);

    const span = c.spanOf("unknown_variable").?;
    try std.testing.expectEqual(@as(u32, 18), span.start);
    try std.testing.expectEqual(@as(u32, 34), span.end);

    const p = c.positionAt(span.start);
    try std.testing.expectEqual(@as(u32, 3), p.line);
    try std.testing.expectEqual(@as(u32, 12), p.col);
}

test "spanOf returns null for absent needle instead of guessing" {
    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    c.setSource("t.b+", "fn main() {}\n", 0);
    try std.testing.expect(c.spanOf("nope") == null);
}