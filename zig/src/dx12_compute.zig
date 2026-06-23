const std = @import("std");
const windows = std.os.windows;
const hr = windows.HRESULT;

const d3d = @import("d3d12_bindings.zig");
const IID_ID3D12Device = d3d.IID_ID3D12Device;
const IID_ID3D12CommandQueue = d3d.IID_ID3D12CommandQueue;
const IID_ID3D12CommandAllocator = d3d.IID_ID3D12CommandAllocator;
const IID_ID3D12GraphicsCommandList = d3d.IID_ID3D12GraphicsCommandList;
const IID_ID3D12Fence = d3d.IID_ID3D12Fence;
const IID_ID3D12RootSignature = d3d.IID_ID3D12RootSignature;
const IID_ID3D12PipelineState = d3d.IID_ID3D12PipelineState;
const IID_ID3D12DescriptorHeap = d3d.IID_ID3D12DescriptorHeap;
const IID_ID3D12Resource = d3d.IID_ID3D12Resource;
const IID_IDXGIFactory4 = d3d.IID_IDXGIFactory4;
const IID_IDXGIAdapter1 = d3d.IID_IDXGIAdapter1;

const D3D12_COMMAND_QUEUE_DESC = d3d.D3D12_COMMAND_QUEUE_DESC;
const D3D12_DESCRIPTOR_HEAP_DESC = d3d.D3D12_DESCRIPTOR_HEAP_DESC;
const D3D12_HEAP_PROPERTIES = d3d.D3D12_HEAP_PROPERTIES;
const D3D12_RESOURCE_DESC = d3d.D3D12_RESOURCE_DESC;
const D3D12_SHADER_BYTECODE = d3d.D3D12_SHADER_BYTECODE;
const D3D12_COMPUTE_PIPELINE_STATE_DESC = d3d.D3D12_COMPUTE_PIPELINE_STATE_DESC;
const D3D12_ROOT_SIGNATURE_DESC = d3d.D3D12_ROOT_SIGNATURE_DESC;
const D3D12_ROOT_PARAMETER = d3d.D3D12_ROOT_PARAMETER;
const D3D12_DESCRIPTOR_RANGE = d3d.D3D12_DESCRIPTOR_RANGE;
const D3D12_ROOT_SIGNATURE_FLAGS = d3d.D3D12_ROOT_SIGNATURE_FLAGS;
const D3D12_RESOURCE_BARRIER = d3d.D3D12_RESOURCE_BARRIER;
const D3D12_UNORDERED_ACCESS_VIEW_DESC = d3d.D3D12_UNORDERED_ACCESS_VIEW_DESC;
const D3D12_RANGE = d3d.D3D12_RANGE;
const D3D12_CPU_DESCRIPTOR_HANDLE = d3d.D3D12_CPU_DESCRIPTOR_HANDLE;
const D3D12_GPU_DESCRIPTOR_HANDLE = d3d.D3D12_GPU_DESCRIPTOR_HANDLE;
const D3D12_RESOURCE_STATES = d3d.D3D12_RESOURCE_STATES;
const D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES = d3d.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
const D3D12_RESOURCE_BARRIER_FLAG_NONE = d3d.D3D12_RESOURCE_BARRIER_FLAG_NONE;
const D3D12_HEAP_FLAG_NONE = d3d.D3D12_HEAP_FLAG_NONE;
const D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS = d3d.D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
const D3D12_CLEAR_VALUE = d3d.D3D12_CLEAR_VALUE;
const D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE = d3d.D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
const D3D12_ROOT_SIGNATURE_FLAG_DENY_VERTEX_SHADER_ROOT_ACCESS = d3d.D3D12_ROOT_SIGNATURE_FLAG_DENY_VERTEX_SHADER_ROOT_ACCESS;
const D3D12_ROOT_SIGNATURE_FLAG_DENY_PIXEL_SHADER_ROOT_ACCESS = d3d.D3D12_ROOT_SIGNATURE_FLAG_DENY_PIXEL_SHADER_ROOT_ACCESS;
const D3D12_SAMPLER_DESC = d3d.D3D12_SAMPLER_DESC;
const D3D12_SHADER_RESOURCE_VIEW_DESC = d3d.D3D12_SHADER_RESOURCE_VIEW_DESC;
const D3D12_TEXTURE_COPY_LOCATION = d3d.D3D12_TEXTURE_COPY_LOCATION;
const D3D12_PLACED_SUBRESOURCE_FOOTPRINT = d3d.D3D12_PLACED_SUBRESOURCE_FOOTPRINT;
const D3D12_BOX = d3d.D3D12_BOX;

