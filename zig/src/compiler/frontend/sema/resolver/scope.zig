const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../ast.zig");

pub const SymbolKind = enum {
    variable,
    param,
    function,
    state,
    struct_def,
    enum_def,
    module,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    type_id: ast.TypeId,
    type_name: ?[]const u8,
    scope_level: u32,
};

pub const Scope = struct {
    level: u32,
    parent: ?*Scope,
    symbols: std.StringHashMap(Symbol),
    allocator: Allocator,

    pub fn init(allocator: Allocator, level: u32, parent: ?*Scope) Scope {
        return .{
            .level = level,
            .parent = parent,
            .symbols = std.StringHashMap(Symbol).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scope) void {
        self.symbols.deinit();
    }
};

pub const ScopeTable = struct {
    root: *Scope,
    current: *Scope,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !ScopeTable {
        const root = try allocator.create(Scope);
        root.* = Scope.init(allocator, 0, null);
        return .{
            .root = root,
            .current = root,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ScopeTable) void {
        self.destroyScope(self.root);
    }

    fn destroyScope(self: *ScopeTable, scope: *Scope) void {
        scope.deinit();
        self.allocator.destroy(scope);
    }

    pub fn pushScope(self: *ScopeTable) !void {
        const new_scope = try self.allocator.create(Scope);
        new_scope.* = Scope.init(self.allocator, self.current.level + 1, self.current);
        self.current = new_scope;
    }

    pub fn popScope(self: *ScopeTable) void {
        if (self.current.parent) |parent| {
            const old = self.current;
            old.deinit();
            self.allocator.destroy(old);
            self.current = parent;
        }
    }

    pub fn define(
        self: *ScopeTable,
        name: []const u8,
        kind: SymbolKind,
        type_id: ast.TypeId,
        type_name: ?[]const u8,
    ) !void {
        const sym = Symbol{
            .name = name,
            .kind = kind,
            .type_id = type_id,
            .type_name = type_name,
            .scope_level = self.current.level,
        };
        try self.current.symbols.put(name, sym);
    }

    pub fn lookup(self: *ScopeTable, name: []const u8) ?Symbol {
        var scope: ?*Scope = self.current;
        while (scope) |s| {
            if (s.symbols.get(name)) |found| return found;
            scope = s.parent;
        }
        return null;
    }

    pub fn lookupCurrent(self: *ScopeTable, name: []const u8) ?Symbol {
        return self.current.symbols.get(name);
    }

    pub fn isDefinedInCurrentScope(self: *ScopeTable, name: []const u8) bool {
        return self.current.symbols.contains(name);
    }
};
