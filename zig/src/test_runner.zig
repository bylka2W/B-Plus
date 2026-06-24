const std = @import("std");
const parser = @import("parser.zig");
const x64gen = @import("x64gen.zig");
const pe = @import("pe.zig");

// --- v1: per-case return expectations ---
pub const Expect = union(enum) {
    null_val: void,
    int_val: i64,
    float_val: f32,
};

pub const CaseDesc = struct {
    name: []const u8,
    calls: [][]const u8,
    expect: Expect,
};

pub const BuildType = enum { dll };
pub const ResetMode = enum { per_case, per_test };

// --- v2: Frame Snapshot Engine ---

const FieldType = enum(u32) {
    INT = 0,
    FLOAT = 1,
    IMAGE_F32 = 2,
};

const ImageHeader = extern struct {
    stride: u32,
    width: u32,
    height: u32,
    _pad: u32,
};

const StateView = struct {
    base: [*]u8,

    fn getInt(self: StateView, offset: usize) i32 {
        return @as(*align(1) i32, @ptrCast(self.base + offset)).*;
    }
    fn getFloat(self: StateView, offset: usize) f32 {
        return @as(*align(1) f32, @ptrCast(self.base + offset)).*;
    }
    fn getPtr(self: StateView, offset: usize) usize {
        return @as(*align(1) usize, @ptrCast(self.base + offset)).*;
    }
};

const ImageView = struct {
    data: [*]f32,
    stride: u32,
    width: u32,
    height: u32,

    fn get(self: ImageView, x: u32, y: u32) f32 {
        return self.data[y * self.stride + x];
    }
};

const FieldEntry = struct {
    name: []const u8,
    type: FieldType,
    offset: u32,
};

const SnapshotValue = union(enum) {
    int: i64,
    float: f64,
    image: ImageView,
};

const Snapshot = struct {
    fields: std.StringHashMap(SnapshotValue),
};

pub const ExpectEntry = union(enum) {
    state_int: struct { name: []const u8, value: i64 },
    state_float: struct { name: []const u8, value: f64 },
    image_pixel: struct { name: []const u8, x: u32, y: u32, value: f32 },
    image_approx: struct { name: []const u8, x: u32, y: u32, value: f32, eps: f32 },
};

pub const FrameDesc = struct {
    index: u32,
    calls: [][]const u8,
    expects: []ExpectEntry,
};

pub const TestDesc = struct {
    name: []const u8,
    source: []const u8,
    build_type: BuildType,
    reset_mode: ResetMode,
    exports: [][]const u8,
    cases: []CaseDesc,
    frames: []FrameDesc,
};

pub const CaseStatus = enum { pass, fail, @"error" };
pub const TestStatus = enum { pass, fail, @"error" };

pub const CaseResult = struct {
    name: []const u8,
    calls: [][]const u8,
    status: CaseStatus,
    expected: []const u8,
    actual: []const u8,
};

pub const ExpectResult = struct {
    desc: []const u8,
    status: CaseStatus,
    expected: []const u8,
    actual: []const u8,
};

pub const FrameResult = struct {
    index: u32,
    calls: [][]const u8,
    expects: []ExpectResult,
};

pub const TestResult = struct {
    name: []const u8,
    status: TestStatus,
    compile_ok: bool,
    load_ok: bool,
    cases: []CaseResult,
    frames: []FrameResult,
};

const win = std.os.windows;
const kernel32 = win.kernel32;

fn toUtf16(allocator: std.mem.Allocator, str: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, str);
}

const DynLib = struct {
    handle: win.HMODULE,

    fn open(path: []const u8) !DynLib {
        const path16 = try toUtf16(std.heap.page_allocator, path);
        defer std.heap.page_allocator.free(path16);
        const handle = kernel32.LoadLibraryW(path16.ptr) orelse return error.LoadLibraryFailed;
        return DynLib{ .handle = handle };
    }

    fn lookup(self: DynLib, name: []const u8) !?*const fn () callconv(.C) i64 {
        const name_z = try std.fmt.allocPrintZ(std.heap.page_allocator, "{s}", .{name});
        defer std.heap.page_allocator.free(name_z);
        const proc = kernel32.GetProcAddress(self.handle, name_z.ptr) orelse return null;
        return @as(*const fn () callconv(.C) i64, @ptrCast(proc));
    }

    fn close(self: DynLib) void {
        _ = kernel32.FreeLibrary(self.handle);
    }
};

// --- Parser helpers (reused from v1) ---

fn countIndent(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
    return n;
}

fn skipSpaces(src: []const u8, pos: *usize) void {
    while (pos.* < src.len and (src[pos.*] == ' ' or src[pos.*] == '\t')) pos.* += 1;
}

fn expectChar(src: []const u8, pos: *usize, c: u8) bool {
    skipSpaces(src, pos);
    if (pos.* < src.len and src[pos.*] == c) {
        pos.* += 1;
        return true;
    }
    return false;
}

fn parseQuotedString(src: []const u8, pos: *usize) ![]const u8 {
    skipSpaces(src, pos);
    if (pos.* >= src.len or src[pos.*] != '"') return error.ExpectedQuotedString;
    pos.* += 1;
    const start = pos.*;
    while (pos.* < src.len and src[pos.*] != '"') pos.* += 1;
    if (pos.* >= src.len) return error.UnterminatedString;
    const result = src[start..pos.*];
    pos.* += 1;
    return result;
}

