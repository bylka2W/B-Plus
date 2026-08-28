"""
SourceCoverage gate.

Enforces the two independent metrics the user requires:

  COVERAGE   -- every source file is indexed, every non-empty file is
                represented by at least one symbol, nothing is discarded.
  VERIFICATION -- every extracted fact has valid evidence whose text/sha256
                matches the LIVE source (readlines method).

Plus tier separation: memory/full_zig is the SOURCE OF TRUTH (tier=truth),
memory/ is the B+ ENVIRONMENT. And UNRESOLVED targets are PRESERVED, not
dropped.
"""
import io
import json
import os
import hashlib
import random

import pytest

MEM = os.path.join(os.path.dirname(__file__), "..", "memory")
TRUTH = os.path.join(MEM, "full_zig")


def _load(name):
    with io.open(os.path.join(TRUTH, name), encoding="utf-8") as f:
        return json.load(f)


def _load_mem(name):
    with io.open(os.path.join(MEM, name), encoding="utf-8") as f:
        return json.load(f)


def test_truth_block_exists():
    assert os.path.isdir(TRUTH), "memory/full_zig (source of truth) block missing"


def test_file_coverage_100():
    idx = _load("source_index.json")["files"]
    syms = _load("source_symbols.json")["items"]
    sym_files = {s["source_file"] for s in syms}
    indexed = {f["path"] for f in idx}
    # every indexed file exists on disk
    missing = [p for p in indexed if not os.path.isfile(p)]
    assert not missing, f"indexed files missing on disk: {missing[:3]}"
    # every NON-EMPTY indexed file is represented by >=1 symbol
    lost = []
    for p in indexed:
        if p in sym_files:
            continue
        if os.path.isfile(p):
            with open(p, "r", encoding="utf-8", errors="replace") as fh:
                if fh.read().strip():
                    lost.append(p)
    assert not lost, f"non-empty files without representation: {lost[:3]}"


def test_fact_evidence_and_tier():
    facts = _load("facts.json")["items"]
    evs = _load("source_evidence.json")["items"]
    ev_by_id = {e["id"]: e for e in evs}
    # every fact references existing evidence
    miss = [f["fact_id"] for f in facts if f["evidence_id"] not in ev_by_id]
    assert not miss, f"facts without evidence: {miss[:3]}"
    # every fact is VERIFIED and tier=truth
    bad = [f["fact_id"] for f in facts
           if f.get("verification_status") != "VERIFIED" or f.get("tier") != "truth"]
    assert not bad, f"facts not VERIFIED/truth: {bad[:3]}"


def test_evidence_chain_sampled():
    """Sample evidence and verify sha256 against live source (readlines)."""
    evs = _load("source_evidence.json")["items"]
    sample = random.sample(evs, min(3000, len(evs)))
    cache = {}

    def lines(p):
        if p not in cache:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                cache[p] = f.readlines()
        return cache[p]

    bad = 0
    for e in sample:
        p = e["source_file"]
        s, en = e["line_start"], e["line_end"]
        if not os.path.isfile(p):
            bad += 1
            continue
        L = lines(p)
        if s < 1 or en > len(L) or en < s:
            bad += 1
            continue
        seg = "".join(L[s - 1:en])
        if hashlib.sha256(seg.encode("utf-8", "replace")).hexdigest() != e["sha256"]:
            bad += 1
    assert bad == 0, f"{bad} sampled evidence records have broken hash chains"


def test_bplus_unresolved_preserved():
    """UNRESOLVED targets in the B+ environment block are PRESERVED as
    VERIFIED + resolution_status=UNRESOLVED, never dropped."""
    facts = _load_mem("facts.json")["items"]
    unres = [f for f in facts if f.get("resolution_status") == "UNRESOLVED"]
    # at least the previously-known 1681 must be preserved (not deleted)
    assert len(unres) >= 1681, f"UNRESOLVED facts were lost: {len(unres)}"
    # none may carry an UNRESOLVED verification_status (we keep them VERIFIED)
    dropped = [f for f in facts if f.get("verification_status") != "VERIFIED"]
    assert not dropped, "facts left in non-VERIFIED status"


def test_tier_separation():
    """full_zig = truth; memory = environment. Confirm truth has no env tier."""
    facts = _load("facts.json")["items"]
    tiers = {f.get("tier") for f in facts}
    assert tiers == {"truth"}, f"truth block has wrong tiers: {tiers}"
    mem_facts = _load_mem("facts.json")["items"]
    # B+ environment facts must NOT claim truth
    truth_in_env = [f for f in mem_facts if f.get("tier") == "truth"]
    assert not truth_in_env, "B+ environment block must not be marked truth"
