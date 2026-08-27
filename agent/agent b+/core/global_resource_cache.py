import time
import os
import hashlib
import json
import threading
import zlib
from enum import Enum
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Set, Tuple


def _sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:16]


def _content_hash(obj: Any) -> str:
    if isinstance(obj, bytes):
        return _sha256_hex(obj)
    if isinstance(obj, str):
        return _sha256_hex(obj.encode("utf-8"))
    if isinstance(obj, (list, dict)):
        return _sha256_hex(json.dumps(obj, sort_keys=True, default=str).encode("utf-8"))
    return _sha256_hex(str(obj).encode("utf-8"))


class CacheTier(Enum):
    VRAM = 0
    RAM = 1
    NVME_HOT = 2
    NVME_COLD = 3


@dataclass
class CacheKey:
    operation: str
    input_hash: str
    version: str = "1.0"

    @staticmethod
    def make(operation: str, *args, **kwargs) -> "CacheKey":
        parts = [operation]
        for a in args:
            parts.append(_content_hash(a) if not isinstance(a, str) else a)
        for k, v in sorted(kwargs.items()):
            parts.append(f"{k}={_content_hash(v) if not isinstance(v, str) else v}")
        input_h = _sha256_hex(":".join(parts).encode())
        return CacheKey(operation=operation, input_hash=input_h)

    def __str__(self):
        return f"{self.operation}:{self.input_hash}:{self.version}"


@dataclass
class CacheEntry:
    key: CacheKey
    data: Any
    tier: CacheTier
    size_bytes: int
    recompute_cost_ms: float
    access_count: int = 0
    last_access: float = 0.0
    created: float = 0.0
    compressed: bool = False
    content_hash: str = ""

    def __post_init__(self):
        now = time.monotonic()
        if self.created == 0.0:
            self.created = now
        if self.last_access == 0.0:
            self.last_access = now
        if not self.content_hash:
            self.content_hash = _content_hash(self.data) if self.data is not None else ""


class ResourceMeter:
    def __init__(self):
        self._process = None
        try:
            import psutil
            self._process = psutil.Process(os.getpid())
        except ImportError:
            pass
        self._vram_total = 0
        self._vram_used = 0
        self._ram_baseline = 0
        self._ram_peak = 0
        self._cpu_time_baseline = 0.0
        self._cpu_time_peak = 0.0
        self._recompute_count = 0
        self._cache_hit_count = 0
        self._cache_miss_count = 0
        self._bytes_written = 0
        self._bytes_read = 0

    def ram_bytes(self) -> int:
        if self._process:
            return self._process.memory_info().rss
        return 0

    def vram_bytes(self) -> int:
        try:
            import torch
            if torch.cuda.is_available():
                return torch.cuda.memory_allocated()
        except Exception:
            pass
        return 0

    def vram_total(self) -> int:
        try:
            import torch
            if torch.cuda.is_available():
                return torch.cuda.get_device_properties(0).total_mem
        except Exception:
            pass
        return 0

    def cpu_time_ms(self) -> float:
        if self._process:
            t = self._process.cpu_times()
            return (t.user + t.system) * 1000
        return time.process_time() * 1000

    def snapshot(self) -> dict:
        return {
            "ram_bytes": self.ram_bytes(),
            "vram_bytes": self.vram_bytes(),
            "vram_total": self.vram_total(),
            "cpu_time_ms": self.cpu_time_ms(),
            "recompute_count": self._recompute_count,
            "cache_hit_count": self._cache_hit_count,
            "cache_miss_count": self._cache_miss_count,
        }

    def record_recompute(self):
        self._recompute_count += 1

    def record_hit(self):
        self._cache_hit_count += 1

    def record_miss(self):
        self._cache_miss_count += 1