fn parseIdentifier(src: []const u8, pos: *usize) []const u8 {
    skipSpaces(src, pos);
    const start = pos.*;
    while (pos.* < src.len and (std.ascii.isAlphanumeric(src[pos.*]) or src[pos.*] == '_' or src[pos.*] == '<' or src[pos.*] == '>')) pos.* += 1;
    return src[start..pos.*];
}

fn parseCommaList(allocator: std.mem.Allocator, src: []const u8, pos: *usize) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(allocator);
    while (true) {
        skipSpaces(src, pos);
        const start = pos.*;
        while (pos.* < src.len and (std.ascii.isAlphanumeric(src[pos.*]) or src[pos.*] == '_')) pos.* += 1;
        if (pos.* > start) {
            try list.append(src[start..pos.*]);
        }
        skipSpaces(src, pos);
        if (pos.* >= src.len or src[pos.*] != ',') break;
        pos.* += 1;
    }
    return list.toOwnedSlice();
}

fn parseIntValue(src: []const u8, pos: *usize) !i64 {
    skipSpaces(src, pos);
    const sign: i64 = if (pos.* < src.len and src[pos.*] == '-') blk: {
        pos.* += 1;
        break :blk -1;
    } else 1;
    const start = pos.*;
    if (pos.* >= src.len or !std.ascii.isDigit(src[pos.*])) return error.ExpectedInt;
    while (pos.* < src.len and std.ascii.isDigit(src[pos.*])) pos.* += 1;
    const val = try std.fmt.parseInt(u64, src[start..pos.*], 10);
    return @as(i64, @intCast(val)) * sign;
}

fn parseFloatValue(src: []const u8, pos: *usize) !f64 {
    skipSpaces(src, pos);
    const start = pos.*;
    while (pos.* < src.len) {
        const c = src[pos.*];
        if (std.ascii.isDigit(c) or c == '.' or c == '-' or c == '+' or c == 'e' or c == 'E') {
            pos.* += 1;
        } else break;
    }
    if (pos.* == start) return error.ExpectedFloat;
    return try std.fmt.parseFloat(f64, src[start..pos.*]);
}

fn parseExpect(src: []const u8, pos: *usize) !Expect {
    const kw = parseIdentifier(src, pos);
    if (std.mem.eql(u8, kw, "null")) {
        return Expect{ .null_val = {} };
    }
    if (std.mem.eql(u8, kw, "return")) {
        skipSpaces(src, pos);
        if (pos.* < src.len) {
            const c = src[pos.*];
            if (std.ascii.isDigit(c) or c == '-') {
                const val = try parseIntValue(src, pos);
                return Expect{ .int_val = val };
            }
        }
        const ty = parseIdentifier(src, pos);
        if (std.mem.eql(u8, ty, "float")) {
            const val = try parseFloatValue(src, pos);
            return Expect{ .float_val = @as(f32, @floatCast(val)) };
        }
        return error.UnknownExpectType;
    }
    return error.UnknownExpectKeyword;
}

// --- v2: Frame expect parser ---

fn parseFrameExpect(src: []const u8, pos: *usize) !ExpectEntry {
    const kw = parseIdentifier(src, pos);
    if (std.mem.eql(u8, kw, "state")) {
        if (!expectChar(src, pos, '.')) return error.ExpectedDotAfterState;
        const field_name = parseIdentifier(src, pos);
        if (!expectChar(src, pos, '=')) return error.ExpectedEqInStateExpect;
        if (expectChar(src, pos, '=')) {} // allow ==
        // Determine if value is int or float by looking ahead for '.'
        const val_pos = pos.*;
        skipSpaces(src, pos);
        var is_float = false;
        const scan = pos.*;
        var si = scan;
        if (si < src.len and src[si] == '-') si += 1;
        while (si < src.len and std.ascii.isDigit(src[si])) si += 1;
        if (si < src.len and src[si] == '.') is_float = true;
        pos.* = val_pos;
        if (is_float) {
            const val = try parseFloatValue(src, pos);
            return ExpectEntry{ .state_float = .{ .name = field_name, .value = val } };
        } else {
            const val = try parseIntValue(src, pos);
            return ExpectEntry{ .state_int = .{ .name = field_name, .value = val } };
        }
    } else if (std.mem.eql(u8, kw, "image")) {
        if (!expectChar(src, pos, '[')) return error.ExpectedOpenBracketAfterImage;
        const img_name = try parseQuotedString(src, pos);
        if (!expectChar(src, pos, ']')) return error.ExpectedCloseBracket;
        if (!expectChar(src, pos, '[')) return error.ExpectedOpenBracket;
        const x_str = parseIdentifier(src, pos);
        if (!expectChar(src, pos, ',')) return error.ExpectedComma;
        const y_str = parseIdentifier(src, pos);
        if (!expectChar(src, pos, ']')) return error.ExpectedCloseBracket;
        const x = try std.fmt.parseInt(u32, x_str, 10);
        const y = try std.fmt.parseInt(u32, y_str, 10);
        // Check for == or ≈
        skipSpaces(src, pos);
        if (pos.* < src.len and src[pos.*] == '=') {
            pos.* += 1;
            if (pos.* < src.len and src[pos.*] == '=') pos.* += 1;
            const val = @as(f32, @floatCast(try parseFloatValue(src, pos)));
            return ExpectEntry{ .image_pixel = .{ .name = img_name, .x = x, .y = y, .value = val } };
        } else if (pos.* < src.len and src[pos.*] == 0x2248) { // ≈
            pos.* += 1;
            const val = @as(f32, @floatCast(try parseFloatValue(src, pos)));
            const eps: f32 = 0.0001;
            return ExpectEntry{ .image_approx = .{ .name = img_name, .x = x, .y = y, .value = val, .eps = eps } };
        } else {
            return error.ExpectedEqOrApprox;
        }
    } else {
        return error.UnknownFrameExpectKeyword;
    }
}

