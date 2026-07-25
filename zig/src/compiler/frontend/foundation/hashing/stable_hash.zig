const std = @import("std");

pub const Fingerprint = struct {
    hash: u64,

    pub const zero = Fingerprint{ .hash = 0 };

    pub fn fromBytes(bytes: []const u8) Fingerprint {
        return .{ .hash = std.hash.Wyhash.hash(0, bytes) };
    }

    pub fn combine(self: Fingerprint, other: Fingerprint) Fingerprint {
        var hasher = std.hash.Wyhash.init(self.hash);
        std.hash.autoHash(&hasher, other.hash);
        return .{ .hash = hasher.final() };
    }

    pub fn mix(self: Fingerprint, comptime T: type, value: T) Fingerprint {
        var hasher = std.hash.Wyhash.init(self.hash);
        std.hash.autoHash(&hasher, value);
        return .{ .hash = hasher.final() };
    }

    pub fn eql(self: Fingerprint, other: Fingerprint) bool {
        return self.hash == other.hash;
    }

    pub fn format(self: Fingerprint, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("0x{x:016}", .{self.hash});
    }
};

pub const StableHasher = struct {
    state: std.hash.Wyhash,

    pub fn init(seed: u64) StableHasher {
        return .{ .state = std.hash.Wyhash.init(seed) };
    }

    pub fn feed(self: *StableHasher, comptime T: type, value: T) void {
        std.hash.autoHash(&self.state, value);
    }

    pub fn feedBytes(self: *StableHasher, bytes: []const u8) void {
        self.state.update(bytes);
    }

    pub fn finish(self: StableHasher) u64 {
        return self.state.final();
    }

    pub fn fingerprint(self: StableHasher) Fingerprint {
        return .{ .hash = self.finish() };
    }
};
