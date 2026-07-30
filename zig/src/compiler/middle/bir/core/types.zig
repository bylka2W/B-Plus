const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TypeId = u32;
pub const INVALID_TYPE: TypeId = std.math.maxInt(TypeId);

pub const ScalarKind = enum {
    i1,
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f16,
    bf16,
    f32,
    f64,
};

pub const AddressSpace = enum {
    generic,
    global,
    shared,
    @"const",
    local,
    uniform,
    device,
};

pub const Type = struct {
    kind: Kind,

    pub const Kind = union(enum) {
        void,
        scalar: ScalarKind,
        vector: struct { scalar: ScalarKind, len: u32 },
        matrix: struct { scalar: ScalarKind, rows: u32, cols: u32 },
        pointer: struct { elem: TypeId, space: AddressSpace },
        array: struct { elem: TypeId, len: u32 },
        struct_type: StructType,
        function: FunctionType,
        texture: TextureKind,
        buffer: BufferKind,
        sampler: void,
        custom_opaque: []const u8,
    };

    pub const StructType = struct {
        name: []const u8,
        fields: []TypeId,
        offsets: []u32,
        size_val: u32,
        alignment_val: u32,
    };

    pub const FunctionType = struct {
        params: []TypeId,
        return_type: TypeId,
    };

    pub const TextureKind = enum {
        tex1d,
        tex2d,
        tex3d,
        texcube,
        tex1d_array,
        tex2d_array,
        texcube_array,
        rw_tex1d,
        rw_tex2d,
        rw_tex3d,
    };

    pub const BufferKind = enum {
        structured,
        raw,
        typed,
        rw_structured,
        rw_raw,
        rw_typed,
        constant,
    };
};

pub const TypeTable = struct {
    allocator: Allocator,
    types: std.ArrayList(Type),

    pub fn init(allocator: Allocator) TypeTable {
        const table = TypeTable{
            .allocator = allocator,
            .types = std.ArrayList(Type).init(allocator),
        };
        return table;
    }

    pub fn deinit(self: *TypeTable) void {
        for (self.types.items) |t| {
            switch (t.kind) {
                .struct_type => |st| {
                    self.allocator.free(st.fields);
                    self.allocator.free(st.offsets);
                    self.allocator.free(st.name);
                },
                .function => |ft| {
                    self.allocator.free(ft.params);
                },
                else => {},
            }
        }
        self.types.deinit();
    }

    pub fn add(self: *TypeTable, kind: Type.Kind) !TypeId {
        // Deduplicate: return existing ID if this kind already exists
        for (self.types.items, 0..) |t, i| {
            if (std.meta.eql(t.kind, kind)) return @intCast(i);
        }
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(.{ .kind = kind });
        return id;
    }

    pub fn get(self: *const TypeTable, id: TypeId) Type {
        return self.types.items[id];
    }

    pub fn voidType(self: *TypeTable) !TypeId {
        return self.add(.void);
    }

    pub fn scalarType(self: *TypeTable, sk: ScalarKind) !TypeId {
        return self.add(.{ .scalar = sk });
    }

    pub fn vectorType(self: *TypeTable, scalar: ScalarKind, len: u32) !TypeId {
        return self.add(.{ .vector = .{ .scalar = scalar, .len = len } });
    }

    pub fn pointerType(self: *TypeTable, elem: TypeId, space: AddressSpace) !TypeId {
        return self.add(.{ .pointer = .{ .elem = elem, .space = space } });
    }

    pub fn arrayType(self: *TypeTable, elem: TypeId, len: u32) !TypeId {
        return self.add(.{ .array = .{ .elem = elem, .len = len } });
    }

    pub fn textureType(self: *TypeTable, kind: Type.TextureKind) !TypeId {
        return self.add(.{ .texture = kind });
    }

    pub fn bufferType(self: *TypeTable, kind: Type.BufferKind) !TypeId {
        return self.add(.{ .buffer = kind });
    }

    pub fn samplerType(self: *TypeTable) !TypeId {
        return self.add(.sampler);
    }

    pub fn sizeOf(self: *const TypeTable, id: TypeId) u32 {
        const t = self.types.items[id];
        return switch (t.kind) {
            .void => 0,
            .scalar => |sk| scalarBitSize(sk) / 8,
            .vector => |v| (scalarBitSize(v.scalar) / 8) * v.len,
            .matrix => |m| (scalarBitSize(m.scalar) / 8) * m.rows * m.cols,
            .pointer => 8,
            .array => |a| self.sizeOf(a.elem) * a.len,
            .struct_type => |st| st.size_val,
            .function => 0,
            .texture => 8,
            .buffer => 8,
            .sampler => 4,
            .custom_opaque => 0,
        };
    }

    pub fn alignOf(self: *const TypeTable, id: TypeId) u32 {
        const t = self.types.items[id];
        return switch (t.kind) {
            .void => 1,
            .scalar => |sk| (scalarBitSize(sk) / 8),
            .vector => |v| (scalarBitSize(v.scalar) / 8) * v.len,
            .matrix => |m| (scalarBitSize(m.scalar) / 8) * m.cols,
            .pointer => 8,
            .array => |a| self.alignOf(a.elem),
            .struct_type => |st| st.alignment_val,
            .function => 1,
            .texture => 8,
            .buffer => 8,
            .sampler => 4,
            .custom_opaque => 1,
        };
    }

};

pub fn scalarBitSize(sk: ScalarKind) u32 {
    return switch (sk) {
        .i1 => 1,
        .i8, .u8 => 8,
        .i16, .u16, .f16, .bf16 => 16,
        .i32, .u32, .f32 => 32,
        .i64, .u64, .f64 => 64,
    };
}
