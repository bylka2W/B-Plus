// Single source of truth for the B+ vocabulary.
//
// Everything that needs to agree on "what is a keyword / a type / a builtin"
// must read it from here: the lexer, semantic analysis, the VS Code grammar,
// and `bpc capabilities`. A second hardcoded list is a bug waiting to happen.
const std = @import("std");

pub const scalar_types = [_][]const u8{
    "int", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64",
    "f32", "f64", "bool", "void", "string", "ptr",
};

pub const builtin_functions = [_][]const u8{
    "print",           "free",
    "malloc",          "ptr_load",
    "ptr_store",       "reinterpret_cast",
    "addr",            "sizeof",
    "alignof",         "GetStdHandle",
    "WriteConsoleA",   "ReadConsoleA",
    "ExitProcess",     "GetLastError",
    "VirtualAlloc",    "LoadLibraryA",
    "GetProcAddress",
};

/// PLAN/state-machine vocabulary. These are keywords of the language, not
/// identifiers, so an LSP must colour and complete them as such.
pub const plan_keywords = [_][]const u8{
    "state", "entry", "exit", "on", "emit", "goto", "start", "stop",
    "always", "fire", "machine", "initial", "parallel",
};

pub const file_extensions = [_][]const u8{ ".b+", ".bplus", ".bp" };

pub fn isScalarType(ident: []const u8) bool {
    for (scalar_types) |t| {
        if (std.mem.eql(u8, ident, t)) return true;
    }
    return false;
}

pub fn isBuiltin(ident: []const u8) bool {
    for (builtin_functions) |b| {
        if (std.mem.eql(u8, ident, b)) return true;
    }
    return false;
}

pub fn isPlanKeyword(ident: []const u8) bool {
    for (plan_keywords) |k| {
        if (std.mem.eql(u8, ident, k)) return true;
    }
    return false;
}