fn parseU32Value(src: []const u8, pos: *usize) !u32 {
    skipSpaces(src, pos);
    const start = pos.*;
    while (pos.* < src.len and std.ascii.isDigit(src[pos.*])) pos.* += 1;
    if (pos.* == start) return error.ExpectedInt;
    return try std.fmt.parseInt(u32, src[start..pos.*], 10);
}

fn parseFrameDecl(src: []const u8, pos: *usize) !u32 {
    const kw = parseIdentifier(src, pos);
    if (!std.mem.eql(u8, kw, "frame")) return error.ExpectedFrameKeyword;
    const idx = try parseU32Value(src, pos);
    if (!expectChar(src, pos, ':')) return error.ExpectedColonAfterFrame;
    return idx;
}

// --- Main parser ---

pub fn parseTestDesc(allocator: std.mem.Allocator, text: []const u8) !TestDesc {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var test_name: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var build_type_str: ?[]const u8 = null;
    var reset_str: ?[]const u8 = null;
    var export_list: ?[][]const u8 = null;
    var cases = std.ArrayList(CaseDesc).init(allocator);
    var frames = std.ArrayList(FrameDesc).init(allocator);
    var parse_frames = false;

    var case_name: ?[]const u8 = null;
    var case_calls = std.ArrayList([]const u8).init(allocator);
    var case_expect: ?Expect = null;

    var frame_idx: ?u32 = null;
    var frame_calls = std.ArrayList([]const u8).init(allocator);
    var frame_expects = std.ArrayList(ExpectEntry).init(allocator);

    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const indent = countIndent(line);
        const content = std.mem.trimLeft(u8, line, " \t");

        if (indent == 0) {
            // Flush pending case/frame
            if (case_name) |cn| {
                try cases.append(CaseDesc{
                    .name = cn,
                    .calls = try case_calls.toOwnedSlice(),
                    .expect = case_expect orelse Expect{ .null_val = {} },
                });
                case_calls = std.ArrayList([]const u8).init(allocator);
            }
            case_name = null;
            case_expect = null;
            if (frame_idx) |fi| {
                try frames.append(FrameDesc{
                    .index = fi,
                    .calls = try frame_calls.toOwnedSlice(),
                    .expects = try frame_expects.toOwnedSlice(),
                });
                frame_calls = std.ArrayList([]const u8).init(allocator);
                frame_expects = std.ArrayList(ExpectEntry).init(allocator);
            }
            frame_idx = null;

            var pos: usize = 0;
            const kw = parseIdentifier(content, &pos);
            if (!std.mem.eql(u8, kw, "test")) return error.ExpectedTestKeyword;
            test_name = try parseQuotedString(content, &pos);
            if (!expectChar(content, &pos, ':')) return error.ExpectedColonAfterTest;
        } else if (indent == 4) {
            // Check for frame keyword
            var pos: usize = 0;
            const kw = parseIdentifier(content, &pos);
            if (std.mem.eql(u8, kw, "frame")) {
                parse_frames = true;
                // Flush pending case
                if (case_name) |cn| {
                    try cases.append(CaseDesc{
                        .name = cn,
                        .calls = try case_calls.toOwnedSlice(),
                        .expect = case_expect orelse Expect{ .null_val = {} },
                    });
                    case_calls = std.ArrayList([]const u8).init(allocator);
                }
                case_name = null;
                case_expect = null;
                // Flush pending frame
                if (frame_idx) |fi| {
                    try frames.append(FrameDesc{
                        .index = fi,
                        .calls = try frame_calls.toOwnedSlice(),
                        .expects = try frame_expects.toOwnedSlice(),
                    });
                    frame_calls = std.ArrayList([]const u8).init(allocator);
                    frame_expects = std.ArrayList(ExpectEntry).init(allocator);
                }
                frame_idx = null;

                pos = 0;
                frame_idx = try parseFrameDecl(content, &pos);
            } else if (std.mem.eql(u8, kw, "source")) {
                source = try parseQuotedString(content, &pos);
            } else if (std.mem.eql(u8, kw, "build")) {
                build_type_str = parseIdentifier(content, &pos);
            } else if (std.mem.eql(u8, kw, "reset")) {
                reset_str = parseIdentifier(content, &pos);
            } else if (std.mem.eql(u8, kw, "exports")) {
                export_list = try parseCommaList(allocator, content, &pos);
            } else if (std.mem.eql(u8, kw, "case")) {
                if (case_name) |cn| {
                    try cases.append(CaseDesc{
                        .name = cn,
                        .calls = try case_calls.toOwnedSlice(),
                        .expect = case_expect orelse Expect{ .null_val = {} },
                    });
                    case_calls = std.ArrayList([]const u8).init(allocator);
                }
                case_name = null;
                case_expect = null;

                case_name = try parseQuotedString(content, &pos);
                if (!expectChar(content, &pos, ':')) return error.ExpectedColonAfterCase;
            } else {
                return error.UnknownTestKeyword;
            }
        } else if (indent == 8) {
            var pos: usize = 0;
            const kw = parseIdentifier(content, &pos);
            if (std.mem.eql(u8, kw, "call")) {
                const name = parseIdentifier(content, &pos);
                if (name.len > 0) {
                    if (frame_idx != null) {
                        try frame_calls.append(name);
                    } else {
                        try case_calls.append(name);
                    }
                }
            } else if (std.mem.eql(u8, kw, "expect")) {
                if (frame_idx != null) {
                    const ee = try parseFrameExpect(content, &pos);
                    try frame_expects.append(ee);
                } else {
                    case_expect = try parseExpect(content, &pos);
                }
            }
        } else {
            return error.UnexpectedIndent;
        }
    }

    // Flush final case/frame
    if (case_name) |cn| {
        try cases.append(CaseDesc{
            .name = cn,
            .calls = try case_calls.toOwnedSlice(),
            .expect = case_expect orelse Expect{ .null_val = {} },
        });
    } else {
        case_calls.deinit();
    }
    if (frame_idx) |fi| {
        try frames.append(FrameDesc{
            .index = fi,
            .calls = try frame_calls.toOwnedSlice(),
            .expects = try frame_expects.toOwnedSlice(),
        });
    } else {
        frame_calls.deinit();
        frame_expects.deinit();
    }

    const bt: BuildType = if (build_type_str) |b| blk: {
        if (std.mem.eql(u8, b, "dll")) break :blk .dll;
        return error.UnsupportedBuildType;
    } else .dll;
    const rm: ResetMode = if (std.mem.eql(u8, reset_str orelse "per_case", "per_case")) .per_case else .per_test;

    return TestDesc{
        .name = test_name orelse return error.MissingTestName,
        .source = source orelse return error.MissingSource,
        .build_type = bt,
        .reset_mode = rm,
        .exports = export_list orelse return error.MissingExports,
        .cases = try cases.toOwnedSlice(),
        .frames = try frames.toOwnedSlice(),
    };
}

