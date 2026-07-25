const std = @import("std");

pub const QueryKey = struct {
    kind: QueryKind,
    input: u64,
    fingerprint: u64,

    pub const QueryKind = enum(u8) {
        parse_file,
        expand,
        resolve_name,
        type_of,
        hir_body,
        thir_body,
        bir_lower,
        const_eval,
        layout_of,
        is_copy,
        is_sized,
        discriminant,
    };

    pub fn hash(self: QueryKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, self.kind);
        std.hash.autoHash(&hasher, self.input);
        std.hash.autoHash(&hasher, self.fingerprint);
        return hasher.final();
    }

    pub fn eql(self: QueryKey, other: QueryKey) bool {
        return self.kind == other.kind and self.input == other.input and self.fingerprint == other.fingerprint;
    }

    pub fn format(self: QueryKey, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("Query({s}, input={d}, fp={x})", .{ @tagName(self.kind), self.input, self.fingerprint });
    }
};
