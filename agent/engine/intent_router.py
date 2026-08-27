import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from entity_resolver import (
    get_entity_resolver, ENTITY_FUNCTION, ENTITY_STRUCT, ENTITY_ENUM,
    ENTITY_UNION, ENTITY_ERROR_SET, ENTITY_CONST, ENTITY_VARIABLE,
    ENTITY_FIELD, ENTITY_IMPORT, ENTITY_MODULE, ENTITY_FILE,
    ENTITY_CONCEPT, ENTITY_UNKNOWN, ALL_ENTITY_TYPES,
    ENTITY_TYPE_TO_CONCEPT,
)

INTENT_DEFINITION = "DEFINITION"
INTENT_CALLERS = "CALLERS"
INTENT_CALLEES = "CALLEES"
INTENT_REFERENCES = "REFERENCES"
INTENT_DEPENDENCIES = "DEPENDENCIES"
INTENT_DEPENDENTS = "DEPENDENTS"
INTENT_CONTAINS = "CONTAINS"
INTENT_USES_TYPE = "USES_TYPE"
INTENT_TYPE_USERS = "TYPE_USERS"
INTENT_MODULE = "MODULE"
INTENT_FILE = "FILE"
INTENT_TRACE = "TRACE"
INTENT_EXPLAIN = "EXPLAIN"
INTENT_COMPARE = "COMPARE"
INTENT_IMPACT = "IMPACT"
INTENT_ARCHITECTURE = "ARCHITECTURE"
INTENT_UNKNOWN = "UNKNOWN"

ALL_INTENTS = {
    INTENT_DEFINITION, INTENT_CALLERS, INTENT_CALLEES, INTENT_REFERENCES,
    INTENT_DEPENDENCIES, INTENT_DEPENDENTS, INTENT_CONTAINS, INTENT_USES_TYPE,
    INTENT_TYPE_USERS, INTENT_MODULE, INTENT_FILE, INTENT_TRACE,
    INTENT_EXPLAIN, INTENT_COMPARE, INTENT_IMPACT, INTENT_ARCHITECTURE,
    INTENT_UNKNOWN,
}

FAST_INTENTS = {
    INTENT_DEFINITION, INTENT_CALLERS, INTENT_CALLEES, INTENT_REFERENCES,
    INTENT_CONTAINS, INTENT_DEPENDENCIES, INTENT_DEPENDENTS, INTENT_MODULE,
    INTENT_FILE, INTENT_USES_TYPE, INTENT_TYPE_USERS,
}

INTENT_REQUIRES_EVIDENCE = {
    INTENT_DEFINITION: True,
    INTENT_CALLERS: True,
    INTENT_CALLEES: True,
    INTENT_REFERENCES: True,
    INTENT_DEPENDENCIES: True,
    INTENT_DEPENDENTS: True,
    INTENT_CONTAINS: True,
    INTENT_USES_TYPE: True,
    INTENT_TYPE_USERS: True,
    INTENT_MODULE: True,
    INTENT_FILE: True,
    INTENT_TRACE: True,
    INTENT_EXPLAIN: True,
    INTENT_COMPARE: True,
    INTENT_IMPACT: True,
    INTENT_ARCHITECTURE: False,
    INTENT_UNKNOWN: False,
}

INTENT_REQUIRES_EXECUTION = {
    INTENT_DEFINITION: False,
    INTENT_CALLERS: False,
    INTENT_CALLEES: False,
    INTENT_REFERENCES: False,
    INTENT_DEPENDENCIES: False,
    INTENT_DEPENDENTS: False,
    INTENT_CONTAINS: False,
    INTENT_USES_TYPE: False,
    INTENT_TYPE_USERS: False,
    INTENT_MODULE: False,
    INTENT_FILE: False,
    INTENT_TRACE: False,
    INTENT_EXPLAIN: False,
    INTENT_COMPARE: False,
    INTENT_IMPACT: False,
    INTENT_ARCHITECTURE: False,
    INTENT_UNKNOWN: False,
}

INTENT_EXPECTED_TYPES = {
    INTENT_DEFINITION: set(),
    INTENT_CALLERS: {ENTITY_FUNCTION, ENTITY_STRUCT, ENTITY_MODULE},
    INTENT_CALLEES: {ENTITY_FUNCTION, ENTITY_STRUCT, ENTITY_MODULE},
    INTENT_REFERENCES: set(),
    INTENT_DEPENDENCIES: {ENTITY_MODULE, ENTITY_FILE},
    INTENT_DEPENDENTS: {ENTITY_MODULE, ENTITY_FILE},
    INTENT_CONTAINS: {ENTITY_MODULE, ENTITY_STRUCT, ENTITY_ENUM, ENTITY_UNION},
    INTENT_USES_TYPE: set(),
    INTENT_TYPE_USERS: set(),
    INTENT_MODULE: {ENTITY_MODULE},
    INTENT_FILE: {ENTITY_FILE},
    INTENT_TRACE: set(),
    INTENT_EXPLAIN: set(),
    INTENT_COMPARE: set(),
    INTENT_IMPACT: set(),
    INTENT_ARCHITECTURE: set(),
    INTENT_UNKNOWN: set(),
}

