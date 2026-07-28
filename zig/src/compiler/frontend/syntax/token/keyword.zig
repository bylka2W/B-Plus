const std = @import("std");
const token_kind = @import("token_kind.zig");

pub const TokenKind = token_kind.TokenKind;

pub const keywords = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "fn", .kw_fn },
    .{ "let", .kw_let },
    .{ "var", .kw_var },
    .{ "const", .kw_const },
    .{ "mut", .kw_mut },
    .{ "return", .kw_return },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "while", .kw_while },
    .{ "for", .kw_for },
    .{ "in", .kw_in },
    .{ "loop", .kw_loop },
    .{ "break", .kw_break },
    .{ "continue", .kw_continue },
    .{ "match", .kw_match },
    .{ "struct", .kw_struct },
    .{ "enum", .kw_enum },
    .{ "trait", .kw_trait },
    .{ "impl", .kw_impl },
    .{ "type", .kw_type },
    .{ "import", .kw_import },
    .{ "export", .kw_export },
    .{ "from", .kw_from },
    .{ "as", .kw_as },
    .{ "pub", .kw_pub },
    .{ "priv", .kw_priv },
    .{ "static", .kw_static },
    .{ "extern", .kw_extern },
    .{ "self", .kw_self },
    .{ "this", .kw_this },
    .{ "super", .kw_super },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "null", .kw_null },
    .{ "void", .kw_void },
    .{ "bool", .kw_bool },
    .{ "i8", .kw_i8 },
    .{ "i16", .kw_i16 },
    .{ "i32", .kw_i32 },
    .{ "i64", .kw_i64 },
    .{ "u8", .kw_u8 },
    .{ "u16", .kw_u16 },
    .{ "u32", .kw_u32 },
    .{ "u64", .kw_u64 },
    .{ "f32", .kw_f32 },
    .{ "f64", .kw_f64 },
    .{ "string", .kw_string },
    .{ "any", .kw_any },
    .{ "comptime", .kw_comptime },
    .{ "inline", .kw_inline },
    .{ "noinline", .kw_noinline },
    .{ "unreachable", .kw_unreachable },
    .{ "panic", .kw_panic },
    .{ "sizeof", .kw_sizeof },
    .{ "alignof", .kw_alignof },
    .{ "typeof", .kw_typeof },
    .{ "ref", .kw_ref },
    .{ "deref", .kw_deref },
    .{ "defer", .kw_defer },
    .{ "errdefer", .kw_errdefer },
    .{ "orelse", .kw_orelse },
    .{ "catch", .kw_catch },
    .{ "try", .kw_try },
    .{ "and", .kw_and },
    .{ "or", .kw_or },
    .{ "not", .kw_not },
    .{ "async", .kw_async },
    .{ "await", .kw_await },
    .{ "yield", .kw_yield },
    .{ "atomic", .kw_atomic },
    .{ "volatile", .kw_volatile },

    // State machine
    .{ "state", .kw_state },
    .{ "entry", .kw_entry },
    .{ "on", .kw_on },
    .{ "always", .kw_always },
    .{ "parallel", .kw_parallel },
    .{ "fire", .kw_fire },
    .{ "machine", .kw_machine },

    // GPU / compute
    .{ "kernel", .kw_kernel },
    .{ "pipeline", .kw_pipeline },
    .{ "forward", .kw_forward },

    // Runtime
    .{ "run", .kw_run },
    .{ "print", .kw_print },
    .{ "free", .kw_free },
    .{ "body", .kw_body },
    .{ "step", .kw_step },
    .{ "publish", .kw_publish },
    .{ "enter", .kw_enter },
    .{ "exit", .kw_exit },

    // Ownership
    .{ "owned", .kw_owned },
    .{ "borrowed", .kw_borrowed },

    // Modules / FFI
    .{ "use", .kw_use },
    .{ "metal", .kw_metal },
    .{ "cxx", .kw_cxx },

    // Russian aliases — state machine
    .{ "состояние", .kw_state },
    .{ "вход", .kw_entry },
    .{ "на", .kw_on },
    .{ "всегда", .kw_always },
    .{ "параллельно", .kw_parallel },
    .{ "пуск", .kw_fire },
    .{ "автомат", .kw_machine },

    // Russian aliases — GPU / compute
    .{ "ядро", .kw_kernel },
    .{ "конвейер", .kw_pipeline },
    .{ "метал", .kw_metal },

    // Russian aliases — general
    .{ "фн", .kw_fn },
    .{ "структура", .kw_struct },
    .{ "перечисление", .kw_enum },
    .{ "импорт", .kw_import },
    .{ "экспорт", .kw_export },
    .{ "использовать", .kw_use },
    .{ "пер", .kw_var },
    .{ "внешний", .kw_extern },

    // Russian aliases — control flow
    .{ "если", .kw_if },
    .{ "иначе", .kw_else },
    .{ "вернуть", .kw_return },

    // Russian aliases — runtime
    .{ "запуск", .kw_run },
    .{ "печать", .kw_print },
    .{ "освободить", .kw_free },
    .{ "тело", .kw_body },
    .{ "шаг", .kw_step },
    .{ "опубликовать", .kw_publish },
    .{ "войти", .kw_enter },
    .{ "выйти", .kw_exit },

    // Russian aliases — ownership
    .{ "владение", .kw_owned },
    .{ "заимствовано", .kw_borrowed },

    // Russian aliases — literals
    .{ "истина", .kw_true },
    .{ "ложь", .kw_false },
});

pub fn lookupKeyword(text: []const u8) ?TokenKind {
    return keywords.get(text);
}

pub fn isKeyword(text: []const u8) bool {
    return keywords.has(text);
}
