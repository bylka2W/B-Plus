const std = @import("std");
const ids = @import("../foundation/ids/ids.zig");

pub const TypeId = ids.TypeId;
pub const SymbolId = ids.SymbolId;

pub const HirTy = union(enum) {
    builtin: BuiltinTy,
    named: NamedTy,
    pointer: PointerTy,
    slice: SliceTy,
    array: ArrayTy,
    tuple: TupleTy,
    fn_type: FnTy,
    generic: GenericTy,
    inference_var: InferenceVar,
    error_union: ErrorUnionTy,
    optional: OptionalTy,
    missing: MissingTy,

    pub const BuiltinTy = struct {
        kind: BuiltinKind,
    };

    pub const BuiltinKind = enum {
        bool,
        i8,
        i16,
        i32,
        i64,
        u8,
        u16,
        u32,
        u64,
        f32,
        f64,
        void_type,
        never,
        str,
        char_type,
    };

    pub const NamedTy = struct {
        name: SymbolId,
        args: []const TypeId,
    };

    pub const PointerTy = struct {
        mutable: bool,
        pointee: TypeId,
    };

    pub const SliceTy = struct {
        element: TypeId,
    };

    pub const ArrayTy = struct {
        element: TypeId,
        length: u64,
    };

    pub const TupleTy = struct {
        elements: []const TypeId,
    };

    pub const FnTy = struct {
        params: []const TypeId,
        ret: TypeId,
    };

    pub const GenericTy = struct {
        name: SymbolId,
    };

    pub const InferenceVar = struct {
        id: u32,
    };

    pub const ErrorUnionTy = struct {
        ok: TypeId,
        err: TypeId,
    };

    pub const OptionalTy = struct {
        inner: TypeId,
    };

    pub const MissingTy = struct {};

    pub fn format(self: HirTy, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .builtin => |b| try writer.print("{s}", .{@tagName(b.kind)}),
            .named => |n| try writer.print("{d}", .{n.name.index}),
            .pointer => |p| {
                if (p.mutable) {
                    try writer.print("*mut {d}", .{p.pointee.index});
                } else {
                    try writer.print("*{d}", .{p.pointee.index});
                }
            },
            .slice => |s| try writer.print("[{d}]", .{s.element.index}),
            .array => |a| try writer.print("[{d}; {d}]", .{ a.element.index, a.length }),
            .tuple => |t| try writer.print("({d}...)", .{t.elements.len}),
            .fn_type => |f| try writer.print("fn({d}) {d}", .{ f.params.len, f.ret.index }),
            .generic => |g| try writer.print("T({d})", .{g.name.index}),
            .inference_var => |v| try writer.print("?{d}", .{v.id}),
            .error_union => |eu| try writer.print("{d}!{d}", .{ eu.ok.index, eu.err.index }),
            .optional => |o| try writer.print("{d}?", .{o.inner.index}),
            .missing => try writer.print("<<missing>>", .{}),
        }
    }
};
