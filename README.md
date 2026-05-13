# B+ v3.0.4L BETA — state machine + Metal Stack + AI + µarch + NUMA + ILP + AutoTune

B+ — язык описания конечных автоматов (state machine) с транспиляцией в **Python, C#, C++, C, LLVM IR, HLSL (DXIL), GLSL (SPIR-V)**. Плагины для **Unity, Unreal Engine, Godot, Web (TypeScript), Unigine**. Никакого рантайма.

**v3.0.4L BETA**: NUMA placement (`@numa`), Store forwarding guard (`@store_forward_safe`), µarch profiles (Agner Fog tables for Intel/AMD/ARM), ILP dependency analyzer, Auto-Tune (hardware perf counters → AI retrain).

---

## Быстрый старт

```bash
git clone https://github.com/CapGames221/B-Plus.git "B+ v1.0"
cd "B+ v1.0"
dotnet run --project src/BPlusTranspiler -- examples/traffic_light.bp
```

Нужен [.NET 8 SDK](https://dotnet.microsoft.com/download).

---

## B+ Syntax Reference

### State machine
```bp
state Red {
    on timer -> Green   enter { stop_traffic() }
}
state Green {
    on timer -> Yellow  enter { allow_traffic() }
}
```

### Variables + types
```bp
state HttpParser {
    var buffer_pos: int
    var buffer: string
    var flags: byte
    @fast_path
    var hot_counter: int
}
```

### GPU kernels
```bp
kernel upscale(src: Image[1080, 1920]) -> Image[2160, 3840]
    body: src |> relu |> shuffle >> output
```

### Pipeline operations
```bp
pipeline process(tex: Image[512, 512]) -> Image[512, 512]
    step blur: gaussian_blur(tex, sigma=1.5)
    step edge: sobel(blur)
    step final: relu(edge)
```

### Streaming parser (Ragel-style)
```bp
#parser
state HttpParser {
    on 'G' -> ExpectGet
    on 'H' -> ExpectHeader
}
```

### Memory comptime
```bp
#memory comptime
kernel safe(src: Image[1080, 1920]) -> Image[1080, 1920]
    touches: reads[src], writes[output]
    body: src |> relu >> output
```

### GPU annotations
```bp
@simd_width(512)
@simd_unroll(8)
@simd_gather
kernel process(src: Image[1080, 1920]) -> Image[1080, 1920]
    body: src |> relu >> output
```

### Metal annotations
```bp
@metal {
    @tier(0)                    // L0 — µop cache
    @register(r8)               // GPR pin
    @zmm(7)                     // ZMM register
    @mask(k5)                   // mask register
    @fusion(dec+jnz)            // macro-fusion pair
    @section("my_hot_code")     // custom linker section
    @gateway(L3)                // cold gateway
    @prefetch(t0)               // prefetch hint
    @align(128)                 // alignment
    @packed                     // bitfield packing
    @data_tier(2)               // data in L2
    @critical_size(8192)        // hot size hint
    @hot_path(true)             // hot path annotation
    @numa(0)                    // NUMA node bind
    @store_forward_safe          // guard store forwarding
    @muarch(amd_zen4)           // target µarch
    @ilp_max(4)                 // max dependency chain
}
```

---

## CLI Reference — полный список флагов

```bash
# === Compilation ===
bpc input.bp                          # все цели
bpc input.bp --target llvm            # LLVM IR
bpc input.bp --target cpp             # C++ only
bpc input.bp --target dxil            # HLSL (DX12)
bpc input.bp --target spirv           # GLSL (Vulkan)
bpc input.bp --output ./dir           # кастомный выход

# === Metal Stack (L0–L3, cache-aware code gen) ===
bpc input.bp --metal                  # полный стек
bpc input.bp --metal --tier=L0        # принудительный tier
bpc input.bp --metal --fusion         # fusion-aware
bpc input.bp --metal --register-alloc # аллокация регистров
bpc input.bp --metal --unpack         # AI-распаковщик
bpc input.bp --metal --hidden-buffers # LSD/LFB/TLB/BTB/RSB

# === AI Optimizer ===
bpc input.bp --ai                     # AI-оптимизация metal
bpc input.bp --auto-tune [N]          # Auto-Tune: AI + perf counters
bpc --train-unpack                    # обучить UnpackPredictor

# === Analysis ===
bpc input.bp --roofline               # Roofline model
bpc input.bp --ilp                    # ILP dependency chains
bpc input.bp --store-fwd              # Store forwarding hazards
bpc --muarch                          # µarch profile (Agner Fog)
bpc input.bp --buffer-counters        # Store/Load buffer PMC analysis

# === PGO + BOLT ===
bpc input.bp --pgo                    # Full PGO pipeline: instrument→run→merge→recompile   +15-25%
bpc input.bp --pgo --pgo-use file      # Use existing profile
bpc input.bp --bolt [--binary path]   # BOLT post-link: reorder code by hot paths        +10-20%

# === PGO / Optimization ===
bpc input.bp --optimize               # таблица переходов
bpc input.bp --turbo                  # optimize+pool+pack
bpc input.bp --predict                # предсказание next state

# === Streaming ===
bpc input.bp --stream                 # goto-driven parser

# === Diagnostics ===
bpc input.bp --check                  # 7 категорий ошибок
bpc health                            # мёртвые состояния
bpc diff old.bp new.bp                # семантическое сравнение

# === Engine Plugins ===
bpc input.bp --plugin unity           # MonoBehaviour
bpc input.bp --plugin unreal          # UCLASS Actor
bpc input.bp --plugin godot           # Godot Node
bpc input.bp --plugin web             # TypeScript
bpc input.bp --plugin unigine         # Unigine Component

# === Tools ===
bpc --visualize input.bp              # граф (Mermaid)
bpc format input.bp                   # автоформатирование
bpc docs input.bp                     # документация
bpc debug input.bp                    # дебаггер
bpc profile input.bp 100000           # профайлинг
bpc watch . --target cpp              # автоперегенерация
bpc --lsp                             # LSP сервер
bpc --install-lsp                     # VS Code extension
bpc build                             # сборка по bp.toml
bpc publish --runtime linux-x64 --aot # NativeAOT binary
bpc test run input.bp                 # авто-тесты
```

---

## 6 языков — пример кода

### 1. Python
```bp
state TrafficLight {
    on timer -> Red
}
```
```python
class TrafficLight(State):
    def on_timer(self):
        return StateRed
```

### 2. C#
```bp
state Player {
    on hit -> Damaged
}
```
```csharp
class Player : State {
    public State OnHit() => new Damaged();
}
```

### 3. C++ (table-driven, optimized)
```bp
state Idle { @hot(0.9) on walk -> Walking }
state Walking { on stop -> Idle }
```
```cpp
StateId dispatch(Event ev) {
    switch (current) {
        case ST_Idle:
            if (ev == EV_walk) [[likely]] return ST_Walking;
            break;
        case ST_Walking:
            if (ev == EV_stop) return ST_Idle;
            break;
    }
    return current;
}
```

### 4. C (minimal embedded)
```bp
state Boot { on ready -> Run }
```
```c
typedef enum { ST_Boot, ST_Run } StateId;
StateId run(StateId current, Event ev) {
    switch (current) {
        case ST_Boot: if (ev == EV_ready) return ST_Run;
    }
    return current;
}
```

### 5. LLVM IR
```bp
kernel relu(src: Image[512, 512]) -> Image[512, 512]
    body: src |> relu >> output
```
```llvm
define void @relu_kernel(ptr %src, ptr %dst) {
entry:
    %w = alloca i32
    store i32 512, ptr %w
    %h = alloca i32
    store i32 512, ptr %h
    %total = mul i32 512, 512
    br label %loop
loop:
    %i = phi i32 [ 0, %entry ], [ %next, %loop ]
    %src_ptr = getelementptr float, ptr %src, i32 %i
    %val = load float, ptr %src_ptr
    %cmp = fcmp ogt float %val, 0.0
    %relu = select i1 %cmp, float %val, float 0.0
    %dst_ptr = getelementptr float, ptr %dst, i32 %i
    store float %relu, ptr %dst_ptr
    %next = add i32 %i, 1
    %done = icmp eq i32 %next, %total
    br i1 %done, label %exit, label %loop
exit:
    ret void
}
```

### 6. HLSL (DirectX 12 compute shader)
```bp
kernel blur(src: Image[1080, 1920]) -> Image[1080, 1920]
    body: src |> convolve(weights) >> output
```
```hlsl
[numthreads(16, 16, 1)]
void CSMain(uint3 id : SV_DispatchThreadID) {
    if (id.x >= 1920 || id.y >= 1080) return;
    float4 result = float4(0,0,0,0);
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++) {
            uint2 px = uint2(clamp((int)id.x + dx, 0, 1919), clamp((int)id.y + dy, 0, 1079));
            result += Input[px * 4] * kernel[dy + 1][dx + 1];
        }
    Output[id * 4] = result;
}
```

---

## Структура проекта

```
B+ v1.0/
├── src/BPlusTranspiler/
│   ├── Ast/                     — AST nodes + MetalNodes
│   ├── Parser/                  — B+ parser + MetalParser
│   ├── Optimizer/
│   │   ├── TierClassifier.cs    — L0/L1/L2/L3 + working set
│   │   ├── CodePacker.cs        — µop bundles, splicing
│   │   ├── DataPacker.cs        — fields + false-sharing padding
│   │   ├── RegisterAllocator.cs — GPR/ZMM/Mask allocation
│   │   ├── RegisterPacker.cs    — AI variable→register packer
│   │   ├── PrefetchInjector.cs  — latency-aware prefetch
│   │   ├── HiddenBufferOptimizer — LSD/LFB/TLB/BTB/RSB
│   │   ├── MicroArchProfile.cs  — Agner Fog µarch tables
│   │   ├── IlpAnalyzer.cs       — ILP dependency chains
│   │   ├── StoreForwardGuard.cs — store-forwarding hazards
│   │   ├── AutoTuner.cs         — AI + real perf counters
│   │   └── RooflineAnalyzer.cs  — Roofline model
│   ├── AI/
│   │   ├── DataCollector.cs     — samples + per-state misses
│   │   ├── NeuralPredictor.cs   — 21+→16→1 NN
│   │   ├── LayoutOptimizer.cs   — 10k config search
│   │   └── UnpackPredictor.cs   — 12→8→4 unpack NN
│   ├── Generators/
│   │   ├── LlvmGenMetal.cs      — LLVM IR + intrinsics
│   │   ├── AsmGenerator.cs      — x86-64 asm
│   │   └── LinkerScriptGenerator — .ld sections
│   └── Program.cs               — CLI entry point
├── examples/
│   ├── traffic_light.bp         — minimal example
│   └── traffic_light_metal.bp   — AI-optimized output
└── gen_metal/                   — generated LLVM IR, asm, ld
```

---

## Бенчмарк

| Версия | нс/ит | Относительно C++ |
|--------|-------|------------------|
| C++ naive (virtual) | ~30-50 нс | 1× |
| C++ table + pool | ~5-10 нс | 3-5× |
| B+ `--turbo` | ~4-8 нс | 4-6× |
| B+ `--metal` | ~2-4 нс | 8-12× |
| B+ `--metal --auto-tune` | ~1-3 нс | 10-15× |

GPU kernels: B+ **300-600%** vs C++.

---

## NativeAOT — компилятор ×4 быстрее

Было 300 мс запуска → стало ~50 мс. Self-contained бинарник без .NET Runtime.

| Оптимизация | Файл | Эффект |
|---|---|---|
| `AsSpan()` вместо `Substring()` | `Parser/BPlusParser.cs` | ×2–3 |
| `ArrayPool<double>` в AI | `AI/NeuralPredictor.cs` | ×2 |
| Кэш fd perf counters | `Runtime/MetalRuntime.cs` | ×10 |
| `Parallel.ForEach` бэкенды | `Program.cs` | ×4–8 |
| Кэш AST / CodeFeatures | `AI/DataCollector.cs` | ×2 |

```bash
# Build self-contained binary
publish.bat --aot

# Cross-platform
publish.bat --aot --linux   # linux-x64
publish.bat --aot --osx     # osx-x64

# From bpc
bpc publish --runtime win-x64 --aot
```

---

## Known Limitations (roadmap)

| Проблема | Описание | Статус |
|---|---|---|
| AI на синтетике | `NeuralPredictor` учился на 2000 сгенерированных сэмплах. **Исправлено**: DataCollector теперь читает реальные perf counters (`PerfCounterReader`), добавляет `CollectWithPerf()` для цикла run→measure→train и смешивает real + synthetic samples | ✅ v3.0.4L |
| RegisterPacker без dep graph | AI паковал переменные без проверки зависимостей — serialization stall. **Исправлено**: построен dependency graph из action body, detected conflicts (A→B) разделяются в разные регистры | ✅ v3.0.4L |
| HiddenBufferOptimizer статичен | LSD/LFB/TLB лимиты были хардкодными. **Исправлено**: теперь использует µarch профили (MicroArchProfiles) — лимиты под Intel/AMD/ARM динамически | ✅ v3.0.4L |
| Компилятор ×4 быстрее | Парсер, AI, perf counters, бэкенды оптимизированы (Span, ArrayPool, cached fd, Parallel.ForEach, AST cache) | ✅ v3.0.4L |
| NativeAOT binary | Self-contained бинарник без .NET Runtime (~50 мс запуск). `publish.bat --aot` | ✅ v3.0.4L |
| 121 real errors fixed | Cyclic inheritance, void type, depth limit, RTL filter, undefined base, parallel races, guard purity, memory conflicts, @quant checks, LLP intrinsics, malloc checks, atomics, BPM lock/SHA256, code injection, GPU barriers | ✅ v3.0.4L |
| Unit tests | Первый тест-сьют — 29 тестов, 100% pass | ✅ v3.0.4L |
| BPlusValidator | Централизованный валидатор на 121 ошибку, запускается через `bpc --check` | ✅ v3.0.4L |

---

## Лицензия

MIT
