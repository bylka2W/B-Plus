# B+ Compiler

A self-contained compiler + runtime for a custom language on Windows x64. Generates native PE executables and DLLs with zero runtime dependencies.

Язык B+ поддерживает `struct`, `enum`, `parallel`, `kernel`, `extern`, `context`, `guard`, `export entry`, `forward` (прокси-DLL), аннотации (`@hot/@cold/@cache`), компиляцию в HLSL (`bpc hlsl`) с wave-операциями, cbuffer, groupshared, Texture2D/RWTexture2D.

## GPU Backend Architecture (Zig)

The GPU backend is a layered architecture that bridges the FrameGraph temporal compute DAG to DX12 compute:

```
FrameGraph (ExecutionPlan)
    ↓
GPU IR (BindingKey, PipelineKey, DispatchDesc)
    ↓
Root Signature Builder (per-pass RS from BindLayout)
    ↓
Resource Pool (RS-driven descriptor allocation, state tracking)
    ↓
DX12 Compute (ComputeContext — command lists, barriers, dispatch)
```

### Source Files

| File | Purpose |
|------|---------|
| `gpu_ir.zig` | GPU IR types: `BindingKey{reg,space,kind}`, `BindEntry`, `BindGroup`, `PipelineKey`, `DispatchDesc`, `ResourceId`, `ResourceState`, `BarrierDesc` |
| `root_signature_builder.zig` | `RSRootSignatureBuilder` — per-pass root signature compiled from `BindLayout`, cached by layout hash. Produces `CompiledRS{root_signature, ranges, total_descriptors}` with validate/getHeapOffset |
| `resource_system.zig` | `ResourcePool` — GPU resource lifecycle (create Buffer/Texture2D, state tracking via barriers, RS-driven descriptor heap writes with validation) |
| `frame_graph_executor.zig` | `FrameGraphGPUExecutor` — orchestrates multi-pass GPU execution: per-pass RS/PSO, shader compilation cache, barrier application, dispatch, fence sync |
| `frame_graph.zig` | FrameGraph: `Pass`, `ExecutionNode`, `ExecutionPlan` — temporal compute DAG IR with intra/inter-frame edges, topo sort, budget enforcement |
| `gpu_job.zig` | `GPUJob` dispatch descriptor (dispatch dims, semaphores, priority) |
| `gpu_scheduler.zig` | `GPUScheduler` — pure GPU dispatch sink (budget-aware, dropable jobs) |
| `dx12_compute.zig` | `ComputeContext` — raw D3D12: device init, buffer/texture creation, SRV/UAV views, descriptor heaps, command list recording, barriers, fence sync, readback, shader compilation via `d3dcompiler_47` |
| `d3d12_bindings.zig` | Pure Zig COM vtbl bindings for D3D12/DXGI — no `cImport`, no SDK headers at build time |

### Key Design Decisions

**Register-based binding model:**
- `BindingKey(reg, space, kind)` replaces linear `slot_index`
- `slotIndex()` provides deterministic mapping: SRV→0..255, UAV→256..511, CBV→512..767
- No iteration-order dependency — sparse-safe

**Per-pass root signature:**
- `RSRootSignatureBuilder` derives exact RS from `BindLayout`
- Only uses descriptors the shader actually needs (not 256+256 hardcoded)
- Cached by layout hash; validated against bindings at dispatch time

**Unified descriptor heap:**
- 1024-entry CBV_SRV_UAV heap shared across all passes
- RS defines which portions are accessible; `setupDescriptorHeap` writes at RS-computed offsets

### Build & Run Tests

```
zig build-exe src\gpu_executor_test.zig --name gpu_executor_test -ld3d12 -ldxgi -ld3dcompiler_47
.\gpu_executor_test.exe
```


