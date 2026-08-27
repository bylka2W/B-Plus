import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import SYMBOLS_PATH, load_json
from graph import KnowledgeGraph
from search import Search

SUPPORTED_INTENTS = {
    "CALLERS", "CALLEES", "REFERENCES", "DEPENDENCIES", "DEPENDENTS",
    "USES_TYPE", "TYPE_USERS", "DEFINITION", "MODULE", "FILE", "CONTAINS",
}

_INTENT_SEARCH = {
    "CALLERS": "find_callers",
    "CALLEES": "find_callees",
    "REFERENCES": "find_references",
    "USES_TYPE": "find_types_used",
    "TYPE_USERS": "find_type_users",
    "CONTAINS": "find_contains",
}

_INTENT_MODULE_SEARCH = {
    "DEPENDENCIES": "find_dependencies",
    "DEPENDENTS": "find_dependents",
}


class QueryEngine:
    def __init__(self, search, definitions=None):
        self.search = search
        self.definitions = definitions or {}

    @classmethod
    def load(cls):
        kg = KnowledgeGraph.load()
        search = Search(kg)
        symbols_doc = load_json(SYMBOLS_PATH)
        definitions = {
            s["symbol_id"]: {
                "symbol_id": s["symbol_id"],
                "name": s["name"],
                "kind": s["kind"],
                "file": s["source_file"],
                "line_start": s["line_start"],
                "line_end": s["line_end"],
                "evidence_id": s["evidence_id"],
            }
            for s in symbols_doc["items"]
        }
        return cls(search, definitions)

    def _definition_items(self, concept_ids):
        items = []
        for cid in concept_ids:
            c = self.search.concepts.get(cid)
            if not c:
                continue
            for sid in c["source_symbol_ids"]:
                d = self.definitions.get(sid)
                if d:
                    item = dict(d)
                    item["concept_id"] = cid
                    items.append(item)
        items.sort(key=lambda x: (x["file"], x["line_start"], x["symbol_id"]))
        return items

    def query(self, intent, entity):
        if intent not in SUPPORTED_INTENTS:
            return {
                "schema": "query_result",
                "version": 1,
                "intent": intent,
                "entity": entity,
                "status": "UNKNOWN_INTENT",
                "targets": [],
                "items": [],
                "count": 0,
            }
        if intent == "DEFINITION":
            r = self.search.find_symbol(entity)
            items = self._definition_items(
                [t["concept_id"] for t in r["targets"]]
            )
        elif intent == "MODULE":
            r = self.search.find_module(entity)
            items = r["items"]
        elif intent == "FILE":
            r = self.search.find_file(entity)
            items = r["items"]
        elif intent in _INTENT_SEARCH:
            r = getattr(self.search, _INTENT_SEARCH[intent])(entity)
            items = r["items"]
        else:
            r = getattr(self.search, _INTENT_MODULE_SEARCH[intent])(entity)
            items = r["items"]
        return {
            "schema": "query_result",
            "version": 1,
            "intent": intent,
            "entity": entity,
            "status": r["status"],
            "targets": r["targets"],
            "items": items,
            "count": len(items),
        }


def main():
    qe = QueryEngine.load()
    print("QUERY ENGINE READY")
    print(f"INTENTS: {len(SUPPORTED_INTENTS)}")
    print(f"DEFINITIONS: {len(qe.definitions)}")
    demo = qe.query("DEFINITION", "foldConstantOp")
    print(
        f"DEMO DEFINITION foldConstantOp: {demo['status']} "
        f"{demo['items'][0]['file'].split(chr(92))[-1]}:{demo['items'][0]['line_start']}"
        if demo["items"]
        else f"DEMO DEFINITION: {demo['status']}"
    )
    sys.exit(0)


if __name__ == "__main__":
    main()
