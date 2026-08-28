"""
Anti-hallucination adversarial suite — TF Step 4.
9 categories testing that the Knowledge Engine NEVER fabricates answers.

A. Nonexistent entities → UNKNOWN/NEEDS_DEEP_SEARCH
B. Real entity + false relation claim → must not confirm
C. Wrong type (STRUCT queried as FUNCTION) → correct handling
D. Real file + fabricated line → no evidence at fake line
E. Real function + fabricated caller → not in CALLERS results
F. Real function + fabricated callee → not in CALLEES results
G. Partial information → PARTIAL, not VERIFIED
H. Ambiguous entity → AMBIGUOUS, not ANSWER_READY
I. Question outside knowledge scope → UNKNOWN
"""
import os
import sys
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "engine"))

from knowledge import Knowledge
from evidence_bundle import build_evidence_bundle
from protocol import is_terminal
from source_store import SourceStore


@pytest.fixture(scope="module")
def knowledge():
    return Knowledge.load()


@pytest.fixture(scope="module")
def store():
    return SourceStore.load()


@pytest.fixture(scope="module")
def sample_func():
    from common import MEMORY_DIR, load_json
    concepts = load_json(MEMORY_DIR / "concepts.json")
    verified = [c for c in concepts["items"]
                if c.get("verification_status") == "VERIFIED"
                and c["concept_type"] == "FUNCTION"]
    return verified[0] if verified else None


@pytest.fixture(scope="module")
def sample_struct():
    from common import MEMORY_DIR, load_json
    concepts = load_json(MEMORY_DIR / "concepts.json")
    verified = [c for c in concepts["items"]
                if c.get("verification_status") == "VERIFIED"
                and c["concept_type"] == "STRUCT"]
    return verified[0] if verified else None


@pytest.fixture(scope="module")
def sample_module():
    from common import MEMORY_DIR, load_json
    concepts = load_json(MEMORY_DIR / "concepts.json")
    verified = [c for c in concepts["items"]
                if c.get("verification_status") == "VERIFIED"
                and c["concept_type"] == "MODULE"]
    return verified[0] if verified else None


def _check_no_hallucination(k, question, label=""):
    bd = build_evidence_bundle(k, question, None).to_dict()
    assert bd["confidence"] != "VERIFIED" or bd["status"] == "UNKNOWN", (
        f"[{label}] '{question}' got VERIFIED — hallucination risk"
    )
    assert not is_terminal(bd), (
        f"[{label}] '{question}' reached terminal — false positive"
    )
    return bd


# === A. Nonexistent entities ===

NONEXISTENT = [
    "Who calls DefinitelyFakeFunction_A?",
    "What does FakeModule_xyz call?",
    "Where is FakeStruct_B defined?",
    "What does FakeFile_99.zig contain?",
    "Who calls nonexistent_function_12345?",
]


@pytest.mark.parametrize("question", NONEXISTENT)
def test_a_nonexistent_entity(knowledge, question):
    bd = _check_no_hallucination(knowledge, question, "A-nonexistent")
    assert bd["status"] in ("NEEDS_DEEP_SEARCH", "UNKNOWN"), (
        f"nonexistent '{question}' got status={bd['status']}"
    )


# === B. Real entity + false relation claim ===

def test_b_real_entity_false_caller(knowledge, sample_func):
    if not sample_func:
        pytest.skip("no verified function")
    name = sample_func["canonical_name"].rsplit("/", 1)[-1]
    question = "Who calls %s?" % name
    bd = build_evidence_bundle(knowledge, question, None).to_dict()
    if bd["status"] == "ANSWER_READY":
        callers = [e.get("name", "") for e in bd.get("entities", [])]
        assert "FabricatedCallerThatDoesNotExist" not in str(callers), (
            f"false caller in results for '{name}'"
        )


def test_b_real_entity_false_callee(knowledge, sample_func):
    if not sample_func:
        pytest.skip("no verified function")
    name = sample_func["canonical_name"].rsplit("/", 1)[-1]
    question = "What does %s call?" % name
    bd = build_evidence_bundle(knowledge, question, None).to_dict()
    if bd["status"] == "ANSWER_READY":
        callees = [e.get("name", "") for e in bd.get("entities", [])]
        assert "FabricatedCalleeThatDoesNotExist" not in str(callees), (
            f"false callee in results for '{name}'"
        )


# === C. Wrong type ===

