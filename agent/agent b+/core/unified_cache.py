import time
import hashlib
import json
import threading
from enum import Enum
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set, Tuple


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:16]


def content_hash(obj: Any) -> str:
    if isinstance(obj, bytes):
        return sha256_hex(obj)
    if isinstance(obj, str):
        return sha256_hex(obj.encode("utf-8"))
    if isinstance(obj, (list, dict)):
        return sha256_hex(json.dumps(obj, sort_keys=True, default=str).encode("utf-8"))
    return sha256_hex(str(obj).encode("utf-8"))


class Tier(Enum):
    VRAM = 0
    RAM = 1
    NVME_HOT = 2
    NVME_COLD = 3
    SOURCE = 4


@dataclass
class CacheObject:
    object_id: str
    content_hash: str
    data: Any
    tier: Tier
    size_bytes: int
    recompute_cost_ms: float
    access_count: int = 0
    last_access: float = 0.0
    created: float = 0.0
    compressed: bool = False
    dependencies: List[str] = field(default_factory=list)
    metadata: Dict[str, Any] = field(default_factory=dict)

    def __post_init__(self):
        now = time.monotonic()
        if self.created == 0.0:
            self.created = now
        if self.last_access == 0.0:
            self.last_access = now


class CacheAddressSpace:
    def __init__(self):
        self._objects: Dict[str, CacheObject] = {}
        self._hash_index: Dict[str, Set[str]] = {}
        self._tier_index: Dict[Tier, Set[str]] = {t: set() for t in Tier}

    def register(self, object_id: str, data: Any, tier: Tier,
                 recompute_cost_ms: float = 1.0, dependencies: list = None,
                 metadata: dict = None) -> CacheObject:
        ch = content_hash(data)
        size = len(data) if isinstance(data, (bytes, str)) else len(json.dumps(data, default=str).encode())
        obj = CacheObject(
            object_id=object_id, content_hash=ch, data=data, tier=tier,
            size_bytes=size, recompute_cost_ms=recompute_cost_ms,
            dependencies=dependencies or [], metadata=metadata or {},
        )
        self._objects[object_id] = obj
        self._hash_index.setdefault(ch, set()).add(object_id)
        self._tier_index[tier].add(object_id)
        return obj

    def get(self, object_id: str) -> Optional[CacheObject]:
        obj = self._objects.get(object_id)
        if obj:
            obj.access_count += 1
            obj.last_access = time.monotonic()
        return obj

    def get_by_hash(self, ch: str) -> List[CacheObject]:
        ids = self._hash_index.get(ch, set())
        return [self._objects[i] for i in ids if i in self._objects]

    def move_tier(self, object_id: str, new_tier: Tier) -> bool:
        obj = self._objects.get(object_id)
        if not obj:
            return False
        self._tier_index[obj.tier].discard(object_id)
        obj.tier = new_tier
        self._tier_index[new_tier].add(object_id)
        return True

    def remove(self, object_id: str) -> bool:
        obj = self._objects.pop(object_id, None)
        if not obj:
            return False
        self._tier_index[obj.tier].discard(object_id)
        s = self._hash_index.get(obj.content_hash, set())
        s.discard(object_id)
        if not s:
            del self._hash_index[obj.content_hash]
        return True

    def invalidate_hash(self, ch: str) -> int:
        ids = self._hash_index.get(ch, set()).copy()
        for oid in ids:
            self.remove(oid)
        return len(ids)

    def objects_in_tier(self, tier: Tier) -> List[CacheObject]:
        return [self._objects[i] for i in self._tier_index[tier] if i in self._objects]

    def all_objects(self) -> List[CacheObject]:
        return list(self._objects.values())

    def stats(self) -> dict:
        tier_sizes = {}
        for t in Tier:
            objs = self.objects_in_tier(t)
            tier_sizes[t.name] = {"count": len(objs), "bytes": sum(o.size_bytes for o in objs)}
        return {
            "total_objects": len(self._objects),
            "unique_hashes": len(self._hash_index),
            "tiers": tier_sizes,
        }


class ContentAddressedStore:
    def __init__(self, base_path: str = None):
        self.base_path = base_path
        self._store: Dict[str, bytes] = {}
        self._ref_count: Dict[str, int] = {}

    def put(self, data: bytes, metadata: dict = None) -> str:
        ch = content_hash(data)
        if ch in self._store:
            self._ref_count[ch] = self._ref_count.get(ch, 0) + 1
            return ch
        self._store[ch] = data
        self._ref_count[ch] = 1
        return ch

    def get(self, ch: str) -> Optional[bytes]:
        return self._store.get(ch)

    def has(self, ch: str) -> bool:
        return ch in self._store

    def ref_count(self, ch: str) -> int:
        return self._ref_count.get(ch, 0)

    def dedup_ratio(self) -> float:
        total_refs = sum(self._ref_count.values())
        unique = len(self._store)
        if unique == 0:
            return 0.0
        return total_refs / unique

    def stats(self) -> dict:
        return {
            "objects": len(self._store),
            "total_bytes": sum(len(v) for v in self._store.values()),
            "total_refs": sum(self._ref_count.values()),
            "dedup_ratio": round(self.dedup_ratio(), 2),
        }


