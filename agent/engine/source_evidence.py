import os
import sys

from common import (
    CHUNK_SIZE,
    EVIDENCE_PATH,
    INDEX_PATH,
    ZIG_ROOT,
    iter_zig_files,
    load_json,
    read_lines,
    save_json,
    sha256_file,
    short_id,
)


def evidence_id(path, digest, start, end):
    return short_id("EV", path, digest, start, end)


def build_items(index_files):
    items = []
    for entry in index_files:
        lines = read_lines(entry["path"])
        total = len(lines)
        for start in range(1, total + 1, CHUNK_SIZE):
            end = min(start + CHUNK_SIZE - 1, total)
            items.append({
                "id": evidence_id(entry["path"], entry["sha256"], start, end),
                "source_file": entry["path"],
                "file_id": entry["id"],
                "sha256": entry["sha256"],
                "line_start": start,
                "line_end": end,
                "text": "\n".join(lines[start - 1:end]),
                "verification_status": "VERIFIED",
            })
    return items


def main():
    index = load_json(INDEX_PATH)
    index_files = index.get("files")
    if not isinstance(index_files, list) or not index_files:
        print("ERROR: source_index.json is empty or malformed")
        sys.exit(1)

    for entry in index_files:
        if not os.path.isfile(entry["path"]):
            print("ERROR: indexed file missing:", entry["path"])
            sys.exit(1)
        if sha256_file(entry["path"]) != entry["sha256"]:
            print("ERROR: sha mismatch at load time:", entry["path"])
            sys.exit(1)

    items = build_items(index_files)
    doc = {
        "schema": "source_evidence",
        "version": 1,
        "chunk_size": CHUNK_SIZE,
        "root": str(ZIG_ROOT),
        "file_count": len(index_files),
        "evidence_count": len(items),
        "items": items,
    }
    save_json(EVIDENCE_PATH, doc)
    print("written:", len(items))

    real_file_count = len(iter_zig_files())

    by_file = {}
    for item in items:
        by_file.setdefault(item["source_file"], []).append(item)

    paths_exist = True
    sha_match = True
    ranges_valid = True
    text_match = True
    coverage_ok = True
    ids_deterministic = True
    duplicate_ids = len({i["id"] for i in items}) != len(items)

    seen_ids = set()
    for entry in index_files:
        path = entry["path"]
        if not os.path.isfile(path):
            paths_exist = False
            continue
        actual_sha = sha256_file(path)
        if actual_sha != entry["sha256"]:
            sha_match = False
            continue
        lines = read_lines(path)
        total = len(lines)
        chunks = sorted(by_file.get(path, []), key=lambda c: c["line_start"])

        expected_start = 1
        for chunk in chunks:
            start = chunk["line_start"]
            end = chunk["line_end"]
            if start < 1 or end > total or start > end:
                ranges_valid = False
                continue
            if start != expected_start or (expected_start == 1 and start != 1):
                coverage_ok = False
            expected_start = end + 1
            if "\n".join(lines[start - 1:end]) != chunk["text"]:
                text_match = False
            if chunk["id"] != evidence_id(path, actual_sha, start, end):
                ids_deterministic = False
            if chunk["id"] in seen_ids:
                ids_deterministic = False
            seen_ids.add(chunk["id"])

        if chunks and expected_start - 1 != total:
            coverage_ok = False
        if not chunks and total != 0:
            coverage_ok = False

    print("evidence_count:", len(items))
    print("real_file_count:", real_file_count)
    print("index_file_count:", len(index_files))
    print("paths_exist:", paths_exist)
    print("sha256_match:", sha_match)
    print("ranges_valid:", ranges_valid)
    print("coverage_full:", coverage_ok)
    print("text_match:", text_match)
    print("ids_deterministic:", ids_deterministic and not duplicate_ids)

    ok = all([
        len(index_files) == real_file_count,
        paths_exist,
        sha_match,
        ranges_valid,
        coverage_ok,
        text_match,
        ids_deterministic,
        not duplicate_ids,
    ])
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
