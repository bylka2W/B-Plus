const std = @import("std");
const testing = std.testing;

const lexer_mod = @import("syntax/lexer/scanner.zig");
const token_kind_mod = @import("syntax/token/token_kind.zig");
const TokenKind = token_kind_mod.TokenKind;
const token_stream_mod = @import("syntax/token/token_stream.zig");
const green_tree_mod = @import("syntax/green/green_tree.zig");
const parser_mod = @import("syntax/parser/parser.zig");
const legacy_parser = @import("parser/parser.zig");
const ast_arena_mod = @import("ast/arena.zig");
const ast_builder_mod = @import("ast/builder.zig");
const ast_dump_mod = @import("ast/dump.zig");
const ast_node = @import("ast/ast_node.zig");
const syntax_node_mod = @import("syntax/red/syntax_node.zig");
const resolver_mod = @import("resolver/resolver.zig");

const Lexer = lexer_mod.Lexer;
const TokenStream = token_stream_mod.TokenStream;
const GreenTree = green_tree_mod.GreenTree;
const Parser = parser_mod.Parser;
const AstArena = ast_arena_mod.AstArena;
const AstBuilder = ast_builder_mod.AstBuilder;
const SyntaxNode = syntax_node_mod.SyntaxNode;

fn parseAndBuild(source: []const u8, allocator: std.mem.Allocator) !struct { arena: AstArena, decls: std.ArrayList(ast_node.DeclId) } {
    var lexer = Lexer.init(source, 0, allocator);
    defer lexer.deinit();

    const tokens = try lexer.lex();
    var stream = TokenStream.init(allocator);
    defer stream.deinit();

    for (tokens.items) |tok| {
        try stream.append(tok);
    }

    var green = GreenTree.init(allocator);
    defer green.deinit();

    var parser = Parser.init(&stream, allocator);
    defer parser.deinit();

    const green_root = try parser.parse(&green);

    var arena = AstArena.init(allocator);
    var builder = AstBuilder.init(&arena);
    defer builder.deinit();

    const syntax_root = SyntaxNode.init(green_root, 0);
    const decls = builder.lowerSourceFile(syntax_root);

    return .{ .arena = arena, .decls = decls };
}

test "lexer: simple tokens" {
    const allocator = testing.allocator;
    var lexer = Lexer.init("let x = 10;", 0, allocator);
    defer lexer.deinit();

    const tokens = try lexer.lex();
    try testing.expect(tokens.items.len > 0);
    try testing.expect(tokens.items[0].kind == .kw_let);
}

test "lexer: keywords" {
    const allocator = testing.allocator;
    var lexer = Lexer.init("fn struct enum trait impl return if else while for", 0, allocator);
    defer lexer.deinit();

    const tokens = try lexer.lex();
    var kw_count: u32 = 0;
    for (tokens.items) |tok| {
        if (tok.kind.isKeyword()) kw_count += 1;
    }
    try testing.expect(kw_count >= 10);
}

test "lexer: number literals" {
    const allocator = testing.allocator;
    var lexer = Lexer.init("42 0xff 0b1010 3.14", 0, allocator);
    defer lexer.deinit();

    const tokens = try lexer.lex();
    var num_count: u32 = 0;
    for (tokens.items) |tok| {
        if (tok.kind == .int_literal or tok.kind == .float_literal) num_count += 1;
    }
    try testing.expectEqual(@as(u32, 4), num_count);
}

test "lexer: string literal" {
    const allocator = testing.allocator;
    var lexer = Lexer.init("\"hello world\"", 0, allocator);
    defer lexer.deinit();

    const tokens = try lexer.lex();
    try testing.expect(tokens.items.len > 0);
    try testing.expectEqual(.string_literal, tokens.items[0].kind);
}

test "lexer: operators" {
    const allocator = testing.allocator;
    var lexer = Lexer.init("a + b * c == d != e", 0, allocator);
    defer lexer.deinit();

    const tokens = try lexer.lex();
    var op_count: u32 = 0;
    for (tokens.items) |tok| {
        if (tok.kind == .plus or tok.kind == .star or tok.kind == .eq_eq or tok.kind == .bang_eq) op_count += 1;
    }
    try testing.expectEqual(@as(u32, 4), op_count);
}

