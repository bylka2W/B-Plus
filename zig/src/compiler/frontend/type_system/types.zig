const std = @import("std");
const ids = @import("../foundation/ids/ids.zig");

pub const TypeId = ids.TypeId;
pub const SymbolId = ids.SymbolId;
pub const DefId = ids.DefId;

pub const INVALID: TypeId = TypeId.INVALID;

pub const BuiltinKind = enum(u8) {
    bool_type,
    i8_type,
    i16_type,
    i32_type,
    i64_type,
    u8_type,
    u16_type,
    u32_type,
    u64_type,
    f32_type,
    f64_type,
    void_type,
    never_type,
    str_type,
    char_type,
};

pub const TypeVarId = struct {
    index: u32,
    pub const INVALID = TypeVarId{ .index = std.math.maxInt(u32) };
    pub fn new(idx: u32) TypeVarId { return .{ .index = idx }; }
    pub fn isValid(self: TypeVarId) bool { return self.index != std.math.maxInt(u32); }
};

pub const Mutability = enum { @"const", mut };

pub const TypeData = union(enum) {
    builtin: BuiltinKind,
    adt: AdtTy,
    pointer: PointerTy,
    slice: SliceTy,
    array: ArrayTy,
    tuple: TupleTy,
    fn_ptr: FnPtrTy,
    reference: ReferenceTy,
    optional: OptionalTy,
    error_union: ErrorUnionTy,
    type_param: TypeParamTy,
    infer_var: InferVarData,
    resolved_var: TypeId,
    never: void,
    unit: void,
    error_type: void,

    pub const AdtTy = struct {
        def_id: DefId,
        args: []const TypeId,
    };

    pub const PointerTy = struct {
        mutable: Mutability,
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

    pub const FnPtrTy = struct {
        params: []const TypeId,
        ret: TypeId,
        is_variadic: bool,
    };

    pub const ReferenceTy = struct {
        mutable: Mutability,
        referent: TypeId,
    };

    pub const OptionalTy = struct {
        inner: TypeId,
    };

    pub const ErrorUnionTy = struct {
        ok: TypeId,
        err: TypeId,
    };

    pub const TypeParamTy = struct {
        index: u32,
        name: SymbolId,
    };

    pub const InferVarData = struct {
        var_id: TypeVarId,
    };

    pub fn format(self: TypeData, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .builtin => |b| try writer.print("{s}", .{@tagName(b)}),
            .adt => |a| try writer.print("Adt({d})", .{a.def_id.index}),
            .pointer => |p| {
                if (p.mutable == .mut) try writer.print("*mut {d}", .{p.pointee.index})
                else try writer.print("*{d}", .{p.pointee.index});
            },
            .slice => |s| try writer.print("[{d}]", .{s.element.index}),
            .array => |a| try writer.print("[{d}; {d}]", .{ a.element.index, a.length }),
            .tuple => |t| try writer.print("({d} params)", .{t.elements.len}),
            .fn_ptr => |f| try writer.print("fn({d}) -> {d}", .{ f.params.len, f.ret.index }),
            .reference => |r| {
                if (r.mutable == .mut) try writer.print("&mut {d}", .{r.referent.index})
                else try writer.print("&{d}", .{r.referent.index});
            },
            .optional => |o| try writer.print("{d}?", .{o.inner.index}),
            .error_union => |eu| try writer.print("{d}!{d}", .{ eu.ok.index, eu.err.index }),
            .type_param => |tp| try writer.print("T({d})", .{tp.index}),
            .infer_var => |v| try writer.print("?{d}", .{v.var_id.index}),
            .resolved_var => |r| try writer.print("=Type({d})", .{r.index}),
            .never => try writer.print("!", .{}),
            .unit => try writer.print("()", .{}),
            .error_type => try writer.print("<<error>>", .{}),
        }
    }

    pub fn eql(self: TypeData, other: TypeData) bool {
        if (@as(TypeData.Tag, self) != other) return false;
        return switch (self) {
            .builtin => |b| b == other.builtin,
            .adt => |a| a.def_id.eql(other.adt.def_id) and a.args.len == other.adt.args.len,
            .pointer => |p| p.mutable == other.pointer.mutable and p.pointee.eql(other.pointer.pointee),
            .slice => |s| s.element.eql(other.slice.element),
            .array => |a| a.element.eql(other.array.element) and a.length == other.array.length,
            .tuple => |t| t.elements.len == other.tuple.elements.len,
            .fn_ptr => |f| f.params.len == other.fn_ptr.params.len and f.ret.eql(other.fn_ptr.ret) and f.is_variadic == other.fn_ptr.is_variadic,
            .reference => |r| r.mutable == other.reference.mutable and r.referent.eql(other.reference.referent),
            .optional => |o| o.inner.eql(other.optional.inner),
            .error_union => |eu| eu.ok.eql(other.error_union.ok) and eu.err.eql(other.error_union.err),
            .type_param => |tp| tp.index == other.type_param.index and tp.name.eql(other.type_param.name),
            .infer_var => |v| v.var_id.index == other.infer_var.var_id.index,
            .resolved_var => |r| r.eql(other.resolved_var),
            .never, .unit, .error_type => true,
        };
    }
};
