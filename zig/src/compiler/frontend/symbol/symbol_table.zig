const std = @import("std");
const sym_mod = @import("symbol.zig");
const scope_mod = @import("scope.zig");
const intern = @import("../intern/identifier_table.zig");
const source = @import("../source/location/span.zig");

pub const SymbolId = sym_mod.SymbolId;
pub const ScopeId = sym_mod.ScopeId;
pub const SymbolKind = sym_mod.SymbolKind;
pub const Symbol = sym_mod.Symbol;
pub const Scope = scope_mod.Scope;
pub const ScopeGraph = scope_mod.ScopeGraph;
pub const IdentifierId = intern.IdentifierId;
pub const SourceSpan = source.SourceSpan;

pub const SymbolTable = struct {
    allocator: std.mem.Allocator,
    symbols: std.ArrayList(Symbol),
    interner: *intern.IdentifierInterner,
    scope_graph: ScopeGraph,
    name_index: std.AutoHashMap(IdentifierId, SymbolId),
    next_id: SymbolId,

    pub fn init(allocator: std.mem.Allocator, interner: *intern.IdentifierInterner) SymbolTable {
        var st = SymbolTable{
            .allocator = allocator,
            .symbols = std.ArrayList(Symbol).init(allocator),
            .interner = interner,
            .scope_graph = ScopeGraph.init(allocator),
            .name_index = std.AutoHashMap(IdentifierId, SymbolId).init(allocator),
            .next_id = 0,
        };
        _ = st.scope_graph.pushScope(.global, "global");
        return st;
    }

    pub fn deinit(self: *SymbolTable) void {
        self.symbols.deinit();
        self.scope_graph.deinit();
        self.name_index.deinit();
    }

    pub fn pushScope(self: *SymbolTable, kind: scope_mod.ScopeKind, label: ?[]const u8) ScopeId {
        return self.scope_graph.pushScope(kind, label);
    }

    pub fn popScope(self: *SymbolTable) void {
        self.scope_graph.popScope();
    }

    pub fn getCurrentScope(self: *const SymbolTable) ?ScopeId {
        return self.scope_graph.getCurrentScope();
    }

    pub fn insert(self: *SymbolTable, name: []const u8, kind: SymbolKind, span: ?SourceSpan) !SymbolId {
        const name_id = self.interner.intern(name);
        const scope_id = self.scope_graph.getCurrentScope() orelse return error.NoCurrentScope;

        if (self.lookupCurrent(name_id)) |existing_id| {
            _ = existing_id;
            return error.DuplicateSymbol;
        }

        const id = self.next_id;
        self.next_id += 1;

        self.symbols.append(.{
            .id = id,
            .name_id = name_id,
            .kind = kind,
            .scope_id = scope_id,
            .type_id = 0,
            .declared = span,
        }) catch return error.OutOfMemory;

        self.name_index.put(name_id, id) catch return error.OutOfMemory;
        self.scope_graph.addSymbolToScope(scope_id, id) catch return error.OutOfMemory;

        return id;
    }

    pub fn insertInScope(self: *SymbolTable, scope_id: ScopeId, name: []const u8, kind: SymbolKind, span: ?SourceSpan) !SymbolId {
        const name_id = self.interner.intern(name);

        if (self.lookupInScope(scope_id, name_id) != null) {
            return error.DuplicateSymbol;
        }

        const id = self.next_id;
        self.next_id += 1;

        self.symbols.append(.{
            .id = id,
            .name_id = name_id,
            .kind = kind,
            .scope_id = scope_id,
            .type_id = 0,
            .declared = span,
        }) catch return error.OutOfMemory;

        self.name_index.put(name_id, id) catch return error.OutOfMemory;
        self.scope_graph.addSymbolToScope(scope_id, id) catch return error.OutOfMemory;

        return id;
    }

    pub fn lookup(self: *const SymbolTable, name: []const u8) ?SymbolId {
        const name_id = self.interner.intern(name);
        var scope_id = self.scope_graph.getCurrentScope();
        while (scope_id) |sid| {
            const scope = self.scope_graph.getScope(sid) orelse break;
            for (scope.symbols.items) |sym_id| {
                if (self.symbols.items[sym_id].name_id == name_id) return sym_id;
            }
            scope_id = scope.parent;
        }
        return null;
    }

    pub fn lookupById(self: *const SymbolTable, name_id: IdentifierId) ?SymbolId {
        var scope_id = self.scope_graph.getCurrentScope();
        while (scope_id) |sid| {
            const scope = self.scope_graph.getScope(sid) orelse break;
            for (scope.symbols.items) |sym_id| {
                if (self.symbols.items[sym_id].name_id == name_id) return sym_id;
            }
            scope_id = scope.parent;
        }
        return null;
    }

    pub fn lookupCurrent(self: *const SymbolTable, name_id: IdentifierId) ?SymbolId {
        const scope_id = self.scope_graph.getCurrentScope() orelse return null;
        const scope = self.scope_graph.getScope(scope_id) orelse return null;
        for (scope.symbols.items) |sym_id| {
            if (self.symbols.items[sym_id].name_id == name_id) return sym_id;
        }
        return null;
    }

    pub fn lookupInScope(self: *const SymbolTable, scope_id: ScopeId, name_id: IdentifierId) ?SymbolId {
        const scope = self.scope_graph.getScope(scope_id) orelse return null;
        for (scope.symbols.items) |sym_id| {
            if (self.symbols.items[sym_id].name_id == name_id) return sym_id;
        }
        return null;
    }

    pub fn getSymbol(self: *const SymbolTable, id: SymbolId) ?*const Symbol {
        if (id < self.symbols.items.len) return &self.symbols.items[id];
        return null;
    }

    pub fn getSymbolMut(self: *SymbolTable, id: SymbolId) ?*Symbol {
        if (id < self.symbols.items.len) return &self.symbols.items[id];
        return null;
    }

    pub fn setType(self: *SymbolTable, id: SymbolId, type_id: u32) void {
        if (self.getSymbolMut(id)) |sym| {
            sym.type_id = type_id;
        }
    }

    pub fn symbolCount(self: *const SymbolTable) usize {
        return self.symbols.items.len;
    }

    pub fn resolveName(self: *const SymbolTable, id: IdentifierId) []const u8 {
        return self.interner.resolve(id);
    }
};