test "lexer: comments skipped" {
    const allocator = testing.allocator;
    var lexer = Lexer.init("// comment\n42", 0, allocator);
    defer lexer.deinit();

    const tokens = try lexer.lex();
    var found_int = false;
    for (tokens.items) |tok| {
        if (tok.kind == .int_literal) found_int = true;
    }
    try testing.expect(found_int);
}

test "parser: source file with function" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    return 42;
        \\}
    ;
    var result = try parseAndBuild(source, allocator);
    defer result.arena.deinit();

    try testing.expect(result.decls.items.len > 0);
    const first = result.arena.getDecl(result.decls.items[0]);
    try testing.expect(first != null);
    try testing.expect(first.?.fn_decl.name.isValid());
}

test "parser: struct declaration" {
    const allocator = testing.allocator;
    const source =
        \\struct Vec2 {
        \\    x: f32,
        \\    y: f32
        \\}
    ;
    var result = try parseAndBuild(source, allocator);
    defer result.arena.deinit();

    try testing.expect(result.decls.items.len > 0);
    const first = result.arena.getDecl(result.decls.items[0]);
    try testing.expect(first != null);
    try testing.expect(first.?.struct_decl.name.isValid());
    try testing.expectEqual(@as(usize, 2), first.?.struct_decl.fields.len);
}

test "parser: enum declaration" {
    const allocator = testing.allocator;
    const source =
        \\enum Color {
        \\    Red,
        \\    Green,
        \\    Blue
        \\}
    ;
    var result = try parseAndBuild(source, allocator);
    defer result.arena.deinit();

    try testing.expect(result.decls.items.len > 0);
    const first = result.arena.getDecl(result.decls.items[0]);
    try testing.expect(first != null);
    try testing.expect(first.?.enum_decl.name.isValid());
    try testing.expectEqual(@as(usize, 3), first.?.enum_decl.variants.len);
}

test "parser: let statement" {
    const allocator = testing.allocator;
    const source =
        \\fn test_fn() {
        \\    let x = 10;
        \\}
    ;
    var result = try parseAndBuild(source, allocator);
    defer result.arena.deinit();

    try testing.expect(result.decls.items.len > 0);
    const fn_decl = result.arena.getDecl(result.decls.items[0]);
    try testing.expect(fn_decl != null);
    try testing.expect(fn_decl.?.fn_decl.body != null);

    const body = result.arena.getStmt(fn_decl.?.fn_decl.body.?);
    try testing.expect(body != null);
    try testing.expect(body.?.block.stmts.len > 0);
}

test "AST arena: expr storage" {
    const allocator = testing.allocator;
    var arena = AstArena.init(allocator);
    defer arena.deinit();

    const id1 = arena.addExpr(.{ .literal = .{ .kind = .integer, .symbol_id = 0, .span = .{ .file_id = 0, .start = 0, .end = 3 } } });
    const id2 = arena.addExpr(.{ .literal = .{ .kind = .string, .symbol_id = 1, .span = .{ .file_id = 0, .start = 5, .end = 12 } } });

    try testing.expect(id1.isValid());
    try testing.expect(id2.isValid());
    try testing.expect(!id1.eql(id2));

    const e1 = arena.getExpr(id1);
    try testing.expect(e1 != null);
    try testing.expectEqual(.integer, e1.?.literal.kind);
}

test "AST arena: stmt storage" {
    const allocator = testing.allocator;
    var arena = AstArena.init(allocator);
    defer arena.deinit();

    const pat = arena.addPattern(.{ .identifier = .{
        .name = .{ .index = 0 },
        .mutable = false,
        .span = .{ .file_id = 0, .start = 4, .end = 5 },
    } });

    const init_e = arena.addExpr(.{ .literal = .{ .kind = .integer, .symbol_id = 0, .span = .{ .file_id = 0, .start = 8, .end = 10 } } });

    const stmt = arena.addStmt(.{ .let = .{
        .pattern = pat,
        .type_annotation = null,
        .init = init_e,
        .span = .{ .file_id = 0, .start = 0, .end = 11 },
    } });

    try testing.expect(stmt.isValid());
    const s = arena.getStmt(stmt);
    try testing.expect(s != null);
    try testing.expect(s.?.let.init != null);
}

