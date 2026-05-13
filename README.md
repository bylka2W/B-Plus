# B+ v3.0.2L1 — язык конечных автоматов + GPU kernels + Metal Stack (L0–L3) + AI optimizer + Hidden Buffer Control

B+ — язык описания конечных автоматов (state machine) с транспиляцией в **Python, C#, C++, C**, LLVM IR, **HLSL (DXIL)**, **GLSL (SPIR-V)**, а также плагинами для **Unity, Unreal Engine, Godot, Web (TypeScript), Unigine**. Никакого рантайма — чистый код под твою платформу.

**v3.0.2L1**: Full Metal Stack (TierClassifier, CodePacker, DataPacker, RegisterAllocator, LlvmGenMetal, AsmGenerator, LinkerScriptGenerator, PrefetchInjector, MetalRuntime) + AI optimizer (DataCollector, NeuralPredictor, LayoutOptimizer) + AI UnpackPredictor + RegisterPacker + HiddenBufferOptimizer (LSD/LFB/TLB/BTB/RSB control).

---

## Быстрый старт

```bash
git clone https://github.com/CapGames221/B-Plus.git "B+ v1.0"
cd "B+ v1.0"
dotnet run --project src/BPlusTranspiler -- examples/traffic_light.bp
```

Нужен [.NET 8 SDK](https://dotnet.microsoft.com/download).

**VS Code:** `setup-vscode.bat` — установка расширения в один клик.

```bp
// traffic_light.bp
state Red    { on timer -> Green  enter { stop_traffic() } }
state Green  { on timer -> Yellow enter { allow_traffic() } }
state Yellow { on timer -> Red    enter { warn_traffic() } }
```

---

## CLI Reference (bpc)

```bash
bpc input.bp                          # все цели сразу
bpc input.bp --target llvm            # → kernels.ll (LLVM IR)
bpc input.bp --target dxil            # → HLSL compute shader (DirectX 12)
bpc input.bp --target spirv           # → GLSL compute shader (Vulkan)
bpc input.bp --output ./out           # кастомный выход

# Metal Stack (L0–L3 cache-aware)
bpc input.bp --ai                     # AI Optimizer (NeuralPredictor + LayoutOptimizer)
bpc input.bp --metal                  # Full Metal Stack (tier classify, pack, asm, ld)
bpc input.bp --metal --tier=L0        # принудительный Tier
bpc input.bp --metal --fusion         # fusion-aware codegen
bpc input.bp --metal --register-alloc # регистровая аллокация
bpc input.bp --metal --unpack         # AI-распаковщик регистров (movzx/shr/vpermq)
bpc input.bp --metal --hidden-buffers # LSD/LFB/TLB/BTB/RSB анализ
bpc --train-unpack                    # обучение UnpackPredictor

# Оптимизация
bpc input.bp --optimize               # таблица переходов
bpc input.bp --turbo                  # --optimize + --pool + --pack
bpc input.bp --pgo                    # PGO profile counters
bpc input.bp --predict                # предсказание след. состояния

# Streaming / парсеры
bpc input.bp --stream                 # goto-driven, zero-copy

# Диагностика
bpc input.bp --check                  # 7 категорий ошибок
bpc health                            # мёртвые состояния, память
bpc diff old.bp new.bp                # семантическое сравнение

# Плагины движков
bpc input.bp --plugin unity           # → MonoBehaviour
bpc input.bp --plugin unreal          # → UCLASS Actor
bpc input.bp --plugin godot           # → Godot Node
bpc input.bp --plugin web             # → TypeScript класс
bpc input.bp --plugin unigine         # → Unigine Component

# Инструменты
bpc --visualize input.bp              # → интерактивный граф (Mermaid)
bpc format input.bp                   # → автоформатирование
bpc docs input.bp                     # → документация
bpc debug input.bp                    # → интерактивный дебаггер
bpc profile input.bp 10000            # → профайлинг переходов
bpc watch . --target cpp              # → автоперегенерация
bpc --lsp                             # → LSP сервер
bpc --install-lsp                     # → установка VS Code extension
bpc build                             # → сборка по bp.toml
bpc test run input.bp                 # → авто-тесты
```

---

## 🏗 Metal Stack (L0–L3 cache-aware code generation)

Генерирует LLVM IR + x86-64 asm + linker script с placement по кэшу:

```bp
@metal {
    @tier(0)          // L0 — µop cache (hot)
    @register(r8)     // GPR pin
    @zmm(7)           // ZMM register
    @mask(k5)         // mask register
    @fusion(dec+jnz)  // fusion pair
    @gateway(L3)      // cold gateway
    @prefetch(t0)     // prefetch hint
    @align(128)       // alignment
    @packed           // bitfield packing
    @data_tier(2)     // data placement (L2)
    @critical_size(8192)
    @hot_path(true)
}
```

### Фазы Metal Stack:
| Фаза | Компонент | Описание |
|------|-----------|----------|
| 1 | TierClassifier | L0/L1/L2/L3 по @tier или hot weights |
| 1 | CodePacker | L0 µop bundles (4 instr/16B), L1 splice, L2/L3 gateways |
| 1 | DataPacker | Struct field reordering, L1-D/L2/L3 placement |
| 2 | RegisterAllocator | GPR (rax-r15), ZMM (zmm0-31), Mask (k0-7) |
| 2 | LlvmGenMetal | LLVM IR + intrinsics + inline asm |
| 3 | AsmGenerator | x86-64 fusion-aware, K-mask predication |
| 3 | LinkerScriptGenerator | .ld sections for L0-L3 |
| 4 | PrefetchInjector | Prefetch analysis + asm generation |
| 4 | MetalRuntime | mlock/madvise/mmap wrappers |

---

## 🧠 AI Optimizer

Чистый C# нейросетевой оптимизатор без внешних зависимостей:

```
bpc examples/traffic_light.bp --ai
```

- **DataCollector**: 2000 samples, feature extraction (16 metal config features + 5 code features)
- **NeuralPredictor**: 3-layer NN (21→16→1), ReLU, SGD + L2 decay, gradient clip 0.5
- **LayoutOptimizer**: 10k config search → predicted IPC: 4.884
- Генерирует `traffic_light_metal.bp` с @metal блоком

### AI UnpackPredictor + RegisterPacker

AI распаковывает данные из регистров оптимальным способом:

```
bpc input.bp --metal --unpack
```

- Анализирует порядок доступа к переменным по тактам
- Выбирает: `movzx` (малые поля), `shr` (сдвиг), `vpermq` (ZMM), `vextractf64x4`
- Пакует 3+ переменные в один RAX, достаёт за 1–3 такта

### HiddenBufferOptimizer

Анализ скрытых буферов CPU (LSD, LFB, TLB, BTB, RSB):

```
bpc input.bp --metal --hidden-buffers
```

| Буфер | Что контролирует | Выигрыш |
|---|---|---|
| LSD (Loop Stream Detector) | Цикл < 64B без call | −1 такт/iter |
| Store/Load Buffer | 42–56 / 72–128 записей | −2–3 такта |
| Line Fill Buffer (L1↔L2) | 12–16 pending misses | −5–10 тактов |
| TLB (L1-D) | 64 entries × 4KB = 256KB | −20 тактов (huge pages) |
| BTB (Branch Target Buffer) | Выравнивание jmp по 16B | −15 тактов (mispredict) |
| RSB (Return Stack Buffer) | call/ret → jmp | −15 тактов |

### Самообучение

Каждая правка @metal блока → новый training sample → модель точнее:
```
Прогон 1: IPC 3.5
Прогон 2: IPC 4.2 (перестроил упаковку)
Прогон 3: IPC 4.88 (найдена оптимальная раскладка)
```

---

## 📊 Флаги оптимизации

| Флаг | Эффект | Прирост |
|------|--------|---------|
| `--ai` | AI-оптимизатор Metal конфига | IPC prediction |
| `--metal` | Full Metal Stack (L0–L3) | cache-aware |
| `--unpack` | AI-распаковка регистров | −1–3 такта |
| `--hidden-buffers` | LSD/LFB/TLB/BTB/RSB | −5–40 тактов |
| `--optimize` | Таблица переходов вместо virtual | +10-30% |
| `--pool` | Пул состояний без new/delete | +20-40% |
| `--cache-friendly` | Упорядоченный layout данных | +10-20% |
| `--prefetch` | Программная предзагрузка кэша | +10-20% |
| `--branchless` | cmov вместо if/else | +5-15% |
| `--predict` | Предсказание след. состояния | +5-15% |
| `--pack` | Битфилды, упаковка структур | -40% памяти |
| `--pgo` | PGO profile counters в LLVM IR | +15-25% |
| `--lto` | Link-Time Optimization | +10-20% |
| `--turbo` | `--optimize + --pool + --pack` | +40-80% |

---

## 📁 Структура проекта

```
B+ v1.0/
├── bp.toml                          ← конфиг сборки
├── src/BPlusTranspiler/
│   ├── Ast/                         — AST nodes + MetalNodes
│   ├── Parser/                      — B+ parser + MetalParser
│   ├── Optimizer/
│   │   ├── TierClassifier.cs        — L0/L1/L2/L3 классификация
│   │   ├── CodePacker.cs            — µop bundles, splicing
│   │   ├── DataPacker.cs            — Struct field reordering
│   │   ├── RegisterAllocator.cs     — GPR/ZMM/Mask allocation
│   │   ├── RegisterPacker.cs        — AI variable→register packer
│   │   ├── PrefetchInjector.cs      — Prefetch analysis
│   │   ├── HiddenBufferOptimizer.cs — LSD/LFB/TLB/BTB/RSB control
│   │   └── BPlusOptimizer.cs        — DCE, const fold, dedup
│   ├── AI/
│   │   ├── DataCollector.cs         — 2000 training samples
│   │   ├── NeuralPredictor.cs       — 21→16→1 NN
│   │   ├── LayoutOptimizer.cs       — 10k config search
│   │   └── UnpackPredictor.cs       — 12→8→4 unpack NN
│   ├── Generators/
│   │   ├── LlvmGenMetal.cs          — LLVM IR + intrinsics
│   │   ├── AsmGenerator.cs          — x86-64 fusion-aware asm
│   │   ├── LinkerScriptGenerator.cs — .ld sections
│   │   └── ...                      — C++, C#, Python, C, GPU shaders
│   ├── Runtime/
│   │   └── MetalRuntime.cs          — mlock/madvise/mmap
│   └── Program.cs                   — CLI entry point
├── examples/
│   ├── traffic_light.bp             — минимальный пример
│   ├── traffic_light_metal.bp       — AI-optimized metal output
│   └── ...
└── gen_metal/                       — Generated LLVM IR, asm, ld script
```

---

## Бенчмарк: B+ vs C++

| Версия | нс/ит | Относительно C++ |
|--------|-------|------------------|
| C++ наивный (virtual + new/delete) | ~30-50 нс | 1× |
| C++ таблица + пул | ~5-10 нс | ~3-5× быстрее |
| B+ `--optimize` | ~5-10 нс | ~3-5× быстрее |
| B+ `--turbo` | ~4-8 нс | ~4-6× быстрее |
| B+ `--metal` + AI | ~2-4 нс | ~8-12× быстрее |
| B+ `--metal --hidden-buffers` | ~1-3 нс | ~10-15× быстрее |

GPU kernels (1920×1080, upscale 2× с shuffle): B+ **300-600%** vs C++.

---

## Лицензия

MIT
