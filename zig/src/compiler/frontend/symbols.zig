pub const symbol = @import("symbol/symbol.zig");
pub const scope = @import("symbol/scope.zig");
pub const symbol_table = @import("symbol/symbol_table.zig");

pub const SymbolId = symbol.SymbolId;
pub const ScopeId = symbol.ScopeId;
pub const SymbolKind = symbol.SymbolKind;
pub const Symbol = symbol.Symbol;
pub const Scope = scope.Scope;
pub const ScopeGraph = scope.ScopeGraph;
pub const ScopeKind = scope.ScopeKind;
pub const SymbolTable = symbol_table.SymbolTable;
pub const IdentifierId = symbol.IdentifierId;