INTENT_DEPTH = {
    INTENT_DEFINITION: 1,
    INTENT_CALLERS: 1,
    INTENT_CALLEES: 1,
    INTENT_REFERENCES: 1,
    INTENT_DEPENDENCIES: 1,
    INTENT_DEPENDENTS: 1,
    INTENT_CONTAINS: 1,
    INTENT_USES_TYPE: 1,
    INTENT_TYPE_USERS: 1,
    INTENT_MODULE: 1,
    INTENT_FILE: 1,
    INTENT_TRACE: 3,
    INTENT_EXPLAIN: 2,
    INTENT_COMPARE: 2,
    INTENT_IMPACT: 3,
    INTENT_ARCHITECTURE: 2,
    INTENT_UNKNOWN: 1,
}

_QUOTE_RE = re.compile(r'[`"\'«»]([^`"\'«»]+)[`"\'«»]')
_LINE_RE = re.compile(r'^(.+?):(\d+)$')

_STOP_ENTITY = {
    "who", "what", "where", "when", "why", "how", "does", "the", "a", "an",
    "is", "are", "was", "do", "does", "в", "во", "из", "у", "для", "по",
    "на", "с", "к", "и", "а", "но", "или", "это", "мне", "пожалуйста",
    "давай", "хочу", "узнать", "посмотреть", "список", "все", "про", "об",
    "calls", "call", "depend", "dependencies", "dependents", "used", "uses",
    "contain", "definition", "module", "file", "вызывает", "содержит",
    "зависимости", "зависит", "используется", "определён", "объявлен",
}

_PATTERN_INTENTS = [
    (INTENT_CALLERS, [
        re.compile(r'\b(?:who|кто)\s+(?:calls|вызывает)\b', re.I),
        re.compile(r'\bcallers?\s+(?:of|для)\b', re.I),
        re.compile(r'\bкто\s+вызывает\b', re.I),
    ]),
    (INTENT_CALLEES, [
        re.compile(r'\bwhat\s+does\s+\S+\s+call\b', re.I),
        re.compile(r'\b(?:что|кого)\s+(?:вызывает|called)\b', re.I),
        re.compile(r'\bcallees?\s+(?:of|для)\b', re.I),
    ]),
    (INTENT_REFERENCES, [
        re.compile(r'\bwhere\s+(?:is|are)\s+\S+\s+used\b', re.I),
        re.compile(r'\bгде\s+(?:используется|применяется)\b', re.I),
        re.compile(r'\breferences?\s+(?:of|для)\b', re.I),
    ]),
    (INTENT_DEPENDENCIES, [
        re.compile(r'\bwhat\s+does\s+\S+\s+depend\b', re.I),
        re.compile(r'\bот\s+чего\s+зависит\b', re.I),
        re.compile(r'\bdependencies?\s+(?:of|для)\b', re.I),
    ]),
    (INTENT_DEPENDENTS, [
        re.compile(r'\bwho\s+depends\s+on\b', re.I),
        re.compile(r'\bкто\s+зависит\s+от\b', re.I),
        re.compile(r'\bdependents?\s+(?:of|для)\b', re.I),
    ]),
    (INTENT_CONTAINS, [
        re.compile(r'\bwhat\s+(?:does|is\s+in)\s+\S+\s+contain\b', re.I),
        re.compile(r'\bчто\s+содержит\b', re.I),
        re.compile(r'\bfields?\s+(?:of|для)\b', re.I),
    ]),
    (INTENT_USES_TYPE, [
        re.compile(r'\bwhat\s+types?\s+does\s+\S+\s+use\b', re.I),
        re.compile(r'\bкакие\s+типы\s+использует\b', re.I),
    ]),
    (INTENT_TYPE_USERS, [
        re.compile(r'\bwho\s+uses\s+(?:the\s+)?type\b', re.I),
        re.compile(r'\bкто\s+использует\s+тип\b', re.I),
    ]),
    (INTENT_DEFINITION, [
        re.compile(r'\bwhere\s+is\s+\S+\s+defined\b', re.I),
        re.compile(r'\bdefinition\s+(?:of|для)\b', re.I),
        re.compile(r'\bгде\s+определён\b', re.I),
        re.compile(r'\bгде\s+объявлен\b', re.I),
        re.compile(r'\bчто\s+такое\b', re.I),
    ]),
    (INTENT_MODULE, [
        re.compile(r'\bmodule\b', re.I),
        re.compile(r'\bмодуль\b', re.I),
    ]),
    (INTENT_FILE, [
        re.compile(r'\bfile\b', re.I),
        re.compile(r'\bфайл\b', re.I),
    ]),
    (INTENT_TRACE, [
        re.compile(r'\btrace\b', re.I),
        re.compile(r'\bpath\s+(?:from|to)\b', re.I),
        re.compile(r'\bпуть\s+(?:от|до)\b', re.I),
    ]),
    (INTENT_EXPLAIN, [
        re.compile(r'\bexplain\b', re.I),
        re.compile(r'\bобъясни\b', re.I),
        re.compile(r'\bопиши\b', re.I),
    ]),
    (INTENT_COMPARE, [
        re.compile(r'\bcompare\b', re.I),
        re.compile(r'\bсравни\b', re.I),
        re.compile(r'\bvs\b', re.I),
    ]),
    (INTENT_IMPACT, [
        re.compile(r'\bwhat\s+(?:will|would)\s+(?:break|change)\b', re.I),
        re.compile(r'\bimpact\b', re.I),
        re.compile(r'\bвлияние\b', re.I),
    ]),
    (INTENT_ARCHITECTURE, [
        re.compile(r'\barchitecture\b', re.I),
        re.compile(r'\barхитектура\b', re.I),
        re.compile(r'\bdesign\b', re.I),
    ]),
]