// --- Compilation ---

fn compileDll(allocator: std.mem.Allocator, source_path: []const u8, dll_path: []const u8) !void {
    return compileDllEx(allocator, source_path, dll_path, .off);
}

fn compileDllEx(allocator: std.mem.Allocator, source_path: []const u8, dll_path: []const u8, trace_mode: x64gen.TraceMode) !void {
    var src = try std.fs.cwd().readFileAlloc(allocator, source_path, std.math.maxInt(u32));
    defer allocator.free(src);

    if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) {
        const stripped = try allocator.dupe(u8, src[3..]);
        allocator.free(src);
        src = stripped;
    }

    var p = parser.Parser.init(allocator, src);
    var program = try p.parse();
    defer program.deinit();

    var output = try x64gen.generateEx(allocator, program, true, trace_mode);
    defer allocator.free(output.code);
    defer output.symbols.deinit();

    var resolved = std.ArrayList(pe.ResolvedExport).init(allocator);
    defer resolved.deinit();
    for (output.symbols.symbols.items) |s| {
        if (s.kind == .exp) {
            try resolved.append(.{
                .name = s.name,
                .rva = if (s.forward_to == null) pe.section_rva + s.rva else 0,
                .forward_to = s.forward_to,
            });
        }
    }

    const pe_bytes = try pe.writeDll(allocator, output.code, output.import_dir_rva, output.idat_size, resolved.items);
    defer allocator.free(pe_bytes);

    try std.fs.cwd().writeFile(.{ .sub_path = dll_path, .data = pe_bytes });
}

// --- v1: per-case return expectation helpers ---

fn formatExpect(e: Expect, allocator: std.mem.Allocator) ![]const u8 {
    return switch (e) {
        .null_val => try allocator.dupe(u8, "null"),
        .int_val => |v| try std.fmt.allocPrint(allocator, "{}", .{v}),
        .float_val => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
    };
}

fn formatActual(val: i64, expect: Expect, allocator: std.mem.Allocator) ![]const u8 {
    return switch (expect) {
        .null_val => try allocator.dupe(u8, "<non-null>"),
        .int_val => try std.fmt.allocPrint(allocator, "{}", .{val}),
        .float_val => blk: {
            const f = @as(f32, @bitCast(@as(u32, @truncate(@as(u64, @intCast(val))))));
            break :blk try std.fmt.allocPrint(allocator, "{d}", .{f});
        },
    };
}

fn matchesExpect(val: i64, expect: Expect) bool {
    return switch (expect) {
        .null_val => false,
        .int_val => |ev| val == ev,
        .float_val => |ev| blk: {
            const f = @as(f32, @bitCast(@as(u32, @truncate(@as(u64, @intCast(val))))));
            break :blk f == ev;
        },
    };
}

// --- v2: Snapshot capture ---

const FIELD_RECORD_SIZE = 48;