test "AST dump: function declaration" {
    const allocator = testing.allocator;
    const source =
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a;
        \\}
    ;
    var result = try parseAndBuild(source, allocator);
    defer result.arena.deinit();

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const writer = buf.writer();
    try ast_dump_mod.dumpModule(&result.arena, result.decls.items, writer);

    const output = try buf.toOwnedSlice();
    defer allocator.free(output);

    try testing.expect(output.len > 0);
    const contains_fn = std.mem.indexOf(u8, output, "FnDecl") != null;
    try testing.expect(contains_fn);
}

test "AST dump: struct declaration" {
    const allocator = testing.allocator;
    const source =
        \\struct Player {
        \\    name: string,
        \\    health: i32
        \\}
    ;
    var result = try parseAndBuild(source, allocator);
    defer result.arena.deinit();

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const writer = buf.writer();
    try ast_dump_mod.dumpModule(&result.arena, result.decls.items, writer);

    const output = try buf.toOwnedSlice();
    defer allocator.free(output);

    const contains_struct = std.mem.indexOf(u8, output, "StructDecl") != null;
    try testing.expect(contains_struct);
    const contains_field = std.mem.indexOf(u8, output, "Field") != null;
    try testing.expect(contains_field);
}

fn resolveSource(source: []const u8, allocator: std.mem.Allocator) !struct { arena: ast_arena_mod.AstArena, resolver: resolver_mod.Resolver } {
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

    var arena = ast_arena_mod.AstArena.init(allocator);
    var builder = AstBuilder.init(&arena);
    defer builder.deinit();

    const syntax_root = SyntaxNode.init(green_root, 0);
    _ = builder.lowerSourceFile(syntax_root);

    var resolver = resolver_mod.Resolver.init(allocator);
    resolver.resolve(&arena);

    return .{ .arena = arena, .resolver = resolver };
}

test "resolver: local variable" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\}
    ;
    var result = try resolveSource(source, allocator);
    defer result.arena.deinit();
    defer result.resolver.deinit();

    try testing.expect(result.arena.declCount() > 0);
    try testing.expect(result.resolver.defCount() >= 2);
    try testing.expect(result.resolver.resolvedCount() == 0);
}

test "resolver: function lookup" {
    const allocator = testing.allocator;
    const source =
        \\fn add(a: i32, b: i32) {
        \\    let result = a;
        \\}
    ;
    var result = try resolveSource(source, allocator);
    defer result.arena.deinit();
    defer result.resolver.deinit();

    try testing.expect(result.resolver.defCount() >= 4);

    const add_id = result.resolver.defs.lookupName(.new(0));
    try testing.expect(add_id != null);
    try testing.expect(add_id.?.isValid());
}

test "resolver: nested scope" {
    const allocator = testing.allocator;
    const source =
        \\fn test_fn() {
        \\    let x = 10;
        \\    {
        \\        let y = 20;
        \\    }
        \\}
    ;
    var result = try resolveSource(source, allocator);
    defer result.arena.deinit();
    defer result.resolver.deinit();

    try testing.expect(result.resolver.defCount() >= 3);
}

test "resolver: for loop variable" {
    const allocator = testing.allocator;
    const source =
        \\fn test_fn() {
        \\    for i in items {
        \\        let x = i;
        \\    }
        \\}
    ;
    var result = try resolveSource(source, allocator);
    defer result.arena.deinit();
    defer result.resolver.deinit();

    try testing.expect(result.resolver.defCount() >= 3);
}

test "resolver: struct fields" {
    const allocator = testing.allocator;
    const source =
        \\struct Vec2 {
        \\    x: f32,
        \\    y: f32
        \\}
    ;
    var result = try resolveSource(source, allocator);
    defer result.arena.deinit();
    defer result.resolver.deinit();

    try testing.expect(result.resolver.defCount() >= 3);
}

test "resolver: enum variants" {
    const allocator = testing.allocator;
    const source =
        \\enum Color {
        \\    Red,
        \\    Green,
        \\    Blue
        \\}
    ;
    var result = try resolveSource(source, allocator);
    defer result.arena.deinit();
    defer result.resolver.deinit();

    try testing.expect(result.resolver.defCount() >= 4);
}

