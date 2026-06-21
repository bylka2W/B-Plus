const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SymbolKind = enum {
    code,
    exp,
    data,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    rva: u32,
};

pub const SymbolTable = struct {
    symbols: std.ArrayList(Symbol),
    allocator: Allocator,

    pub fn init(allocator: Allocator) SymbolTable {
        return .{
            .symbols = std.ArrayList(Symbol).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SymbolTable) void {
        for (self.symbols.items) |s| self.allocator.free(s.name);
        self.symbols.deinit();
    }

    pub fn add(self: *SymbolTable, name: []const u8, kind: SymbolKind, rva: u32) !void {
        const owned = try self.allocator.dupe(u8, name);
        try self.symbols.append(.{ .name = owned, .kind = kind, .rva = rva });
    }

    pub fn lookup(self: *const SymbolTable, name: []const u8) ?u32 {
        for (self.symbols.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return s.rva;
        }
        return null;
    }

    pub fn filterByKind(self: *const SymbolTable, kind: SymbolKind) struct { items: []const Symbol } {
        // Returns a view slice — caller must not outlive the table
        var result = std.ArrayList(Symbol).init(self.allocator);
        for (self.symbols.items) |s| {
            if (s.kind == kind) result.append(s) catch {};
        }
        return .{ .items = result.items };
    }
};
