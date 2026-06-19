const std = @import("std");
const windows = std.os.windows;

const WINAPI = windows.WINAPI;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const LPVOID = windows.LPVOID;

extern "kernel32" fn GetSystemInfo(lpSystemInfo: *SYSTEM_INFO) callconv(WINAPI) void;
extern "kernel32" fn GetLogicalProcessorInformation(
    Buffer: ?*SYSTEM_LOGICAL_PROCESSOR_INFORMATION,
    ReturnedLength: *DWORD,
) callconv(WINAPI) BOOL;
extern "kernel32" fn GetLogicalProcessorInformationEx(
    RelationshipType: LOGICAL_PROCESSOR_RELATIONSHIP,
    Buffer: ?*anyopaque,
    ReturnedLength: *DWORD,
) callconv(WINAPI) BOOL;

const ERROR_INSUFFICIENT_BUFFER: windows.Win32Error = .INSUFFICIENT_BUFFER;

const LOGICAL_PROCESSOR_RELATIONSHIP = enum(u32) {
    RelationProcessorCore = 0,
    RelationNumaNode = 1,
    RelationCache = 2,
    RelationProcessorPackage = 3,
    RelationGroup = 4,
    RelationProcessorDie = 5,
    RelationNumaNodeEx = 6,
    RelationProcessorModule = 7,
    RelationAll = 0xFFFF,
};

const SYSTEM_INFO = extern struct {
    wProcessorArchitecture: u16,
    wReserved: u16,
    dwPageSize: DWORD,
    lpMinimumApplicationAddress: LPVOID,
    lpMaximumApplicationAddress: LPVOID,
    dwActiveProcessorMask: ?*anyopaque,
    dwNumberOfProcessors: DWORD,
    dwProcessorType: DWORD,
    dwAllocationGranularity: DWORD,
    wProcessorLevel: u16,
    wProcessorRevision: u16,
};

const CACHE_DESCRIPTOR = extern struct {
    Level: u8,
    Associativity: u8,
    LineSize: u16,
    Size: DWORD,
    Type: enum(u32) {
        CacheUnified = 0,
        CacheInstruction = 1,
        CacheData = 2,
        CacheTrace = 3,
    },
};

const SYSTEM_LOGICAL_PROCESSOR_INFORMATION = extern struct {
    ProcessorMask: ?*anyopaque,
    Relationship: LOGICAL_PROCESSOR_RELATIONSHIP,
    Anonymous: extern union {
        ProcessorCore: extern struct {
            Flags: u8,
        },
        NumaNode: extern struct {
            NodeNumber: DWORD,
        },
        Cache: CACHE_DESCRIPTOR,
        Reserved: [2]u64,
    },
};

pub const CacheInfo = struct {
    level: u8,
    size_bytes: u64,
    line_size: u16,
    associativity: u8,
};

pub const NumaNode = struct {
    node_number: u32,
    processor_count: u32,
    processor_mask: usize,
};

pub const CpuClass = enum(u8) {
    tiny,
    pc,
    workstation,
    manycore,
};

pub const CpuTopology = struct {
    logical_cores: u32,
    physical_cores: u32,
    has_hyperthreading: bool,
    class: CpuClass,
    numa_nodes: []const NumaNode,
    caches: []const CacheInfo,
    logical_to_physical: []u32,
    allocator: std.mem.Allocator,

    pub fn detect(allocator: std.mem.Allocator) !CpuTopology {
        var sys_info: SYSTEM_INFO = undefined;
        GetSystemInfo(&sys_info);
        const logical_cores = sys_info.dwNumberOfProcessors;

        var nodes = std.ArrayList(NumaNode).init(allocator);
        var caches = std.ArrayList(CacheInfo).init(allocator);
        var phys_count: u32 = 0;
        const logical_to_physical = try allocator.alloc(u32, logical_cores);
        @memset(logical_to_physical, 0);

        // Try GetLogicalProcessorInformationEx first (richer data)
        const ex_used = try detectEx(allocator, logical_cores, &nodes, &caches, &phys_count, logical_to_physical);

        if (!ex_used) {
            // Fallback to the older API
            _ = try detectLegacy(allocator, &nodes, &caches, &phys_count, logical_to_physical);
        }
        if (phys_count == 0) phys_count = logical_cores;

        // Fill missing NUMA: single node if none detected
        if (nodes.items.len == 0) {
            try nodes.append(.{
                .node_number = 0,
                .processor_count = logical_cores,
                .processor_mask = 0,
            });
        }

        // Deduplicate caches (the Ex API returns one entry per cache per core)
        {
            var deduped = std.ArrayList(CacheInfo).init(allocator);
            for (caches.items) |c| {
                var found = false;
                for (deduped.items) |d| {
                    if (d.level == c.level and d.size_bytes == c.size_bytes and d.line_size == c.line_size and d.associativity == c.associativity) {
                        found = true;
                        break;
                    }
                }
                if (!found) try deduped.append(c);
            }
            caches.deinit();
            caches = deduped;
        }

        // Determine CPU class
        const class = classify(logical_cores, phys_count);

        return CpuTopology{
            .logical_cores = logical_cores,
            .physical_cores = phys_count,
            .has_hyperthreading = logical_cores > phys_count,
            .class = class,
            .numa_nodes = try nodes.toOwnedSlice(),
            .caches = try caches.toOwnedSlice(),
            .logical_to_physical = logical_to_physical,
            .allocator = allocator,
        };
    }

    pub fn deinit(topo: *const CpuTopology) void {
        topo.allocator.free(topo.numa_nodes);
        topo.allocator.free(topo.caches);
        topo.allocator.free(topo.logical_to_physical);
    }
};

