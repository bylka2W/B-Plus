const std = @import("std");
const ids = @import("../foundation/ids/ids.zig");
const SourceSpan = @import("../source/location/span.zig").SourceSpan;
const HirLiteral = @import("literal.zig").HirLiteral;

pub const PatId = ids.PatId;
pub const DefId = ids.DefId;
pub const TypeId = ids.TypeId;

pub const HirPattern = struct {
    span: SourceSpan,
    kind: HirPatternKind,

    pub const HirPatternKind = union(enum) {
        binding: BindingPat,
        wildcard: WildcardPat,
        literal: LiteralPat,
        tuple: TuplePat,
        struct_pat: StructPat,
        range: RangePat,
        missing,

        pub const BindingPat = struct {
            def: DefId,
            sub_pattern: PatId,
            ty: TypeId,
            mutable: bool,
        };

        pub const WildcardPat = struct {};

        pub const LiteralPat = struct {
            value: HirLiteral,
            ty: TypeId,
        };

        pub const TuplePat = struct {
            elements: []const PatId,
            ty: TypeId,
        };

        pub const StructPat = struct {
            def: DefId,
            fields: []const FieldPat,
            ty: TypeId,
        };

        pub const FieldPat = struct {
            span: SourceSpan,
            def: DefId,
            pattern: PatId,
        };

        pub const RangePat = struct {
            start: HirLiteral,
            end: HirLiteral,
            inclusive: bool,
            ty: TypeId,
        };
    };
};
