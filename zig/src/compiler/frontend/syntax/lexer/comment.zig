const cursor_mod = @import("cursor.zig");
const Cursor = cursor_mod.Cursor;

pub const CommentKind = enum {
    line,
    block,
    doc_line,
    doc_block,
};

pub const Comment = struct {
    kind: CommentKind,
    start: u32,
    end: u32,
};

pub fn skipLineComment(cursor: *Cursor) Comment {
    const start: u32 = @intCast(cursor.pos);
    cursor.skipLineComment();
    return .{ .kind = .line, .start = start, .end = @intCast(cursor.pos) };
}

pub fn skipBlockComment(cursor: *Cursor) Comment {
    const start: u32 = @intCast(cursor.pos);
    const is_doc = cursor.peekAhead(2) == '!';
    cursor.skipBlockComment();
    return .{
        .kind = if (is_doc) .doc_block else .block,
        .start = start,
        .end = @intCast(cursor.pos),
    };
}

pub fn skipDocCommentLine(cursor: *Cursor) Comment {
    const start: u32 = @intCast(cursor.pos);
    cursor.skipLineComment();
    return .{ .kind = .doc_line, .start = start, .end = @intCast(cursor.pos) };
}