fn detectEx(
    allocator: std.mem.Allocator,
    logical_cores: u32,
    nodes: *std.ArrayList(NumaNode),
    caches: *std.ArrayList(CacheInfo),
    phys_count: *u32,
    logical_to_physical: []u32,
) !bool {
    _ = logical_cores;
    // Try to call GetLogicalProcessorInformationEx
    var buf_size: DWORD = 0;
    const rs = GetLogicalProcessorInformationEx(.RelationAll, null, &buf_size);
    if (rs == 0 and buf_size == 0) return false;
    if (windows.kernel32.GetLastError() != ERROR_INSUFFICIENT_BUFFER) return false;

    const buf = try allocator.alloc(u8, buf_size);
    defer allocator.free(buf);

    if (GetLogicalProcessorInformationEx(.RelationAll, @ptrCast(buf.ptr), &buf_size) == 0) return false;

    // Parse the buffer
    var offset: usize = 0;
    while (offset < buf_size) {
        const header = @as(*align(1) const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX, @ptrCast(buf.ptr + offset));
        switch (header.Relationship) {
            .RelationProcessorCore => {
                // Count physical cores
                const core = @as(*align(1) const PROCESSOR_RELATIONSHIP, @ptrCast(&header.Anonymous));
                phys_count.* += 1;
                // Map logical cores to this physical core
                var group: u32 = 0;
                while (group < core.GroupCount) : (group += 1) {
                    const ga = &core.GroupMasks[@intCast(group)];
                    var bit: u32 = 0;
                    while (bit < 64) : (bit += 1) {
                        if ((ga.Mask >> @as(u6, @intCast(bit))) & 1 != 0) {
                            // Find which logical core this corresponds to
                            const logical_idx = group * 64 + bit;
                            if (logical_idx < logical_to_physical.len and phys_count.* > 0) {
                                logical_to_physical[logical_idx] = phys_count.* - 1;
                            }
                        }
                    }
                }
            },
            .RelationCache => {
                const cache = @as(*align(1) const CACHE_RELATIONSHIP, @ptrCast(&header.Anonymous));
                try caches.append(.{
                    .level = cache.Level,
                    .size_bytes = cache.CacheSize,
                    .line_size = @intCast(cache.LineSize),
                    .associativity = cache.Associativity,
                });
            },
            .RelationNumaNode => {
                const numa = @as(*align(1) const NUMA_NODE_RELATIONSHIP, @ptrCast(&header.Anonymous));
                // Count processors in this NUMA node
                var proc_count: u32 = 0;
                var group: u32 = 0;
                while (group < numa.GroupCount) : (group += 1) {
                    const ga = &numa.GroupMasks[@intCast(group)];
                    var bit: u32 = 0;
                    while (bit < 64) : (bit += 1) {
                        if ((ga.Mask >> @as(u6, @intCast(bit))) & 1 != 0) proc_count += 1;
                    }
                }
                try nodes.append(.{
                    .node_number = numa.NodeNumber,
                    .processor_count = proc_count,
                    .processor_mask = 0,
                });
            },
            else => {},
        }
        if (header.Size == 0) break;
        offset += header.Size;
    }

    return true;
}