class GlobalCacheStore:
    def __init__(self, vram_limit: int = 8 * 1024**3, ram_limit: int = 16 * 1024**3,
                 nvme_limit: int = 100 * 1024**3):
        self._entries: Dict[str, CacheEntry] = {}
        self._content_index: Dict[str, Set[str]] = {}
        self._tier_index: Dict[CacheTier, Set[str]] = {t: set() for t in CacheTier}
        self.vram_limit = vram_limit
        self.ram_limit = ram_limit
        self.nvme_limit = nvme_limit
        self.vram_used = 0
        self.ram_used = 0
        self.nvme_used = 0
        self._lock = threading.Lock()
        self._hits = 0
        self._misses = 0
        self._evictions = 0
        self._evicted_bytes = 0
        self._dedup_saves = 0
        self._dedup_bytes_saved = 0

    def _try_allocate(self, tier: CacheTier, size: int) -> bool:
        if tier == CacheTier.VRAM:
            if self.vram_used + size <= self.vram_limit:
                self.vram_used += size
                return True
            return False
        elif tier == CacheTier.RAM:
            if self.ram_used + size <= self.ram_limit:
                self.ram_used += size
                return True
            return False
        elif tier in (CacheTier.NVME_HOT, CacheTier.NVME_COLD):
            if self.nvme_used + size <= self.nvme_limit:
                self.nvme_used += size
                return True
            return False
        return True

    def _free_tier(self, tier: CacheTier, size: int):
        if tier == CacheTier.VRAM:
            self.vram_used = max(0, self.vram_used - size)
        elif tier == CacheTier.RAM:
            self.ram_used = max(0, self.ram_used - size)
        elif tier in (CacheTier.NVME_HOT, CacheTier.NVME_COLD):
            self.nvme_used = max(0, self.nvme_used - size)

    def put(self, key: CacheKey, data: Any, tier: CacheTier,
            recompute_cost_ms: float = 1.0) -> dict:
        with self._lock:
            ch = _content_hash(data)
            existing = self._content_index.get(ch, set())
            if existing:
                self._dedup_saves += 1
                size = len(data) if isinstance(data, (bytes, str)) else len(json.dumps(data, default=str).encode())
                self._dedup_bytes_saved += size
                return {"status": "dedup", "original": next(iter(existing))}

            size = len(data) if isinstance(data, (bytes, str)) else len(json.dumps(data, default=str).encode())

            allocated_tier = tier
            if not self._try_allocate(tier, size):
                if tier == CacheTier.VRAM:
                    if self._try_allocate(CacheTier.RAM, size):
                        allocated_tier = CacheTier.RAM
                    elif self._try_allocate(CacheTier.NVME_HOT, size):
                        allocated_tier = CacheTier.NVME_HOT
                    else:
                        self._evict_to_fit(size)
                        if not self._try_allocate(tier, size):
                            allocated_tier = CacheTier.NVME_HOT
                            self._try_allocate(allocated_tier, size)
                elif tier == CacheTier.RAM:
                    if self._try_allocate(CacheTier.NVME_HOT, size):
                        allocated_tier = CacheTier.NVME_HOT
                    else:
                        self._evict_to_fit(size)
                        self._try_allocate(allocated_tier, size)
                else:
                    self._evict_to_fit(size)
                    self._try_allocate(allocated_tier, size)

            entry = CacheEntry(
                key=key, data=data, tier=allocated_tier, size_bytes=size,
                recompute_cost_ms=recompute_cost_ms, content_hash=ch,
            )
            key_str = str(key)
            self._entries[key_str] = entry
            self._content_index.setdefault(ch, set()).add(key_str)
            self._tier_index[allocated_tier].add(key_str)
            return {"status": "stored", "tier": allocated_tier.name, "size": size}

    def get(self, key: CacheKey) -> Optional[Any]:
        key_str = str(key)
        entry = self._entries.get(key_str)
        if entry:
            self._hits += 1
            entry.access_count += 1
            entry.last_access = time.monotonic()
            return entry.data
        self._misses += 1
        return None

    def get_by_content(self, ch: str) -> List[CacheEntry]:
        ids = self._content_index.get(ch, set())
        return [self._entries[i] for i in ids if i in self._entries]

    def has(self, key: CacheKey) -> bool:
        return str(key) in self._entries

    def remove(self, key_str: str) -> bool:
        entry = self._entries.pop(key_str, None)
        if not entry:
            return False
        self._tier_index[entry.tier].discard(key_str)
        s = self._content_index.get(entry.content_hash, set())
        s.discard(key_str)
        if not s:
            del self._content_index[entry.content_hash]
        self._free_tier(entry.tier, entry.size_bytes)
        return True

    def _evict_to_fit(self, needed: int):
        candidates = []
        for key_str, entry in self._entries.items():
            candidates.append((entry, key_str))
        candidates.sort(key=lambda x: self._eviction_score(x[0]))
        freed = 0
        for entry, key_str in candidates:
            if freed >= needed:
                break
            freed += entry.size_bytes
            self._evictions += 1
            self._evicted_bytes += entry.size_bytes
            self.remove(key_str)

    def _eviction_score(self, entry: CacheEntry) -> float:
        age = max(time.monotonic() - entry.last_access, 0.001)
        size_mb = max(entry.size_bytes / (1024 * 1024), 0.0001)
        access_freq = entry.access_count / age
        recompute = max(entry.recompute_cost_ms, 0.001)
        return size_mb / (recompute * (1 + access_freq))

    def promote_to_tier(self, key_str: str, new_tier: CacheTier) -> bool:
        entry = self._entries.get(key_str)
        if not entry:
            return False
        if entry.tier == new_tier:
            return True
        if not self._try_allocate(new_tier, entry.size_bytes):
            return False
        self._tier_index[entry.tier].discard(key_str)
        self._free_tier(entry.tier, entry.size_bytes)
        entry.tier = new_tier
        self._tier_index[new_tier].add(key_str)
        return True

    def compress_cold(self, threshold_access: int = 2, max_tier: CacheTier = CacheTier.NVME_HOT):
        compressed = 0
        for key_str, entry in list(self._entries.items()):
            if entry.compressed:
                continue
            if entry.access_count <= threshold_access and entry.tier.value >= max_tier.value:
                raw = entry.data if isinstance(entry.data, bytes) else json.dumps(entry.data, default=str).encode()
                c = zlib.compress(raw, 6)
                if len(c) < len(raw):
                    entry.data = c
                    old_size = entry.size_bytes
                    entry.size_bytes = len(c)
                    entry.compressed = True
                    self._free_tier(entry.tier, old_size - len(c))
                    compressed += 1
        return compressed

    def hit_ratio(self) -> float:
        total = self._hits + self._misses
        return self._hits / max(total, 1)

    def tier_stats(self) -> dict:
        stats = {}
        for tier in CacheTier:
            entries = [self._entries[k] for k in self._tier_index[tier] if k in self._entries]
            stats[tier.name] = {
                "count": len(entries),
                "bytes": sum(e.size_bytes for e in entries),
                "total_accesses": sum(e.access_count for e in entries),
            }
        return stats

    def stats(self) -> dict:
        return {
            "entries": len(self._entries),
            "unique_content_hashes": len(self._content_index),
            "hits": self._hits,
            "misses": self._misses,
            "hit_ratio": round(self.hit_ratio(), 3),
            "dedup_saves": self._dedup_saves,
            "dedup_bytes_saved": self._dedup_bytes_saved,
            "evictions": self._evictions,
            "evicted_bytes": self._evicted_bytes,
            "vram_used": self.vram_used,
            "ram_used": self.ram_used,
            "nvme_used": self.nvme_used,
            "tiers": self.tier_stats(),
        }


