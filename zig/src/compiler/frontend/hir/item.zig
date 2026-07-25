const std = @import("std");
const ids = @import("../foundation/ids/ids.zig");
const SourceSpan = @import("../source/location/span.zig").SourceSpan;

pub const ItemId = ids.ItemId;
pub const BodyId = ids.BodyId;
pub const TypeId = ids.TypeId;
pub const SymbolId = ids.SymbolId;
pub const DefId = ids.DefId;
pub const ExprId = ids.ExprId;

pub const HirItem = struct {
    span: SourceSpan,
    kind: HirItemKind,

    pub const HirItemKind = union(enum) {
        fn_decl: FnItem,
        struct_item: StructItem,
        enum_item: EnumItem,
        trait_item: TraitItem,
        impl_item: ImplItem,
        const_item: ConstItem,
        type_alias: TypeAliasItem,
        extern_fn: ExternFnItem,
        missing: MissingItem,

        pub const FnItem = struct {
            name: SymbolId,
            def_id: DefId,
            params: []const Param,
            return_type: TypeId,
            body: BodyId,
            visibility: Visibility,
        };

        pub const StructItem = struct {
            name: SymbolId,
            def_id: DefId,
            fields: []const Field,
            visibility: Visibility,
        };

        pub const EnumItem = struct {
            name: SymbolId,
            def_id: DefId,
            variants: []const Variant,
            visibility: Visibility,
        };

        pub const TraitItem = struct {
            name: SymbolId,
            def_id: DefId,
            methods: []const FnItem,
            visibility: Visibility,
        };

        pub const ImplItem = struct {
            self_type: TypeId,
            trait_ref: ?TypeId,
            methods: []const FnItem,
        };

        pub const ConstItem = struct {
            name: SymbolId,
            def_id: DefId,
            ty: TypeId,
            init: ExprId,
            visibility: Visibility,
        };

        pub const TypeAliasItem = struct {
            name: SymbolId,
            def_id: DefId,
            target: TypeId,
            visibility: Visibility,
        };

        pub const ExternFnItem = struct {
            name: SymbolId,
            def_id: DefId,
            params: []const Param,
            return_type: TypeId,
            visibility: Visibility,
        };

        pub const MissingItem = struct {};

        pub const Param = struct {
            name: SymbolId,
            def_id: DefId,
            ty: TypeId,
            span: SourceSpan,
        };

        pub const Field = struct {
            name: SymbolId,
            ty: TypeId,
            visibility: Visibility,
            span: SourceSpan,
        };

        pub const Variant = struct {
            name: SymbolId,
            fields: []const Field,
        };

        pub const Visibility = enum {
            public, private, package,
        };
    };
};
