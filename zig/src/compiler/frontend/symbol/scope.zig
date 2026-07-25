const std = @import("std");
const sym = @import("symbol.zig");

pub const ScopeId = sym.ScopeId;
pub const SymbolId = sym.SymbolId;

pub const ScopeKind = enum {
    global,
    module,
    function,
    block,
    @"if",
    @"while",
    for_loop,
    closure,
};

pub const Scope = struct {
    id: ScopeId,
    parent: ?ScopeId,
    kind: ScopeKind,
    symbols: std.ArrayList(SymbolId),
    label: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, id: ScopeId, parent: ?ScopeId, kind: ScopeKind, label: ?[]const u8) Scope {
        return .{
            .id = id,
            .parent = parent,
            .kind = kind,
            .symbols = std.ArrayList(SymbolId).init(allocator),
            .label = label,
        };
    }

    pub fn deinit(self: *Scope) void {
        self.symbols.deinit();
    }
};

pub const ScopeGraph = struct {
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(Scope),
    current: ?ScopeId,
    next_scope_id: ScopeId,

    pub fn init(allocator: std.mem.Allocator) ScopeGraph {
        return .{
            .allocator = allocator,
            .scopes = std.ArrayList(Scope).init(allocator),
            .current = null,
            .next_scope_id = 0,
        };
    }

    pub fn deinit(self: *ScopeGraph) void {
        for (self.scopes.items) |*s| s.deinit();
        self.scopes.deinit();
    }

    pub fn pushScope(self: *ScopeGraph, kind: ScopeKind, label: ?[]const u8) ScopeId {
        const id = self.next_scope_id;
        self.next_scope_id += 1;
        self.scopes.append(Scope.init(self.allocator, id, self.current, kind, label)) catch unreachable;
        self.current = id;
        return id;
    }

    pub fn popScope(self: *ScopeGraph) void {
        if (self.current) |sid| {
            self.current = self.scopes.items[sid].parent;
        }
    }

    pub fn getCurrentScope(self: *const ScopeGraph) ?ScopeId {
        return self.current;
    }

    pub fn getScope(self: *const ScopeGraph, id: ScopeId) ?*const Scope {
        if (id < self.scopes.items.len) return &self.scopes.items[id];
        return null;
    }

    pub fn getScopeMut(self: *ScopeGraph, id: ScopeId) ?*Scope {
        if (id < self.scopes.items.len) return &self.scopes.items[id];
        return null;
    }

    pub fn addSymbolToScope(self: *ScopeGraph, scope_id: ScopeId, symbol_id: SymbolId) !void {
        self.scopes.items[scope_id].symbols.append(symbol_id) catch return error.OutOfMemory;
    }

    pub fn walkUpFind(self: *const ScopeGraph, scope_id: ScopeId, name_id: sym.IdentifierId, resolver: *const fn (*const ScopeGraph, ScopeId, sym.IdentifierId) ?SymbolId) ?SymbolId {
        var sid: ?ScopeId = scope_id;
        while (sid) |current| {
            if (resolver(self, current, name_id)) |found| return found;
            sid = self.scopes.items[current].parent;
        }
        return null;
    }

    pub fn scopeCount(self: *const ScopeGraph) usize {
        return self.scopes.items.len;
    }
};
