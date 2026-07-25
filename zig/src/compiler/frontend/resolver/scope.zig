const std = @import("std");
const def_mod = @import("def.zig");

pub const DefId = def_mod.DefId;
pub const SymbolId = def_mod.SymbolId;
pub const DefKind = def_mod.DefKind;
pub const Def = def_mod.Def;

pub const ScopeKind = enum {
    module,
    function,
    block,
    closure,
    loop,
};

pub const Scope = struct {
    id: u32,
    kind: ScopeKind,
    parent: ?u32,
    owner: DefId,
    symbols: std.AutoHashMap(SymbolId, DefId),
    defs: std.ArrayList(DefId),

    pub fn deinit(self: *Scope) void {
        self.symbols.deinit();
        self.defs.deinit();
    }

    pub fn define(self: *Scope, name: SymbolId, def_id: DefId) void {
        self.symbols.put(name, def_id) catch {};
        self.defs.append(def_id) catch {};
    }
};

pub const ScopeChain = struct {
    scopes: std.ArrayList(Scope),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ScopeChain {
        return .{
            .scopes = std.ArrayList(Scope).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ScopeChain) void {
        for (self.scopes.items) |*scope| {
            scope.deinit();
        }
        self.scopes.deinit();
    }

    pub fn pushScope(self: *ScopeChain, kind: ScopeKind, parent: ?u32, owner: DefId) u32 {
        const id: u32 = @intCast(self.scopes.items.len);
        self.scopes.append(.{
            .id = id,
            .kind = kind,
            .parent = parent,
            .owner = owner,
            .symbols = std.AutoHashMap(SymbolId, DefId).init(self.allocator),
            .defs = std.ArrayList(DefId).init(self.allocator),
        }) catch return 0;
        return id;
    }

    pub fn getScope(self: *const ScopeChain, id: u32) ?*const Scope {
        if (id >= self.scopes.items.len) return null;
        return &self.scopes.items[id];
    }

    pub fn getScopeMut(self: *ScopeChain, id: u32) ?*Scope {
        if (id >= self.scopes.items.len) return null;
        return &self.scopes.items[id];
    }

    pub fn defineInScope(self: *ScopeChain, scope_id: u32, name: SymbolId, def_id: DefId) void {
        if (self.getScopeMut(scope_id)) |scope| {
            scope.define(name, def_id);
        }
    }

    pub fn lookupInScope(self: *const ScopeChain, scope_id: u32, name: SymbolId) ?DefId {
        var current_id: ?u32 = scope_id;
        while (current_id) |sid| {
            if (self.getScope(sid)) |scope| {
                if (scope.symbols.get(name)) |def_id| {
                    return def_id;
                }
                current_id = scope.parent;
            } else {
                break;
            }
        }
        return null;
    }
};
