const std = @import("std");
const events_mod = @import("events.zig");
const declaration_mod = @import("declaration.zig");
const statement_mod = @import("statement.zig");
const expression_mod = @import("expression.zig");
const type_parser_mod = @import("type_parser.zig");
const pattern_mod = @import("pattern.zig");
const recovery_mod = @import("recovery.zig");
const green_tree_mod = @import("../green/green_tree.zig");
const green_node_mod = @import("../green/green_node.zig");
const token_stream_mod = @import("../token/token_stream.zig");
const token_kind = @import("../token/token_kind.zig");
const kind_mod = @import("../kind/syntax_kind.zig");

pub const TokenKind = token_kind.TokenKind;
pub const EventSink = events_mod.EventSink;
pub const SyntaxKind = green_node_mod.SyntaxKind;
pub const GreenNode = green_node_mod.GreenNode;
pub const GreenTree = green_tree_mod.GreenTree;
pub const TokenStream = token_stream_mod.TokenStream;
const tokenKindToSyntaxKind = kind_mod.tokenKindToSyntaxKind;

pub const Parser = struct {
    stream: *TokenStream,
    events: *EventSink,
    allocator: std.mem.Allocator,
    diagnostics: recovery_mod.DiagnosticSink,
    decl_parser: declaration_mod.DeclarationParser,

    pub fn init(stream: *TokenStream, allocator: std.mem.Allocator) Parser {
        const events = allocator.create(EventSink) catch unreachable;
        events.* = EventSink.init(allocator);
        var parser = Parser{
            .stream = stream,
            .events = events,
            .allocator = allocator,
            .diagnostics = recovery_mod.DiagnosticSink.init(allocator),
            .decl_parser = undefined,
        };
        parser.decl_parser = declaration_mod.DeclarationParser.init(events);
        return parser;
    }

    pub fn deinit(self: *Parser) void {
        self.events.deinit();
        self.allocator.destroy(self.events);
        self.diagnostics.deinit();
    }

    pub fn parse(self: *Parser, tree: *GreenTree) !*GreenNode {
        self.stream.skipTrivia();

        while (!self.stream.at(.eof)) {
            const before = self.stream.positionAsU32();
            self.decl_parser.parseItem(self.stream);
            _ = self.stream.recoverProgress(before);
        }

        return self.events.build(tree, .source_file);
    }

    pub fn parsePartial(self: *Parser, tree: *GreenNode, tree_ctx: *GreenTree) !*GreenNode {
        _ = tree;
        return self.parse(tree_ctx);
    }

    pub fn hasErrors(self: *const Parser) bool {
        return self.diagnostics.hasErrors();
    }

    pub fn errorCount(self: *const Parser) u32 {
        return self.diagnostics.errorCount();
    }

    pub fn eventSink(self: *Parser) *EventSink {
        return self.events;
    }

    pub fn eatCurrentToken(self: *Parser) void {
        const tok = self.stream.current();
        self.events.addToken(tokenKindToSyntaxKind(tok.kind), tok.text, tok.span.start, tok.span.end);
        _ = self.stream.advance();
        self.stream.skipTrivia();
    }

    pub fn expectToken(self: *Parser, kind: TokenKind) void {
        if (self.stream.at(kind)) {
            self.eatCurrentToken();
        } else {
            self.diagnostics.pushMessage("unexpected token", self.stream.current().span.start, self.stream.current().span.end, .@"error");
        }
    }

    pub fn startNode(self: *Parser, kind: SyntaxKind) void {
        _ = self.events.startNode(kind);
    }

    pub fn finishNode(self: *Parser) void {
        self.events.finishNode();
    }
};

pub fn parseSource(allocator: std.mem.Allocator, stream: *TokenStream, tree: *GreenTree) !*GreenNode {
    var parser = Parser.init(stream, allocator);
    defer parser.deinit();
    return parser.parse(tree);
}

pub fn parseFile(allocator: std.mem.Allocator, source: []const u8, file_id: u32, tree: *GreenTree) !*GreenNode {
    var stream = TokenStream.init(allocator);
    defer stream.deinit();

    var lex_source = @import("../lexer/scanner.zig").Lexer.init(source, file_id, allocator);
    defer lex_source.deinit();

    const tokens = try lex_source.lex();
    for (tokens.items) |tok| {
        try stream.append(tok);
    }

    var parser = Parser.init(&stream, allocator);
    defer parser.deinit();

    return parser.parse(tree);
}
