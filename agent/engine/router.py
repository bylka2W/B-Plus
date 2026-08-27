import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from search import Search

EN_INVERTERS = [
    (re.compile(r"^what\s+does\s+(.+?)\s+call\s*\??$", re.I), "CALLEES"),
    (re.compile(r"^what\s+does\s+(.+?)\s+depend\s+on\s*\??$", re.I),
     "DEPENDENCIES"),
    (re.compile(r"^what\s+types?\s+does\s+(.+?)\s+use\s*\??$", re.I),
     "USES_TYPE"),
    (re.compile(r"^what\s+does\s+(.+?)\s+contain\s*\??$", re.I), "CONTAINS"),
    (re.compile(r"^where\s+is\s+(.+?)\s+defined\s*\??$", re.I), "DEFINITION"),
    (re.compile(r"^where\s+is\s+(.+?)\s+used\s*\??$", re.I), "REFERENCES"),
]

INTENT_RULES = [
    ("TYPE_USERS", [
        r"кто использует тип",
        r"где используется тип",
        r"кто использует",
        r"who uses the type",
        r"who uses type",
        r"users of the type",
        r"users of type",
        r"who uses",
    ]),
    ("USES_TYPE", [
        r"какие типы использует",
        r"какой тип использует",
        r"какие типы у",
        r"types used by",
    ]),
    ("REFERENCES", [
        r"где используется",
        r"где применяетс",
        r"кто ссылаетс",
        r"where used",
        r"references of",
        r"who references",
    ]),
    ("DEPENDENCIES", [
        r"от чего зависит",
        r"от каких модулей зависит",
        r"зависимости модуля",
        r"dependencies of",
    ]),
    ("DEPENDENTS", [
        r"кто зависит от",
        r"кто зависит",
        r"who depends on",
        r"dependents of",
    ]),
    ("CALLERS", [
        r"кто вызывает",
        r"все вызовы",
        r"who calls",
        r"callers of",
    ]),
    ("CALLEES", [
        r"что вызывает",
        r"кого вызывает",
        r"какие функции вызывает",
        r"callees of",
    ]),
    ("CONTAINS", [
        r"что содержит",
        r"что внутри",
        r"поля структуры",
        r"поля класса",
        r"what contains",
        r"fields of",
        r"contains what",
    ]),
    ("DEFINITION", [
        r"где определен",
        r"где объявлен",
        r"в каком файле",
        r"в каком месте",
        r"объявлен",
        r"где находится",
        r"где расположен",
        r"что такое",
        r"определение",
        r"where is defined",
        r"definition of",
        r"where is",
        r"what is",
    ]),
    ("MODULE", [
        r"модуль",
        r"module",
    ]),
    ("FILE", [
        r"файл",
        r"file",
    ]),
]

_COMPILED = [
    (intent, [re.compile(r"\b" + re.escape(p).replace(r"\ ", r"\s+") + r"",
                        re.I) for p in phrases])
    for intent, phrases in INTENT_RULES
]

QUOTED_RE = re.compile(r"[`'\"\u00ab]([^\n`'\"\u00bb]{1,200})[`'\"\u00bb]")

GRAM_STOP = {
    "в", "во", "из", "у", "для", "по", "на", "с", "к", "и", "а", "но",
    "или", "это", "он", "она", "они", "него", "ней", "них",
    "the", "a", "an", "of", "in", "on", "at", "to", "by", "from",
    "is", "are", "was", "were",
}

STOP_TOKENS = {
    "кто", "что", "где", "какие", "какой", "какая", "как", "покажи",
    "найди", "скажи", "дай", "мне", "пожалуйста", "давай", "хочу",
    "узнать", "посмотреть", "список", "все", "про", "об",
    "тип", "типа", "типы", "типов", "функцию", "функции", "функция",
    "метод", "метода", "методы", "символ", "символа",
    "символы", "модуль", "модуля", "модуле", "файл", "файла", "файле",
    "класс", "класса", "структуру", "структуры", "полей", "поля",
} | GRAM_STOP

EDGE_PUNCT = " \t?!.,:;\"'`\u00ab\u00bb()[]{}\u2026\u2014-"

MAX_ENTITY_LEN = 200


def _norm(q):
    q = q.replace("\u0451", "\u0435").replace("\u0401", "\u0415")
    return re.sub(r"\s+", " ", q).strip()


ASCII_ID_RE = re.compile(r"[A-Za-z0-9_.:/\\\-]+")


