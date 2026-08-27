import hashlib
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import MEMORY_DIR, load_json, save_json
from source_snapshot import SourceSnapshot

CACHE_DIR = MEMORY_DIR / "query_cache"
CACHE_INDEX = CACHE_DIR / "index.json"
MAX_CACHE_ENTRIES = 500
DEFAULT_TTL_SEC = 300


class QueryCache:
    def __init__(self, tree_sha, entries=None, max_entries=MAX_CACHE_ENTRIES,
                 data=None):
        self.tree_sha = tree_sha
        self.entries = entries or {}
        self.data = data or {}
        self.max_entries = max_entries
        self.hits = 0
        self.misses = 0
        self._dirty = False
        self._save_interval = 50
        self._since_save = 0

    @classmethod
    def load(cls, tree_sha=None):
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        if tree_sha is None:
            snap = SourceSnapshot.load()
            tree_sha = snap.tree_sha() if snap else "none"
        idx = {}
        if CACHE_INDEX.exists():
            try:
                idx = load_json(CACHE_INDEX)
            except (json.JSONDecodeError, OSError):
                idx = {}
        entries = idx.get("entries", {})
        data = {}
        for key, meta in entries.items():
            path = Path(meta.get("path", ""))
            if path.exists():
                try:
                    data[key] = load_json(path)
                except (json.JSONDecodeError, OSError):
                    pass
        return cls(tree_sha, entries, data=data)

    def save(self):
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        idx = {
            "schema": "query_cache_index",
            "version": 1,
            "tree_sha": self.tree_sha,
            "entries": self.entries,
        }
        save_json(CACHE_INDEX, idx)
        self._dirty = False
        self._since_save = 0

    def flush(self):
        if self._dirty:
            self.save()

    def _key(self, intent, entity):
        norm_entity = entity.strip().lower() if entity else ""
        raw = f"{intent}:{norm_entity}"
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]

    def _entry_path(self, key):
        return CACHE_DIR / f"{key}.json"

    def get(self, intent, entity, tree_sha=None):
        key = self._key(intent, entity)
        meta = self.entries.get(key)
        if meta is None:
            self.misses += 1
            return None
        if tree_sha and meta.get("tree_sha") != tree_sha:
            self._invalidate(key)
            self.misses += 1
            return None
        ttl = meta.get("ttl_sec", DEFAULT_TTL_SEC)
        age = time.time() - meta.get("created_at", 0)
        if age > ttl:
            self._invalidate(key)
            self.misses += 1
            return None
        data = self.data.get(key)
        if data is None:
            self._invalidate(key)
            self.misses += 1
            return None
        self.hits += 1
        return data

    def put(self, intent, entity, bundle_dict, tree_sha=None, ttl_sec=None):
        key = self._key(intent, entity)
        tree_sha = tree_sha or self.tree_sha
        ttl = ttl_sec if ttl_sec is not None else DEFAULT_TTL_SEC
        path = self._entry_path(key)
        save_json(path, bundle_dict)
        self.data[key] = bundle_dict
        self.entries[key] = {
            "intent": intent,
            "entity": entity,
            "tree_sha": tree_sha,
            "created_at": time.time(),
            "ttl_sec": ttl,
            "path": str(path),
        }
        self._evict()
        self._dirty = True
        self._since_save += 1
        if self._since_save >= self._save_interval:
            self.save()

    def _invalidate(self, key):
        meta = self.entries.pop(key, None)
        self.data.pop(key, None)
        if meta:
            path = Path(meta.get("path", ""))
            if path.exists():
                try:
                    os.remove(path)
                except OSError:
                    pass

    def invalidate_entity(self, intent, entity):
        key = self._key(intent, entity)
        self._invalidate(key)
        self.save()

    def invalidate_tree(self):
        for key in list(self.entries.keys()):
            self._invalidate(key)
        self.entries.clear()
        self.data.clear()
        self.save()

    def _evict(self):
        if len(self.entries) <= self.max_entries:
            return
        sorted_keys = sorted(
            self.entries.keys(),
            key=lambda k: self.entries[k].get("created_at", 0),
        )
        to_remove = len(self.entries) - self.max_entries
        for key in sorted_keys[:to_remove]:
            self._invalidate(key)

    def stats(self):
        total = self.hits + self.misses
        hit_rate = self.hits / total if total > 0 else 0.0
        return {
            "entries": len(self.entries),
            "hits": self.hits,
            "misses": self.misses,
            "hit_rate": round(hit_rate, 4),
            "tree_sha": self.tree_sha[:16] + "...",
        }


def format_cache_stats(cache):
    s = cache.stats()
    return (f"CACHE: {s['entries']} entries | "
            f"hits={s['hits']} misses={s['misses']} "
            f"rate={s['hit_rate']:.1%} | "
            f"tree={s['tree_sha']}")


def main():
    cache = QueryCache.load()
    print(format_cache_stats(cache))
    print("QUERY CACHE MODULE READY")
    sys.exit(0)


if __name__ == "__main__":
    main()
