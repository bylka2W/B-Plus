const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const ast = @import("ast.zig");
const Token = tokenizer.Token;
const TokenType = tokenizer.TokenType;

pub const Parser = struct {
    tokens: []const Token,
    pos: usize,
    source: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(tokens: []const Token, source: []const u8, allocator: std.mem.Allocator) Parser {
        return .{ .tokens = tokens, .pos = 0, .source = source, .allocator = allocator };
    }

    fn peek(p: *Parser) TokenType {
        if (p.pos >= p.tokens.len) return .eof;
        return p.tokens[p.pos].ttype;
    }

    fn peekToken(p: *Parser) Token {
        return p.tokens[p.pos];
    }

    fn advance(p: *Parser) Token {
        const t = p.tokens[p.pos];
        p.pos += 1;
        return t;
    }

    fn expect(p: *Parser, tt: TokenType) !Token {
        if (p.pos >= p.tokens.len or p.tokens[p.pos].ttype != tt) {
            return error.UnexpectedToken;
        }
        return p.advance();
    }

    fn tokenText(p: *Parser, t: Token) []const u8 {
        return p.source[t.start .. t.start + t.len];
    }

    fn maybe(p: *Parser, tt: TokenType) bool {
        if (p.pos < p.tokens.len and p.tokens[p.pos].ttype == tt) {
            p.pos += 1;
            return true;
        }
        return false;
    }

    pub fn parseProgram(p: *Parser) !ast.Program {
        var prog = ast.Program{
            .allocator = p.allocator,
            .entry = null,
            .start_state = "",
            .context_vars = std.ArrayList(ast.VarDecl).init(p.allocator),
            .states = std.ArrayList(ast.StateDecl).init(p.allocator),
            .fns = std.ArrayList(ast.FnDecl).init(p.allocator),
            .structs = std.ArrayList(ast.StructDecl).init(p.allocator),
            .kernels = std.ArrayList(ast.ComputeKernel).init(p.allocator),
        };
        while (p.pos < p.tokens.len and p.peek() != .eof) {
            switch (p.peek()) {
                .at => {
                    _ = p.advance();
                },
                .keyword_entry => {
                    prog.entry = try p.parseEntry();
                },
                .keyword_state => {
                    const state = try p.parseState();
                    try prog.states.append(state);
                },
                .keyword_compute_kernel => {
                    const k = try p.parseComputeKernel();
                    try prog.kernels.append(k);
                },
                .keyword_struct => {
                    const s = try p.parseStructDecl();
                    try prog.structs.append(s);
                },
                .keyword_fn, .keyword_inline => {
                    const f = try p.parseFnDecl(false);
                    try prog.fns.append(f);
                },
                else => {
                    return error.UnexpectedToken;
                },
            }
        }
        return prog;
    }

    fn parseEntry(p: *Parser) !ast.EntryDecl {
        _ = try p.expect(.keyword_entry);
        const nameTok = try p.expect(.ident);
        _ = try p.expect(.lparen);
        _ = try p.expect(.rparen);
        const name = p.tokenText(nameTok);
        var body = std.ArrayList(ast.Stmt).init(p.allocator);
        if (p.peek() == .lbrace) {
            const content = try p.extractBracedContent();
            body = p.parseBodyStmtsFromSource(content);
        }
        return ast.EntryDecl{ .name = name, .body = body };
    }

    fn parsePrint(p: *Parser) !ast.Stmt {
        _ = try p.expect(.keyword_print);
        _ = try p.expect(.lparen);
        const expr = try p.parseExpr();
        _ = try p.expect(.rparen);
        return ast.Stmt{ .kind = .print, .print_arg = expr };
    }

    fn parseVarDecl(p: *Parser) !ast.Stmt {
        _ = try p.expect(.keyword_var);
        const nameTok = try p.expect(.ident);
        const name = p.tokenText(nameTok);
        var vtype: []const u8 = "inferred";
        if (p.peek() == .colon) {
            _ = p.advance();
            const typeTok = try p.expect(.ident);
            vtype = p.tokenText(typeTok);
        }
        var var_init: ?*ast.Expr = null;
        if (p.peek() == .assign) {
            _ = p.advance();
            var_init = try p.parseExpr();
        }
        return ast.Stmt{ .kind = .var_decl, .var_name = name, .var_type = vtype, .var_init = var_init };
    }

    fn parseIf(p: *Parser) !ast.Stmt {
        _ = try p.expect(.keyword_if);
        _ = try p.expect(.lparen);
        const cond = try p.parseExpr();
        _ = try p.expect(.rparen);
        var then_body = std.ArrayList(ast.Stmt).init(p.allocator);
        if (p.peek() == .lbrace) {
            const content = try p.extractBracedContent();
            then_body = p.parseBodyStmtsFromSource(content);
        }
        var else_body = std.ArrayList(ast.Stmt).init(p.allocator);
        if (p.peek() == .keyword_else) {
            _ = p.advance();
            if (p.peek() == .lbrace) {
                const content = try p.extractBracedContent();
                else_body = p.parseBodyStmtsFromSource(content);
            }
        }
        return ast.Stmt{ .kind = .if_stmt, .condition = cond, .then_body = then_body, .else_body = else_body };
    }

    fn parseWhile(p: *Parser) !ast.Stmt {
        _ = try p.expect(.keyword_while);
        _ = try p.expect(.lparen);
        const cond = try p.parseExpr();
        _ = try p.expect(.rparen);
        var stmts = std.ArrayList(ast.Stmt).init(p.allocator);
        if (p.peek() == .lbrace) {
            const content = try p.extractBracedContent();
            stmts = p.parseBodyStmtsFromSource(content);
        }
        return ast.Stmt{ .kind = .while_stmt, .condition = cond, .stmts = stmts };
    }

    fn parseFor(p: *Parser) !ast.Stmt {
        _ = try p.expect(.keyword_for);
        const nameTok = try p.expect(.ident);
        const name = p.tokenText(nameTok);
        var stmts = std.ArrayList(ast.Stmt).init(p.allocator);
        if (p.peek() == .lbrace) {
            const content = try p.extractBracedContent();
            stmts = p.parseBodyStmtsFromSource(content);
        }
        return ast.Stmt{ .kind = .for_stmt, .assign_name = name, .stmts = stmts };
    }

    fn parseReturn(p: *Parser) !ast.Stmt {
        _ = try p.expect(.keyword_return);
        var expr: ?*ast.Expr = null;
        if (p.peek() != .eof and !isBlockEnd(p.peek())) {
            expr = try p.parseExpr();
        }
        return ast.Stmt{ .kind = .return_stmt, .return_expr = expr };
    }

    fn parseExprStmt(p: *Parser) !ast.Stmt {
        const expr = try p.parseExpr();
        return ast.Stmt{ .kind = .expr_stmt, .expr = expr };
    }

    fn parseState(p: *Parser) !ast.StateDecl {
        _ = try p.expect(.keyword_state);
        const nameTok = try p.expect(.ident);
        const name = p.tokenText(nameTok);
        _ = try p.expect(.lbrace);
        var vars = std.ArrayList(ast.VarDecl).init(p.allocator);
        var transitions = std.ArrayList(ast.Transition).init(p.allocator);
        while (p.pos < p.tokens.len and p.peek() != .rbrace) {
            if (p.peek() == .keyword_var or p.peek() == .keyword_volatile or p.peek() == .keyword_fixed) {
                if (p.peek() == .keyword_volatile or p.peek() == .keyword_fixed) _ = p.advance();
                const vd = try p.parseVarDeclInState();
                try vars.append(vd);
            } else if (p.peek() == .keyword_on) {
                const tr = try p.parseTransition();
                try transitions.append(tr);
            } else if (p.peek() == .keyword_inline or p.peek() == .keyword_fn) {
                const fd = try p.parseFnDecl(true);
                try transitions.append(.{ .event = "fn", .target = fd.name, .body = fd.body });
            } else if (p.peek() == .semicolon) {
                _ = p.advance();
            } else {
                break;
            }
        }
        _ = try p.expect(.rbrace);
        return ast.StateDecl{ .name = name, .vars = vars, .actions = std.ArrayList(ast.ActionDecl).init(p.allocator), .transitions = transitions };
    }

    fn parseVarDeclInState(p: *Parser) !ast.VarDecl {
        _ = try p.expect(.keyword_var);
        const nameTok = try p.expect(.ident);
        const name = p.tokenText(nameTok);
        var vtype: []const u8 = "inferred";
        if (p.peek() == .colon) {
            _ = p.advance();
            const typeTok = try p.expect(.ident);
            vtype = p.tokenText(typeTok);
        }
        var var_init: ?*ast.Expr = null;
        if (p.peek() == .assign) {
            _ = p.advance();
            var_init = try p.parseExpr();
        }
        return ast.VarDecl{ .name = name, .var_type = vtype, .init = var_init };
    }

    fn parseTransition(p: *Parser) !ast.Transition {
        _ = try p.expect(.keyword_on);
        const eventTok = try p.expect(.ident);
        const event = p.tokenText(eventTok);
        const guard: []const u8 = "";
        var guard_stmts = std.ArrayList(ast.Stmt).init(p.allocator);
        if (p.peek() == .lsquare) {
            _ = p.advance();
            const expr = p.parseExpr() catch null;
            if (expr) |e| {
                guard_stmts.append(.{ .kind = .expr_stmt, .expr = e }) catch {};
            }
            _ = p.expect(.rsquare) catch {};
        }
        var target: []const u8 = "";
        if (p.peek() == .arrow) {
            _ = p.advance();
            if (p.peek() == .lbrace) {} else {
                const targetTok = try p.expect(.ident);
                target = p.tokenText(targetTok);
            }
        }
        var body: []const u8 = "";
        var body_stmts = std.ArrayList(ast.Stmt).init(p.allocator);
        if (p.peek() == .lbrace) {
            body = try p.extractBracedContent();
            body_stmts = p.parseBodyStmtsFromSource(body);
        }
        return ast.Transition{ .event = event, .target = target, .guard = guard, .guard_stmts = guard_stmts, .body = body, .body_stmts = body_stmts };
    }


pub fn parseBodyStmtsFromSourceText(src: []const u8, allocator: std.mem.Allocator) std.ArrayList(ast.Stmt) {
    const tokens = tokenizer.tokenizeFull(src, allocator) catch return std.ArrayList(ast.Stmt).init(allocator);
    if (tokens.len == 0) return std.ArrayList(ast.Stmt).init(allocator);
    var sub = Parser.init(tokens, src, allocator);
    var stmts = std.ArrayList(ast.Stmt).init(allocator);
    while (sub.pos < sub.tokens.len) {
        const tt = sub.peek();
        if (tt == .eof) break;
        switch (tt) {
            .keyword_print => { const s = sub.parsePrint() catch break; stmts.append(s) catch {}; },
            .keyword_return => { const s = sub.parseReturn() catch break; stmts.append(s) catch {}; },
            .keyword_var => { const s = sub.parseVarDecl() catch break; stmts.append(s) catch {}; },
            .keyword_if => { const s = sub.parseIf() catch break; stmts.append(s) catch {}; },
            .keyword_while => { const s = sub.parseWhile() catch break; stmts.append(s) catch {}; },
            .keyword_for => { const s = sub.parseFor() catch break; stmts.append(s) catch {}; },
            else => {
                var compound = false;
                if (sub.pos + 2 < sub.tokens.len and sub.tokens[sub.pos].ttype == .ident) {
                    const plus_assign = sub.tokens[sub.pos + 1].ttype == .plus and sub.tokens[sub.pos + 2].ttype == .assign;
                    const minus_assign = sub.tokens[sub.pos + 1].ttype == .minus and sub.tokens[sub.pos + 2].ttype == .assign;
                    if (plus_assign or minus_assign) {
                        const nameTok = sub.advance();
                        _ = sub.advance(); // '+' or '-'
                        _ = sub.expect(.assign) catch break;
                        const expr = sub.parseExpr() catch break;
                        const op = if (plus_assign) "+=" else "-=";
                        stmts.append(ast.Stmt{ .kind = .assign, .assign_name = sub.tokenText(nameTok), .assign_op = op, .assign_expr = expr }) catch {};
                        compound = true;
                    }
                }
                if (!compound) {
                    if (sub.pos < sub.tokens.len and sub.tokens[sub.pos].ttype == .lbrace) {
                        const content = sub.extractBracedContent() catch break;
                        const blockStmts = parseBodyStmtsFromSourceText(content, allocator);
                        stmts.append(.{ .kind = .block, .stmts = blockStmts }) catch {};
                    } else if (sub.pos + 1 < sub.tokens.len and sub.tokens[sub.pos].ttype == .ident and sub.tokens[sub.pos + 1].ttype == .assign) {
                        const nameTok = sub.advance();
                        _ = sub.advance();
                        const expr = sub.parseExpr() catch break;
                        stmts.append(ast.Stmt{ .kind = .assign, .assign_name = sub.tokenText(nameTok), .assign_op = "=", .assign_expr = expr }) catch {};
                    } else {
                        const expr = sub.parseExpr() catch { _ = sub.advance(); continue; };
                        if (sub.peek() == .assign) {
                            _ = sub.advance();
                            const rhs = sub.parseExpr() catch break;
                            if (expr) |e| {
                                if (e.kind == .ident) {
                                    stmts.append(ast.Stmt{ .kind = .assign, .assign_name = e.ident, .assign_op = "=", .assign_expr = rhs }) catch {};
                                }
                            }
                        } else {
                            if (expr) |e| {
                                stmts.append(ast.Stmt{ .kind = .expr_stmt, .expr = e }) catch {};
                            }
                        }
                    }
                }
                if (sub.peek() == .semicolon) _ = sub.advance();
            },
        }
    }
    return stmts;
}

fn parseBodyStmtsFromSource(p: *Parser, src: []const u8) std.ArrayList(ast.Stmt) {
    return parseBodyStmtsFromSourceText(src, p.allocator);
}

    fn extractBracedContent(p: *Parser) ![]const u8 {
        const startTok = p.peekToken();
        _ = try p.expect(.lbrace);
        const start = startTok.start + 1;
        var depth: usize = 1;
        var end: usize = start;
        while (p.pos < p.tokens.len and depth > 0) {
            const tok = p.advance();
            if (tok.ttype == .lbrace) depth += 1;
            if (tok.ttype == .rbrace) depth -= 1;
            if (depth > 0) end = tok.start + tok.len;
        }
        return p.source[start..end];
    }

    fn parseFnDecl(p: *Parser, consumed_keyword: bool) !ast.FnDecl {
        const is_inline = if (!consumed_keyword and p.peek() == .keyword_inline) blk: {
            _ = p.advance();
            break :blk true;
        } else false;
        if (!consumed_keyword) _ = try p.expect(.keyword_fn);
        const nameTok = try p.expect(.ident);
        const name = p.tokenText(nameTok);
        _ = try p.expect(.lparen);
        var params = std.ArrayList(ast.Param).init(p.allocator);
        if (p.peek() != .rparen) {
            while (true) {
                const pnTok = try p.expect(.ident);
                const pn = p.tokenText(pnTok);
                var pt: []const u8 = "inferred";
                if (p.peek() == .colon) {
                    _ = p.advance();
                    const ptTok = try p.expect(.ident);
                    pt = p.tokenText(ptTok);
                }
                try params.append(ast.Param{ .name = pn, .ptype = pt });
                if (p.peek() == .comma) { _ = p.advance(); } else break;
            }
        }
        _ = try p.expect(.rparen);
        var ret_type: []const u8 = "void";
        if (p.peek() == .colon) {
            _ = p.advance();
            const rtTok = try p.expect(.ident);
            ret_type = p.tokenText(rtTok);
        }
        var body: []const u8 = "";
        if (p.peek() == .lbrace) {
            body = try p.extractBracedContent();
        } else if (p.peek() == .semicolon) {
            _ = p.advance();
        }
        return ast.FnDecl{ .name = name, .is_inline = is_inline, .return_type = ret_type, .params = params, .body = body };
    }

    fn parseStructDecl(p: *Parser) !ast.StructDecl {
        _ = try p.expect(.keyword_struct);
        const nameTok = try p.expect(.ident);
        const name = p.tokenText(nameTok);
        _ = try p.expect(.lbrace);
        var fields = std.ArrayList(ast.Field).init(p.allocator);
        while (p.pos < p.tokens.len and p.peek() != .rbrace) {
            if (p.peek() == .keyword_var) _ = p.advance();
            const fnTok = try p.expect(.ident);
            const fnName = p.tokenText(fnTok);
            var ft: []const u8 = "inferred";
            if (p.peek() == .colon) {
                _ = p.advance();
                const ftTok = try p.expect(.ident);
                ft = p.tokenText(ftTok);
            }
            try fields.append(ast.Field{ .name = fnName, .ftype = ft });
            if (p.peek() == .semicolon) _ = p.advance();
        }
        _ = try p.expect(.rbrace);
        return ast.StructDecl{ .name = name, .fields = fields };
    }

    fn parseComputeKernel(p: *Parser) !ast.ComputeKernel {
        _ = try p.expect(.keyword_compute_kernel);
        const nameTok = try p.expect(.ident);
        const name = p.tokenText(nameTok);
        const body = try p.extractBracedContent();
        return ast.ComputeKernel{ .name = name, .body = body };
    }

    fn isBlockEnd(tt: TokenType) bool {
        return switch (tt) {
            .rbrace, .rparen, .keyword_state, .keyword_entry, .keyword_compute_kernel, .keyword_struct, .keyword_fn, .keyword_inline, .eof => true,
            else => false,
        };
    }

    fn parseExpr(p: *Parser) anyerror!?*ast.Expr {
        return p.parseBinary(0);
    }

    fn parseBinary(p: *Parser, min_prec: usize) anyerror!?*ast.Expr {
        var left = try p.parsePrimary();
        if (left == null) return null;
        while (p.pos < p.tokens.len) {
            if (!isBinaryOp(p.peek())) break;
            const prec = precedence(p.peek());
            if (prec < min_prec) break;
            const opTok = p.advance();
            const opText = opTextFromToken(opTok.ttype);
            const right = try p.parseBinary(prec + 1);
            if (right == null) return left;
            const node = try p.allocator.create(ast.Expr);
            node.* = .{
                .kind = .binary,
                .left = left,
                .right = right,
                .op = opText,
            };
            left = node;
        }
        return left;
    }

    fn parsePrimary(p: *Parser) !?*ast.Expr {
        const tt = p.peek();
        if (tt == .number) {
            const tok = p.advance();
            const text = p.tokenText(tok);
            const node = try p.allocator.create(ast.Expr);
            if (std.mem.indexOfScalar(u8, text, '.') != null) {
                node.* = .{ .kind = .literal, .literal = .{ .lit_type = .float, .float_val = try std.fmt.parseFloat(f64, text) } };
            } else {
                node.* = .{ .kind = .literal, .literal = .{ .lit_type = .int, .int_val = try std.fmt.parseInt(i64, text, 0) } };
            }
            return node;
        }
        if (tt == .string_lit) {
            const tok = p.advance();
            const text = p.tokenText(tok);
            const unquoted = text[1 .. text.len - 1];
            const node = try p.allocator.create(ast.Expr);
            node.* = .{ .kind = .literal, .literal = .{ .lit_type = .string, .string_val = unquoted } };
            return node;
        }
        if (tt == .keyword_true or tt == .keyword_false) {
            const tok = p.advance();
            const node = try p.allocator.create(ast.Expr);
            node.* = .{ .kind = .literal, .literal = .{ .lit_type = .boolean, .bool_val = tok.ttype == .keyword_true } };
            return node;
        }
        if (tt == .ident) {
            const tok = p.advance();
            const name = p.tokenText(tok);
            if (p.peek() == .lparen) {
                _ = p.advance();
                var args = std.ArrayList(*ast.Expr).init(p.allocator);
                if (p.peek() != .rparen) {
                    while (true) {
                        const arg = try p.parseExpr();
                        if (arg) |a| try args.append(a);
                        if (p.peek() == .comma) { _ = p.advance(); } else break;
                    }
                }
                _ = try p.expect(.rparen);
                const node = try p.allocator.create(ast.Expr);
                node.* = .{ .kind = .call, .callee = name, .args = args };
                return node;
            }
            if (p.peek() == .increment or p.peek() == .decrement) {
                const opTok = p.advance();
                const opText = if (opTok.ttype == .increment) "++" else "--";
                const node = try p.allocator.create(ast.Expr);
                node.* = .{ .kind = .postfix, .op = opText, .left = blk: {
                    const n = try p.allocator.create(ast.Expr);
                    n.* = .{ .kind = .ident, .ident = name };
                    break :blk n;
                } };
                return node;
            }
            const node = try p.allocator.create(ast.Expr);
            node.* = .{ .kind = .ident, .ident = name };
            return node;
        }
        if (tt == .minus or tt == .not) {
            _ = p.advance();
            const opText = if (tt == .minus) "-" else "!";
            const operand = try p.parsePrimary();
            if (operand) |op| {
                const node = try p.allocator.create(ast.Expr);
                node.* = .{ .kind = .unary, .op = opText, .right = op };
                return node;
            }
            return null;
        }
        if (tt == .lparen) {
            _ = p.advance();
            const expr = try p.parseExpr();
            _ = try p.expect(.rparen);
            return expr;
        }
        return null;
    }

    fn isBinaryOp(tt: TokenType) bool {
        return switch (tt) {
            .plus, .minus, .star, .slash, .percent,
            .amp, .pipe, .caret, .lshift, .rshift,
            .eq, .neq, .lt, .gt, .le, .ge,
            .and_op, .or_op => true,
            else => false,
        };
    }

    fn precedence(tt: TokenType) usize {
        return switch (tt) {
            .or_op => 1,
            .and_op => 2,
            .eq, .neq => 3,
            .lt, .gt, .le, .ge => 4,
            .pipe => 5,
            .caret => 6,
            .amp => 7,
            .lshift, .rshift => 8,
            .plus, .minus => 9,
            .star, .slash, .percent => 10,
            else => 0,
        };
    }

    fn opTextFromToken(tt: TokenType) []const u8 {
        return switch (tt) {
            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .amp => "&",
            .pipe => "|",
            .caret => "^",
            .lshift => "<<",
            .rshift => ">>",
            .eq => "==",
            .neq => "!=",
            .lt => "<",
            .gt => ">",
            .le => "<=",
            .ge => ">=",
            .and_op => "&&",
            .or_op => "||",
            else => "?",
        };
    }
};