class MemoryPressureManager:
    PRESSURE_LOW = 0.3
    PRESSURE_MEDIUM = 0.6
    PRESSURE_HIGH = 0.85

    def __init__(self, vram_limit: int = 8 * 1024**3, ram_limit: int = 16 * 1024**3):
        self.vram_limit = vram_limit
        self.ram_limit = ram_limit
        self.vram_used = 0
        self.ram_used = 0

    def vram_pressure(self) -> float:
        return min(1.0, self.vram_used / max(self.vram_limit, 1))

    def ram_pressure(self) -> float:
        return min(1.0, self.ram_used / max(self.ram_limit, 1))

    def overall_pressure(self) -> float:
        return max(self.vram_pressure(), self.ram_pressure())

    def level(self) -> str:
        p = self.overall_pressure()
        if p < self.PRESSURE_LOW:
            return "LOW"
        if p < self.PRESSURE_MEDIUM:
            return "MEDIUM"
        if p < self.PRESSURE_HIGH:
            return "HIGH"
        return "CRITICAL"

    def allocate_vram(self, size: int) -> bool:
        if self.vram_used + size <= self.vram_limit:
            self.vram_used += size
            return True
        return False

    def free_vram(self, size: int):
        self.vram_used = max(0, self.vram_used - size)

    def allocate_ram(self, size: int) -> bool:
        if self.ram_used + size <= self.ram_limit:
            self.ram_used += size
            return True
        return False

    def free_ram(self, size: int):
        self.ram_used = max(0, self.ram_used - size)

    def demote_candidates(self, objects: List[CacheObject], target_bytes: int) -> List[CacheObject]:
        candidates = sorted(objects, key=lambda o: (o.recompute_cost_ms / max(o.size_bytes, 1), -o.access_count))
        selected = []
        freed = 0
        for obj in candidates:
            if freed >= target_bytes:
                break
            selected.append(obj)
            freed += obj.size_bytes
        return selected

    def stats(self) -> dict:
        return {
            "vram_used": self.vram_used, "vram_limit": self.vram_limit,
            "vram_pressure": round(self.vram_pressure(), 3),
            "ram_used": self.ram_used, "ram_limit": self.ram_limit,
            "ram_pressure": round(self.ram_pressure(), 3),
            "level": self.level(),
        }


class CostAwareEviction:
    def __init__(self, address_space: CacheAddressSpace, pressure: MemoryPressureManager):
        self.address_space = address_space
        self.pressure = pressure
        self.eviction_log: List[dict] = []

    def eviction_cost_score(self, obj: CacheObject) -> float:
        age = time.monotonic() - obj.last_access
        size_factor = obj.size_bytes / (1024 * 1024)
        recompute = obj.recompute_cost_ms
        access_freq = obj.access_count / max(age, 1.0)
        return recompute / max(size_factor * (1 + access_freq), 0.001)

    def evict_to_target(self, tier: Tier, target_free_bytes: int) -> List[str]:
        objs = self.address_space.objects_in_tier(tier)
        if not objs:
            return []
        scored = [(self.eviction_cost_score(o), o) for o in objs]
        scored.sort(key=lambda x: x[0])
        evicted = []
        freed = 0
        for score, obj in scored:
            if freed >= target_free_bytes:
                break
            evicted.append(obj.object_id)
            freed += obj.size_bytes
            if obj.tier == Tier.VRAM:
                self.pressure.free_vram(obj.size_bytes)
            elif obj.tier == Tier.RAM:
                self.pressure.free_ram(obj.size_bytes)
            self.address_space.remove(obj.object_id)
            self.eviction_log.append({
                "object_id": obj.object_id, "size": obj.size_bytes,
                "score": round(score, 3), "tier": tier.name,
            })
        return evicted

    def stats(self) -> dict:
        return {
            "total_evictions": len(self.eviction_log),
            "total_bytes_freed": sum(e["size"] for e in self.eviction_log),
        }


