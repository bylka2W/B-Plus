const std = @import("std");
const bir = @import("../bir.zig");
const FunctionId = bir.FunctionId;
const diagnostics = @import("diagnostics.zig");
const DiagnosticList = diagnostics.DiagnosticList;
const Diagnostic = diagnostics.Diagnostic;

pub fn verifyModule(module: *const bir.Module, errs: *DiagnosticList) !void {
    const n = module.functions.items.len;
    if (n == 0) return;

    var seen_names = std.StringHashMap(void).init(errs.allocator);
    defer seen_names.deinit();

    for (module.functions.items, 0..) |func, fid| {
        const func_id = @as(FunctionId, @intCast(fid));

        if (func_id >= module.functions.items.len) {
            try errs.push(.{
                .code = .invalid_function_id,
                .func_id = func_id,
                .message = "function ID out of range",
            });
            continue;
        }

        if (seen_names.getPtr(func.name)) |_| {
            try errs.push(.{
                .code = .duplicate_function_name,
                .func_id = func_id,
                .func_name = func.name,
                .message = "function name defined more than once",
            });
        } else {
            try seen_names.put(func.name, {});
        }
    }
}