fn readFieldTable(base: [*]u8, allocator: std.mem.Allocator) ![]FieldEntry {
    var list = std.ArrayList(FieldEntry).init(allocator);
    var i: usize = 0;
    while (true) {
        const off = i * FIELD_RECORD_SIZE;
        const name_ptr: [*]u8 = base + off;
        var name_len: usize = 0;
        while (name_len < 32 and name_ptr[name_len] != 0) name_len += 1;
        if (name_len == 0) break;
        const name = try allocator.dupe(u8, name_ptr[0..name_len]);
        const type_tag = @as(*align(1) u32, @ptrCast(base + off + 32)).*;
        const layout_off = @as(*align(1) u64, @ptrCast(base + off + 40)).*;
        try list.append(FieldEntry{
            .name = name,
            .type = @as(FieldType, @enumFromInt(type_tag)),
            .offset = @as(u32, @intCast(layout_off)),
        });
        i += 1;
    }
    return list.toOwnedSlice();
}

fn captureState(state_base: [*]u8, fields: []const FieldEntry, allocator: std.mem.Allocator) !Snapshot {
    var map = std.StringHashMap(SnapshotValue).init(allocator);
    const sv = StateView{ .base = state_base };
    for (fields) |f| {
        const val: SnapshotValue = switch (f.type) {
            .INT => .{ .int = sv.getInt(f.offset) },
            .FLOAT => .{ .float = sv.getFloat(f.offset) },
            .IMAGE_F32 => blk: {
                const ptr = sv.getPtr(f.offset);
                if (ptr == 0) {
                    break :blk .{ .image = ImageView{ .data = undefined, .stride = 0, .width = 0, .height = 0 } };
                }
                const hdr = @as(*align(1) ImageHeader, @ptrCast(@as(*anyopaque, @ptrFromInt(ptr))));
                const data: [*]f32 = @ptrCast(@as([*]align(4) u8, @ptrFromInt(ptr + 16)));
                break :blk .{ .image = ImageView{ .data = data, .stride = hdr.stride, .width = hdr.width, .height = hdr.height } };
            },
        };
        // Dup name so HashMap owns keys independently from fields[] lifetime
        const key = try allocator.dupe(u8, f.name);
        try map.put(key, val);
    }
    return Snapshot{ .fields = map };
}

fn formatSnapshotValue(val: SnapshotValue, allocator: std.mem.Allocator) ![]const u8 {
    return switch (val) {
        .int => |v| try std.fmt.allocPrint(allocator, "{}", .{v}),
        .float => |v| try std.fmt.allocPrint(allocator, "{d:.6}", .{v}),
        .image => |v| try std.fmt.allocPrint(allocator, "image<{}x{} stride={}>", .{ v.width, v.height, v.stride }),
    };
}

fn getSnapshotValue(snap: *const Snapshot, name: []const u8) ?SnapshotValue {
    return snap.fields.get(name);
}

// --- v2: Diff engine ---

fn diffExpect(expect: ExpectEntry, snap: *const Snapshot, allocator: std.mem.Allocator) !ExpectResult {
    const desc = switch (expect) {
        .state_int => |e| try std.fmt.allocPrint(allocator, "state.{s} == {}", .{ e.name, e.value }),
        .state_float => |e| try std.fmt.allocPrint(allocator, "state.{s} ≈ {d:.6}", .{ e.name, e.value }),
        .image_pixel => |e| try std.fmt.allocPrint(allocator, "image[\"{s}\"][{},{}] == {d}", .{ e.name, e.x, e.y, e.value }),
        .image_approx => |e| try std.fmt.allocPrint(allocator, "image[\"{s}\"][{},{}] ≈ {d}", .{ e.name, e.x, e.y, e.value }),
    };

    const matched: bool = switch (expect) {
        .state_int => |e| blk: {
            const actual = getSnapshotValue(snap, e.name);
            break :blk if (actual) |v| switch (v) {
                .int => |iv| iv == e.value,
                else => false,
            } else false;
        },
        .state_float => |e| blk: {
            const actual = getSnapshotValue(snap, e.name);
            break :blk if (actual) |v| switch (v) {
                .float => |fv| @abs(fv - e.value) < 0.000001,
                else => false,
            } else false;
        },
        .image_pixel => |e| blk: {
            const actual = getSnapshotValue(snap, e.name);
            break :blk if (actual) |v| switch (v) {
                .image => |img| img.get(e.x, e.y) == e.value,
                else => false,
            } else false;
        },
        .image_approx => |e| blk: {
            const actual = getSnapshotValue(snap, e.name);
            break :blk if (actual) |v| switch (v) {
                .image => |img| @abs(img.get(e.x, e.y) - e.value) <= e.eps,
                else => false,
            } else false;
        },
    };

    const expected_str = switch (expect) {
        .state_int => |e| try std.fmt.allocPrint(allocator, "== {}", .{e.value}),
        .state_float => |e| try std.fmt.allocPrint(allocator, "≈ {d:.6}", .{e.value}),
        .image_pixel => |e| try std.fmt.allocPrint(allocator, "== {d}", .{e.value}),
        .image_approx => |e| try std.fmt.allocPrint(allocator, "≈ {d}", .{e.value}),
    };

    const actual_str = if (!matched) blk: {
        const name = switch (expect) {
            .state_int => |e| e.name,
            .state_float => |e| e.name,
            .image_pixel => |e| e.name,
            .image_approx => |e| e.name,
        };
        const actual = getSnapshotValue(snap, name);
        if (actual) |v| {
            switch (v) {
                .int => |iv| break :blk try std.fmt.allocPrint(allocator, "{}", .{iv}),
                .float => |fv| break :blk try std.fmt.allocPrint(allocator, "{d:.6}", .{fv}),
                .image => |img| {
                    switch (expect) {
                        .image_pixel => |e| break :blk try std.fmt.allocPrint(allocator, "{d}", .{img.get(e.x, e.y)}),
                        .image_approx => |e| break :blk try std.fmt.allocPrint(allocator, "{d}", .{img.get(e.x, e.y)}),
                        else => break :blk try std.fmt.allocPrint(allocator, "image<{}x{} stride={}>", .{ img.width, img.height, img.stride }),
                    }
                },
            }
        } else break :blk try allocator.dupe(u8, "<missing>");
    } else try allocator.dupe(u8, "<ok>");

    return ExpectResult{
        .desc = desc,
        .status = if (matched) .pass else .fail,
        .expected = expected_str,
        .actual = actual_str,
    };
}