class GlobalResourceCache:
    def __init__(self, vram_limit: int = 8 * 1024**3, ram_limit: int = 16 * 1024**3):
        self.store = GlobalCacheStore(vram_limit, ram_limit)
        self.meter = ResourceMeter()
        self._operation_log: List[dict] = []

    def compute(self, operation: str, fn: Callable, *args,
                recompute_cost_ms: float = 1.0, tier: CacheTier = CacheTier.RAM,
                version: str = "1.0", **kwargs) -> Tuple[Any, bool]:
        key = CacheKey.make(operation, *args, **kwargs)
        cached = self.store.get(key)
        if cached is not None:
            self.meter.record_hit()
            return cached, True

        self.meter.record_miss()
        t0 = time.monotonic()
        result = fn(*args, **kwargs)
        elapsed = (time.monotonic() - t0) * 1000
        self.meter.record_recompute()

        self.store.put(key, result, tier, recompute_cost_ms=recompute_cost_ms)
        return result, False

    def get_or_none(self, operation: str, *args, **kwargs) -> Optional[Any]:
        key = CacheKey.make(operation, *args, **kwargs)
        return self.store.get(key)

    def put(self, operation: str, data: Any, *args,
            tier: CacheTier = CacheTier.RAM, recompute_cost_ms: float = 1.0,
            **kwargs) -> dict:
        key = CacheKey.make(operation, *args, **kwargs)
        return self.store.put(key, data, tier, recompute_cost_ms=recompute_cost_ms)

    def compress_cold(self) -> int:
        return self.store.compress_cold()

    def evict_under_pressure(self) -> int:
        snap = self.meter.snapshot()
        evicted = 0
        if snap["ram_bytes"] > 0:
            threshold = 0.8
            for key_str, entry in list(self.store._entries.items()):
                if entry.tier == CacheTier.RAM and entry.access_count < 2:
                    self.store.remove(key_str)
                    evicted += 1
        return evicted

    def snapshot(self) -> dict:
        return {
            "resource": self.meter.snapshot(),
            "cache": self.store.stats(),
        }

    def baseline_benchmark(self, operations: List[Tuple[str, Callable, tuple, dict]],
                           iterations: int = 3) -> dict:
        t0 = time.monotonic()
        ram_start = self.meter.ram_bytes()
        total_recomputes = 0

        for _ in range(iterations):
            for op_name, fn, args, kwargs in operations:
                fn(*args, **kwargs)
                total_recomputes += 1

        elapsed = (time.monotonic() - t0) * 1000
        ram_end = self.meter.ram_bytes()

        return {
            "mode": "baseline",
            "iterations": iterations,
            "total_operations": len(operations) * iterations,
            "total_recomputes": total_recomputes,
            "elapsed_ms": round(elapsed, 1),
            "ram_delta_bytes": ram_end - ram_start,
        }

    def cached_benchmark(self, operations: List[Tuple[str, Callable, tuple, dict]],
                         iterations: int = 3) -> dict:
        t0 = time.monotonic()
        ram_start = self.meter.ram_bytes()
        total_recomputes = 0
        total_hits = 0
        total_misses = 0

        for _ in range(iterations):
            for op_name, fn, args, kwargs in operations:
                _, hit = self.compute(op_name, fn, *args, **kwargs)
                if hit:
                    total_hits += 1
                else:
                    total_recomputes += 1
                    total_misses += 1

        elapsed = (time.monotonic() - t0) * 1000
        ram_end = self.meter.ram_bytes()

        return {
            "mode": "cached",
            "iterations": iterations,
            "total_operations": len(operations) * iterations,
            "total_recomputes": total_recomputes,
            "total_hits": total_hits,
            "total_misses": total_misses,
            "hit_ratio": round(total_hits / max(total_hits + total_misses, 1), 3),
            "elapsed_ms": round(elapsed, 1),
            "ram_delta_bytes": ram_end - ram_start,
        }

    def savings_report(self, baseline: dict, cached: dict) -> dict:
        b_time = baseline["elapsed_ms"]
        c_time = cached["elapsed_ms"]
        b_recomputes = baseline["total_recomputes"]
        c_recomputes = cached["total_recomputes"]

        time_saved = max(0, b_time - c_time)
        time_reduction = time_saved / max(b_time, 0.001)
        compute_saved = max(0, b_recomputes - c_recomputes)
        compute_reduction = compute_saved / max(b_recomputes, 1)

        return {
            "time_baseline_ms": b_time,
            "time_cached_ms": c_time,
            "time_saved_ms": round(time_saved, 1),
            "time_reduction_pct": round(time_reduction * 100, 1),
            "recomputes_baseline": b_recomputes,
            "recomputes_cached": c_recomputes,
            "recomputes_saved": compute_saved,
            "compute_reduction_pct": round(compute_reduction * 100, 1),
            "hit_ratio": cached.get("hit_ratio", 0),
            "dedup_saves": self.store._dedup_saves,
            "dedup_bytes_saved": self.store._dedup_bytes_saved,
            "cache_entries": len(self.store._entries),
        }
