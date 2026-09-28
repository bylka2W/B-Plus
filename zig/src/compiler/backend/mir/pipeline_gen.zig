const std = @import("std");

pub const ResourceType = enum {
    input,
    transient,
    output,
    persistent,
};

pub const Resource = struct {
    name: []const u8,
    resource_type: ResourceType,
    format: []const u8,
    size_hint: []const u8,
};

pub const Pass = struct {
    name: []const u8,
    shader: []const u8,
    reads: [][]const u8,
    writes: [][]const u8,
    group_x: u32,
    group_y: u32,
    group_z: u32,
};

pub const Pipeline = struct {
    name: []const u8,
    resources: []Resource,
    passes: []Pass,
};

pub fn parsePipeline(allocator: std.mem.Allocator, source: []const u8) !Pipeline {
    var resources = std.ArrayList(Resource).init(allocator);
    var passes = std.ArrayList(Pass).init(allocator);

    var lines = std.ArrayList([]const u8).init(allocator);
    var line_iter = std.mem.tokenizeScalar(u8, source, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) continue;
        try lines.append(trimmed);
    }

    var i: usize = 0;
    var pipeline_name: ?[]const u8 = null;

    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i];

        if (std.mem.startsWith(u8, line, "pipeline ")) {
            const rest = std.mem.trim(u8, line["pipeline ".len..], " \t");
            if (std.mem.endsWith(u8, rest, "{")) {
                pipeline_name = std.mem.trim(u8, rest[0 .. rest.len - 1], " \t");
            } else {
                pipeline_name = rest;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "resource ")) {
            const rest = std.mem.trim(u8, line["resource ".len..], " \t");
            const name = std.mem.trimRight(u8, rest, " {");
            var res_type: ResourceType = .transient;
            var format: []const u8 = "rgba16f";
            var size_hint: []const u8 = "render";

            i += 1;
            while (i < lines.items.len and !std.mem.eql(u8, lines.items[i], "}")) {
                const prop_line = std.mem.trim(u8, lines.items[i], " \t");
                if (parseProp(prop_line, "type")) |val| {
                    res_type = std.meta.stringToEnum(ResourceType, val) orelse .transient;
                } else if (parseProp(prop_line, "format")) |val| {
                    format = val;
                } else if (parseProp(prop_line, "size")) |val| {
                    size_hint = val;
                }
                i += 1;
            }

            try resources.append(Resource{
                .name = try allocator.dupe(u8, name),
                .resource_type = res_type,
                .format = try allocator.dupe(u8, format),
                .size_hint = try allocator.dupe(u8, size_hint),
            });
            continue;
        }

        if (std.mem.startsWith(u8, line, "pass ")) {
            const rest = std.mem.trim(u8, line["pass ".len..], " \t");
            const pass_name = std.mem.trimRight(u8, rest, " {");

            var shader: ?[]const u8 = null;
            var reads = std.ArrayList([]const u8).init(allocator);
            var writes = std.ArrayList([]const u8).init(allocator);
            var gx: u32 = 8;
            var gy: u32 = 8;
            var gz: u32 = 1;

            i += 1;
            while (i < lines.items.len and !std.mem.eql(u8, lines.items[i], "}")) {
                const prop_line = std.mem.trim(u8, lines.items[i], " \t");
                if (std.mem.startsWith(u8, prop_line, "shader ")) {
                    shader = extractQuoted(prop_line["shader ".len..]);
                } else if (std.mem.startsWith(u8, prop_line, "read ")) {
                    const rest2 = std.mem.trim(u8, prop_line["read ".len..], " \t;");
                    var it2 = std.mem.tokenizeScalar(u8, rest2, ',');
                    while (it2.next()) |token| {
                        const t = std.mem.trim(u8, token, " \t\"");
                        if (t.len > 0) try reads.append(try allocator.dupe(u8, t));
                    }
                } else if (std.mem.startsWith(u8, prop_line, "write ")) {
                    const rest2 = std.mem.trim(u8, prop_line["write ".len..], " \t;");
                    var it2 = std.mem.tokenizeScalar(u8, rest2, ',');
                    while (it2.next()) |token| {
                        const t = std.mem.trim(u8, token, " \t\"");
                        if (t.len > 0) try writes.append(try allocator.dupe(u8, t));
                    }
                } else if (std.mem.startsWith(u8, prop_line, "dispatch(")) {
                    parseDispatch(prop_line, &gx, &gy, &gz);
                }
                i += 1;
            }

            try passes.append(Pass{
                .name = try allocator.dupe(u8, pass_name),
                .shader = try allocator.dupe(u8, shader orelse "unknown"),
                .reads = try reads.toOwnedSlice(),
                .writes = try writes.toOwnedSlice(),
                .group_x = gx,
                .group_y = gy,
                .group_z = gz,
            });
            continue;
        }
    }

    return Pipeline{
        .name = try allocator.dupe(u8, pipeline_name orelse "TSS"),
        .resources = try resources.toOwnedSlice(),
        .passes = try passes.toOwnedSlice(),
    };
}

fn parseProp(line: []const u8, key: []const u8) ?[]const u8 {
    const prefix1 = std.fmt.allocPrint(std.heap.page_allocator, "{s} = ", .{key}) catch return null;
    defer std.heap.page_allocator.free(prefix1);
    if (std.mem.startsWith(u8, line, prefix1)) {
        return std.mem.trim(u8, line[prefix1.len..], " \t;\"");
    }
    const prefix2 = std.fmt.allocPrint(std.heap.page_allocator, "{s}=", .{key}) catch return null;
    defer std.heap.page_allocator.free(prefix2);
    if (std.mem.startsWith(u8, line, prefix2)) {
        return std.mem.trim(u8, line[prefix2.len..], " \t;\"");
    }
    return null;
}

fn extractQuoted(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t;");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn parseDispatch(line: []const u8, gx: *u32, gy: *u32, gz: *u32) void {
    const start = "dispatch(".len;
    const inner = line[start..];
    const end = std.mem.indexOfScalar(u8, inner, ')') orelse return;
    const args_str = std.mem.trim(u8, inner[0..end], " \t");
    var arg_iter = std.mem.tokenizeScalar(u8, args_str, ',');
    const parts = [_]*u32{ gx, gy, gz };
    var pi: usize = 0;
    while (arg_iter.next()) |token| : (pi += 1) {
        const t = std.mem.trim(u8, token, " \t");
        if (pi < parts.len and t.len > 0) {
            parts[pi].* = std.fmt.parseInt(u32, t, 10) catch 8;
        }
    }
}
