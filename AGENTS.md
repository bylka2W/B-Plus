# B+ Runtime — Memory Physics Engine

## Architecture Model

```
Handle → Chunk → Tier           (region-centric, current)
Handle → Address → Tier          (pointer-centric, replaced)
```

Chunk = 64KB atomic region = "атом термодинамики" памяти.

## Stage 2 — Chunk Layer (in progress)

### Step 1 ✅ Chunk Spec (designed, not yet implemented)

Core types agreed:

```zig
const CHUNK_SIZE = 64 * 1024;
const MAX_CHUNKS = 4096;

const Chunk = struct {
    id: u16,
    base: [*]u8,
    size: u32,        // always CHUNK_SIZE
    used: u32,
    tier: Tier,
    heat: u32,
    total_heat: u32,
    live_handles: u32,
    epoch: u32,
    flags: u8,        // migrating / frozen / full
};
```

Key changes:
- `Handle` now carries `chunk_id: u16` + `offset: u16` instead of raw pointer
- `tierOfHandle` = `cs.chunks[h.chunk_id].tier` (O(1), deterministic, no UB)
- Allocation: `findChunkWithSpace(tier, size)` → region bump inside chunk
- Migration: move chunk between tiers (logical, not byte-copy yet in Stage 2)
- Heat: aggregated at chunk level, not per-handle

### Step 2 🔜 Chunk Heat Model v2
- Entropy-based weighting
- Migration anti-oscillation (hysteresis at chunk level)
- Stability equation (prevents thrashing)
- Epoch system integration

### Step 3 🔜 epoch system
- epoch++ every N ticks
- heat decay tied to epoch
- migration budget per epoch
- replay = exact physics trace

### Step 4 🔜 Replay formalization
- deterministic log contract
- 100% fingerprint match across runs

### Step 5 🔜 Stage 3 (future)
- L3 = disk (mmap)
- async eviction
- compression
- chunk = page

## Stage 1 — Done (kernel foundations)

- ✔ Arena safety (fail-fast on OOM)
- ✔ classifyPtr (single source of truth, now being replaced by chunk_id)
- ✔ MigrationResult enum
- ✔ Snapshot struct (formal state inspection)
- ✔ Dual heat (heat / total_heat)
- ✔ 28 unit tests
- ✔ Stress test (delta = 0, fingerprint stable)

## Mental Model

```
Stage 1 → runtime kernel
Stage 2 → thermodynamic (chunk) system
Stage 3 → storage hierarchy / OS-like VM
```

This is NOT a runtime allocator anymore. This is a **discrete thermodynamic memory system**:
- chunks = atoms
- heat = energy
- migration = phase transition

## Invariants

### Hard
- `chunk.used <= CHUNK_SIZE`
- `chunk.tier` always valid
- `handle.chunk_id` always valid

### Thermodynamic
- `heat` monotonic per tick window
- `total_heat` monotonic lifetime
- migration = response to energy imbalance, not operation