const hir_mod = @import("hir/arena.zig");
const hir_lower = @import("hir/lowering/lower.zig");
const hir_dump = @import("hir/dump.zig");
const hir_verify = @import("hir/verify.zig");

const HirArena = hir_mod.HirArena;
const HirLowering = hir_lower.HirLowering;

fn lowerSource(source: []const u8, allocator: std.mem.Allocator) !struct {
    ast_arena: ast_arena_mod.AstArena,
    hir_arena: HirArena,
    resolver: resolver_mod.Resolver,
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

    var ast_arena = ast_arena_mod.AstArena.init(allocator);
    var builder = AstBuilder.init(&ast_arena);
    defer builder.deinit();

    const syntax_root = SyntaxNode.init(green_root, 0);
    _ = builder.lowerSourceFile(syntax_root);

    var resolver = resolver_mod.Resolver.init(allocator);
    resolver.resolve(&ast_arena);

    var hir_arena = HirArena.init(allocator);
    var lowering = HirLowering.init(&hir_arena, &ast_arena, &resolver);
    try lowering.lower();

    return .{ .ast_arena = ast_arena, .hir_arena = hir_arena, .resolver = resolver };
}

test "HIR: lower struct declaration" {
    const allocator = testing.allocator;
    const source =
        \\struct Vec2 {
        \\    x: f32,
        \\    y: f32
        \\}
    ;
    var result = try lowerSource(source, allocator);
    defer result.ast_arena.deinit();
    defer result.hir_arena.deinit();
    defer result.resolver.deinit();

    try testing.expect(result.hir_arena.itemCount() >= 1);
    const item = result.hir_arena.getItem(hir_mod.ItemId.new(0));
    try testing.expect(item != null);
    try testing.expect(item.?.kind.struct_item.name.index == 0);
}

test "HIR: lower enum declaration" {
    const allocator = testing.allocator;
    const source =
        \\enum Color {
        \\    Red,
        \\    Green,
        \\    Blue
        \\}
    ;
    var result = try lowerSource(source, allocator);
    defer result.ast_arena.deinit();
    defer result.hir_arena.deinit();
    defer result.resolver.deinit();

    try testing.expect(result.hir_arena.itemCount() >= 1);
    const item = result.hir_arena.getItem(hir_mod.ItemId.new(0));
    try testing.expect(item != null);
    try testing.expect(item.?.kind.enum_item.variants.len == 3);
}

test "HIR: lower function declaration" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\}
    ;
    var result = try lowerSource(source, allocator);
    defer result.ast_arena.deinit();
    defer result.hir_arena.deinit();
    defer result.resolver.deinit();

    try testing.expect(result.hir_arena.itemCount() >= 1);
    const item = result.hir_arena.getItem(hir_mod.ItemId.new(0));
    try testing.expect(item != null);
    try testing.expect(item.?.kind.fn_decl.name.index == 0);
}

test "HIR: lower function with parameters" {
    const allocator = testing.allocator;
    const source =
        \\fn add(a: i32, b: i32) {
        \\    let result = a;
        \\}
    ;
    var result = try lowerSource(source, allocator);
    defer result.ast_arena.deinit();
    defer result.hir_arena.deinit();
    defer result.resolver.deinit();

    try testing.expect(result.hir_arena.itemCount() >= 1);
    const item = result.hir_arena.getItem(hir_mod.ItemId.new(0));
    try testing.expect(item != null);
    try testing.expect(item.?.kind.fn_decl.params.len == 2);
}

test "HIR: verify valid program" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\}
    ;
    var result = try lowerSource(source, allocator);
    defer result.ast_arena.deinit();
    defer result.hir_arena.deinit();
    defer result.resolver.deinit();

    try hir_verify.verifyHIR(&result.hir_arena);
}

test "HIR: dump does not crash" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\}
    ;
    var result = try lowerSource(source, allocator);
    defer result.ast_arena.deinit();
    defer result.hir_arena.deinit();
    defer result.resolver.deinit();

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try hir_dump.dumpHIR(&result.hir_arena, buf.writer());
    try testing.expect(buf.items.len > 0);
}

test {
    _ = @import("type_system/type_system.zig");
    _ = @import("type_checker/type_checker.zig");
}

