const std = @import("std");
const kind_mod = @import("type_kind.zig");
const type_mod = @import("type.zig");

pub const TypeKind = kind_mod.TypeKind;
pub const TypeId = type_mod.TypeId;
pub const Type = type_mod.Type;
pub const invalid_type_id = type_mod.invalid_type_id;

pub const TypeTable = struct {
    allocator: std.mem.Allocator,
    types: std.ArrayList(Type),
    name_index: std.StringHashMap(TypeId),
    next_id: TypeId,

    pub const builtin_ids = struct {
        pub const void_t: TypeId = 1;
        pub const bool_t: TypeId = 2;
        pub const i8_t: TypeId = 3;
        pub const i16_t: TypeId = 4;
        pub const i32_t: TypeId = 5;
        pub const i64_t: TypeId = 6;
        pub const u8_t: TypeId = 7;
        pub const u16_t: TypeId = 8;
        pub const u32_t: TypeId = 9;
        pub const u64_t: TypeId = 10;
        pub const f32_t: TypeId = 11;
        pub const f64_t: TypeId = 12;
        pub const string_t: TypeId = 13;
    };

    pub fn init(allocator: std.mem.Allocator) TypeTable {
        var tt = TypeTable{
            .allocator = allocator,
            .types = std.ArrayList(Type).init(allocator),
            .name_index = std.StringHashMap(TypeId).init(allocator),
            .next_id = 0,
        };
        tt.registerBuiltins();
        return tt;
    }

    pub fn deinit(self: *TypeTable) void {
        for (self.types.items) |*t| {
            self.freeExtra(t);
        }
        self.types.deinit();
        self.name_index.deinit();
    }

    fn registerBuiltins(self: *TypeTable) void {
        const builtins = [_]struct { kind: TypeKind, nm: []const u8 }{
            .{ .kind = .void, .nm = "void" },
            .{ .kind = .bool_type, .nm = "bool" },
            .{ .kind = .i8, .nm = "i8" },
            .{ .kind = .i16, .nm = "i16" },
            .{ .kind = .i32, .nm = "i32" },
            .{ .kind = .i64, .nm = "i64" },
            .{ .kind = .u8, .nm = "u8" },
            .{ .kind = .u16, .nm = "u16" },
            .{ .kind = .u32, .nm = "u32" },
            .{ .kind = .u64, .nm = "u64" },
            .{ .kind = .f32, .nm = "f32" },
            .{ .kind = .f64, .nm = "f64" },
            .{ .kind = .string, .nm = "string" },
        };
        for (builtins) |b| {
            const id = self.next_id;
            self.next_id += 1;
            self.types.append(.{
                .id = id,
                .kind = b.kind,
                .name = b.nm,
                .size_bytes = b.kind.bitWidth() orelse (if (b.kind == .string) @as(?u16, 8) else null),
            }) catch unreachable;
            self.name_index.put(b.nm, id) catch unreachable;
        }
    }

    pub fn insert(self: *TypeTable, kind: TypeKind, tname: ?[]const u8, extra: type_mod.TypeExtra) TypeId {
        const id = self.next_id;
        self.next_id += 1;
        self.types.append(.{
            .id = id,
            .kind = kind,
            .name = tname,
            .size_bytes = kind.bitWidth(),
            .extra = extra,
        }) catch unreachable;
        if (tname) |n| {
            self.name_index.put(n, id) catch unreachable;
        }
        return id;
    }

    pub fn insertNamed(self: *TypeTable, kind: TypeKind, tname: []const u8) !TypeId {
        if (self.name_index.get(tname) != null) {
            return error.DuplicateType;
        }
        return self.insert(kind, tname, .none);
    }

    pub fn lookup(self: *const TypeTable, tname: []const u8) ?TypeId {
        return self.name_index.get(tname);
    }

    pub fn getType(self: *const TypeTable, id: TypeId) ?*const Type {
        if (id < self.types.items.len) return &self.types.items[id];
        return null;
    }

    pub fn getTypeMut(self: *TypeTable, id: TypeId) ?*Type {
        if (id < self.types.items.len) return &self.types.items[id];
        return null;
    }

    pub fn getKind(self: *const TypeTable, id: TypeId) ?TypeKind {
        if (self.getType(id)) |t| return t.kind;
        return null;
    }

    pub fn typeCount(self: *const TypeTable) usize {
        return self.types.items.len;
    }

    pub fn isInt(self: *const TypeTable, id: TypeId) bool {
        if (self.getKind(id)) |k| return k.isInt();
        return false;
    }

    pub fn isFloat(self: *const TypeTable, id: TypeId) bool {
        if (self.getKind(id)) |k| return k.isFloat();
        return false;
    }

    pub fn isNumeric(self: *const TypeTable, id: TypeId) bool {
        if (self.getKind(id)) |k| return k.isNumeric();
        return false;
    }

    fn freeExtra(self: *const TypeTable, t: *Type) void {
        switch (t.extra) {
            .structure => |s| {
                for (s.fields) |f| {
                    self.allocator.free(f.name);
                }
                self.allocator.free(s.fields);
            },
            .enumeration => |e| {
                for (e.members) |m| {
                    self.allocator.free(m.name);
                }
                self.allocator.free(e.members);
            },
            .func => |f| {
                self.allocator.free(f.params);
            },
            else => {},
        }
    }
};
