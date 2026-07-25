pub const identifier_table = @import("intern/identifier_table.zig");
pub const string_pool = @import("intern/string_pool.zig");

pub const IdentifierInterner = identifier_table.IdentifierInterner;
pub const IdentifierId = identifier_table.IdentifierId;
pub const StringPool = string_pool.StringPool;
pub const StringId = string_pool.StringId;
