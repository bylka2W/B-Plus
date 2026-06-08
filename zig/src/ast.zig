const std = @import("std");
const Allocator = std.mem.Allocator;

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
    body_lines: std.ArrayList([]const u8),
    return_type: ?[]const u8,
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

pub const ProgramNode = struct {
    allocator: Allocator,
    states: std.ArrayList(StateDefNode),
    entries: std.ArrayList(EntryDecl),
    kernels: std.ArrayList(KernelDecl),
    enums: std.ArrayList(EnumDecl),
    parallel_blocks: std.ArrayList(ParallelBlock),
    memory: ?MemoryDirective,
    directives: std.ArrayList([]const u8),
    context: ?ContextDecl,
    extern_cpp_fns: std.ArrayList(ExternCppFn),

    pub fn deinit(self: *ProgramNode) void {
        for (self.states.items) |*s| {
            s.variables.deinit();
            s.transitions.deinit();
            if (s.enter_body) |b| self.allocator.free(b);
            if (s.exit_body) |b| self.allocator.free(b);
        }
        self.states.deinit();
        for (self.entries.items) |*e| e.body_lines.deinit();
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
        self.directives.deinit();
        self.extern_cpp_fns.deinit();
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
