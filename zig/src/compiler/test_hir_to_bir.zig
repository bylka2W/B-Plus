const std = @import("std");
const testing = std.testing;

const lexer_mod = @import("frontend/syntax/lexer/scanner.zig");
const token_stream_mod = @import("frontend/syntax/token/token_stream.zig");
const green_tree_mod = @import("frontend/syntax/green/green_tree.zig");
const parser_mod = @import("frontend/syntax/parser/parser.zig");
const ast_arena_mod = @import("frontend/ast/arena.zig");
const ast_builder_mod = @import("frontend/ast/builder.zig");
const syntax_node_mod = @import("frontend/syntax/red/syntax_node.zig");
const resolver_mod = @import("frontend/resolver/resolver.zig");
const hir_lower = @import("frontend/hir/lowering/lower.zig");
const hir_mod = @import("frontend/hir/arena.zig");
const TypeEngine = @import("frontend/type_system/engine.zig").TypeEngine;
const type_checker_mod = @import("frontend/type_checker/checker.zig");
const type_errors = @import("frontend/type_checker/errors.zig");

const Lexer = lexer_mod.Lexer;
const TokenStream = token_stream_mod.TokenStream;
const GreenTree = green_tree_mod.GreenTree;
const Parser = parser_mod.Parser;
const AstArena = ast_arena_mod.AstArena;
const AstBuilder = ast_builder_mod.AstBuilder;
const SyntaxNode = syntax_node_mod.SyntaxNode;
const HirArena = hir_mod.HirArena;
const HirLowering = hir_lower.HirLowering;
const TypeChecker = type_checker_mod.TypeChecker;
const ErrorList = type_errors.ErrorList;

const hir_to_bir = @import("middle/hir_to_bir.zig");

fn typeCheckSource(source: []const u8, allocator: std.mem.Allocator) !struct {
    hir_arena: HirArena,
    engine: TypeEngine,
    errors: ErrorList,
    resolver: resolver_mod.Resolver,
    ast_arena: AstArena,
} {
    var lexer = Lexer.init(source, 0, allocator);
    defer lexer.deinit();

    const tokens = try lexer.lex();
    var stream = TokenStream.init(allocator);
    defer stream.deinit();
    for (tokens.items) |tok| {
        try stream.append(tok);
    }

    var green = green_tree_mod.GreenTree.init(allocator);
    defer green.deinit();

    var parser = Parser.init(&stream, allocator);
    defer parser.deinit();
    const green_root = try parser.parse(&green);

    var ast_arena = AstArena.init(allocator);
    var builder = AstBuilder.init(&ast_arena);
    defer builder.deinit();
    const syntax_root = SyntaxNode.init(green_root, 0);
    _ = builder.lowerSourceFile(syntax_root);

    var resolver = resolver_mod.Resolver.init(allocator);
    resolver.resolve(&ast_arena);

    var hir_arena = HirArena.init(allocator);
    var lowering = HirLowering.init(&hir_arena, &ast_arena, &resolver);
    try lowering.lower();

    var engine = TypeEngine.init(allocator);
    engine.initInference();
    var errors = ErrorList.init(allocator);

    var checker = TypeChecker.init(&hir_arena, &engine, &errors, &resolver.defs);
    try checker.check();
    checker.deinit();

    return .{
        .hir_arena = hir_arena,
        .engine = engine,
        .errors = errors,
        .resolver = resolver,
        .ast_arena = ast_arena,
    };
}

test "BIR lowering: simple function with literals" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    var lowerer = hir_to_bir.HirToBir.init(allocator, &result.hir_arena, &result.engine);
    defer lowerer.deinit();
    var bir_module = try lowerer.lower();
    defer bir_module.deinit();

    try testing.expect(bir_module.functions.items.len >= 1);
}

test "BIR lowering: binary expression" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\    let y = 20;
        \\    let z = x + y;
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    var lowerer = hir_to_bir.HirToBir.init(allocator, &result.hir_arena, &result.engine);
    defer lowerer.deinit();
    var bir_module = try lowerer.lower();
    defer bir_module.deinit();

    try testing.expect(bir_module.functions.items.len >= 1);
    const func = bir_module.getFunction(0);
    try testing.expect(func.blocks.items.len >= 1);
}

test "BIR lowering: if statement creates blocks" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\    if x > 5 {
        \\        let y = 1;
        \\    }
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    var lowerer = hir_to_bir.HirToBir.init(allocator, &result.hir_arena, &result.engine);
    defer lowerer.deinit();
    var bir_module = try lowerer.lower();
    defer bir_module.deinit();

    try testing.expect(bir_module.functions.items.len >= 1);
    const func = bir_module.getFunction(0);
    try testing.expect(func.blocks.items.len >= 2);
}

test "BIR lowering: while loop creates blocks" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\    while x > 0 {
        \\        x = x - 1;
        \\    }
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    var lowerer = hir_to_bir.HirToBir.init(allocator, &result.hir_arena, &result.engine);
    defer lowerer.deinit();
    var bir_module = try lowerer.lower();
    defer bir_module.deinit();

    try testing.expect(bir_module.functions.items.len >= 1);
    const func = bir_module.getFunction(0);
    try testing.expect(func.blocks.items.len >= 3);
}

test "BIR lowering: return statement" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\    return x;
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    var lowerer = hir_to_bir.HirToBir.init(allocator, &result.hir_arena, &result.engine);
    defer lowerer.deinit();
    var bir_module = try lowerer.lower();
    defer bir_module.deinit();

    try testing.expect(bir_module.functions.items.len >= 1);
    const func = bir_module.getFunctionMut(0);
    const entry = func.getBlock(0);
    const last_inst = entry.instrs.items[entry.instrs.items.len - 1];
    try testing.expectEqual(@import("middle/bir/bir.zig").Op.ret, last_inst.op);
}
