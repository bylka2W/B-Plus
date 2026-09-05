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
    type_name: ?[]const u8,  // null = auto-infer type from value
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

pub const ProgramPlan = struct {
    states: std.ArrayList(StateDefNode),
    parallel_blocks: std.ArrayList(ParallelBlock),
    memory: ?MemoryDirective,
    fire_events: std.ArrayList([]const u8),
    initial_state: ?[]const u8,
};

pub const ProgramMetal = struct {
    entries: std.ArrayList(EntryDecl),
    kernels: std.ArrayList(KernelDecl),
    context: ?ContextDecl,
    imports: std.ArrayList(ImportNode),
    enums: std.ArrayList(EnumDecl),
    struct_defs: std.StringHashMap(StructDef),
    func_defs: std.ArrayList(EntryDecl),
    forwarders: std.ArrayList(ForwardDecl),
    extern_cpp_fns: std.ArrayList(ExternCppFn),
    directives: std.ArrayList([]const u8),
};

pub const ProgramNode = struct {
    allocator: Allocator,
    plan: ProgramPlan,
    metal: ProgramMetal,

    pub fn deinit(self: *ProgramNode) void {
        const a = self.allocator;

        // Metal
        for (self.metal.imports.items) |*imp| a.free(imp.path);
        self.metal.imports.deinit();
        for (self.metal.enums.items) |*e| e.members.deinit();
        self.metal.enums.deinit();
        {
            var it = self.metal.struct_defs.iterator();
            while (it.next()) |kv| {
                a.free(kv.key_ptr.*);
                kv.value_ptr.fields.deinit();
            }
        }
        self.metal.struct_defs.deinit();
        for (self.metal.func_defs.items) |*f| {
            for (f.params.items) |*p| {
                a.free(p.name);
                a.free(p.type_name);
            }
            f.params.deinit();
            for (f.body_lines.items) |line| a.free(line);
            f.body_lines.deinit();
            if (f.return_type) |rt| a.free(rt);
        }
        self.metal.func_defs.deinit();
        self.metal.forwarders.deinit();
        self.metal.extern_cpp_fns.deinit();
        self.metal.directives.deinit();

        // Plan
        for (self.plan.states.items) |*s| {
            s.variables.deinit();
            s.transitions.deinit();
            if (s.enter_body) |b| a.free(b);
            if (s.exit_body) |b| a.free(b);
            if (s.cache_policy) |cp| a.free(cp);
        }
        self.plan.states.deinit();
        for (self.plan.parallel_blocks.items) |*p| p.states.deinit();
        self.plan.parallel_blocks.deinit();
        for (self.plan.fire_events.items) |fe| a.free(fe);
        self.plan.fire_events.deinit();
        if (self.plan.initial_state) |is| a.free(is);

        // Metal
        for (self.metal.entries.items) |*e| {
            for (e.body_lines.items) |line| a.free(line);
            e.body_lines.deinit();
            e.params.deinit();
        }
        self.metal.entries.deinit();
        for (self.metal.kernels.items) |*k| {
            k.params.deinit();
            k.annotations.deinit();
        }
        self.metal.kernels.deinit();
        if (self.metal.context) |*ctx| ctx.variables.deinit();
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