class CPUResultCache:
    def __init__(self):
        self._cache: Dict[str, CacheObject] = {}
        self.hits = 0
        self.misses = 0

    def operation_key(self, op: str, *args, **kwargs) -> str:
        parts = [op]
        for a in args:
            parts.append(content_hash(a) if not isinstance(a, str) else a)
        for k, v in sorted(kwargs.items()):
            parts.append(f"{k}={content_hash(v) if not isinstance(v, str) else v}")
        return ":".join(parts)

    def get(self, op: str, *args, **kwargs) -> Optional[Any]:
        key = self.operation_key(op, *args, **kwargs)
        obj = self._cache.get(key)
        if obj:
            self.hits += 1
            obj.access_count += 1
            obj.last_access = time.monotonic()
            return obj.data
        self.misses += 1
        return None

    def put(self, op: str, result: Any, *args, **kwargs):
        key = self.operation_key(op, *args, **kwargs)
        if key in self._cache:
            return
        size = len(json.dumps(result, default=str).encode()) if not isinstance(result, bytes) else len(result)
        self._cache[key] = CacheObject(
            object_id=key, content_hash=content_hash(result),
            data=result, tier=Tier.RAM, size_bytes=size, recompute_cost_ms=0,
        )

    def hit_ratio(self) -> float:
        total = self.hits + self.misses
        return self.hits / max(total, 1)

    def stats(self) -> dict:
        return {
            "cached_ops": len(self._cache),
            "hits": self.hits, "misses": self.misses,
            "hit_ratio": round(self.hit_ratio(), 3),
        }


class CompressionManager:
    def __init__(self):
        self._original_bytes = 0
        self._compressed_bytes = 0

    def compress(self, data: bytes, level: str = "light") -> bytes:
        self._original_bytes += len(data)
        if level == "none" or len(data) < 128:
            self._compressed_bytes += len(data)
            return data
        try:
            import zlib
            wbits = -zlib.MAX_WBITS if level == "aggressive" else zlib.MAX_WBITS
            compressed = zlib.compress(data, 6 if level == "aggressive" else 3)
            if len(compressed) < len(data):
                self._compressed_bytes += len(compressed)
                return compressed
            self._compressed_bytes += len(data)
            return data
        except Exception:
            self._compressed_bytes += len(data)
            return data

    def decompress(self, data: bytes) -> bytes:
        try:
            import zlib
            return zlib.decompress(data)
        except Exception:
            return data

    def compression_ratio(self) -> float:
        return self._compressed_bytes / max(self._original_bytes, 1)

    def bytes_saved(self) -> int:
        return max(0, self._original_bytes - self._compressed_bytes)

    def stats(self) -> dict:
        return {
            "original_bytes": self._original_bytes,
            "compressed_bytes": self._compressed_bytes,
            "ratio": round(self.compression_ratio(), 3),
            "bytes_saved": self.bytes_saved(),
        }


class DeduplicationEngine:
    def __init__(self, address_space: CacheAddressSpace, store: ContentAddressedStore):
        self.address_space = address_space
        self.store = store
        self._dedup_count = 0
        self._dedup_bytes = 0
        self._dedup_pairs: Dict[str, str] = {}

    def check_and_store(self, object_id: str, data: bytes, tier: Tier) -> Tuple[bool, str]:
        ch = content_hash(data)
        existing = self.address_space.get_by_hash(ch)
        if existing:
            self._dedup_count += 1
            self._dedup_bytes += len(data)
            self._dedup_pairs[object_id] = existing[0].object_id
            return True, existing[0].object_id
        self.store.put(data)
        self.address_space.register(object_id, data, tier)
        return False, object_id

    def find_duplicates(self) -> List[Tuple[str, List[str]]]:
        by_original: Dict[str, List[str]] = {}
        for dup_id, orig_id in self._dedup_pairs.items():
            by_original.setdefault(orig_id, []).append(dup_id)
        return [(orig, dups) for orig, dups in by_original.items()]

    def stats(self) -> dict:
        return {
            "dedup_count": self._dedup_count,
            "dedup_bytes": self._dedup_bytes,
            "duplicates_found": len(self.find_duplicates()),
        }


class CacheTelemetry:
    def __init__(self):
        self._snapshots: List[dict] = []

    def snapshot(self, components: dict) -> dict:
        ts = time.monotonic()
        snap = {"timestamp": ts, "components": components}
        self._snapshots.append(snap)
        return snap

    def trend(self, component: str, metric: str) -> List[float]:
        values = []
        for s in self._snapshots:
            c = s.get("components", {}).get(component, {})
            if metric in c:
                values.append(c[metric])
        return values

    def summary(self) -> dict:
        if not self._snapshots:
            return {"snapshots": 0}
        latest = self._snapshots[-1]
        return {
            "snapshots": len(self._snapshots),
            "latest": latest["components"],
        }


