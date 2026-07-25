const std = @import("std");
const events_mod = @import("events.zig");
const statement_mod = @import("statement.zig");
const expression_mod = @import("expression.zig");
const token_kind = @import("../token/token_kind.zig");
const kind_mod = @import("../kind/syntax_kind.zig");
const tokenKindToSyntaxKind = kind_mod.tokenKindToSyntaxKind;

pub const TokenKind = token_kind.TokenKind;
pub const EventSink = events_mod.EventSink;
pub const SyntaxKind = events_mod.SyntaxKind;
pub const StatementParser = statement_mod.StatementParser;

pub const DeclarationParser = struct {
    events: *EventSink,
    stmt_parser: StatementParser,

    pub fn init(events: *EventSink) DeclarationParser {
        return .{
            .events = events,
            .stmt_parser = StatementParser.init(events),
        };
    }

    pub fn parseItem(self: *DeclarationParser, stream: anytype) void {
        const kind = stream.current().kind;

        if (kind == .kw_fn) {
            self.parseFnDecl(stream);
        } else if (kind == .kw_struct) {
            self.parseStructDecl(stream);
        } else if (kind == .kw_enum) {
            self.parseEnumDecl(stream);
        } else if (kind == .kw_trait) {
            self.parseTraitDecl(stream);
        } else if (kind == .kw_impl) {
            self.parseImplDecl(stream);
        } else if (kind == .kw_type) {
            self.parseTypeAlias(stream);
        } else if (kind == .kw_import) {
            self.parseImportDecl(stream);
        } else if (kind == .kw_extern) {
            self.parseExternDecl(stream);
        } else {
            self.stmt_parser.parseStatement(stream);
        }
    }

    fn parseFnDecl(self: *DeclarationParser, stream: anytype) void {
        _ = self.events.startNode(.fn_decl);
        self.eatToken(stream);

        if (stream.at(.identifier)) self.eatToken(stream);

        _ = self.events.startNode(.param_list);
        self.eatToken(stream);
        while (!stream.at(.rparen) and !stream.at(.eof)) {
            const before = stream.positionAsU32();
            _ = self.events.startNode(.param);
            if (stream.at(.identifier) or stream.at(.kw_self) or stream.at(.kw_this)) {
                self.eatToken(stream);
            }
            if (stream.at(.colon)) {
                self.eatToken(stream);
                _ = self.events.startNode(.type_ref);
                self.parseTypeRef(stream);
                self.events.finishNode();
            }
            self.events.finishNode();
            if (stream.at(.comma)) self.eatToken(stream);
            _ = stream.recoverProgress(before);
        }
        if (stream.at(.rparen)) self.eatToken(stream);
        self.events.finishNode();

        if (stream.at(.arrow)) {
            self.eatToken(stream);
            _ = self.events.startNode(.type_ref);
            self.parseTypeRef(stream);
            self.events.finishNode();
        }

        if (stream.at(.lbrace)) {
            self.stmt_parser.parseBlockStatement(stream);
        } else if (stream.at(.semicolon)) {
            self.eatToken(stream);
        }

        self.events.finishNode();
    }

    fn parseStructDecl(self: *DeclarationParser, stream: anytype) void {
        _ = self.events.startNode(.struct_decl);
        self.eatToken(stream);

        if (stream.at(.identifier)) self.eatToken(stream);

        if (stream.at(.lbrace)) {
            self.eatToken(stream);
            while (!stream.at(.rbrace) and !stream.at(.eof)) {
                const before = stream.positionAsU32();
                _ = self.events.startNode(.field);
                if (stream.at(.identifier) or stream.at(.kw_pub)) {
                    self.eatToken(stream);
                }
                if (stream.at(.colon)) {
                    self.eatToken(stream);
                    _ = self.events.startNode(.type_ref);
                    self.parseTypeRef(stream);
                    self.events.finishNode();
                }
                self.events.finishNode();
                if (stream.at(.comma)) self.eatToken(stream);
                _ = stream.recoverProgress(before);
            }
            if (stream.at(.rbrace)) self.eatToken(stream);
        } else if (stream.at(.semicolon)) {
            self.eatToken(stream);
        }

        self.events.finishNode();
    }

    fn parseEnumDecl(self: *DeclarationParser, stream: anytype) void {
        _ = self.events.startNode(.enum_decl);
        self.eatToken(stream);

        if (stream.at(.identifier)) self.eatToken(stream);

        if (stream.at(.lbrace)) {
            self.eatToken(stream);
            _ = self.events.startNode(.variant_list);
            while (!stream.at(.rbrace) and !stream.at(.eof)) {
                const before = stream.positionAsU32();
                _ = self.events.startNode(.variant);
                if (stream.at(.identifier)) self.eatToken(stream);
                if (stream.at(.lparen)) {
                    self.eatToken(stream);
                    while (!stream.at(.rparen) and !stream.at(.eof)) {
                        const before2 = stream.positionAsU32();
                        _ = self.events.startNode(.type_ref);
                        self.parseTypeRef(stream);
                        self.events.finishNode();
                        if (stream.at(.comma)) self.eatToken(stream);
                        _ = stream.recoverProgress(before2);
                    }
                    if (stream.at(.rparen)) self.eatToken(stream);
                }
                self.events.finishNode();
                if (stream.at(.comma)) self.eatToken(stream);
                _ = stream.recoverProgress(before);
            }
            self.events.finishNode();
            if (stream.at(.rbrace)) self.eatToken(stream);
        }

        self.events.finishNode();
    }

    fn parseTraitDecl(self: *DeclarationParser, stream: anytype) void {
        _ = self.events.startNode(.trait_decl);
        self.eatToken(stream);

        if (stream.at(.identifier)) self.eatToken(stream);

        if (stream.at(.lbrace)) {
            self.eatToken(stream);
            while (!stream.at(.rbrace) and !stream.at(.eof)) {
                const before = stream.positionAsU32();
                self.parseFnDecl(stream);
                _ = stream.recoverProgress(before);
            }
            if (stream.at(.rbrace)) self.eatToken(stream);
        }

        self.events.finishNode();
    }

    fn parseImplDecl(self: *DeclarationParser, stream: anytype) void {
        _ = self.events.startNode(.impl_decl);
        self.eatToken(stream);

        if (stream.at(.identifier) or stream.at(.kw_self)) {
            self.eatToken(stream);
        }

        if (stream.at(.kw_for)) {
            self.eatToken(stream);
            if (stream.at(.identifier)) self.eatToken(stream);
        }

        if (stream.at(.lbrace)) {
            self.eatToken(stream);
            while (!stream.at(.rbrace) and !stream.at(.eof)) {
                const before = stream.positionAsU32();
                self.parseFnDecl(stream);
                _ = stream.recoverProgress(before);
            }
            if (stream.at(.rbrace)) self.eatToken(stream);
        }

        self.events.finishNode();
    }

    fn parseTypeAlias(self: *DeclarationParser, stream: anytype) void {
        _ = self.events.startNode(.type_decl);
        self.eatToken(stream);

        if (stream.at(.identifier)) self.eatToken(stream);

        if (stream.at(.eq)) {
            self.eatToken(stream);
            _ = self.events.startNode(.type_ref);
            self.parseTypeRef(stream);
            self.events.finishNode();
        }

        if (stream.at(.semicolon)) self.eatToken(stream);
        self.events.finishNode();
    }

    fn parseImportDecl(self: *DeclarationParser, stream: anytype) void {
        _ = self.events.startNode(.import_decl);
        self.eatToken(stream);

        if (stream.at(.string_literal)) self.eatToken(stream);

        if (stream.at(.kw_as)) {
            self.eatToken(stream);
            if (stream.at(.identifier)) self.eatToken(stream);
        }

        if (stream.at(.semicolon)) self.eatToken(stream);
        self.events.finishNode();
    }

    fn parseExternDecl(self: *DeclarationParser, stream: anytype) void {
        _ = self.events.startNode(.fn_decl);
        self.eatToken(stream);

        if (stream.at(.kw_fn)) self.eatToken(stream);
        if (stream.at(.identifier)) self.eatToken(stream);

        _ = self.events.startNode(.param_list);
        self.eatToken(stream);
        while (!stream.at(.rparen) and !stream.at(.eof)) {
            const before = stream.positionAsU32();
            _ = self.events.startNode(.param);
            if (stream.at(.identifier)) self.eatToken(stream);
            if (stream.at(.colon)) {
                self.eatToken(stream);
                _ = self.events.startNode(.type_ref);
                self.parseTypeRef(stream);
                self.events.finishNode();
            }
            self.events.finishNode();
            if (stream.at(.comma)) self.eatToken(stream);
            _ = stream.recoverProgress(before);
        }
        if (stream.at(.rparen)) self.eatToken(stream);
        self.events.finishNode();

        if (stream.at(.arrow)) {
            self.eatToken(stream);
            _ = self.events.startNode(.type_ref);
            self.parseTypeRef(stream);
            self.events.finishNode();
        }

        if (stream.at(.semicolon)) self.eatToken(stream);
        self.events.finishNode();
    }

    fn parseTypeRef(self: *DeclarationParser, stream: anytype) void {
        if (stream.at(.identifier) or stream.at(.kw_bool) or stream.at(.kw_i8) or
            stream.at(.kw_i16) or stream.at(.kw_i32) or stream.at(.kw_i64) or
            stream.at(.kw_u8) or stream.at(.kw_u16) or stream.at(.kw_u32) or
            stream.at(.kw_u64) or stream.at(.kw_f32) or stream.at(.kw_f64) or
            stream.at(.kw_string) or stream.at(.kw_void) or stream.at(.kw_any))
        {
            self.eatToken(stream);
        }
    }

    fn eatToken(self: *DeclarationParser, stream: anytype) void {
        const tok = stream.current();
        self.events.addToken(tokenKindToSyntaxKind(tok.kind), tok.text, tok.span.start, tok.span.end);
        _ = stream.advance();
        stream.skipTrivia();
    }
};