fn detectLegacy(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(NumaNode),
    caches: *std.ArrayList(CacheInfo),
    phys_count: *u32,
    logical_to_physical: []u32,
) !bool {
    var buf_size: DWORD = 0;
    if (GetLogicalProcessorInformation(null, &buf_size) == 0) {
        if (windows.kernel32.GetLastError() != ERROR_INSUFFICIENT_BUFFER) return false;
    }

    const buf = try allocator.alloc(u8, buf_size);
    defer allocator.free(buf);

    if (GetLogicalProcessorInformation(@ptrCast(@alignCast(buf.ptr)), &buf_size) == 0) return false;

    const entries = @as([*]SYSTEM_LOGICAL_PROCESSOR_INFORMATION, @ptrCast(@alignCast(buf.ptr)));
    const count = buf_size / @sizeOf(SYSTEM_LOGICAL_PROCESSOR_INFORMATION);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entry = &entries[i];
        switch (entry.Relationship) {
            .RelationProcessorCore => {
                const idx = phys_count.*;
                phys_count.* += 1;
                // Map logical bits to physical core index
                const mask = @intFromPtr(entry.ProcessorMask);
                var bit: u32 = 0;
                while (bit < 64) : (bit += 1) {
                    if ((mask >> @as(u6, @intCast(bit))) & 1 != 0) {
                        if (bit < logical_to_physical.len) {
                            logical_to_physical[bit] = idx;
                        }
                    }
                }
            },
            .RelationCache => {
                const cache = &entry.Anonymous.Cache;
                try caches.append(.{
                    .level = cache.Level,
                    .size_bytes = cache.Size,
                    .line_size = cache.LineSize,
                    .associativity = cache.Associativity,
                });
            },
            .RelationNumaNode => {
                try nodes.append(.{
                    .node_number = entry.Anonymous.NumaNode.NodeNumber,
                    .processor_count = 0,
                    .processor_mask = @intFromPtr(entry.ProcessorMask),
                });
            },
            else => {},
        }
    }

    return true;
}

fn classify(logical: u32, physical: u32) CpuClass {
    _ = logical;
    if (physical <= 2) return .tiny;
    if (physical <= 16) return .pc;
    if (physical <= 24) return .workstation;
    return .manycore;
}

test "CPU topology detection" {
    const topo = try CpuTopology.detect(std.testing.allocator);
    defer topo.deinit();

    try std.testing.expect(topo.logical_cores > 0);
    try std.testing.expect(topo.physical_cores > 0);
    try std.testing.expect(topo.physical_cores <= topo.logical_cores);
    try std.testing.expect(topo.numa_nodes.len > 0);

    std.debug.print("\n  logical={d} physical={d} ht={} class={s} numa={d}", .{
        topo.logical_cores, topo.physical_cores, topo.has_hyperthreading,
        @tagName(topo.class), topo.numa_nodes.len,
    });
    std.debug.print("\n  caches:", .{});
    for (topo.caches) |c| {
        std.debug.print(" L{d}={}KB", .{ c.level, c.size_bytes / 1024 });
    }
    std.debug.print("\n", .{});
}

// ── Ex API structures ──

const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX = extern struct {
    Relationship: LOGICAL_PROCESSOR_RELATIONSHIP,
    Size: DWORD,
    Anonymous: extern union {
        ProcessorCore: PROCESSOR_RELATIONSHIP,
        NumaNode: NUMA_NODE_RELATIONSHIP,
        Cache: CACHE_RELATIONSHIP,
    },
};

const PROCESSOR_RELATIONSHIP = extern struct {
    Flags: u8,
    EfficiencyClass: u8,
    Reserved: [20]u8,
    GroupCount: u16,
    GroupMasks: [1]GROUP_AFFINITY,
    // Followed by GroupMasks[GroupCount - 1] extra entries
};

const NUMA_NODE_RELATIONSHIP = extern struct {
    NodeNumber: DWORD,
    Reserved: [18]u8,
    GroupCount: u16,
    GroupMasks: [1]GROUP_AFFINITY,
};

const CACHE_RELATIONSHIP = extern struct {
    Level: u8,
    Associativity: u8,
    LineSize: u16,
    CacheSize: DWORD,
    Type: enum(u32) {
        CacheUnified = 0,
        CacheInstruction = 1,
        CacheData = 2,
        CacheTrace = 3,
    },
    Reserved: [20]u8,
    GroupCount: u16,
    GroupMasks: [1]GROUP_AFFINITY,
};

const GROUP_AFFINITY = extern struct {
    Mask: usize,
    Group: u16,
    Reserved: [3]u16,
};