class IntentResult:
    __slots__ = (
        "intent", "entity", "expected_type", "scope", "depth",
        "requires_evidence", "requires_execution", "status",
        "entity_resolved", "question", "elapsed_ms",
    )

    def __init__(self):
        self.intent = INTENT_UNKNOWN
        self.entity = ""
        self.expected_type = ""
        self.scope = "local"
        self.depth = 1
        self.requires_evidence = False
        self.requires_execution = False
        self.status = INTENT_UNKNOWN
        self.entity_resolved = None
        self.question = ""
        self.elapsed_ms = 0.0

    def to_dict(self):
        d = {
            "intent": self.intent,
            "entity": self.entity,
            "expected_type": self.expected_type,
            "scope": self.scope,
            "depth": self.depth,
            "requires_evidence": self.requires_evidence,
            "requires_execution": self.requires_execution,
            "status": self.status,
            "question": self.question,
            "elapsed_ms": self.elapsed_ms,
        }
        if self.entity_resolved:
            d["entity_resolved"] = {
                "name": self.entity_resolved.name,
                "entity_type": self.entity_resolved.entity_type,
                "concept_id": self.entity_resolved.concept_id,
                "status": self.entity_resolved.status,
            }
        return d


class IntentRouter:
    def __init__(self):
        self.resolver = get_entity_resolver()

    @classmethod
    def load(cls):
        return cls()

    def route(self, question):
        t0 = time.monotonic()
        result = IntentResult()
        result.question = question

        intent, entity = self._parse_intent(question)
        result.intent = intent
        result.entity = entity

        expected = INTENT_EXPECTED_TYPES.get(intent, set())
        result.expected_type = sorted(expected)[0] if len(expected) == 1 else ""

        result.depth = INTENT_DEPTH.get(intent, 1)
        result.requires_evidence = INTENT_REQUIRES_EVIDENCE.get(intent, False)
        result.requires_execution = INTENT_REQUIRES_EXECUTION.get(intent, False)

        if entity:
            resolved = self.resolver.resolve(
                entity,
                expected_type=result.expected_type if result.expected_type else None,
            )
            result.entity_resolved = resolved
            if resolved.status == "RESOLVED":
                result.status = "RESOLVED"
            elif resolved.status == "AMBIGUOUS":
                result.status = "AMBIGUOUS"
            elif resolved.status == "TYPE_MISMATCH":
                result.status = "TYPE_MISMATCH"
                result.expected_type = resolved.entity_type
            else:
                result.status = "NOT_FOUND"
        else:
            result.status = "NO_ENTITY"

        elapsed = (time.monotonic() - t0) * 1000
        result.elapsed_ms = round(elapsed, 3)
        return result

    def _parse_intent(self, question):
        q = question.strip()
        if not q:
            return INTENT_UNKNOWN, ""

        for intent, patterns in _PATTERN_INTENTS:
            for rx in patterns:
                m = rx.search(q)
                if m:
                    entity = self._extract_entity_inline(q, m)
                    if entity:
                        return intent, entity
                    entity = self._extract_entity_after(q, m.end())
                    if entity:
                        return intent, entity

        entity = self._extract_entity_anywhere(q)
        if entity:
            return INTENT_DEFINITION, entity

        return INTENT_UNKNOWN, ""

    def _extract_entity_inline(self, question, match):
        text = question
        span = match.span()
        region = text[max(0, span[0] - 80):span[1] + 80]
        region = re.sub(r'^(who|what|where|when|why|how|does|is|are|was|'
                        r'кто|что|где|какие|какой|какая|как|покажи|найди|'
                        r'скажи|дай|мне|пожалуйста|давай|хочу|узнать|'
                        r'посмотреть|список|все|про|об)\s+', '', region, flags=re.I)
        region = re.sub(r'\s*(calls?|call|depend(?:s|ents?|encies?)?|'
                        r'used|uses?|contain(?:s|ed)?|definition|defined|module|file|'
                        r'вызывает|содержит|зависимости|зависит|'
                        r'используется|определён|объявлен)\b.*$', '',
                        region, flags=re.I)
        region = region.strip('?!.,:;\"\' ')
        if not region:
            return ""
        m2 = _QUOTE_RE.search(region)
        if m2:
            return m2.group(1).strip()
        tokens = region.split()
        clean = []
        for t in tokens:
            t = t.strip('?!.,:;\"\'')
            if t and t.lower() not in _STOP_ENTITY:
                clean.append(t)
        if not clean:
            return ""
        pathy = [t for t in clean if '.' in t or '/' in t or '\\' in t or ':' in t]
        if pathy:
            return pathy[-1]
        return clean[-1] if clean else ""

    def _extract_entity_after(self, question, start):
        rest = question[start:].strip()
        rest = re.sub(r'^[\s?!.,:;]+', '', rest)
        if not rest:
            return ""
        m = _QUOTE_RE.search(rest)
        if m:
            return m.group(1).strip()
        tokens = rest.split()
        clean = []
        for t in tokens:
            t = t.strip('?!.,:;\"\'')
            if t.lower() not in {'the', 'a', 'an', 'of', 'in', 'on', 'to',
                                  'and', 'or', 'is', 'are', 'was', 'does',
                                  'в', 'во', 'из', 'у', 'для', 'по', 'на',
                                  'с', 'к', 'и', 'а', 'но', 'или', 'это',
                                  'мне', 'пожалуйста', 'давай', 'хочу'}:
                clean.append(t)
        if not clean:
            return ""
        pathy = [t for t in clean if '.' in t or '/' in t or '\\' in t or ':' in t]
        if pathy:
            return pathy[-1]
        return clean[-1] if clean else ""

    def _extract_entity_anywhere(self, question):
        m = _QUOTE_RE.search(question)
        if m:
            return m.group(1).strip()
        tokens = question.split()
        clean = []
        for t in tokens:
            t = t.strip('?!.,:;\"\'')
            if t and t.lower() not in {'who', 'what', 'where', 'when', 'why',
                                        'how', 'does', 'the', 'a', 'an',
                                        'is', 'are', 'was', 'do', 'does',
                                        'кто', 'что', 'где', 'какие', 'какой',
                                        'какая', 'как', 'покажи', 'найди',
                                        'скажи', 'дай', 'мне', 'пожалуйста',
                                        'давай', 'хочу', 'узнать', 'посмотреть',
                                        'список', 'все', 'про', 'об'}:
                clean.append(t)
        if len(clean) == 1:
            return clean[0]
        if len(clean) > 1:
            pathy = [t for t in clean if '.' in t or '/' in t or '\\' in t]
            if pathy:
                return pathy[-1]
        return ""


_instance = None


def get_intent_router():
    global _instance
    if _instance is None:
        _instance = IntentRouter.load()
    return _instance


def main():
    router = IntentRouter.load()
    questions = [
        "Who calls foldConstantOp?",
        "What does foldConstantOp call?",
        "Where is foldConstantOp defined?",
        "Where is emit used?",
        "What does build.zig depend on?",
        "Who depends on x64gen.zig?",
        "What contains manager.zig?",
        "What types does foldConstantOp use?",
        "Explain foldConstantOp",
        "Compare foldConstantOp vs emit",
        "What will break if I change foldConstantOp?",
        "Architecture of B+",
        "manager.zig",
        "build.zig:183",
        "nonexistentXYZ",
    ]
    for q in questions:
        r = router.route(q)
        print("  %-50s -> intent=%-14s entity=%-20s status=%s" % (
            q[:50], r.intent, r.entity[:20], r.status))
    print("\nINTENT ROUTER READY")
    sys.exit(0)


if __name__ == "__main__":
    main()