def _clean_entity(rest):
    toks = []
    for raw in rest.split():
        t = raw.strip(EDGE_PUNCT)
        if t:
            toks.append(t)
    keep = [t for t in toks
            if t.lower() not in GRAM_STOP and t.lower() not in STOP_TOKENS]
    if not keep:
        return None
    ascii_pool = [t for t in keep if ASCII_ID_RE.fullmatch(t)]
    pool = ascii_pool if ascii_pool else keep
    if len(pool) == 1:
        cand = pool[0]
    else:
        pathy = [t for t in pool
                 if "." in t or "/" in t or "\\" in t or ":" in t]
        if pathy:
            cand = pathy[-1]
        else:
            cand = max(pool, key=len)
            for t in pool:
                if t[0].isupper():
                    cand = t
                    break
    cand = cand.strip(EDGE_PUNCT)
    if not cand or len(cand) > MAX_ENTITY_LEN:
        return None
    return cand


class Router:
    def __init__(self, search):
        self.search = search

    @classmethod
    def load(cls):
        return cls(Search.load())

    def route(self, question):
        raw = str(question)
        q = _norm(raw)

        for rx, intent in EN_INVERTERS:
            m = rx.match(q)
            if m:
                ent = _clean_entity(m.group(1))
                if ent:
                    return self._resolve(intent, ent, raw)

        intent, ent = None, None
        for cand_intent, patterns in _COMPILED:
            for rx in patterns:
                m = rx.search(q)
                if m:
                    rest = q[m.end():]
                    ent = _clean_entity(rest)
                    if ent:
                        intent = cand_intent
                    break
            if intent:
                break

        quoted = QUOTED_RE.search(raw)
        if intent is None and quoted:
            toks = [
                t for t in _norm(quoted.group(1)).split()
                if t.lower() not in STOP_TOKENS
            ]
            if len(toks) == 1:
                intent = "DEFINITION"
                ent = toks[0]

        if intent is None:
            fillers_removed = [
                t for t in q.split() if t.lower() not in STOP_TOKENS
            ]
            fillers_removed = [t.strip(EDGE_PUNCT)
                               for t in fillers_removed]
            fillers_removed = [t for t in fillers_removed if t]
            if len(fillers_removed) == 1:
                intent = "DEFINITION"
                ent = fillers_removed[0]

        if intent is None or ent is None:
            return self._decision(raw, None, None, "UNKNOWN_INTENT", [])

        if quoted and intent != "FILE":
            qent = quoted.group(1).strip().strip(EDGE_PUNCT)
            if qent:
                ent = qent

        return self._resolve(intent, ent, raw)

    def _resolve(self, intent, ent, raw):
        env = self._lookup(intent, ent)
        status = env["status"]
        cands = self._candidates(env)
        if status == "RESOLVED":
            return self._decision(raw, intent, ent, "ROUTED", [])
        if status == "AMBIGUOUS":
            return self._decision(raw, intent, ent,
                                  "AMBIGUOUS_ENTITY", cands)
        return self._decision(raw, intent, ent,
                              "ENTITY_NOT_FOUND", [])

    def _lookup(self, intent, ent):
        s = self.search
        if intent in ("MODULE", "DEPENDENCIES", "DEPENDENTS"):
            return s.find_module(ent)
        if intent == "FILE":
            env = s.find_file(ent)
            if env["status"] == "RESOLVED":
                return env
            norm = ent.replace("/", "\\")
            matches = sorted(
                p for p in s.file_paths
                if p.lower().endswith("\\" + ent.lower())
                or p.lower().endswith("/" + ent.lower())
                or p.replace("\\", "/").lower()
                .endswith("/" + ent.lower())
            )
            if not matches:
                return env
            if len(matches) == 1:
                return s.find_file(matches[0])
            fake = {"status": "AMBIGUOUS",
                    "count": len(matches),
                    "targets": [{"matched_path": p} for p in matches[:8]]}
            return fake
        return s.find_symbol(ent)

    @staticmethod
    def _candidates(env):
        out = []
        for t in env.get("targets", [])[:8]:
            item = {}
            for key in ("name", "concept_id", "concept_type",
                        "module_id", "file_id", "matched_path"):
                if key in t:
                    item[key] = t[key]
            out.append(item)
        return out

    @staticmethod
    def _decision(raw, intent, ent, status, candidates):
        return {
            "schema": "route_decision",
            "version": 1,
            "question": raw,
            "intent": intent,
            "entity": ent,
            "status": status,
            "candidates": candidates,
        }


def main():
    r = Router.load()
    probes = [
        "Кто вызывает foldConstantOp?",
        "Что вызывает foldConstantOp?",
        "Где определён foldConstantOp?",
        "От чего зависит x64gen.zig?",
        "Кто зависит от x64gen.zig?",
        "Покажи emit",
        "Кто вызывает `emit`?",
    ]
    for p in probes:
        d = r.route(p)
        print(f"{p!r:55} -> {d['status']:16} "
              f"{d['intent']} / {d['entity']} "
              f"cands={len(d['candidates'])}")
    sys.exit(0)


if __name__ == "__main__":
    main()
