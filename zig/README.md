# B+ Compiler

A self-contained compiler + runtime for a custom language on Windows x64. Generates native PE executables and DLLs with zero runtime dependencies.

## D3D12 Compute Pipeline (Zig)

Located in `src/`:

| File | Purpose |
|------|---------|
| `dx12_compute.zig` | `ComputeContext` — device init, buffer creation, UAV views, cmd list recording, dispatch, barriers, fence sync, readback |
| `d3d12_bindings.zig` | Pure Zig COM vtbl bindings for D3D12 / DXGI — no `cImport`, no SDK headers at build time. All vtbl structs manually declared from `d3d12.h` / `d3d12sdklayers.h` ABI |
| `gpu_compute_test.zig` | End-to-end test: creates UAV buffer → dispatches `float(tid.x * 2)` shader → barrier → copy to readback → fence sync → Map → verify 64 f32 elements |

### Build & Run

```
zig build-exe src\gpu_compute_test.zig --name gpu_compute_test -I src
.\gpu_compute_test.exe
```

### Known Limitations

- **COMPUTE queue + COMPUTE command list** works and passes. **DIRECT queue + COMPUTE list** crashes with `DXGI_ERROR_DEVICE_HUNG` (0x887A0001) on this driver (NVIDIA 32.0.15.7688 / RTX 5060 Ti) — suspect driver/runtime issue.
- InfoQueue (`ID3D12InfoQueue`) vtbl is declared but QI on device returns `E_NOINTERFACE` even with debug layer enabled.

### Architecture

All COM interfaces are loaded via `LoadLibrary` + `GetProcAddress` at runtime from `d3d12.dll` and `dxgi.dll`. No import libs. Method calls go through manually-typed extern vtbl structs with `*const fn (*anyopaque, ...) callconv(CC) ...` declarations following the Windows ABI convention (out-param pattern for struct returns via `#else` branch in SDK headers).