// --- v2: State diff engine ---

const StateDiff = struct {
    field: []const u8,
    before: SnapshotValue,
    after: SnapshotValue,
};

fn snapshotValueEql(a: SnapshotValue, b: SnapshotValue) bool {
    return switch (a) {
        .int => |av| switch (b) { .int => |bv| av == bv, else => false },
        .float => |av| switch (b) { .float => |bv| @abs(av - bv) < 0.000001, else => false },
        .image => |av| switch (b) { .image => |bv| @intFromPtr(av.data) == @intFromPtr(bv.data), else => false },
    };
}

fn diffSnapshots(before: *const Snapshot, after: *const Snapshot, allocator: std.mem.Allocator) ![]StateDiff {
    var list = std.ArrayList(StateDiff).init(allocator);
    // Fields in after that differ from before
    var it = after.fields.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const after_val = entry.value_ptr.*;
        const before_val = before.fields.get(name);
        if (before_val) |bv| {
            if (!snapshotValueEql(bv, after_val)) {
                try list.append(StateDiff{ .field = name, .before = bv, .after = after_val });
            }
        } else {
            // New field
            try list.append(StateDiff{ .field = name, .before = .{ .int = 0 }, .after = after_val });
        }
    }
    // Fields in before that disappeared from after
    var it2 = before.fields.iterator();
    while (it2.next()) |entry| {
        const name = entry.key_ptr.*;
        if (after.fields.get(name) == null) {
            try list.append(StateDiff{ .field = name, .before = entry.value_ptr.*, .after = .{ .int = 0 } });
        }
    }
    return list.toOwnedSlice();
}

fn formatDiffValue(val: SnapshotValue, allocator: std.mem.Allocator) ![]const u8 {
    return switch (val) {
        .int => |v| try std.fmt.allocPrint(allocator, "{}", .{v}),
        .float => |v| try std.fmt.allocPrint(allocator, "{d:.6}", .{v}),
        .image => |v| if (@intFromPtr(v.data) == 0) try allocator.dupe(u8, "<null>")
        else try std.fmt.allocPrint(allocator, "image<{}x{} stride={}>", .{ v.width, v.height, v.stride }),
    };
}

// --- v2: Timeline / Call Transition Model ---

const CallSnapshot = struct {
    frame_index: u32,
    call_index: u32,
    export_name: []const u8,
    after: Snapshot,
    diffs: []StateDiff,
};

fn freeCallSnapshot(cs: *CallSnapshot, allocator: std.mem.Allocator) void {
    // Free diffs array (field strings owned by snapshot, not freed here)
    allocator.free(cs.diffs);
    // Free snapshot keys and HashMap
    var it = cs.after.fields.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    cs.after.fields.deinit();
}

const CausalEdge = struct {
    frame_index: u32,
    export_name: []const u8,
    field: []const u8,
    before: SnapshotValue,
    after: SnapshotValue,
};

fn printFrameDiffs(diffs: []const StateDiff, writer: anytype, allocator: std.mem.Allocator) !void {
    for (diffs) |d| {
        const before_str = try formatDiffValue(d.before, allocator);
        defer allocator.free(before_str);
        const after_str = try formatDiffValue(d.after, allocator);
        defer allocator.free(after_str);
        try writer.print("    {s}: {s} → {s}\n", .{ d.field, before_str, after_str });
    }
}

fn printCausalGraph(edges: []const CausalEdge, writer: anytype, allocator: std.mem.Allocator) !void {
    try writer.print("\nCAUSAL GRAPH:\n", .{});
    var i: usize = 0;
    while (i < edges.len) {
        const exp = edges[i].export_name;
        try writer.print("  {s}\n", .{exp});
        while (i < edges.len and std.mem.eql(u8, edges[i].export_name, exp)) {
            const e = edges[i];
            const before_str = try formatDiffValue(e.before, allocator);
            defer allocator.free(before_str);
            const after_str = try formatDiffValue(e.after, allocator);
            defer allocator.free(after_str);
            if (e.frame_index > 0) {
                try writer.print("    {s}: {s} → {s}  (frame {})\n", .{ e.field, before_str, after_str, e.frame_index });
            } else {
                try writer.print("    {s}: {s} → {s}\n", .{ e.field, before_str, after_str });
            }
            i += 1;
        }
    }
}

