const std = @import("std");
const testing = std.testing;
const frontend_test = @import("src/compiler/frontend/frontend_test.zig");
const path = std.fs.path;

test "diagnostics-runner" {
    const allocator = testing.allocator;
    const cwd = try std.fs.cwd().openDir("tests/semantic", .{ .iterate = true });
    defer cwd.close();

    while (true) {
        const entry = cwd.next() catch break;
        if (!std.mem.endsWith(u8, entry.name, ".b+")) continue;
        const file_path = try path.join(allocator, &.{ "tests/semantic", entry.name });
        defer allocator.free(file_path);
        const src = try std.fs.cwd().readFileAlloc(allocator, file_path, 32 * 1024);
        defer allocator.free(src);

        const result = try frontend_test.typeCheckSource(src, allocator);
        defer result.errors.deinit();
        defer result.hir_arena.deinit();
        defer result.engine.deinit();
        defer result.resolver.deinit();
        defer result.ast_arena.deinit();

        const err_count = result.errors.count();
        std.debug.print("{s} -> {d} errors\n", .{ file_path, err_count });
    }
}