class UnifiedResourceController:
    def __init__(self, vram_limit: int = 8 * 1024**3, ram_limit: int = 16 * 1024**3):
        self.address_space = CacheAddressSpace()
        self.store = ContentAddressedStore()
        self.pressure = MemoryPressureManager(vram_limit, ram_limit)
        self.eviction = CostAwareEviction(self.address_space, self.pressure)
        self.cpu_cache = CPUResultCache()
        self.compression = CompressionManager()
        self.dedup = DeduplicationEngine(self.address_space, self.store)
        self.telemetry = CacheTelemetry()

    def put(self, object_id: str, data: Any, tier: Tier,
            recompute_cost_ms: float = 1.0, dependencies: list = None,
            metadata: dict = None) -> dict:
        is_dup, actual_id = self.dedup.check_and_store(
            object_id,
            data if isinstance(data, bytes) else json.dumps(data, default=str).encode(),
            tier,
        )
        if is_dup:
            return {"status": "dedup", "original": actual_id}

        if tier == Tier.VRAM and not self.pressure.allocate_vram(self.address_space.get(object_id).size_bytes):
            tier = Tier.RAM
            self.address_space.move_tier(object_id, tier)
        if tier == Tier.RAM and not self.pressure.allocate_ram(self.address_space.get(object_id).size_bytes):
            tier = Tier.NVME_HOT
            self.address_space.move_tier(object_id, tier)

        return {"status": "stored", "object_id": object_id, "tier": tier.name}

    def get(self, object_id: str) -> Optional[Any]:
        obj = self.address_space.get(object_id)
        if obj:
            return obj.data
        return None

    def get_or_compute(self, op: str, compute_fn, *args, **kwargs) -> Tuple[Any, bool]:
        cached = self.cpu_cache.get(op, *args, **kwargs)
        if cached is not None:
            return cached, True
        result = compute_fn(*args, **kwargs)
        self.cpu_cache.put(op, result, *args, **kwargs)
        return result, False

    def promote_on_use(self, object_id: str):
        obj = self.address_space.get(object_id)
        if not obj:
            return
        if obj.tier == Tier.NVME_COLD:
            self.address_space.move_tier(object_id, Tier.NVME_HOT)
        elif obj.tier == Tier.NVME_HOT:
            if self.pressure.ram_pressure() < MemoryPressureManager.PRESSURE_MEDIUM:
                if self.pressure.allocate_ram(obj.size_bytes):
                    self.address_space.move_tier(object_id, Tier.RAM)
        elif obj.tier == Tier.RAM:
            if self.pressure.vram_pressure() < MemoryPressureManager.PRESSURE_MEDIUM:
                if self.pressure.allocate_vram(obj.size_bytes):
                    self.address_space.move_tier(object_id, Tier.VRAM)

    def evict_cold(self, target_tier: Tier = None) -> List[str]:
        if target_tier:
            return self.eviction.evict_to_target(target_tier, 1024 * 1024)
        all_evicted = []
        for tier in [Tier.VRAM, Tier.RAM, Tier.NVME_HOT]:
            p = self.pressure.overall_pressure()
            if p > MemoryPressureManager.PRESSURE_HIGH:
                all_evicted.extend(self.eviction.evict_to_target(tier, 512 * 1024))
        return all_evicted

    def handle_pressure(self) -> dict:
        level = self.pressure.level()
        actions = []
        if level in ("HIGH", "CRITICAL"):
            evicted = self.evict_cold()
            actions.append(f"evicted_{len(evicted)}")
        if level == "CRITICAL":
            for obj in self.address_space.all_objects():
                if obj.tier in (Tier.VRAM, Tier.RAM) and obj.recompute_cost_ms < 5.0:
                    self.address_space.remove(obj.object_id)
                    actions.append(f"removed_cheap_{obj.object_id}")
        return {"level": level, "actions": actions}

    def scan_and_cache(self, entries: List[Tuple[str, bytes, Tier]]) -> dict:
        added = 0
        deduped = 0
        for obj_id, data, tier in entries:
            is_dup, _ = self.dedup.check_and_store(obj_id, data, tier)
            if is_dup:
                deduped += 1
            else:
                added += 1
        return {"added": added, "deduped": deduped, "total": len(entries)}

    def snapshot(self) -> dict:
        return self.telemetry.snapshot({
            "address_space": self.address_space.stats(),
            "store": self.store.stats(),
            "pressure": self.pressure.stats(),
            "cpu_cache": self.cpu_cache.stats(),
            "compression": self.compression.stats(),
            "dedup": self.dedup.stats(),
            "eviction": self.eviction.stats(),
        })

    def stats(self) -> dict:
        return {
            "address_space": self.address_space.stats(),
            "store": self.store.stats(),
            "pressure": self.pressure.stats(),
            "cpu_cache": self.cpu_cache.stats(),
            "compression": self.compression.stats(),
            "dedup": self.dedup.stats(),
            "eviction": self.eviction.stats(),
            "telemetry": self.telemetry.summary(),
        }