fn runFrames(allocator: std.mem.Allocator, lib: *DynLib, frames: []const FrameDesc, writer: anytype) ![]FrameResult {
    var frame_results = std.ArrayList(FrameResult).init(allocator);
    var call_snapshots = std.ArrayList(CallSnapshot).init(allocator);
    var causal_edges = std.ArrayList(CausalEdge).init(allocator);

    // Look up introspection exports
    const get_state_fn = (try lib.lookup("bpc_get_state")) orelse return error.MissingBpcGetState;
    const enum_fields_fn = (try lib.lookup("bpc_enum_fields")) orelse return error.MissingBpcEnumFields;

    // Read field table once (it's constant after DLL load)
    const table_ptr_raw = enum_fields_fn();
    const table_ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(table_ptr_raw)));
    const fields = try readFieldTable(table_ptr, allocator);
    defer {
        for (fields) |f| allocator.free(f.name);
        allocator.free(fields);
    }

    // Capture initial state before any frames
    const initial_ptr_raw = get_state_fn();
    const initial_base: [*]u8 = @ptrFromInt(@as(usize, @intCast(initial_ptr_raw)));
    var prev_snap = try captureState(initial_base, fields, allocator);
    var own_prev = true; // we own prev_snap (it's the initial snapshot)

    for (frames) |frame| {
        try writer.print("  FRAME {}:\n", .{frame.index});

        var call_err = false;
        var expect_results = std.ArrayList(ExpectResult).init(allocator);
        var frame_ok = true;

        for (frame.calls, 0..) |call_name, call_i| {
            const func = (try lib.lookup(call_name)) orelse {
                try writer.print("    CALL {s}: ERROR (not found)\n", .{call_name});
                call_err = true;
                break;
            };

            _ = func();

            // Capture state after this call
            const state_ptr_raw = get_state_fn();
            const state_base: [*]u8 = @ptrFromInt(@as(usize, @intCast(state_ptr_raw)));
            var after_call = try captureState(state_base, fields, allocator);

            // Diffs attributed to THIS export
            const diffs = try diffSnapshots(&prev_snap, &after_call, allocator);

            // Store as atomic CallSnapshot
            try call_snapshots.append(CallSnapshot{
                .frame_index = frame.index,
                .call_index = @as(u32, @intCast(call_i)),
                .export_name = call_name,
                .after = after_call,
                .diffs = diffs,
            });

            // Print per-call timeline with its diffs
            try writer.print("    CALL {s}\n", .{call_name});
            if (diffs.len > 0) {
                try printFrameDiffs(diffs, writer, allocator);
            }

            // Advance: free prev_snap only if we own it (initial or orphaned)
            if (own_prev) {
                var it = prev_snap.fields.iterator();
                while (it.next()) |entry| allocator.free(entry.key_ptr.*);
                prev_snap.fields.deinit();
            }
            prev_snap = after_call; // now owned by call_snapshots (last entry)
            own_prev = false;
        }

        if (call_err) {
            try frame_results.append(FrameResult{
                .index = frame.index,
                .calls = frame.calls,
                .expects = try expect_results.toOwnedSlice(),
            });
            break;
        }

        // Diff expects against final frame state (prev_snap = last call's after)
        for (frame.expects) |exp| {
            const er = try diffExpect(exp, &prev_snap, allocator);
            try expect_results.append(er);
            if (er.status == .pass) {
                try writer.print("    expect {s}: PASS\n", .{er.desc});
            } else {
                try writer.print("    expect {s}: FAIL\n", .{er.desc});
                try writer.print("      expected: {s}\n", .{er.expected});
                try writer.print("      actual:   {s}\n", .{er.actual});
                frame_ok = false;
            }
        }
        if (frame_ok and frame.expects.len > 0) {
            try writer.print("    -> OK\n", .{});
        }

        try frame_results.append(FrameResult{
            .index = frame.index,
            .calls = frame.calls,
            .expects = try expect_results.toOwnedSlice(),
        });
    }

    // Build causal graph from CallSnapshot diffs
    for (call_snapshots.items) |cs| {
        for (cs.diffs) |diff| {
            try causal_edges.append(CausalEdge{
                .frame_index = cs.frame_index,
                .export_name = cs.export_name,
                .field = try allocator.dupe(u8, diff.field),
                .before = diff.before,
                .after = diff.after,
            });
        }
    }

    // Print causal graph after all frames
    if (causal_edges.items.len > 0) {
        try printCausalGraph(causal_edges.items, writer, allocator);
    }

    // Cleanup: free call_snapshots (diffs first, then snapshots)
    for (call_snapshots.items) |*cs| freeCallSnapshot(cs, allocator);
    call_snapshots.deinit();
    // Free causal edges
    for (causal_edges.items) |ce| allocator.free(ce.field);
    causal_edges.deinit();

    // Free prev_snap if we still own it (should only happen with 0 frames)
    if (own_prev) {
        var it = prev_snap.fields.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        prev_snap.fields.deinit();
    }

    return frame_results.toOwnedSlice();
}

// --- Main test entry point ---

