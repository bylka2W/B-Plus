const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TypeId = enum(u8) {
    unknown = 0,
    void,
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

    string_type,
    ptr_type,

    struct_type,
    enum_type,

    pub fn fromName(n: []const u8) TypeId {
        if (std.mem.eql(u8, n, "void")) return .void;
        if (std.mem.eql(u8, n, "bool")) return .bool_type;
        if (std.mem.eql(u8, n, "i8")) return .i8_type;
        if (std.mem.eql(u8, n, "i16")) return .i16_type;
        if (std.mem.eql(u8, n, "i32")) return .i32_type;
        if (std.mem.eql(u8, n, "i64") or std.mem.eql(u8, n, "int")) return .i64_type;
        if (std.mem.eql(u8, n, "u8")) return .u8_type;
        if (std.mem.eql(u8, n, "u16")) return .u16_type;
        if (std.mem.eql(u8, n, "u32")) return .u32_type;
        if (std.mem.eql(u8, n, "u64")) return .u64_type;
        if (std.mem.eql(u8, n, "f32")) return .f32_type;
        if (std.mem.eql(u8, n, "f64")) return .f64_type;
        if (std.mem.eql(u8, n, "string")) return .string_type;
        if (std.mem.eql(u8, n, "ptr")) return .ptr_type;
        return .unknown;
    }

    pub fn isInt(self: TypeId) bool {
        return switch (self) {
            .i8_type, .i16_type, .i32_type, .i64_type,
            .u8_type, .u16_type, .u32_type, .u64_type,
            => true,
            else => false,
        };
    }

    pub fn isFloat(self: TypeId) bool {
        return self == .f32_type or self == .f64_type;
    }

    pub fn isNumeric(self: TypeId) bool {
        return self.isInt() or self.isFloat();
    }

    pub fn name(self: TypeId) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .void => "void",
            .bool_type => "bool",
            .i8_type => "i8",
            .i16_type => "i16",
            .i32_type => "i32",
            .i64_type => "i64",
            .u8_type => "u8",
            .u16_type => "u16",
            .u32_type => "u32",
            .u64_type => "u64",
            .f32_type => "f32",
            .f64_type => "f64",
            .string_type => "string",
            .ptr_type => "ptr",
            .struct_type => "struct",
            .enum_type => "enum",
        };
    }
};

pub const StructField = struct {
    name: []const u8,
    type_name: []const u8,
};

pub const StructDef = struct {
    name: []const u8,
    fields: std.ArrayList(StructField),
};

pub const VariableNode = struct {
    name: []const u8,
    type_name: []const u8,
    default_value: ?[]const u8,
    is_fast_path: bool,
    cache_policy: ?[]const u8,
    cache_align: ?u32,
};

pub const TransitionNode = struct {
    event_name: ?[]const u8,
    target: []const u8,
    is_always: bool,
    hot_weight: ?f64,
    guard: ?[]const u8,
    body: ?[]const u8,
};

pub const ImportNode = struct {
    path: []const u8,
};

pub const StateDefNode = struct {
    name: []const u8,
    base_class: ?[]const u8,
    depth: u32,
    variables: std.ArrayList(VariableNode),
    transitions: std.ArrayList(TransitionNode),
    enter_body: ?[]const u8,
    exit_body: ?[]const u8,
    hot_weight: ?f64,
    cache_policy: ?[]const u8,
    cache_align: ?u32,
    is_fast_path: bool,
    inline_hint: InlineHint,
    ownership: OwnershipHint,
};

pub const EntryDecl = struct {
    name: []const u8,
    params: std.ArrayList(KernelParam),
    body_lines: std.ArrayList([]const u8),
    return_type: ?[]const u8,
    is_export: bool,
};

pub const KernelDecl = struct {
    name: []const u8,
    params: std.ArrayList(KernelParam),
    return_type: ?[]const u8,
    annotations: std.ArrayList(Annotation),
};

pub const KernelParam = struct {
    name: []const u8,
    type_name: []const u8,
};

pub const Annotation = struct {
    name: []const u8,
    value: ?[]const u8,
};

pub const EnumDecl = struct {
    name: []const u8,
    members: std.ArrayList([]const u8),
};

pub const ParallelBlock = struct {
    name: []const u8,
    states: std.ArrayList(StateDefNode),
};

pub const MemoryDirective = struct {
    mode: MemoryMode,
    vram: ?[]const u8,
    ram: ?[]const u8,
};

pub const MemoryMode = enum { smart, precise, none };

pub const InlineHint = enum { default, always_inline, no_inline };
pub const OwnershipHint = enum { default, owned, borrowed };

pub const ForwardDecl = struct {
    export_name: []const u8,
    target_dll: []const u8,
};

pub const ProgramNode = struct {
    allocator: Allocator,
    imports: std.ArrayList(ImportNode),
    states: std.ArrayList(StateDefNode),
    entries: std.ArrayList(EntryDecl),
    kernels: std.ArrayList(KernelDecl),
    enums: std.ArrayList(EnumDecl),
    parallel_blocks: std.ArrayList(ParallelBlock),
    forwarders: std.ArrayList(ForwardDecl),
    memory: ?MemoryDirective,
    directives: std.ArrayList([]const u8),
    metal: ?ContextDecl,
    extern_cpp_fns: std.ArrayList(ExternCppFn),
    struct_defs: std.StringHashMap(StructDef),
    func_defs: std.ArrayList(EntryDecl),

    pub fn deinit(self: *ProgramNode) void {
        for (self.imports.items) |*imp| self.allocator.free(imp.path);
        self.imports.deinit();
        for (self.states.items) |*s| {
            s.variables.deinit();
            s.transitions.deinit();
            if (s.enter_body) |b| self.allocator.free(b);
            if (s.exit_body) |b| self.allocator.free(b);
            if (s.cache_policy) |cp| self.allocator.free(cp);
        }
        self.states.deinit();
        for (self.entries.items) |*e| {
            for (e.body_lines.items) |line| self.allocator.free(line);
            e.body_lines.deinit();
            e.params.deinit();
        }
        self.entries.deinit();
        for (self.kernels.items) |*k| {
            k.params.deinit();
            k.annotations.deinit();
        }
        self.kernels.deinit();
        for (self.enums.items) |*e| e.members.deinit();
        self.enums.deinit();
        for (self.parallel_blocks.items) |*p| p.states.deinit();
        self.parallel_blocks.deinit();
        self.forwarders.deinit();
        if (self.metal) |*ctx| ctx.variables.deinit();
        self.directives.deinit();
        self.extern_cpp_fns.deinit();
        for (self.func_defs.items) |*f| {
            self.allocator.free(f.name);
            for (f.body_lines.items) |line| self.allocator.free(line);
            f.body_lines.deinit();
            f.params.deinit();
        }
        self.func_defs.deinit();
        {
            var it = self.struct_defs.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.fields.deinit();
            }
            self.struct_defs.deinit();
        }
    }
};

pub const ContextDecl = struct {
    variables: std.ArrayList(VariableNode),
};

pub const ExternCppFn = struct {
    name: []const u8,
    parameters: std.ArrayList(KernelParam),
    return_type: ?[]const u8,
};

pub const ErrorTransitionNode = struct {
    from: []const u8,
    to: []const u8,
};