const TypeEngine = @import("type_system/engine.zig").TypeEngine;
const type_checker_mod = @import("type_checker/checker.zig");
const TypeChecker = type_checker_mod.TypeChecker;
const type_errors = @import("type_checker/errors.zig");
const ErrorList = type_errors.ErrorList;

pub fn typeCheckSource(source: []const u8, allocator: std.mem.Allocator) !struct {
    hir_arena: HirArena,
    engine: TypeEngine,
    errors: ErrorList,
    resolver: resolver_mod.Resolver,
    ast_arena: ast_arena_mod.AstArena,
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

    var ast_arena = ast_arena_mod.AstArena.init(allocator);
    var builder = AstBuilder.init(&ast_arena);
    defer builder.deinit();
    const syntax_root = SyntaxNode.init(green_root, 0);
    _ = builder.lowerSourceFile(syntax_root);

    var resolver = resolver_mod.Resolver.init(allocator);
    resolver.resolve(&ast_arena);

    var hir_arena = HirArena.init(allocator);
    var lowering = hir_lower.HirLowering.init(&hir_arena, &ast_arena, &resolver);
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

test "TypeChecker: literal i32 inferred" {
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

    try testing.expect(result.errors.count() == 0);
    try testing.expect(result.hir_arena.itemCount() >= 1);
}

test "TypeChecker: binary i32 + i32" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\    let y = x + 20;
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() == 0);
}

test "TypeChecker: binary bool + bool is error" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let a = true;
        \\    let b = false;
        \\    let c = a + b;
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() > 0);
}

test "TypeChecker: function params typed" {
    const allocator = testing.allocator;
    const source =
        \\fn add(a: i32, b: i32) {
        \\    let result = a + b;
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() == 0);
}

test "TypeChecker: equality returns bool" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\    let y = 20;
        \\    let eq = x == y;
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() == 0);
}

test "TypeChecker: void return for no return stmt" {
    const allocator = testing.allocator;
    const source =
        \\fn noop() {
        \\    let x = 1;
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() == 0);
}

test "TypeChecker: if expression" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\    if x == 10 {
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

    try testing.expect(result.errors.count() == 0);
}

test "TypeChecker: while loop" {
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

    try testing.expect(result.errors.count() == 0);
}

test "TypeChecker: break outside loop is error" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    break;
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() > 0);
}

test "TypeChecker: continue outside loop is error" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    continue;
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() > 0);
}

test "TypeChecker: break inside loop is ok" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    while true {
        \\        break;
        \\    }
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() == 0);
}

test "TypeChecker: nested break targets inner loop" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    while true {
        \\        while true {
        \\            break;
        \\        }
        \\    }
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() == 0);
}

test "TypeChecker: loop with break value" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = loop {
        \\        break 10;
        \\    };
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() == 0);
}

test "TypeChecker: match expression" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\    let y = if x == 0 { 100 } else { 200 };
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() == 0);
}

test "TypeChecker: closure literal" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = true;
        \\    let y = if x { 10 } else { 20 };
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() == 0);
}

test "TypeChecker: return type mismatch is error" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let a = true;
        \\    let b = false;
        \\    let c = a + b;
        \\    let d = 10 + 20;
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() > 0);
}

test "TypeChecker: while loop with condition is typed" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\    while x > 0 {
        \\        let y = x + 1;
        \\    }
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() == 0);
}

test "TypeChecker: nested if/else expressions" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\    let y = if x > 5 {
        \\        x + 1
        \\    } else {
        \\        x - 1
        \\    };
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() == 0);
}

test "TypeChecker: multiple type errors" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let a = true;
        \\    let b = false;
        \\    let c = a + b;
        \\    let d = a + 1;
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() >= 2);
}

test "TypeChecker: for loop" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let items = 10;
        \\    for items {
        \\        let x = 1;
        \\    }
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    try testing.expect(result.errors.count() == 0);
}

test "Finalize: type engine resolves concrete types" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\    let y = x + 20;
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    const finalize_mod = @import("type_checker/finalize.zig");
    try finalize_mod.finalizeTypedHIR(&result.hir_arena, &result.engine, &result.errors);

    try testing.expect(result.errors.count() == 0);
}