const getDeviceVtbl = d3d.getDeviceVtbl;
const getQueueVtbl = d3d.getQueueVtbl;
const getCmdListVtbl = d3d.getCmdListVtbl;
const getFenceVtbl = d3d.getFenceVtbl;
const getAllocatorVtbl = d3d.getAllocatorVtbl;
const getResourceVtbl = d3d.getResourceVtbl;
const getRootSigVtbl = d3d.getRootSigVtbl;
const getPSOVtbl = d3d.getPSOVtbl;
const getHeapVtbl = d3d.getHeapVtbl;
const getBlobVtbl = d3d.getBlobVtbl;
const getFactoryVtbl = d3d.getFactoryVtbl;
const release = d3d.release;

pub const S_OK: hr = 0;

const CC: std.builtin.CallingConvention = .{ .x86_64_win = .{} };

pub const ComputeContext = struct {
    device: ?*anyopaque,
    queue: ?*anyopaque,
    cmd_allocator: ?*anyopaque,
    cmd_list: ?*anyopaque,
    fence: ?*anyopaque,
    fence_value: u64,
    event: usize,
    uav_heap: ?*anyopaque,
    uav_heap_increment: u32,
    sampler_heap: ?*anyopaque,
    sampler_heap_increment: u32,
    root_sig: ?*anyopaque,
    pso: ?*anyopaque,
    d3d12_module: ?*anyopaque,
    D3D12CreateDevice: ?*const fn (?*anyopaque, u32, *const d3d.GUID, *?*anyopaque) callconv(CC) hr,
    D3D12SerializeRootSignature: ?*const fn (*const d3d.D3D12_ROOT_SIGNATURE_DESC, u32, *?*anyopaque, *?*anyopaque) callconv(CC) hr,
    D3D12SerializeVersionedRootSignature: ?*const fn (*const d3d.D3D12_VERSIONED_ROOT_SIGNATURE_DESC, *?*anyopaque, *?*anyopaque) callconv(CC) hr,
    D3D12GetDebugInterface: ?*const fn (*const d3d.GUID, *?*anyopaque) callconv(CC) hr,

    pub fn init(self: *ComputeContext) !void {
        self.root_sig = null;
        self.pso = null;
        const d3d12_mod = try windows.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3d12.dll"));
        self.d3d12_module = @ptrCast(d3d12_mod);

        const k32 = windows.kernel32;
        self.D3D12CreateDevice = @ptrCast((k32.GetProcAddress(d3d12_mod, "D3D12CreateDevice") orelse return error.MissingD3D12CreateDevice));
        self.D3D12SerializeRootSignature = @ptrCast((k32.GetProcAddress(d3d12_mod, "D3D12SerializeRootSignature") orelse return error.MissingSerializeRootSig));
        self.D3D12SerializeVersionedRootSignature = @ptrCast((k32.GetProcAddress(d3d12_mod, "D3D12SerializeVersionedRootSignature") orelse return error.MissingSerializeRootSig));
        self.D3D12GetDebugInterface = if (k32.GetProcAddress(d3d12_mod, "D3D12GetDebugInterface")) |p| @ptrCast(p) else null;

        // Enable debug layer if available
        {
            const IID_ID3D12Debug = d3d.GUID.parse("{344488b7-6846-474b-b989-f027448245e0}");
            var debug_ctrl: ?*anyopaque = null;
            if (self.D3D12GetDebugInterface) |get_debug| {
                const dhr = get_debug(&IID_ID3D12Debug, &debug_ctrl);
                std.debug.print("D3D12GetDebugInterface: hr=0x{x}\n", .{@as(u32, @bitCast(dhr))});
                if (dhr >= 0 and debug_ctrl != null) {
                    const vtbl_ptr = @as(*?*anyopaque, @ptrCast(@alignCast(debug_ctrl.?)));
                    const DebugVtbl = struct {
                        _00: usize, _01: usize, _02: usize, _03: usize, _04: usize, _05: usize, _06: usize, _07: usize,
                        EnableDebugLayer: *const fn (?*anyopaque) callconv(CC) void,
                    };
                    const vtbl = @as(*DebugVtbl, @ptrCast(@alignCast(vtbl_ptr.*)));
                    vtbl.EnableDebugLayer(debug_ctrl.?);
                    std.debug.print("Debug layer enabled\n", .{});
                }
            }
        }

        const dxgi = try loadDXGI();
        defer _ = k32.FreeLibrary(dxgi);

        const factory = try createDXGIFactory(dxgi);
        defer release(factory);

        const adapter = findAdapter(factory) catch null;

        var device: ?*anyopaque = null;
        var hr_ = self.D3D12CreateDevice.?(adapter, @as(u32, 0xc000), &IID_ID3D12Device, &device);
        if (hr_ < 0) {
            hr_ = self.D3D12CreateDevice.?(null, @as(u32, 0xb000), &IID_ID3D12Device, &device);
        }
        if (hr_ < 0) return error.D3D12DeviceFailed;
        self.device = device;

        var queue: ?*anyopaque = null;
        var queue_desc = D3D12_COMMAND_QUEUE_DESC{ .Type = .COMPUTE, .Priority = 0, .Flags = .NONE, .NodeMask = 0 };
        hr_ = getDeviceVtbl(device.?).CreateCommandQueue(device.?, &queue_desc, &IID_ID3D12CommandQueue, &queue);
        if (hr_ < 0) return error.CommandQueueFailed;
        self.queue = queue;

        var allocator: ?*anyopaque = null;
        hr_ = getDeviceVtbl(device.?).CreateCommandAllocator(device.?, .COMPUTE, &IID_ID3D12CommandAllocator, &allocator);
        if (hr_ < 0) return error.CommandAllocatorFailed;
        self.cmd_allocator = allocator;

        var cmd_list: ?*anyopaque = null;
        hr_ = getDeviceVtbl(device.?).CreateCommandList(device.?, 0, .COMPUTE, allocator, null, &IID_ID3D12GraphicsCommandList, &cmd_list);
        if (hr_ < 0) return error.CommandListFailed;
        self.cmd_list = cmd_list;

        var fence: ?*anyopaque = null;
        hr_ = getDeviceVtbl(device.?).CreateFence(device.?, 0, 0, &IID_ID3D12Fence, &fence);
        if (hr_ < 0) return error.FenceFailed;
        self.fence = fence;
        self.fence_value = 0;

        self.event = @intFromPtr(try windows.CreateEventExW(null, null, 0, windows.EVENT_ALL_ACCESS));

        var heap: ?*anyopaque = null;
        const heap_desc = D3D12_DESCRIPTOR_HEAP_DESC{
            .Type = .CBV_SRV_UAV,
            .NumDescriptors = 64,
            .Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,
            .NodeMask = 0,
        };
        std.debug.print("heap_desc size={} type={} num={} flags={} node={}\n", .{
            @sizeOf(D3D12_DESCRIPTOR_HEAP_DESC), @intFromEnum(heap_desc.Type), heap_desc.NumDescriptors, heap_desc.Flags, heap_desc.NodeMask,
        });
        hr_ = getDeviceVtbl(device.?).CreateDescriptorHeap(device.?, &heap_desc, &IID_ID3D12DescriptorHeap, &heap);
        std.debug.print("CreateDescriptorHeap: hr=0x{x} heap=0x{x}\n", .{ @as(u32, @bitCast(hr_)), @intFromPtr(heap) });
        if (hr_ < 0) return error.DescriptorHeapFailed;
        self.uav_heap = heap;
        self.uav_heap_increment = getDeviceVtbl(device.?).GetDescriptorHandleIncrementSize(device.?, .CBV_SRV_UAV);
        std.debug.print("heap_inc={}\n", .{self.uav_heap_increment});

        var samp_heap: ?*anyopaque = null;
        const samp_heap_desc = D3D12_DESCRIPTOR_HEAP_DESC{
            .Type = .SAMPLER,
            .NumDescriptors = 16,
            .Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,
            .NodeMask = 0,
        };
        hr_ = getDeviceVtbl(device.?).CreateDescriptorHeap(device.?, &samp_heap_desc, &IID_ID3D12DescriptorHeap, &samp_heap);
        if (hr_ < 0) return error.SamplerHeapFailed;
        self.sampler_heap = samp_heap;
        self.sampler_heap_increment = getDeviceVtbl(device.?).GetDescriptorHandleIncrementSize(device.?, .SAMPLER);

        try self.createComputeRootSignature();
        try self.createTrivialPSO(
            \\RWBuffer<float> buf : register(u0);
            \\[numthreads(64, 1, 1)]
            \\void main(uint3 tid : SV_DispatchThreadID) {
            \\    buf[tid.x] = float(tid.x * 2);
            \\}
        );

        _ = getCmdListVtbl(cmd_list.?).Close(cmd_list.?);
    }

    fn createComputeRootSignature(self: *ComputeContext) !void {
        var blob: ?*anyopaque = null;
        var err_blob: ?*anyopaque = null;

        // One descriptor table with a UAV range
        var ranges = [1]d3d.D3D12_DESCRIPTOR_RANGE{
            .{
                .RangeType = .UAV,
                .NumDescriptors = 1,
                .BaseShaderRegister = 0,
                .RegisterSpace = 0,
                .OffsetInDescriptorsFromTableStart = 0,
            },
        };
        var params = [1]d3d.D3D12_ROOT_PARAMETER{
            .{
                .ParameterType = .DESCRIPTOR_TABLE,
                ._u = .{ .DescriptorTable = .{
                    .NumDescriptorRanges = 1,
                    .pDescriptorRanges = @as(*const d3d.D3D12_DESCRIPTOR_RANGE, @ptrCast(&ranges)),
                } },
                .ShaderVisibility = .ALL,
            },
        };
        var root_desc = d3d.D3D12_ROOT_SIGNATURE_DESC{
            .NumParameters = 1,
            .pParameters = @as(?*const d3d.D3D12_ROOT_PARAMETER, @ptrCast(&params)),
            .NumStaticSamplers = 0,
            .pStaticSamplers = null,
            .Flags = 0,
        };

        var hr_ = self.D3D12SerializeRootSignature.?(
            &root_desc,
            @as(u32, 1), // D3D_ROOT_SIGNATURE_VERSION_1_0
            &blob,
            &err_blob,
        );
        if (hr_ < 0) {
            if (err_blob) |eb| {
                const vtbl = d3d.getBlobVtbl(eb);
                const ptr = vtbl.GetBufferPointer(eb);
                if (@intFromPtr(ptr) != 0)
                    std.debug.print("Error: {s}\n", .{@as([*:0]u8, @ptrCast(@alignCast(ptr)))});
            }
            return error.RootSignatureFailed;
        }

        const blob_size = d3d.getBlobVtbl(blob.?).GetBufferSize(blob.?);
        const blob_ptr = d3d.getBlobVtbl(blob.?).GetBufferPointer(blob.?);
        std.debug.print("Blob: size={} ptr=0x{x}\n", .{ blob_size, @intFromPtr(blob_ptr) });

        hr_ = getDeviceVtbl(self.device.?).CreateRootSignature(
            self.device.?, 0, blob_ptr, blob_size,
            &IID_ID3D12RootSignature, &self.root_sig,
        );
        std.debug.print("CreateRootSignature: hr=0x{x}\n", .{ @as(u32, @bitCast(hr_)) });
        if (hr_ < 0) return error.RootSignatureFailed;
    }

    pub fn createTrivialPSO(self: *ComputeContext, shader_src: []const u8) !void {
        const shader_code = try compileShaderSource(shader_src);

        std.debug.print("shader_code len={} first_bytes={x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}\n", .{
            shader_code.len,
            @as(u32, if (shader_code.len > 0) shader_code[0] else 0),
            @as(u32, if (shader_code.len > 1) shader_code[1] else 0),
            @as(u32, if (shader_code.len > 2) shader_code[2] else 0),
            @as(u32, if (shader_code.len > 3) shader_code[3] else 0),
            @as(u32, if (shader_code.len > 4) shader_code[4] else 0),
            @as(u32, if (shader_code.len > 5) shader_code[5] else 0),
            @as(u32, if (shader_code.len > 6) shader_code[6] else 0),
            @as(u32, if (shader_code.len > 7) shader_code[7] else 0),
        });
        std.debug.print("pso_desc: size={} root_sig=0x{x} shader_ptr=0x{x}\n", .{
            @sizeOf(D3D12_COMPUTE_PIPELINE_STATE_DESC),
            @intFromPtr(self.root_sig),
            @intFromPtr(shader_code.ptr),
        });
        const desc = D3D12_COMPUTE_PIPELINE_STATE_DESC{
            .pRootSignature = self.root_sig,
            .CS = .{
                .pShaderBytecode = shader_code.ptr,
                .BytecodeLength = shader_code.len,
            },
        };
        var pso: ?*anyopaque = null;
        const hr_ = getDeviceVtbl(self.device.?).CreateComputePipelineState(self.device.?, &desc, &IID_ID3D12PipelineState, &pso);
        std.debug.print("CreateComputePipelineState: hr=0x{x}\n", .{@as(u32, @bitCast(hr_))});
        if (hr_ < 0) return error.PSOFailed;
        self.pso = pso;
    }

    pub fn copyResource(self: *ComputeContext, dst: ?*anyopaque, src: ?*anyopaque) void {
        getCmdListVtbl(self.cmd_list.?).CopyResource(self.cmd_list.?, dst, src);
    }

    pub fn deinit(self: *ComputeContext) void {
        if (self.event != 0) windows.CloseHandle(@as(windows.HANDLE, @ptrFromInt(self.event)));
        release(self.fence);
        release(self.pso);
        release(self.root_sig);
        release(self.uav_heap);
        release(self.sampler_heap);
        release(self.cmd_list);
        release(self.cmd_allocator);
        release(self.queue);
        release(self.device);
        if (self.d3d12_module) |m| _ = windows.kernel32.FreeLibrary(@ptrCast(m));
    }

    pub fn beginFrame(self: *ComputeContext) !void {
        _ = getAllocatorVtbl(self.cmd_allocator.?).Reset(self.cmd_allocator.?);
        _ = getCmdListVtbl(self.cmd_list.?).Reset(self.cmd_list.?, self.cmd_allocator, null);
        getCmdListVtbl(self.cmd_list.?).SetPipelineState(self.cmd_list.?, self.pso);
        getCmdListVtbl(self.cmd_list.?).SetComputeRootSignature(self.cmd_list.?, self.root_sig);
        var heaps = [_]?*anyopaque{self.uav_heap};
        getCmdListVtbl(self.cmd_list.?).SetDescriptorHeaps(self.cmd_list.?, 1, &heaps);
    }

    pub fn dispatch(self: *ComputeContext, x: u32, y: u32, z: u32, uav_gpu_handle: D3D12_GPU_DESCRIPTOR_HANDLE) void {
        getCmdListVtbl(self.cmd_list.?).SetComputeRootDescriptorTable(self.cmd_list.?, 0, uav_gpu_handle.ptr);
        getCmdListVtbl(self.cmd_list.?).Dispatch(self.cmd_list.?, x, y, z);
    }

    pub fn endFrame(self: *ComputeContext) !void {
        _ = getCmdListVtbl(self.cmd_list.?).Close(self.cmd_list.?);
        var lists = [_]?*anyopaque{self.cmd_list};
        getQueueVtbl(self.queue.?).ExecuteCommandLists(self.queue.?, 1, &lists);
    }

    pub fn submitAndWait(self: *ComputeContext) !void {
        self.fence_value += 1;
        _ = getQueueVtbl(self.queue.?).Signal(self.queue.?, self.fence, self.fence_value);
        _ = getFenceVtbl(self.fence.?).SetEventOnCompletion(self.fence.?, self.fence_value, @ptrFromInt(self.event));
        try windows.WaitForSingleObject(@as(windows.HANDLE, @ptrFromInt(self.event)), windows.INFINITE);
    }

    pub fn createBuffer(self: *ComputeContext, size: u64, heap_type: d3d.D3D12_HEAP_TYPE, initial_state: D3D12_RESOURCE_STATES, flags: u32) !?*anyopaque {
        const props = D3D12_HEAP_PROPERTIES{
            .Type = heap_type,
            .CPUPageProperty = 0,
            .MemoryPoolPreference = 0,
            .CreationNodeMask = 1,
            .VisibleNodeMask = 1,
        };
        const desc = D3D12_RESOURCE_DESC{
            .Dimension = .BUFFER,
            .Alignment = 65536,
            .Width = size,
            .Height = 1,
            .DepthOrArraySize = 1,
            .MipLevels = 1,
            .Format = .UNKNOWN,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Layout = .ROW_MAJOR,
            .Flags = flags,
        };
        var resource: ?*anyopaque = null;
        const hr_ = getDeviceVtbl(self.device.?).CreateCommittedResource(
            self.device.?,
            &props,
            D3D12_HEAP_FLAG_NONE,
            &desc,
            initial_state,
            null,
            &IID_ID3D12Resource,
            &resource,
        );
        if (hr_ < 0) return error.BufferFailed;
        return resource;
    }

    pub fn createUAVDesc(_: ?*anyopaque, num_elements: u32) D3D12_UNORDERED_ACCESS_VIEW_DESC {
        return .{
            .Format = .R32_FLOAT,
            .ViewDimension = .BUFFER,
            ._u = .{ .Buffer = .{
                .FirstElement = 0,
                .NumElements = num_elements,
                .StructureByteStride = 0,
                .CounterOffsetInBytes = 0,
                .Flags = 0,
            }},
        };
    }

    pub fn getUAVCPUHandle(self: *ComputeContext, index: u32) D3D12_CPU_DESCRIPTOR_HANDLE {
        var start: D3D12_CPU_DESCRIPTOR_HANDLE = undefined;
        _ = getHeapVtbl(self.uav_heap.?).GetCPUDescriptorHandleForHeapStart(self.uav_heap.?, &start);
        return .{ .ptr = start.ptr + index * self.uav_heap_increment };
    }

    pub fn getUAVGPUHandle(self: *ComputeContext, index: u32) D3D12_GPU_DESCRIPTOR_HANDLE {
        var start: D3D12_GPU_DESCRIPTOR_HANDLE = undefined;
        _ = getHeapVtbl(self.uav_heap.?).GetGPUDescriptorHandleForHeapStart(self.uav_heap.?, &start);
        return .{ .ptr = start.ptr + index * self.uav_heap_increment };
    }

    pub fn mapBuffer(resource: ?*anyopaque) !*anyopaque {
        var ptr: *anyopaque = undefined;
        const hr_ = getResourceVtbl(resource.?).Map(resource.?, 0, null, @as(?**anyopaque, @ptrCast(&ptr)));
        std.debug.print("Map hr=0x{x}\n", .{@as(u32, @bitCast(hr_))});
        if (hr_ < 0) return error.MapFailed;
        return ptr;
    }

    pub fn unmapBuffer(resource: ?*anyopaque) void {
        getResourceVtbl(resource.?).Unmap(resource.?, 0, null);
    }

    pub fn bufferGPUVAddr(resource: ?*anyopaque) u64 {
        return getResourceVtbl(resource.?).GetGPUVirtualAddress(resource.?);
    }

    pub fn createUAVView(self: *ComputeContext, resource: ?*anyopaque, desc: *const D3D12_UNORDERED_ACCESS_VIEW_DESC, cpu_handle: D3D12_CPU_DESCRIPTOR_HANDLE) void {
        getDeviceVtbl(self.device.?).CreateUnorderedAccessView(self.device.?, resource, null, desc, cpu_handle);
    }

    pub fn bufferBarrier(cmd_list: ?*anyopaque, resource: ?*anyopaque, before: D3D12_RESOURCE_STATES, after: D3D12_RESOURCE_STATES) void {
        const barrier = D3D12_RESOURCE_BARRIER{
            .Type = .TRANSITION,
            .Flags = D3D12_RESOURCE_BARRIER_FLAG_NONE,
            ._u = .{ .Transition = .{
                .pResource = resource,
                .Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
                .StateBefore = before,
                .StateAfter = after,
            }},
        };
        getCmdListVtbl(cmd_list.?).ResourceBarrier(cmd_list.?, 1, &barrier);
    }

    pub fn createTexture2D(self: *ComputeContext, width: u32, height: u32, format: d3d.DXGI_FORMAT, initial_state: D3D12_RESOURCE_STATES, flags: u32) !?*anyopaque {
        const props = D3D12_HEAP_PROPERTIES{
            .Type = .DEFAULT,
            .CPUPageProperty = 0,
            .MemoryPoolPreference = 0,
            .CreationNodeMask = 1,
            .VisibleNodeMask = 1,
        };
        const desc = D3D12_RESOURCE_DESC{
            .Dimension = .TEXTURE2D,
            .Alignment = 0,
            .Width = width,
            .Height = height,
            .DepthOrArraySize = 1,
            .MipLevels = 1,
            .Format = format,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Layout = .UNKNOWN,
            .Flags = flags,
        };
        var resource: ?*anyopaque = null;
        const hr_ = getDeviceVtbl(self.device.?).CreateCommittedResource(
            self.device.?,
            &props,
            D3D12_HEAP_FLAG_NONE,
            &desc,
            initial_state,
            null,
            &IID_ID3D12Resource,
            &resource,
        );
        if (hr_ < 0) return error.TextureFailed;
        return resource;
    }

    pub fn createUAVTexture2DDesc(_: *ComputeContext, mip_slice: u32) D3D12_UNORDERED_ACCESS_VIEW_DESC {
        return .{
            .Format = .R32_FLOAT,
            .ViewDimension = .TEXTURE2D,
            ._u = .{ .Texture2D = .{ .MipSlice = mip_slice, .PlaneSlice = 0 } },
        };
    }

    pub fn createUAVViewTexture(self: *ComputeContext, resource: ?*anyopaque, desc: *const D3D12_UNORDERED_ACCESS_VIEW_DESC, cpu_handle: D3D12_CPU_DESCRIPTOR_HANDLE) void {
        getDeviceVtbl(self.device.?).CreateUnorderedAccessView(self.device.?, resource, null, desc, cpu_handle);
    }

    pub fn createSRVTexture2DDesc(_: *ComputeContext, mip_levels: u32) D3D12_SHADER_RESOURCE_VIEW_DESC {
        return .{
            .Format = .R32_FLOAT,
            .ViewDimension = .TEXTURE2D,
            .Shader4ComponentMapping = 0x1608,
            ._u = .{ .Texture2D = .{ .MostDetailedMip = 0, .MipLevels = mip_levels, .PlaneSlice = 0, .ResourceMinLODClamp = 0 } },
        };
    }

    pub fn createSRV(self: *ComputeContext, resource: ?*anyopaque, desc: *const D3D12_SHADER_RESOURCE_VIEW_DESC, cpu_handle: D3D12_CPU_DESCRIPTOR_HANDLE) void {
        getDeviceVtbl(self.device.?).CreateShaderResourceView(self.device.?, resource, desc, cpu_handle);
    }

    pub fn createSamplerDesc(self: *ComputeContext) D3D12_SAMPLER_DESC {
        _ = self;
        return .{
            .Filter = .MIN_MAG_MIP_LINEAR,
            .AddressU = .CLAMP,
            .AddressV = .CLAMP,
            .AddressW = .CLAMP,
            .MipLODBias = 0,
            .MaxAnisotropy = 1,
            .ComparisonFunc = .NEVER,
            .BorderColor = .{ 0, 0, 0, 0 },
            .MinLOD = 0,
            .MaxLOD = 3.40282347e+38,
        };
    }

    pub fn createSampler(self: *ComputeContext, desc: *const D3D12_SAMPLER_DESC, cpu_handle: D3D12_CPU_DESCRIPTOR_HANDLE) void {
        getDeviceVtbl(self.device.?).CreateSampler(self.device.?, desc, cpu_handle);
    }

    pub fn getSamplerCPUHandle(self: *ComputeContext, index: u32) D3D12_CPU_DESCRIPTOR_HANDLE {
        var start: D3D12_CPU_DESCRIPTOR_HANDLE = undefined;
        _ = getHeapVtbl(self.sampler_heap.?).GetCPUDescriptorHandleForHeapStart(self.sampler_heap.?, &start);
        return .{ .ptr = start.ptr + index * self.sampler_heap_increment };
    }

    pub fn getSamplerGPUHandle(self: *ComputeContext, index: u32) D3D12_GPU_DESCRIPTOR_HANDLE {
        var start: D3D12_GPU_DESCRIPTOR_HANDLE = undefined;
        _ = getHeapVtbl(self.sampler_heap.?).GetGPUDescriptorHandleForHeapStart(self.sampler_heap.?, &start);
        return .{ .ptr = start.ptr + index * self.sampler_heap_increment };
    }

    pub fn getTextureFootprint(self: *ComputeContext, width: u32, height: u32, format: d3d.DXGI_FORMAT) !u64 {
        const desc = D3D12_RESOURCE_DESC{
            .Dimension = .TEXTURE2D,
            .Alignment = 0,
            .Width = width,
            .Height = height,
            .DepthOrArraySize = 1,
            .MipLevels = 1,
            .Format = format,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Layout = .UNKNOWN,
            .Flags = 0,
        };
        var footprint: D3D12_PLACED_SUBRESOURCE_FOOTPRINT = undefined;
        var total_bytes: u64 = 0;
        getDeviceVtbl(self.device.?).GetCopyableFootprints(
            self.device.?,
            &desc,
            0,
            1,
            0,
            &footprint,
            null,
            null,
            &total_bytes,
        );
        return total_bytes;
    }

    pub fn copyTextureToBuffer(self: *ComputeContext, dst_buffer: ?*anyopaque, src_texture: ?*anyopaque, width: u32, height: u32, format: d3d.DXGI_FORMAT) u32 {
        const desc = D3D12_RESOURCE_DESC{
            .Dimension = .TEXTURE2D,
            .Alignment = 0,
            .Width = width,
            .Height = height,
            .DepthOrArraySize = 1,
            .MipLevels = 1,
            .Format = format,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Layout = .UNKNOWN,
            .Flags = 0,
        };
        var footprint: D3D12_PLACED_SUBRESOURCE_FOOTPRINT = undefined;
        getDeviceVtbl(self.device.?).GetCopyableFootprints(
            self.device.?,
            &desc,
            0,
            1,
            0,
            &footprint,
            null,
            null,
            null,
        );
        const dst_loc = D3D12_TEXTURE_COPY_LOCATION{
            .pResource = dst_buffer,
            .Type = .PLACED_FOOTPRINT,
            ._u = .{ .PlacedFootprint = footprint },
        };
        const src_loc = D3D12_TEXTURE_COPY_LOCATION{
            .pResource = src_texture,
            .Type = .SUBRESOURCE_INDEX,
            ._u = .{ .SubresourceIndex = 0 },
        };
        getCmdListVtbl(self.cmd_list.?).CopyTextureRegion(self.cmd_list.?, &dst_loc, 0, 0, 0, &src_loc, null);
        return footprint.Footprint.RowPitch;
    }
};

