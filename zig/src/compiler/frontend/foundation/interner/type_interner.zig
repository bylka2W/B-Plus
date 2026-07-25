const std = @import("std");

pub const TypeId = struct {
    index: u32,

    pub const INVALID = TypeId{ .index = std.math.maxInt(u32) };

    pub fn new(index: u32) TypeId {
        return .{ .index = index };
    }

    pub fn isValid(self: TypeId) bool {
        return self.index != std.math.maxInt(u32);
    }
};

pub const Type = union(enum) {
    void,
    bool_type,
    integer: IntegerType,
    float_point: FloatType,
    pointer: PointerType,
    array: ArrayType,
    slice: SliceType,
    function: FunctionType,
    @"struct": StructType,
    @"enum": EnumType,
    tuple: TupleType,
    type_variable: TypeVar,
    error_union: ErrorUnionType,
    optional: OptionalType,
    reference: ReferenceType,

    pub const IntegerType = struct {
        bits: u16,
        signed: bool,
    };

    pub const FloatType = struct {
        bits: u16,
    };

    pub const PointerType = struct {
        pointee: TypeId,
        mutable: bool,
    };

    pub const ArrayType = struct {
        element: TypeId,
        length: u64,
    };

    pub const SliceType = struct {
        element: TypeId,
    };

    pub const FunctionType = struct {
        params: []const TypeId,
        ret: TypeId,
        is_variadic: bool,
    };

    pub const StructType = struct {
        fields: []const StructField,
        name: u32,
    };

    pub const StructField = struct {
        name: u32,
        ty: TypeId,
        offset: u32,
    };

    pub const EnumType = struct {
        name: u32,
        base: TypeId,
        variants: []const VariantInfo,
    };

    pub const VariantInfo = struct {
        name: u32,
        value: i64,
    };

    pub const TupleType = struct {
        elements: []const TypeId,
    };

    pub const TypeVar = struct {
        id: u32,
    };

    pub const ErrorUnionType = struct {
        ok: TypeId,
        err: TypeId,
    };

    pub const OptionalType = struct {
        inner: TypeId,
    };

    pub const ReferenceType = struct {
        pointee: TypeId,
        mutable: bool,
    };
};

pub const TypeInterner = struct {
    types: std.ArrayList(Type),
    hash_index: std.AutoHashMap(u64, TypeId),
    arena: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TypeInterner {
        return .{
            .types = std.ArrayList(Type).init(allocator),
            .hash_index = std.AutoHashMap(u64, TypeId).init(allocator),
            .arena = allocator,
        };
    }

    pub fn deinit(self: *TypeInterner) void {
        for (self.types.items) |t| {
            switch (t) {
                .function => |f| self.arena.free(f.params),
                .@"struct" => |s| self.arena.free(s.fields),
                .@"enum" => |e| self.arena.free(e.variants),
                .tuple => |t_| self.arena.free(t_.elements),
                else => {},
            }
        }
        self.types.deinit();
        self.hash_index.deinit();
    }

    pub fn intern(self: *TypeInterner, t: Type) !TypeId {
        const key = hashType(t);
        if (self.hash_index.get(key)) |id| return id;
        const id = TypeId.new(@intCast(self.types.items.len));
        try self.types.append(t);
        try self.hash_index.put(key, id);
        return id;
    }

    pub fn get(self: *const TypeInterner, id: TypeId) ?Type {
        if (id.index < self.types.items.len) return self.types.items[id.index];
        return null;
    }

    pub fn count(self: *const TypeInterner) u32 {
        return @intCast(self.types.items.len);
    }

    fn hashType(t: Type) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, std.meta.activeTag(t));
        switch (t) {
            .integer => |i| {
                std.hash.autoHash(&hasher, i.bits);
                std.hash.autoHash(&hasher, i.signed);
            },
            .float_point => |f| std.hash.autoHash(&hasher, f.bits),
            .pointer => |p| {
                std.hash.autoHash(&hasher, p.pointee.index);
                std.hash.autoHash(&hasher, p.mutable);
            },
            .array => |a| {
                std.hash.autoHash(&hasher, a.element.index);
                std.hash.autoHash(&hasher, a.length);
            },
            else => {},
        }
        return hasher.final();
    }
};
