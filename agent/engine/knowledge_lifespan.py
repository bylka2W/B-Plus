import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import MEMORY_DIR, FACTS_PATH, CONCEPTS_PATH, SEMANTIC_RELATIONS_PATH
from common import load_json, save_json

LIFESPAN_PATH = MEMORY_DIR / "knowledge_lifespan.json"

ACTIVE = "ACTIVE"
SUPERSEDED = "SUPERSEDED"
ARCHIVED = "ARCHIVED"

ALLOWED_STATUSES = {ACTIVE, SUPERSEDED, ARCHIVED}


def _lifespan_entry(item_id, snapshot_id, status=ACTIVE):
    return {
        "item_id": item_id,
        "valid_from": snapshot_id,
        "valid_to": None,
        "status": status,
    }


class KnowledgeLifespan:
    def __init__(self, entries=None):
        self.entries = entries or {}
        self._by_item = {}
        for e in self.entries:
            self._by_item.setdefault(e["item_id"], []).append(e)

    @classmethod
    def load(cls, path=None):
        path = Path(path or LIFESPAN_PATH)
        if not path.exists():
            return cls()
        doc = load_json(path)
        return cls(doc.get("entries", []))

    def save(self, path=None):
        path = Path(path or LIFESPAN_PATH)
        doc = {
            "schema": "knowledge_lifespan",
            "version": 1,
            "total_entries": len(self.entries),
            "active": sum(1 for e in self.entries if e["status"] == ACTIVE),
            "superseded": sum(1 for e in self.entries if e["status"] == SUPERSEDED),
            "entries": self.entries,
        }
        save_json(path, doc)

    def supersede_all(self, snapshot_id):
        count = 0
        for e in self.entries:
            if e["status"] == ACTIVE:
                e["status"] = SUPERSEDED
                e["valid_to"] = snapshot_id
                count += 1
        self._rebuild_index()
        return count

    def activate(self, item_ids, snapshot_id):
        for iid in item_ids:
            self.entries.append(_lifespan_entry(iid, snapshot_id, ACTIVE))
        self._rebuild_index()

    def active_ids(self):
        return {e["item_id"] for e in self.entries if e["status"] == ACTIVE}

    def superseded_ids(self):
        return {e["item_id"] for e in self.entries if e["status"] == SUPERSEDED}

    def history_for(self, item_id):
        return sorted(self._by_item.get(item_id, []),
                      key=lambda e: e["valid_from"] or "")

    def active_at(self, snapshot_id):
        result = set()
        for e in self.entries:
            if e["status"] == ACTIVE:
                if e["valid_from"] is None or e["valid_from"] <= snapshot_id:
                    result.add(e["item_id"])
            elif e["status"] == SUPERSEDED:
                if (e["valid_from"] is None or e["valid_from"] <= snapshot_id) \
                        and (e["valid_to"] is None or e["valid_to"] > snapshot_id):
                    result.add(e["item_id"])
        return result

    def _rebuild_index(self):
        self._by_item.clear()
        for e in self.entries:
            self._by_item.setdefault(e["item_id"], []).append(e)

    def stats(self):
        return {
            "total": len(self.entries),
            "active": sum(1 for e in self.entries if e["status"] == ACTIVE),
            "superseded": sum(1 for e in self.entries if e["status"] == SUPERSEDED),
            "archived": sum(1 for e in self.entries if e["status"] == ARCHIVED),
        }

    def __len__(self):
        return len(self.entries)


def rebuild_with_lifespan(snapshot_id, facts_doc, concepts_doc, rels_doc, lifespan=None):
    lifespan = lifespan or KnowledgeLifespan()
    lifespan.supersede_all(snapshot_id)

    fact_ids = [f["fact_id"] for f in facts_doc.get("items", [])]
    concept_ids = [c["concept_id"] for c in concepts_doc.get("items", [])]
    rel_ids = [r["relation_id"] for r in rels_doc.get("items", [])]

    all_ids = fact_ids + concept_ids + rel_ids
    lifespan.activate(all_ids, snapshot_id)

    return lifespan


def main():
    lifespan = KnowledgeLifespan.load()
    print("LIFESPAN:", lifespan.stats())
    sys.exit(0)


if __name__ == "__main__":
    main()
