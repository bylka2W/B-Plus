const kind_mod = @import("type_kind.zig");

pub const TypeKind = kind_mod.TypeKind;
pub const TypeId = u32;

pub const invalid_type_id: TypeId = 0;

pub const PointerInfo = struct {
    pointee: TypeId,
};

pub const ArrayInfo = struct {
    element: TypeId,
    length: u32,
};

pub const FunctionInfo = struct {
    params: []const TypeId,
    return_type: TypeId,
};

pub const StructInfo = struct {
    fields: []const FieldInfo,
    size_bytes: u32,
    align_bytes: u32,
};

pub const FieldInfo = struct {
    name: []const u8,
    type_id: TypeId,
    offset: u32,
};

pub const EnumInfo = struct {
    base: TypeId,
    members: []const EnumMember,
};

pub const EnumMember = struct {
    name: []const u8,
    value: i64,
};

pub const TypeExtra = union(enum) {
    none,
    pointer: PointerInfo,
    array: ArrayInfo,
    func: FunctionInfo,
    structure: StructInfo,
    enumeration: EnumInfo,
};

pub const Type = struct {
    id: TypeId,
    kind: TypeKind,
    name: ?[]const u8,
    size_bytes: ?u16,
    extra: TypeExtra = .none,
};
