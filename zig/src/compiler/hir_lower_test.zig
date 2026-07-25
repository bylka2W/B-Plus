const std = @import("std");
const parser_mod = @import("frontend/parser/parser.zig");
const lower = @import("middle/hir/lower.zig");

test "HIR lowering: PLAN state → HirState" {
    const src =
        \\state Idle {
        \\    var timer: i32
        \\    on Start -> Running
        \\}
    ;
    var p = parser_mod.Parser.init(std.testing.allocator, src, "test.bp");
    const program = try p.parse();
    defer {
        var prog = program;
        prog.deinit();
    }

    var module = try lower.lowerProgram(std.testing.allocator, &program, lower.SemaContext.empty());
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 1), module.states.items.len);
    try std.testing.expectEqualStrings("Idle", module.states.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), module.states.items[0].variables.items.len);
    try std.testing.expectEqualStrings("timer", module.states.items[0].variables.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), module.states.items[0].transitions.items.len);
    try std.testing.expectEqualStrings("Running", module.states.items[0].transitions.items[0].target);
}

test "HIR lowering: METAL kernel → HirKernel" {
    const src =
        \\kernel Blur(input: Texture2D) -> void
    ;
    var p = parser_mod.Parser.init(std.testing.allocator, src, "test.bp");
    const program = try p.parse();
    defer {
        var prog = program;
        prog.deinit();
    }

    var module = try lower.lowerProgram(std.testing.allocator, &program, lower.SemaContext.empty());
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 1), module.kernels.items.len);
    try std.testing.expectEqualStrings("Blur", module.kernels.items[0].name);
}

test "HIR lowering: mixed PLAN + METAL in one file" {
    const src =
        \\state Idle {
        \\    on Start -> Running
        \\}
        \\kernel Render() -> void
    ;
    var p = parser_mod.Parser.init(std.testing.allocator, src, "test.bp");
    const program = try p.parse();
    defer {
        var prog = program;
        prog.deinit();
    }

    var module = try lower.lowerProgram(std.testing.allocator, &program, lower.SemaContext.empty());
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 1), module.states.items.len);
    try std.testing.expectEqual(@as(usize, 1), module.kernels.items.len);
    try std.testing.expectEqualStrings("Idle", module.states.items[0].name);
    try std.testing.expectEqualStrings("Render", module.kernels.items[0].name);
}

test "HIR lowering: struct + function preserved" {
    const src =
        \\struct Vec3 { x: f32 }
        \\fn add(a: i32, b: i32) -> i32 { return a + b }
    ;
    var p = parser_mod.Parser.init(std.testing.allocator, src, "test.bp");
    const program = try p.parse();
    defer {
        var prog = program;
        prog.deinit();
    }

    var module = try lower.lowerProgram(std.testing.allocator, &program, lower.SemaContext.empty());
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    try std.testing.expectEqualStrings("add", module.functions.items[0].name);
}
