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
    forward_to: ?[]const u8,
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
        for (self.symbols.items) |s| {
            self.allocator.free(s.name);
            if (s.forward_to) |f| self.allocator.free(f);
        }
        self.symbols.deinit();
    }

    pub fn add(self: *SymbolTable, name: []const u8, kind: SymbolKind, rva: u32) !void {
        const owned = try self.allocator.dupe(u8, name);
        try self.symbols.append(.{ .name = owned, .kind = kind, .rva = rva, .forward_to = null });
    }

    pub fn addForward(self: *SymbolTable, name: []const u8, target: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        const owned_target = try self.allocator.dupe(u8, target);
        try self.symbols.append(.{ .name = owned_name, .kind = .exp, .rva = 0, .forward_to = owned_target });
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