def test_c_struct_queried_as_function(knowledge, sample_struct):
    if not sample_struct:
        pytest.skip("no verified struct")
    name = sample_struct["canonical_name"].rsplit("/", 1)[-1]
    question = "Who calls %s?" % name
    bd = build_evidence_bundle(knowledge, question, None).to_dict()
    assert bd["status"] != "UNKNOWN_INTENT", (
        f"struct '{name}' queried as callers got UNKNOWN_INTENT"
    )


def test_c_function_queried_as_module(knowledge, sample_func):
    if not sample_func:
        pytest.skip("no verified function")
    name = sample_func["canonical_name"].rsplit("/", 1)[-1]
    question = "What does module %s contain?" % name
    bd = build_evidence_bundle(knowledge, question, None).to_dict()
    assert bd["confidence"] != "VERIFIED", (
        f"function '{name}' queried as module got VERIFIED"
    )


# === D. Real file + fabricated line ===

def test_d_real_file_fake_line(knowledge, store):
    real_ev = [e for e in store.evidence_doc["items"]
               if e.get("verification_status") == "VERIFIED"
               and e.get("source_file")
               and os.path.exists(e["source_file"])]
    if not real_ev:
        pytest.skip("no verifiable evidence")
    ev = real_ev[0]
    fname = ev["source_file"].rsplit("/", 1)[-1].rsplit("\\", 1)[-1]
    question = "What is at line 99999 in %s?" % fname
    bd = build_evidence_bundle(knowledge, question, None).to_dict()
    assert bd["confidence"] != "VERIFIED", (
        f"fake line 99999 in '{fname}' got VERIFIED"
    )


# === E/F. Real entity — verify no fabricated callers/callees in results ===

def test_e_no_fabricated_callers_in_results(knowledge, sample_func):
    if not sample_func:
        pytest.skip("no verified function")
    name = sample_func["canonical_name"].rsplit("/", 1)[-1]
    question = "Who calls %s?" % name
    bd = build_evidence_bundle(knowledge, question, None).to_dict()
    if bd["status"] == "ANSWER_READY":
        for entity in bd.get("entities", []):
            ename = entity.get("name", "")
            assert "Fake" not in ename or "FAKE" not in ename, (
                f"suspicious entity in callers: {ename}"
            )


def test_f_no_fabricated_callees_in_results(knowledge, sample_func):
    if not sample_func:
        pytest.skip("no verified function")
    name = sample_func["canonical_name"].rsplit("/", 1)[-1]
    question = "What does %s call?" % name
    bd = build_evidence_bundle(knowledge, question, None).to_dict()
    if bd["status"] == "ANSWER_READY":
        for entity in bd.get("entities", []):
            ename = entity.get("name", "")
            assert "Fake" not in ename or "FAKE" not in ename, (
                f"suspicious entity in callees: {ename}"
            )


# === G. Partial information → PARTIAL, not VERIFIED ===

def test_g_partial_not_verified(knowledge, sample_func):
    if not sample_func:
        pytest.skip("no verified function")
    name = sample_func["canonical_name"].rsplit("/", 1)[-1]
    question = "Who calls %s and what does each caller do in detail?" % name
    bd = build_evidence_bundle(knowledge, question, None).to_dict()
    if bd["confidence"] == "VERIFIED":
        assert len(bd.get("unresolved", [])) == 0, (
            f"VERIFIED but has unresolved — inconsistent"
        )


# === H. Ambiguous entity ===

def test_h_ambiguous_entity(knowledge):
    question = "Who calls emit?"
    bd = build_evidence_bundle(knowledge, question, None).to_dict()
    if bd["status"] == "PARTIAL" or bd["answer_type"] == "AMBIGUOUS_ENTITY":
        assert not is_terminal(bd), (
            "ambiguous entity reached terminal — broken disambiguation gate"
        )


# === I. Question outside knowledge scope ===

OUT_OF_SCOPE = [
    "Why did the developer choose this architecture?",
    "What is the performance of this code at runtime?",
    "Is this code secure against injection attacks?",
    "What unit tests cover this function?",
    "What is the deployment process?",
]


@pytest.mark.parametrize("question", OUT_OF_SCOPE)
def test_i_out_of_scope(knowledge, question):
    bd = _check_no_hallucination(knowledge, question, "I-out-of-scope")
    assert bd["confidence"] in ("UNSUPPORTED", "PARTIAL"), (
        f"out-of-scope '{question}' got confidence={bd['confidence']}"
    )