// --- Blob helpers ---

fn getBlobData(blob: ?*anyopaque) *const anyopaque {
    return getBlobVtbl(blob.?).GetBufferPointer(blob.?);
}

fn getBlobSize(blob: ?*anyopaque) usize {
    return getBlobVtbl(blob.?).GetBufferSize(blob.?);
}

fn releaseBlob(blob: ?*anyopaque) void {
    release(blob);
}

// --- DXGI helpers ---

fn loadDXGI() !windows.HMODULE {
    return try windows.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dxgi.dll"));
}

const IID_IDXGIFactory1 = d3d.GUID.parse("{770aae78-f26f-4dba-a829-253c83d1b387}");

fn createDXGIFactory(dxgi: windows.HMODULE) !?*anyopaque {
    const create1 = windows.kernel32.GetProcAddress(dxgi, "CreateDXGIFactory1");
    var factory: ?*anyopaque = null;
    if (create1) |fn_ptr| {
        const fn1: *const fn (*const d3d.GUID, *?*anyopaque) callconv(.winapi) hr = @ptrCast(fn_ptr);
        const rc = fn1(&IID_IDXGIFactory1, &factory);
        if (rc < 0) return error.DXGIFactoryFailed;
    } else {
        const create = windows.kernel32.GetProcAddress(dxgi, "CreateDXGIFactory") orelse
            return error.NoCreateDXGIFactory;
        const fn0: *const fn (*const d3d.GUID, *?*anyopaque) callconv(.winapi) hr = @ptrCast(create);
        const rc = fn0(&IID_IDXGIFactory1, &factory);
        if (rc < 0) return error.DXGIFactoryFailed;
    }
    return factory;
}

