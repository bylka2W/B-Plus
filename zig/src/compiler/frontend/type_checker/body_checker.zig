const std = @import("std");
const TypeChecker = @import("checker.zig").TypeChecker;
const TypeCheckError = @import("checker.zig").TypeCheckError;
const hir_mod = @import("../hir/arena.zig");

pub fn checkBody(self: *TypeChecker, body: hir_mod.HirBody) TypeCheckError!void {
    if (body.entry.isValid()) {
        _ = try self.checkExpr(body.entry);
    }
}