test "Verify: typed HIR passes verification" {
    const allocator = testing.allocator;
    const source =
        \\fn main() {
        \\    let x = 10;
        \\    let y = x + 20;
        \\}
    ;
    var result = try typeCheckSource(source, allocator);
    defer result.hir_arena.deinit();
    defer result.engine.deinit();
    defer result.errors.deinit();
    defer result.resolver.deinit();
    defer result.ast_arena.deinit();

    const finalize_mod = @import("type_checker/finalize.zig");
    try finalize_mod.finalizeTypedHIR(&result.hir_arena, &result.engine, &result.errors);

    const verify_mod = @import("type_checker/verify_typed.zig");
    try verify_mod.verifyTypedHIR(&result.hir_arena, &result.engine);
}

fn lexToKinds(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(TokenKind) {
    var lx = Lexer.init(source, 0, allocator);
    var tokens = try lx.lex();
    defer tokens.deinit();
    var kinds = std.ArrayList(TokenKind).init(allocator);
    for (tokens.items) |tok| {
        if (tok.kind == .whitespace or tok.kind == .tab) continue;
        try kinds.append(tok.kind);
    }
    return kinds;
}

fn hasKind(kinds: []const TokenKind, kind: TokenKind) bool {
    for (kinds) |k| {
        if (k == kind) return true;
    }
    return false;
}

fn countKind(kinds: []const TokenKind, kind: TokenKind) usize {
    var c: usize = 0;
    for (kinds) |k| {
        if (k == kind) c += 1;
    }
    return c;
}

test "PLAN dialect keywords" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const src =
        \\state Player {
        \\    entry { spawn(); }
        \\    on Damage -> Dead;
        \\    always [hp < 20] -> Warning;
        \\}
        \\parallel RenderPipeline {
        \\    state Idle {}
        \\}
    ;

    const kinds = try lexToKinds(allocator, src);
    defer kinds.deinit();

    try std.testing.expect(hasKind(kinds.items, .kw_state));
    try std.testing.expect(hasKind(kinds.items, .kw_entry));
    try std.testing.expect(hasKind(kinds.items, .kw_on));
    try std.testing.expect(hasKind(kinds.items, .kw_always));
    try std.testing.expect(hasKind(kinds.items, .kw_parallel));
    try std.testing.expect(hasKind(kinds.items, .arrow));
    try std.testing.expect(hasKind(kinds.items, .lbrace));
    try std.testing.expect(hasKind(kinds.items, .rbrace));
    try std.testing.expect(hasKind(kinds.items, .lbracket));
    try std.testing.expect(hasKind(kinds.items, .rbracket));
    try std.testing.expectEqual(@as(usize, 2), countKind(kinds.items, .kw_state));
}

test "METAL dialect keywords" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const src =
        \\struct Vec3 { x: f32, y: f32, z: f32 }
        \\enum Color { Red, Green, Blue }
        \\fn add(a: i32, b: i32) -> i32 { return a + b; }
        \\impl Vec3 { fn length(self) -> f32 {} }
        \\trait Drawable { fn draw(self); }
    ;

    const kinds = try lexToKinds(allocator, src);
    defer kinds.deinit();

    try std.testing.expect(hasKind(kinds.items, .kw_struct));
    try std.testing.expect(hasKind(kinds.items, .kw_enum));
    try std.testing.expect(hasKind(kinds.items, .kw_fn));
    try std.testing.expect(hasKind(kinds.items, .kw_impl));
    try std.testing.expect(hasKind(kinds.items, .kw_trait));
    try std.testing.expect(hasKind(kinds.items, .kw_return));
    try std.testing.expect(hasKind(kinds.items, .colon));
}

test "mixed PLAN + METAL" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const src =
        \\struct GameState { hp: i32 }
        \\state Alive {
        \\    entry { init_player(); }
        \\    on Damage [hp <= 0] -> Dead;
        \\}
        \\fn process_damage(amount: i32) { return amount; }
    ;

    const kinds = try lexToKinds(allocator, src);
    defer kinds.deinit();

    try std.testing.expect(hasKind(kinds.items, .kw_struct));
    try std.testing.expect(hasKind(kinds.items, .kw_state));
    try std.testing.expect(hasKind(kinds.items, .kw_entry));
    try std.testing.expect(hasKind(kinds.items, .kw_on));
    try std.testing.expect(hasKind(kinds.items, .kw_fn));
    try std.testing.expect(hasKind(kinds.items, .kw_return));
    try std.testing.expect(hasKind(kinds.items, .arrow));
    try std.testing.expect(hasKind(kinds.items, .less_eq));
}

