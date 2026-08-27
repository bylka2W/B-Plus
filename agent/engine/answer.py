import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from context import ContextBuilder

ANSWER_TYPES = {
    "DEFINITION": "DEFINITION",
    "CALLERS": "SYMBOL_RELATION",
    "CALLEES": "SYMBOL_RELATION",
    "REFERENCES": "SYMBOL_RELATION",
    "USES_TYPE": "SYMBOL_RELATION",
    "TYPE_USERS": "SYMBOL_RELATION",
    "CONTAINS": "SYMBOL_RELATION",
    "DEPENDENCIES": "MODULE_RELATION",
    "DEPENDENTS": "MODULE_RELATION",
    "MODULE": "ENTITY_PROFILE",
    "FILE": "ENTITY_LOCATION",
}

RELATION_VERBS = {
    "CALLERS": "is called by",
    "CALLEES": "calls",
    "REFERENCES": "references",
    "USES_TYPE": "uses type",
    "TYPE_USERS": "is used as a type by",
    "CONTAINS": "contains",
}

MAX_NAME_SAMPLES = 5

INTENT_TYPE_MAP = {
    "MODULE": {"MODULE"},
    "DEPENDENCIES": {"MODULE"},
    "DEPENDENTS": {"MODULE"},
    "CONTAINS": {"MODULE", "STRUCT"},
    "CALLERS": {"FUNCTION", "STRUCT", "METHOD"},
    "CALLEES": {"FUNCTION", "STRUCT", "METHOD"},
    "REFERENCES": set(),
    "USES_TYPE": set(),
    "TYPE_USERS": set(),
    "DEFINITION": set(),
    "FILE": {"FILE"},
    "MODULE_MEMBER": {"MODULE"},
}


def _type_mismatch(intent, entity_type):
    expected = INTENT_TYPE_MAP.get(intent)
    if expected is None or not expected:
        return None
    if entity_type in expected:
        return None
    return (
        f"TYPE_MISMATCH: entity is {entity_type}, "
        f"intent '{intent}' requires one of {sorted(expected)}"
    )


_LINE_RE = re.compile(r"line\s+(\d+)", re.I)


def _parse_requested_line(question):
    if not question:
        return None
    m = _LINE_RE.search(question)
    if m:
        return int(m.group(1))
    return None


def _names(items, limit=MAX_NAME_SAMPLES):
    seen = []
    for it in items:
        n = it.get("name")
        if n and n not in seen:
            seen.append(n)
    shown = seen[:limit]
    extra = len(seen) - len(shown)
    tail = f" (+{extra} more)" if extra > 0 else ""
    return ", ".join(shown) + tail


def _base(path):
    return str(path).replace("\\", "/").rsplit("/", 1)[-1]


