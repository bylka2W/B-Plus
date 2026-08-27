import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from context import ContextBuilder

ZIG_ROOT = "C:\\B-Plus\\zig"


def _check(name, ok, detail=None):
    item = {"check": name, "status": "PASS" if ok else "FAIL"}
    if detail is not None:
        item["detail"] = str(detail)
    return item


class VerifyEngine:
    def __init__(self, cb, root=None):
        self.cb = cb
        self.root = os.path.normpath(root) if root else ZIG_ROOT
        self._sha_cache = {}

    @classmethod
    def load(cls):
        return cls(ContextBuilder.load())

    def invalidate_cache(self):
        self._sha_cache.clear()

    def _get_source(self, norm):
        cached = self._sha_cache.get(norm)
        if cached is not None:
            return cached
        try:
            with open(norm, "rb") as fh:
                raw = fh.read()
            digest = hashlib.sha256(raw).hexdigest()
            lines = raw.decode("utf-8", errors="ignore").splitlines()
            self._sha_cache[norm] = (digest, lines)
            return digest, lines
        except (OSError, UnicodeDecodeError):
            return None

    def _load_evidence(self, eid, checks, out):
        if not eid or not isinstance(eid, str) \
                or not eid.startswith("EV-"):
            checks.append(_check("evidence_id_format", False,
                                 f"bad evidence id: {eid!r}"))
            out["status"] = "UNVERIFIED"
            out["reason"] = "missing or malformed evidence_id"
            return None
        ev = self.cb.store.evidence_by_id.get(eid)
        if ev is None:
            checks.append(_check("evidence_exists", False, eid))
            out["status"] = "UNVERIFIED"
            out["reason"] = f"evidence not found: {eid}"
            return None
        checks.append(_check("evidence_exists", True))
        return ev

    def _check_source(self, ev, checks, out):
        path = ev.get("source_file")
        if not path:
            checks.append(_check("source_file_present", False))
            out["status"] = "UNVERIFIED"
            out["reason"] = "evidence has no source_file"
            return False
        norm = os.path.normpath(path)
        root = self.root
        if not norm.startswith(root + os.sep) and norm != root:
            checks.append(_check("source_file_under_root", False, path))
            out["status"] = "UNVERIFIED"
            out["reason"] = f"source outside B+ tree: {path}"
            return False
        if not os.path.isfile(norm):
            checks.append(_check("source_file_exists", False, path))
            out["status"] = "UNVERIFIED"
            out["reason"] = f"source file missing on disk: {path}"
            return False
        checks.append(_check("source_file_exists", True))

        fe = self.cb.store.files_by_path.get(path)
        if fe is None:
            checks.append(_check("file_registered_in_index", False, path))
            out["status"] = "UNVERIFIED"
            out["reason"] = "file absent from source index"
            return False
        result = self._get_source(norm)
        if result is None:
            checks.append(_check("source_readable", False, path))
            out["status"] = "UNVERIFIED"
            out["reason"] = f"source unreadable: {path}"
            return False
        digest, lines = result
        if fe.get("sha256") != digest:
            checks.append(_check("file_hash_match",
                                 False, "stale source vs index"))
            out["status"] = "UNVERIFIED"
            out["reason"] = "source file hash differs from index pin"
            return False
        if ev.get("sha256") and ev["sha256"] != digest:
            checks.append(_check("evidence_hash_pin_match", False, path))
            out["status"] = "UNVERIFIED"
            out["reason"] = "evidence file-hash pin mismatch"
            return False
        checks.append(_check("file_hash_match", True))

        ls, le = ev.get("line_start"), ev.get("line_end")
        if not isinstance(ls, int) or ls < 1:
            checks.append(_check("line_start_valid", False, ls))
            out["status"] = "UNVERIFIED"
            out["reason"] = f"invalid line_start: {ls!r}"
            return False
        if not isinstance(le, int) or le < ls:
            checks.append(_check("line_end_valid", False, (ls, le)))
            out["status"] = "UNVERIFIED"
            out["reason"] = f"invalid line_end: {le!r}"
            return False
        if len(lines) < le:
            checks.append(_check("line_range_in_bounds", False,
                                 f"{le} > {len(lines)}"))
            out["status"] = "UNVERIFIED"
            out["reason"] = (f"line range {ls}-{le} exceeds file "
                             f"length {len(lines)}")
            return False
        checks.append(_check("line_range_in_bounds", True))

        actual = "\n".join(lines[ls - 1:le])
        if actual != ev.get("text"):
            checks.append(_check("text_matches_source", False,
                                 f"{path}:{ls}-{le}"))
            out["status"] = "UNVERIFIED"
            out["reason"] = "evidence text differs from real source"
            return False
        checks.append(_check("text_matches_source", True))
        out["source_file"] = path
        out["line_start"] = ls
        out["line_end"] = le
        return True

    def verify_claim(self, claim):
        out = {
            "schema": "verification_result",
            "version": 1,
            "claim": claim.get("claim"),
            "fact_id": claim.get("fact_id"),
            "relation_id": None,
            "evidence_id": claim.get("evidence_id"),
            "source_file": None,
            "line_start": None,
            "line_end": None,
            "status": "UNVERIFIED",
            "reason": None,
            "checks": [],
        }
        checks = out["checks"]

        fid = claim.get("fact_id")
        fact = self.cb.facts.get(fid) if fid else None
        if fact is None:
            checks.append(_check("fact_exists", False, fid))
            out["reason"] = f"fact not found: {fid}"
            return out
        checks.append(_check("fact_exists", True))
        out["fact_id"] = fid

        if fact.get("verification_status") != "VERIFIED":
            checks.append(_check("fact_status_verified", False,
                                 fact.get("verification_status")))
            out["reason"] = (f"fact status "
                             f"{fact.get('verification_status')!r}: "
                             f"promotion forbidden")
            return out
        checks.append(_check("fact_status_verified", True))

        if claim.get("file") != fact.get("source_file") \
                or claim.get("line_start") != fact.get("line_start") \
                or claim.get("line_end") != fact.get("line_end"):
            checks.append(_check("claim_fact_consistent", False))
            out["reason"] = "claim fields contradict underlying fact"
            return out
        checks.append(_check("claim_fact_consistent", True))

        cited = claim.get("evidence_id")
        if cited is not None and cited != fact.get("evidence_id"):
            checks.append(_check("claim_evidence_consistent", False,
                                 f"{cited!r} != "
                                 f"{fact.get('evidence_id')!r}"))
            out["reason"] = "claim cites different evidence than fact"
            return out
        checks.append(_check("claim_evidence_consistent", True))

        ev = self._load_evidence(
            fact.get("evidence_id"),
            checks, out)
        if ev is None:
            return out
        out["evidence_id"] = ev["id"]

        ok = self._check_source(ev, checks, out)
        if ok:
            out["status"] = "VERIFIED"
        return out

    def verify_relation_entry(self, entry):
        out = {
            "schema": "verification_result",
            "version": 1,
            "claim": entry.get("relation_type"),
            "fact_id": None,
            "relation_id": entry.get("relation_id"),
            "evidence_id": None,
            "source_file": None,
            "line_start": None,
            "line_end": None,
            "status": "UNVERIFIED",
            "reason": None,
            "checks": [],
        }
        checks = out["checks"]
        rid = entry.get("relation_id")
        rel = self.cb.relations.get(rid) if rid else None
        if rel is None:
            checks.append(_check("relation_exists", False, rid))
            out["reason"] = f"relation not found: {rid}"
            return out
        checks.append(_check("relation_exists", True))

        if rel.get("verification_status") != "VERIFIED":
            checks.append(_check("relation_status_verified", False,
                                 rel.get("verification_status")))
            out["reason"] = (f"relation status "
                             f"{rel.get('verification_status')!r}")
            return out
        checks.append(_check("relation_status_verified", True))

        fids = rel.get("evidence_fact_ids")
        if not fids:
            checks.append(_check("relation_has_evidence_facts", False))
            out["reason"] = "verified relation without evidence facts"
            return out
        checks.append(_check("relation_has_evidence_facts", True,
                             f"n={len(fids)}"))

        missing = [f for f in sorted(fids) if f not in self.cb.facts]
        if missing:
            checks.append(_check("evidence_facts_exist", False,
                                 missing[:5]))
            out["reason"] = "relation cites missing facts"
            return out
        checks.append(_check("evidence_facts_exist", True))

        first_ev = None
        for fid in sorted(fids):
            ev = self.cb.store.evidence_by_id.get(
                self.cb.facts[fid]["evidence_id"])
            if ev is not None:
                first_ev = ev
                break
        if first_ev is None:
            checks.append(_check("relation_chain_to_source", False))
            out["reason"] = "no resolvable evidence behind relation"
            return out
        ok = self._check_source(first_ev, checks, out)
        if not ok:
            checks[-1] = dict(checks[-1])
            out["reason"] = out["reason"] or "source chain broken"
            return out
        checks.append(_check("relation_chain_to_source", True))
        out["fact_id"] = sorted(fids)[0]
        out["evidence_id"] = first_ev["id"]
        out["status"] = "VERIFIED"
        return out

    def verify_answer(self, model):
        claims = [self.verify_claim(c) for c in model.get("facts", [])]
        rels = [self.verify_relation_entry(r)
                for r in model.get("relations", [])]

        all_v = claims + rels
        failed = [v for v in all_v if v["status"] != "VERIFIED"]

        if not model.get("facts") and not model.get("relations"):
            overall = "UNSUPPORTED"
            reason = "no material claims to verify"
        elif model.get("confidence") != "VERIFIED":
            overall = "UNVERIFIED"
            reason = (f"answer confidence is "
                      f"{model.get('confidence')!r}; promotion forbidden")
        elif failed:
            overall = "UNVERIFIED"
            reason = failed[0].get("reason")
        elif not model.get("evidence"):
            overall = "UNVERIFIED"
            reason = "no evidence blocks in answer"
        else:
            overall = "VERIFIED"
            reason = None

        return {
            "schema": "answer_verification",
            "version": 1,
            "overall": overall,
            "reason": reason,
            "claims_total": len(all_v),
            "claims_verified": len(all_v) - len(failed),
            "claim_results": claims,
            "relation_results": rels,
            "failed_checks": [
                {"kind": "claim" if i < len(claims) else "relation",
                 "result": v}
                for i, v in enumerate(all_v) if v["status"] != "VERIFIED"
            ],
        }


def main():
    ve = VerifyEngine.load()
    from answer import AnswerEngine
    ae = AnswerEngine(ve.cb)
    m = ae.answer("CALLERS", "foldConstantOp",
                  question="Who calls foldConstantOp?")
    res = ve.verify_answer(m)
    print("ANSWER VERIFY:", res["overall"],
          f"{res['claims_verified']}/{res['claims_total']}",
          res["reason"] or "")
    bad = ae.answer("DEFINITION", "ghost_xyz")
    res2 = ve.verify_answer(bad)
    print("EMPTY VERIFY:", res2["overall"], "-", res2["reason"])
    sys.exit(0)


if __name__ == "__main__":
    main()