test "russian keyword aliases - utf8 limitation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const src = "state Player {\n    on Damage -> Dead;\n}\n";

    const kinds = try lexToKinds(allocator, src);
    defer kinds.deinit();

    try std.testing.expect(hasKind(kinds.items, .kw_state));
    try std.testing.expect(hasKind(kinds.items, .kw_on));
    try std.testing.expect(hasKind(kinds.items, .arrow));
    try std.testing.expectEqual(@as(usize, 1), countKind(kinds.items, .kw_state));
}

test "all operators" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const src = "+ - * / % ^ & | ~ = == != < > <= >= += -= *= /= %= ^= &= |= << >> ++";

    const kinds = try lexToKinds(allocator, src);
    defer kinds.deinit();

    try std.testing.expect(hasKind(kinds.items, .plus));
    try std.testing.expect(hasKind(kinds.items, .minus));
    try std.testing.expect(hasKind(kinds.items, .star));
    try std.testing.expect(hasKind(kinds.items, .slash));
    try std.testing.expect(hasKind(kinds.items, .percent));
    try std.testing.expect(hasKind(kinds.items, .caret));
    try std.testing.expect(hasKind(kinds.items, .amp));
    try std.testing.expect(hasKind(kinds.items, .pipe));
    try std.testing.expect(hasKind(kinds.items, .tilde));
    try std.testing.expect(hasKind(kinds.items, .eq));
    try std.testing.expect(hasKind(kinds.items, .eq_eq));
    try std.testing.expect(hasKind(kinds.items, .bang_eq));
    try std.testing.expect(hasKind(kinds.items, .less));
    try std.testing.expect(hasKind(kinds.items, .greater));
    try std.testing.expect(hasKind(kinds.items, .less_eq));
    try std.testing.expect(hasKind(kinds.items, .greater_eq));
    try std.testing.expect(hasKind(kinds.items, .plus_eq));
    try std.testing.expect(hasKind(kinds.items, .minus_eq));
    try std.testing.expect(hasKind(kinds.items, .star_eq));
    try std.testing.expect(hasKind(kinds.items, .slash_eq));
    try std.testing.expect(hasKind(kinds.items, .percent_eq));
    try std.testing.expect(hasKind(kinds.items, .caret_eq));
    try std.testing.expect(hasKind(kinds.items, .amp_eq));
    try std.testing.expect(hasKind(kinds.items, .pipe_eq));
    try std.testing.expect(hasKind(kinds.items, .shl));
    try std.testing.expect(hasKind(kinds.items, .shr));
}

test "kernel with attributes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const src =
        \\@numthreads(8,8,1)
        \\kernel blur {
        \\    @binding(0) input: Texture2D<float4>
        \\    @binding(1) output: RWTexture2D<float4>
        \\    entry main(@builtin(global_invocation_id) id: uint3) {}
        \\}
    ;

    const kinds = try lexToKinds(allocator, src);
    defer kinds.deinit();

    try std.testing.expect(hasKind(kinds.items, .kw_kernel));
    try std.testing.expect(hasKind(kinds.items, .kw_entry));
    try std.testing.expect(hasKind(kinds.items, .at));
    try std.testing.expectEqual(@as(usize, 4), countKind(kinds.items, .at));
    try std.testing.expect(hasKind(kinds.items, .lbrace));
    try std.testing.expect(hasKind(kinds.items, .rbrace));
    try std.testing.expect(hasKind(kinds.items, .colon));
    try std.testing.expect(hasKind(kinds.items, .less));
    try std.testing.expect(hasKind(kinds.items, .greater));
    try std.testing.expect(hasKind(kinds.items, .comma));
    try std.testing.expect(hasKind(kinds.items, .lparen));
    try std.testing.expect(hasKind(kinds.items, .rparen));
}

test "parser: PLAN constructs accepted (no dialect restriction)" {
    var p = legacy_parser.Parser.init(std.testing.allocator, "state Idle { }", "test.bp");
    const program = try p.parse();
    defer {
        var prog = program;
        prog.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), program.plan.states.items.len);
    try std.testing.expectEqualStrings("Idle", program.plan.states.items[0].name);
}

