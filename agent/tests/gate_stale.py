"""
STAGE 2 RELEASE GATE — STALE EVIDENCE AUDIT
Checks if evidence sha256 matches actual source file sha256.
If source changed after evidence creation, evidence is stale.
"""
import hashlib
import os
import sys
import json
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "engine"))

from common import MEMORY_DIR, load_json


def sha256_file(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(8192), b""):
                h.update(chunk)
        return h.hexdigest()
    except (OSError, IOError):
        return None


def main():
    print("=" * 70)
    print("STAGE 2 RELEASE GATE — STALE EVIDENCE AUDIT")
    print("=" * 70)

    evidence_doc = load_json(MEMORY_DIR / "source_evidence.json")
    evidence_items = evidence_doc["items"]

    total = len(evidence_items)
    checked = 0
    stale = 0
    missing_file = 0
    match = 0
    stale_details = []

    for ev in evidence_items:
        sf = ev.get("source_file", "")
        if not sf:
            continue
        if not os.path.exists(sf):
            missing_file += 1
            continue
        actual_sha = sha256_file(sf)
        expected_sha = ev.get("sha256", "")
        if actual_sha and expected_sha:
            checked += 1
            if actual_sha == expected_sha:
                match += 1
            else:
                stale += 1
                stale_details.append({
                    "evidence_id": ev["id"],
                    "file": sf,
                    "expected_sha": expected_sha[:16],
                    "actual_sha": actual_sha[:16],
                    "line": f"{ev.get('line_start')}-{ev.get('line_end')}",
                })

    print(f"\nTotal evidence: {total}")
    print(f"Checked: {checked}")
    print(f"Match: {match}")
    print(f"Stale: {stale}")
    print(f"Missing files: {missing_file}")

    status = "PASS" if stale == 0 else "FAIL"
    print(f"\nSTATUS: {status}")

    if stale_details:
        print(f"\nStale evidence (first 10):")
        for d in stale_details[:10]:
            print(f"  {d['evidence_id']}: {d['file']}")
            print(f"    expected: {d['expected_sha']}  actual: {d['actual_sha']}  lines: {d['line']}")

    result = {
        "timestamp": time.time(),
        "total": total,
        "checked": checked,
        "match": match,
        "stale": stale,
        "missing_file": missing_file,
        "status": status,
        "stale_details": stale_details[:20],
    }
    with open(MEMORY_DIR / "stale_evidence_audit.json", "w") as f:
        json.dump(result, f, indent=2)
    print(f"\nSaved: memory/stale_evidence_audit.json")

    return 0 if stale == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