fn findAdapter(factory: ?*anyopaque) !?*anyopaque {
    const vtbl = getFactoryVtbl(factory.?);
        var adapter: ?*anyopaque = null;
    const hr_ = vtbl.EnumAdapters(factory.?, 0, &adapter);
    if (hr_ >= 0 and adapter != null) return adapter;

    const hr2_ = vtbl.EnumAdapters1(factory.?, 0, &adapter);
    if (hr2_ >= 0 and adapter != null) return adapter;

    return error.NoAdapter;
}

// --- Shader compilation via D3DCompile ---

const D3DCompile = *const fn (
    pSrcData: *const anyopaque,
    SrcDataSize: usize,
    pFileName: [*:0]const u8,
    pDefines: ?*const anyopaque,
    pInclude: ?*anyopaque,
    pEntrypoint: [*:0]const u8,
    pTarget: [*:0]const u8,
    Flags1: u32,
    Flags2: u32,
    ppCode: *?*anyopaque,
    ppErrorMsgs: ?*?*anyopaque,
) callconv(CC) hr;

var compiled_module: ?windows.HMODULE = null;
var d3dcompile_fn: ?D3DCompile = null;

fn getD3DCompile() !D3DCompile {
    if (d3dcompile_fn) |fn_ptr| return fn_ptr;
    const mod = try windows.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3dcompiler_47.dll"));
    compiled_module = @ptrCast(mod);
    const ptr = windows.kernel32.GetProcAddress(mod, "D3DCompile") orelse return error.NoD3DCompile;
    d3dcompile_fn = @ptrCast(ptr);
    return d3dcompile_fn.?;
}

