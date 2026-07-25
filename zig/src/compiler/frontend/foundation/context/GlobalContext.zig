const std = @import("std");
const string_pool_mod = @import("../interner/string_pool.zig");
const string_interner_mod = @import("../interner/string_interner.zig");
const symbol_interner_mod = @import("../interner/symbol_interner.zig");
const path_interner_mod = @import("../interner/path_interner.zig");
const type_interner_mod = @import("../interner/type_interner.zig");

pub const GlobalContext = struct {
    backing_allocator: std.mem.Allocator,
    pool: string_pool_mod.StringPool,
    strings: string_interner_mod.StringInterner,
    symbols: symbol_interner_mod.SymbolInterner,
    paths: path_interner_mod.PathInterner,
    types: type_interner_mod.TypeInterner,
    next_file_id: u32,

    pub fn init(backing: std.mem.Allocator) !GlobalContext {
        const pool = try string_pool_mod.StringPool.init(backing);
        return .{
            .backing_allocator = backing,
            .pool = pool,
            .strings = string_interner_mod.StringInterner.init(&pool),
            .symbols = symbol_interner_mod.SymbolInterner.init(&pool),
            .paths = path_interner_mod.PathInterner.init(backing),
            .types = type_interner_mod.TypeInterner.init(backing),
            .next_file_id = 0,
        };
    }

    pub fn populateBuiltins(self: *GlobalContext) !void {
        const builtins = [_][]const u8{
            "void", "bool", "i8", "i16", "i32", "i64",
            "u8", "u16", "u32", "u64", "f32", "f64",
            "string", "true", "false", "null",
            "fn", "return", "if", "else", "while", "for",
            "struct", "enum", "trait", "impl",
            "import", "export", "pub", "priv",
            "let", "var", "const", "mut",
            "self", "this", "_",
        };
        for (builtins) |b| {
            _ = try self.symbols.intern(b);
        }
    }

    pub fn deinit(self: *GlobalContext) void {
        self.types.deinit();
        self.paths.deinit();
        self.symbols.deinit();
        self.strings.deinit();
        self.pool.deinit();
    }

    pub fn internString(self: *GlobalContext, str: []const u8) !u32 {
        return self.strings.intern(str);
    }

    pub fn resolveString(self: *const GlobalContext, id: u32) []const u8 {
        return self.strings.resolve(id);
    }

    pub fn internSymbol(self: *GlobalContext, name: []const u8) !u32 {
        return self.symbols.intern(name);
    }

    pub fn resolveSymbol(self: *const GlobalContext, id: u32) []const u8 {
        return self.symbols.resolve(id);
    }

    pub fn internPath(self: *GlobalContext, name: u32, parent: ?path_interner_mod.PathId) !path_interner_mod.PathId {
        return self.paths.push(name, parent);
    }

    pub fn internType(self: *GlobalContext, t: type_interner_mod.Type) !type_interner_mod.TypeId {
        return self.types.intern(t);
    }

    pub fn allocFileId(self: *GlobalContext) u32 {
        const id = self.next_file_id;
        self.next_file_id += 1;
        return id;
    }
};
