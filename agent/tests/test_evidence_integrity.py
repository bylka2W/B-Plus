"""
Evidence integrity tests — TF Step 2:
VERIFIED requires: fact + evidence + valid source_path + valid lines + source text matching.

Rules enforced:
  1. Every VERIFIED relation must have evidence_id
  2. Every evidence_id must resolve to real evidence
  3. Every evidence must have source_file, line_start, line_end, text, sha256
  4. line_start >= 1, line_end >= line_start
  5. Source file must exist on disk
  6. Evidence text must match actual source at line range
  7. VERIFIED cannot be assigned without evidence chain
"""
import os
import sys
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "engine"))

from source_store import SourceStore


@pytest.fixture(scope="module")
def store():
    return SourceStore.load()


@pytest.fixture(scope="module")
def verified_rels(store):
    return [r for r in store.relations_doc["items"]
            if r.get("verification_status") == "VERIFIED"]


@pytest.fixture(scope="module")
def verified_evidence(store):
    return [e for e in store.evidence_doc["items"]
            if e.get("verification_status") == "VERIFIED"]


# --- 1. Every VERIFIED relation must have evidence_id ---

def test_verified_relation_has_evidence_id(verified_rels):
    no_ev = [r["relation_id"] for r in verified_rels if not r.get("evidence_id")]
    assert len(no_ev) == 0, (
        f"{len(no_ev)} VERIFIED relations lack evidence_id: {no_ev[:5]}"
    )


# --- 2. Every evidence_id must resolve to real evidence ---

def test_evidence_id_resolves(store, verified_rels):
    bad = []
    for r in verified_rels:
        eid = r.get("evidence_id")
        if eid and eid not in store.evidence_by_id:
            bad.append((r["relation_id"], eid))
    assert len(bad) == 0, (
        f"{len(bad)} evidence_ids not found in evidence store: {bad[:5]}"
    )


# --- 3. Every VERIFIED evidence must have required fields ---

def test_evidence_has_source_file(verified_evidence):
    bad = [e["id"] for e in verified_evidence if not e.get("source_file")]
    assert len(bad) == 0, f"{len(bad)} evidence lack source_file: {bad[:5]}"


def test_evidence_has_sha256(verified_evidence):
    bad = [e["id"] for e in verified_evidence if not e.get("sha256")]
    assert len(bad) == 0, f"{len(bad)} evidence lack sha256: {bad[:5]}"


def test_evidence_has_text(verified_evidence):
    bad = [e["id"] for e in verified_evidence if not e.get("text")]
    assert len(bad) == 0, f"{len(bad)} evidence lack text: {bad[:5]}"


# --- 4. Line ranges must be valid ---

def test_evidence_line_start_valid(verified_evidence):
    bad = [e["id"] for e in verified_evidence
           if not e.get("line_start") or e["line_start"] < 1]
    assert len(bad) == 0, f"{len(bad)} evidence have invalid line_start: {bad[:5]}"


def test_evidence_line_end_gte_start(verified_evidence):
    bad = [e["id"] for e in verified_evidence
           if e.get("line_end", 0) < e.get("line_start", 0)]
    assert len(bad) == 0, (
        f"{len(bad)} evidence have line_end < line_start: {bad[:5]}"
    )


# --- 5. Source files must exist on disk ---

def test_evidence_source_files_exist(verified_evidence):
    missing = []
    for e in verified_evidence:
        sf = e.get("source_file", "")
        if sf and not os.path.exists(sf):
            missing.append((e["id"], sf))
    assert len(missing) == 0, (
        f"{len(missing)} source files missing: {missing[:5]}"
    )


# --- 6. Evidence text must match actual source at line range ---

def test_evidence_text_matches_source(verified_evidence):
    mismatches = []
    checked = 0
    for e in verified_evidence[:200]:
        sf = e.get("source_file", "")
        if not sf or not os.path.exists(sf):
            continue
        try:
            with open(sf, "r", encoding="utf-8", errors="ignore") as f:
                lines = f.readlines()
            start = e.get("line_start", 1) - 1
            end = e.get("line_end", start + 1)
            actual = "".join(lines[start:end])
            expected = e.get("text", "")
            if actual.strip() and expected.strip():
                if actual.strip()[:200] != expected.strip()[:200]:
                    mismatches.append(e["id"])
            checked += 1
        except Exception:
            pass
    assert len(mismatches) == 0, (
        f"{len(mismatches)}/{checked} evidence text mismatches: {mismatches[:5]}"
    )


# --- 7. Facts integrity ---

def test_verified_facts_have_required_fields(store):
    from common import MEMORY_DIR, load_json
    facts_doc = load_json(MEMORY_DIR / "facts.json")
    verified = [f for f in facts_doc["items"]
                if f.get("verification_status") == "VERIFIED"]
    bad_type = [f["fact_id"] for f in verified if not f.get("fact_type")]
    bad_subj = [f["fact_id"] for f in verified if not f.get("subject_id")]
    assert len(bad_type) == 0, f"{len(bad_type)} facts lack fact_type"
    assert len(bad_subj) == 0, f"{len(bad_subj)} facts lack subject_id"


# --- 8. No VERIFIED without evidence chain at protocol level ---

def test_protocol_rejects_unverified_evidence(store):
    from evidence_bundle import build_evidence_bundle
    from protocol import is_terminal
    from knowledge import Knowledge
    k = Knowledge.load()

    nonexistent = "DefinitelyFakeFunction_Protocol_999"
    b = build_evidence_bundle(k, f"Who calls {nonexistent}?", None)
    bd = b.to_dict()

    assert bd["status"] != "ANSWER_READY", (
        f"nonexistent entity got ANSWER_READY — false positive"
    )
    assert bd["confidence"] != "VERIFIED", (
        f"nonexistent entity got VERIFIED confidence — hallucination"
    )
    assert not is_terminal(bd), (
        f"nonexistent entity reached terminal — broken gate"
    )
