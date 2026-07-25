pub const checker = @import("checker.zig");
pub const errors = @import("errors.zig");
pub const coercion = @import("coercion.zig");
pub const expr_checker = @import("expr_checker.zig");
pub const stmt_checker = @import("stmt_checker.zig");
pub const body_checker = @import("body_checker.zig");
pub const finalize = @import("finalize.zig");
pub const verify_typed = @import("verify_typed.zig");

pub const TypeChecker = checker.TypeChecker;
pub const TypeError = errors.TypeError;
pub const ErrorList = errors.ErrorList;
pub const TypeCheckError = checker.TypeCheckError;

test {
    _ = coercion;
    _ = finalize;
    _ = verify_typed;
}