test "parser: METAL constructs accepted (no dialect restriction)" {
    var p = legacy_parser.Parser.init(std.testing.allocator, "kernel Main(input: Texture2D) -> void", "test.bp");
    const program = try p.parse();
    defer {
        var prog = program;
        prog.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), program.metal.kernels.items.len);
}

test "parser: mixed PLAN + METAL in one file" {
    const src =
        \\state Idle { }
        \\kernel Main(input: Texture2D) -> void
        \\struct Vec3 { x: f32 }
    ;
    var p = legacy_parser.Parser.init(std.testing.allocator, src, "test.bp");
    const program = try p.parse();
    defer {
        var prog = program;
        prog.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), program.plan.states.items.len);
    try std.testing.expectEqual(@as(usize, 1), program.metal.kernels.items.len);
    try std.testing.expectEqual(@as(usize, 1), program.metal.struct_defs.count());
}

test "program architecture: common declarations only" {
    const src =
        \\struct Vec2 { x: f32, y: f32 }
        \\fn add(a: i64, b: i64) -> i64 { return a + b }
    ;
    var p = legacy_parser.Parser.init(std.testing.allocator, src, "test.bp");
    const program = try p.parse();
    defer {
        var prog = program;
        prog.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), program.metal.struct_defs.count());
    try std.testing.expectEqual(@as(usize, 1), program.metal.func_defs.items.len);
    try std.testing.expectEqual(@as(usize, 0), program.plan.states.items.len);
    try std.testing.expectEqual(@as(usize, 0), program.metal.kernels.items.len);
}

test "program architecture: plan declarations" {
    const src =
        \\state Active {
        \\    counter: i64 = 0
        \\    -> Idle [done]
        \\}
    ;
    var p = legacy_parser.Parser.init(std.testing.allocator, src, "test.bp");
    const program = try p.parse();
    defer {
        var prog = program;
        prog.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), program.metal.func_defs.items.len);
    try std.testing.expectEqual(@as(usize, 0), program.metal.struct_defs.count());
    try std.testing.expectEqual(@as(usize, 1), program.plan.states.items.len);
    try std.testing.expectEqual(@as(usize, 0), program.metal.kernels.items.len);
    try std.testing.expectEqualStrings("Active", program.plan.states.items[0].name);
}

test "program architecture: metal cpu function" {
    const src = "fn compute(x: i64) -> i64 { return x }";
    var p = legacy_parser.Parser.init(std.testing.allocator, src, "test.bp");
    const program = try p.parse();
    defer {
        var prog = program;
        prog.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), program.metal.func_defs.items.len);
    try std.testing.expectEqualStrings("compute", program.metal.func_defs.items[0].name);
    try std.testing.expectEqual(@as(usize, 0), program.plan.states.items.len);
    try std.testing.expectEqual(@as(usize, 0), program.metal.kernels.items.len);
}

test "program architecture: metal gpu kernel" {
    const src = "kernel Main(input: Texture2D) -> void";
    var p = legacy_parser.Parser.init(std.testing.allocator, src, "test.bp");
    const program = try p.parse();
    defer {
        var prog = program;
        prog.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), program.metal.func_defs.items.len);
    try std.testing.expectEqual(@as(usize, 0), program.plan.states.items.len);
    try std.testing.expectEqual(@as(usize, 1), program.metal.kernels.items.len);
    try std.testing.expectEqualStrings("Main", program.metal.kernels.items[0].name);
}

test "program architecture: all three sections populated" {
    const src =
        \\struct Config { width: u32, height: u32 }
        \\state Idle { }
        \\kernel Render(input: Texture2D) -> void
    ;
    var p = legacy_parser.Parser.init(std.testing.allocator, src, "test.bp");
    const program = try p.parse();
    defer {
        var prog = program;
        prog.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), program.metal.struct_defs.count());
    try std.testing.expectEqual(@as(usize, 1), program.plan.states.items.len);
    try std.testing.expectEqual(@as(usize, 1), program.metal.kernels.items.len);
    try std.testing.expectEqualStrings("Idle", program.plan.states.items[0].name);
    try std.testing.expectEqualStrings("Render", program.metal.kernels.items[0].name);
}