class AnswerEngine:
    def __init__(self, cb):
        self.cb = cb

    @classmethod
    def load(cls):
        return cls(ContextBuilder.load())

    def _empty(self, question, qr, limitations):
        return {
            "schema": "answer_model",
            "version": 1,
            "question": question,
            "answer_type": "EMPTY",
            "direct_answer": None,
            "entities": [],
            "facts": [],
            "relations": [],
            "evidence": [],
            "confidence": "UNSUPPORTED",
            "unresolved": [],
            "limitations": limitations,
            "provenance": {
                "engine": "bplus-knowledge-engine",
                "knowledge": self.cb.knowledge,
                "read_only": True,
            },
            "status": qr.get("status"),
        }

    def answer(self, intent, entity, question=None):
        qr = self.cb.qe.query(intent, entity)
        status = qr["status"]
        if status == "UNKNOWN_INTENT":
            return self._empty(
                question, qr,
                [f"unknown intent: {intent}; no operation performed"],
            )
        if status == "NOT_FOUND":
            expected_types = INTENT_TYPE_MAP.get(intent)
            if expected_types:
                alt = self.cb.qe.search.find_symbol(entity)
                if alt["status"] == "RESOLVED" and alt.get("targets"):
                    actual_type = alt["targets"][0].get("concept_type", "")
                    mm = _type_mismatch(intent, actual_type)
                    if mm:
                        return {
                            "schema": "answer_model",
                            "version": 1,
                            "question": question,
                            "answer_type": "TYPE_MISMATCH",
                            "direct_answer": None,
                            "entities": [],
                            "facts": [],
                            "relations": [],
                            "evidence": [],
                            "confidence": "UNSUPPORTED",
                            "unresolved": [],
                            "limitations": [
                                mm,
                                f"entity '{entity}' is {actual_type}, "
                                f"intent '{intent}' requires different type",
                            ],
                            "provenance": {
                                "engine": "bplus-knowledge-engine",
                                "knowledge": self.cb.knowledge,
                                "read_only": True,
                            },
                            "status": "TYPE_MISMATCH",
                        }
            return self._empty(
                question, qr,
                [f"entity '{entity}' not found in knowledge base; "
                 f"no answer produced rather than guessing"],
            )
        if status == "AMBIGUOUS":
            model = self._empty(question, qr, [])
            model["status"] = "AMBIGUOUS"
            model["answer_type"] = "AMBIGUOUS_ENTITY"
            model["entities"] = qr["targets"][:12]
            model["limitations"] = [
                f"'{entity}' matches {qr['count']} distinct concepts "
                f"(candidates listed); disambiguate by module or full "
                f"path before any factual claim is made"
            ]
            return model

        pack = self.cb.build(qr)

        target = pack["target"]
        if target:
            entity_type = target.get("concept_type", "")
            mismatch = _type_mismatch(intent, entity_type)
            if mismatch:
                return {
                    "schema": "answer_model",
                    "version": 1,
                    "question": question,
                    "answer_type": "TYPE_MISMATCH",
                    "direct_answer": None,
                    "entities": [],
                    "facts": [],
                    "relations": [],
                    "evidence": [],
                    "confidence": "UNSUPPORTED",
                    "unresolved": [],
                    "limitations": [
                        mismatch,
                        f"entity '{entity}' is {entity_type}, "
                        f"intent '{intent}' expects different type",
                    ],
                    "provenance": {
                        "engine": "bplus-knowledge-engine",
                        "knowledge": self.cb.knowledge,
                        "read_only": True,
                    },
                    "status": "TYPE_MISMATCH",
                }

        requested_line = _parse_requested_line(question)
        if requested_line is not None:
            evidence = pack.get("evidence", [])
            line_covered = any(
                e.get("line_start", 0) <= requested_line <= e.get("line_end", 0)
                for e in evidence
            )
            if not line_covered and evidence:
                return {
                    "schema": "answer_model",
                    "version": 1,
                    "question": question,
                    "answer_type": "INVALID_EVIDENCE",
                    "direct_answer": None,
                    "entities": [],
                    "facts": [],
                    "relations": [],
                    "evidence": [],
                    "confidence": "UNSUPPORTED",
                    "unresolved": [],
                    "limitations": [
                        f"requested line {requested_line} not found in "
                        f"evidence (evidence covers "
                        f"{evidence[0].get('line_start', '?')}-"
                        f"{evidence[0].get('line_end', '?')})",
                    ],
                    "provenance": {
                        "engine": "bplus-knowledge-engine",
                        "knowledge": self.cb.knowledge,
                        "read_only": True,
                    },
                    "status": "INVALID_EVIDENCE",
                }

        target_name = (
            pack["target"]["name"] if pack["target"] else str(entity)
        )
        direct, limitations = self._phrase(intent, target_name, pack, qr)

        unresolved = []
        if pack["target"]:
            cid = pack["target"]["concept_id"]
            c = self.cb.qe.search.concepts[cid]
            for fid in c["fact_ids"]:
                f = self.cb.facts.get(fid)
                if f and f["verification_status"] != "VERIFIED":
                    unresolved.append({
                        "fact_id": fid,
                        "fact_type": f["fact_type"],
                        "status": f["verification_status"],
                    })
                    if len(unresolved) >= 20:
                        break

        confidence = pack["confidence"]
        if not pack["evidence"] and confidence == "VERIFIED":
            confidence = "PARTIAL"
        if unresolved and confidence == "VERIFIED":
            confidence = "PARTIAL"

        limitations.append(
            "confidence reflects knowledge-base scope; absence of an edge "
            "means 'not recorded here', not a runtime guarantee"
        )
        limitations.append(
            "semantic layer holds only resolvable edges; unresolved "
            "diagnostics stay in facts layer and are listed when present"
        )

        return {
            "schema": "answer_model",
            "version": 1,
            "question": question,
            "answer_type": ANSWER_TYPES.get(intent, "EMPTY"),
            "direct_answer": direct,
            "entities": qr["items"][:12],
            "facts": pack["claims"],
            "relations": self._full_relations(pack["relation_ids"]),
            "evidence": pack["evidence"],
            "confidence": confidence,
            "unresolved": unresolved,
            "limitations": limitations,
            "provenance": {
                "engine": "bplus-knowledge-engine",
                "knowledge": self.cb.knowledge,
                "read_only": True,
            },
            "status": status,
        }

    def _full_relations(self, rid_entries):
        out = []
        for entry in rid_entries:
            full = dict(entry)
            sr = self.cb.relations.get(entry["relation_id"])
            if sr:
                full["evidence_fact_ids"] = sr.get("evidence_fact_ids", [])
                full["predicate"] = sr.get("predicate")
            out.append(full)
        return out

    def _phrase(self, intent, name, pack, qr):
        n = qr["count"]
        base = _base(pack["evidence"][0]["file"]) if pack["evidence"] else ""
        lines = (
            f"{pack['evidence'][0]['line_start']}-"
            f"{pack['evidence'][0]['line_end']}"
            if pack["evidence"] else "?"
        )
        if intent == "DEFINITION":
            d = qr["items"][0] if qr["items"] else None
            if d:
                return (
                    f"{d['name']} is defined at "
                    f"{_base(d['file'])}:{d['line_start']}-{d['line_end']}",
                    [],
                )
            return (f"{name}: definition anchor available in evidence "
                    f"({base}:{lines})", [])
        if intent == "MODULE":
            return (f"module {_base(name)}: {n} member concept(s)", [])
        if intent == "FILE":
            item = qr["items"][0] if qr["items"] else {}
            mod = item.get("name") or name
            src = entity_path(qr) or str(item.get("file", ""))
            return (f"{_base(src)} belongs to module {_base(mod)}", [])
        verb = RELATION_VERBS.get(intent)
        if verb:
            if n == 0:
                return (f"no records: {name} {verb} nothing in the "
                        f"knowledge base", [])
            return (f"{name} {verb} {n} concept(s): "
                    f"{_names(qr['items'])}", [])
        if intent == "DEPENDENCIES":
            if n == 0:
                return (f"module {_base(name)} has no dependencies "
                        f"in the knowledge base", [])
            return (f"module {_base(name)} depends on {n} module(s): "
                    f"{_names(qr['items'])}", [])
        if intent == "DEPENDENTS":
            if n == 0:
                return (f"nothing depends on module {_base(name)} "
                        f"in the knowledge base", [])
            return (f"{n} module(s) depend on {_base(name)}: "
                    f"{_names(qr['items'])}", [])
        return (f"{intent}: {n} result(s)", [])


def entity_path(qr):
    for it in qr.get("items", []):
        fp = it.get("matched_path")
        if fp:
            return fp
    return ""


def main():
    ae = AnswerEngine.load()
    m = ae.answer("DEFINITION", "foldConstantOp",
                  question="Where is foldConstantOp defined?")
    print("ANSWER ENGINE READY")
    print(f"DIRECT: {m['direct_answer']}")
    print(f"CONFIDENCE: {m['confidence']} TYPE: {m['answer_type']}")
    amb = ae.answer("CALLERS", "emit")
    print(f"AMBIGUITY GUARD: {amb['answer_type']} "
          f"candidates={len(amb['entities'])} "
          f"claims={len(amb['facts'])}")
    sys.exit(0)


if __name__ == "__main__":
    main()
