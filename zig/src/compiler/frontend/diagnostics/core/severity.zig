pub const Severity = enum {
    note,
    warning,
    @"error",
    fatal,
    ice,

    pub fn colorCode(self: Severity) []const u8 {
        return switch (self) {
            .note => "\x1b[36m",
            .warning => "\x1b[33m",
            .@"error" => "\x1b[31m",
            .fatal => "\x1b[31;1m",
            .ice => "\x1b[35;1m",
        };
    }

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .note => "note",
            .warning => "warning",
            .@"error" => "error",
            .fatal => "fatal error",
            .ice => "internal compiler error",
        };
    }

    pub fn isError(self: Severity) bool {
        return self == .@"error" or self == .fatal or self == .ice;
    }
};
