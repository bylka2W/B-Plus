const std = @import("std");

pub const IdentifierId = u32;

pub const invalid_id: IdentifierId = 0;

pub const IdentifierInterner = struct {
    allocator: std.mem.Allocator,
    strings: std.ArrayList([]const u8),
    index: std.StringHashMap(IdentifierId),
    next_id: IdentifierId,

    pub fn init(allocator: std.mem.Allocator) IdentifierInterner {
        var interner = IdentifierInterner{
            .allocator = allocator,
            .strings = std.ArrayList([]const u8).init(allocator),
            .index = std.StringHashMap(IdentifierId).init(allocator),
            .next_id = 1,
        };
        interner.setupBuiltins();
        return interner;
    }

    pub fn deinit(self: *IdentifierInterner) void {
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit();
        self.index.deinit();
    }

    pub fn intern(self: *IdentifierInterner, name: []const u8) IdentifierId {
        if (self.index.get(name)) |id| return id;
        const id = self.next_id;
        self.next_id += 1;
        const owned = self.allocator.dupe(u8, name) catch return invalid_id;
        self.strings.append(owned) catch return invalid_id;
        self.index.put(owned, id) catch return invalid_id;
        return id;
    }

    pub fn get(self: *const IdentifierInterner, id: IdentifierId) ?[]const u8 {
        if (id == 0 or id >= self.strings.items.len) return null;
        return self.strings.items[id];
    }

    pub fn resolve(self: *const IdentifierInterner, id: IdentifierId) []const u8 {
        return self.get(id) orelse "<invalid>";
    }

    pub fn count(self: *const IdentifierInterner) usize {
        return self.strings.items.len;
    }

    fn setupBuiltins(self: *IdentifierInterner) void {
        const builtins = [_][]const u8{
            "void", "bool", "i8", "i16", "i32", "i64",
            "u8", "u16", "u32", "u64", "f32", "f64",
            "string", "true", "false", "null",
            "fn", "return", "if", "else", "while", "for",
            "struct", "enum", "import", "export",
            "let", "var", "const",
            "self", "this",
        };
        for (builtins) |b| {
            _ = self.intern(b);
        }
    }
};