pub fn runTest(allocator: std.mem.Allocator, source_full: []const u8, desc: TestDesc, writer: anytype) !TestResult {
    const dll_path = try std.fmt.allocPrint(allocator, "{s}.dll", .{source_full});
    defer allocator.free(dll_path);

    const has_frames = desc.frames.len > 0;

    // Step 1: compile
    try writer.print("  COMPILE: ", .{});
    const trace_mode: x64gen.TraceMode = if (has_frames) .full else .off;
    compileDllEx(allocator, source_full, dll_path, trace_mode) catch |err| {
        try writer.print("FAIL ({any})\n", .{err});
        return TestResult{ .name = desc.name, .status = .@"error", .compile_ok = false, .load_ok = false, .cases = &.{}, .frames = &.{} };
    };
    try writer.print("OK\n", .{});

    // Step 2: load
    try writer.print("  LOAD: ", .{});
    var lib = DynLib.open(dll_path) catch |err| {
        try writer.print("FAIL ({any})\n", .{err});
        return TestResult{ .name = desc.name, .status = .@"error", .compile_ok = true, .load_ok = false, .cases = &.{}, .frames = &.{} };
    };
    try writer.print("OK\n", .{});

    if (has_frames) {
        // --- v2: Frame-based test ---
        // Set up trace buffer if trace export exists
        var trace_buf: ?[]u8 = null;
        const trace_slot: ?*align(1) u64 = if (try lib.lookup("bpc_get_trace_buf_slot")) |get_slot| blk: {
            const addr = get_slot();
            try writer.print("    trace slot addr={any}\n", .{@as(u64, @bitCast(addr))});
            const ptr: usize = @as(usize, @intCast(addr));
            break :blk @ptrFromInt(ptr);
        } else blk: {
            try writer.print("    trace slot not found\n", .{});
            break :blk null;
        };

        {
            const get_state_fn = (try lib.lookup("bpc_get_state")) orelse return error.MissingGetState;
            const state_ptr_raw = get_state_fn();
            try writer.print("    state_ptr_raw={any}\n", .{@as(u64, @bitCast(state_ptr_raw))});
        }

        if (trace_slot) |slot| {
            const buf_size = 65536;
            const buf = try std.heap.page_allocator.alloc(u8, buf_size);
            @memset(buf, 0);
            trace_buf = buf;
            slot.* = @intFromPtr(buf.ptr);
            try writer.print("    trace buf ptr={any}\n", .{@intFromPtr(buf.ptr)});
        }

        // Print trace slot info (buffer is zeroed and ready for frame events)

        const frame_results = runFrames(allocator, &lib, desc.frames, writer) catch {
            if (trace_buf) |b| std.heap.page_allocator.free(b);
            lib.close();
            return TestResult{ .name = desc.name, .status = .@"error", .compile_ok = true, .load_ok = true, .cases = &.{}, .frames = &.{} };
        };

        // Print trace event count if tracing was active
        if (trace_buf) |buf| {
            if (trace_slot) |slot| {
                const bytes_written = slot.* - @intFromPtr(buf.ptr);
                const event_count = bytes_written / 16;
                if (event_count > 0) {
                    try writer.print("  TRACE: {} events ({} bytes)\n", .{ event_count, bytes_written });
                }
            }
            std.heap.page_allocator.free(buf);
        }

        lib.close();
        // Determine overall status from frame results
        var any_fail = false;
        for (frame_results) |fr| {
            for (fr.expects) |er| {
                if (er.status != .pass) any_fail = true;
            }
        }
        return TestResult{
            .name = desc.name,
            .status = if (any_fail) .fail else .pass,
            .compile_ok = true,
            .load_ok = true,
            .cases = &.{},
            .frames = frame_results,
        };
    } else {
        // --- v1: Case-based test ---
        var case_results = std.ArrayList(CaseResult).init(allocator);
        var any_fail = false;

        for (desc.cases) |case| {
            if (desc.reset_mode == .per_case) {
                lib.close();
                lib = DynLib.open(dll_path) catch |err| {
                    try writer.print("  CASE {s}: ERROR (reload: {any})\n", .{ case.name, err });
                    try case_results.append(CaseResult{
                        .name = case.name,
                        .calls = case.calls,
                        .status = .@"error",
                        .expected = "N/A",
                        .actual = try std.fmt.allocPrint(allocator, "reload failed: {any}", .{err}),
                    });
                    any_fail = true;
                    continue;
                };
            }

            var call_err = false;
            var return_val: i64 = 0;

            for (case.calls) |call_name| {
                const func = (try lib.lookup(call_name)) orelse {
                    try writer.print("  CASE {s}: ERROR (symbol {s} not found)\n", .{ case.name, call_name });
                    try case_results.append(CaseResult{
                        .name = case.name,
                        .calls = case.calls,
                        .status = .@"error",
                        .expected = try formatExpect(case.expect, allocator),
                        .actual = try std.fmt.allocPrint(allocator, "symbol {s} not found", .{call_name}),
                    });
                    call_err = true;
                    any_fail = true;
                    break;
                };
                return_val = func();
            }

            if (call_err) continue;

            const expected_str = try formatExpect(case.expect, allocator);
            const actual_str = try formatActual(return_val, case.expect, allocator);
            const matched = matchesExpect(return_val, case.expect);

            if (matched) {
                try writer.print("  CASE {s}: PASS\n", .{case.name});
            } else {
                try writer.print("  CASE {s}: FAIL\n", .{case.name});
                try writer.print("    expected: {s}\n", .{expected_str});
                try writer.print("    actual:   {s}\n", .{actual_str});
                any_fail = true;
            }

            try case_results.append(CaseResult{
                .name = case.name,
                .calls = case.calls,
                .status = if (matched) .pass else .fail,
                .expected = expected_str,
                .actual = actual_str,
            });
        }

        lib.close();

        return TestResult{
            .name = desc.name,
            .status = if (any_fail) .fail else .pass,
            .compile_ok = true,
            .load_ok = true,
            .cases = try case_results.toOwnedSlice(),
            .frames = &.{},
        };
    }
}