pub fn compileShaderSource(shader_src: []const u8) ![]const u8 {
    const compile = try getD3DCompile();
    var blob: ?*anyopaque = null;
    var err_blob: ?*anyopaque = null;
    const hr_ = compile(
        shader_src.ptr,
        shader_src.len,
        "shader.hlsl",
        null,
        null,
        "main",
        "cs_5_1",
        0,
        0,
        &blob,
        &err_blob,
    );
    if (hr_ < 0) {
        if (err_blob) |eb| {
            const vtbl = d3d.getBlobVtbl(eb);
            const ptr = vtbl.GetBufferPointer(eb);
            if (@intFromPtr(ptr) != 0)
                std.debug.print("Compile error: {s}\n", .{@as([*:0]u8, @ptrCast(@alignCast(ptr)))});
        }
        return error.ShaderCompileFailed;
    }
    const vtbl = d3d.getBlobVtbl(blob.?);
    const size = vtbl.GetBufferSize(blob.?);
    const ptr = vtbl.GetBufferPointer(blob.?);
    const result = try std.heap.page_allocator.dupe(u8, @as([*]const u8, @ptrCast(@alignCast(ptr)))[0..size]);
    d3d.release(blob);
    if (err_blob) |eb| d3d.release(eb);
    std.debug.print("Compiled shader: {} bytes\n", .{result.len});
    return result;
}
