import os
import sys

from common import (
    INDEX_PATH,
    IMPORT_RE,
    ZIG_ROOT,
    iter_zig_files,
    read_lines,
    save_json,
    sha256_file,
    short_id,
)


def build_entry(path):
    digest = sha256_file(path)
    lines = read_lines(path)
    st = os.stat(path)
    text = "\n".join(lines)
    return {
        "id": short_id("FI", str(path), digest),
        "path": str(path),
        "language": "zig",
        "type": "module",
        "size": st.st_size,
        "sha256": digest,
        "line_count": len(lines),
        "non_empty_lines": sum(1 for line in lines if line.strip()),
        "imports": IMPORT_RE.findall(text),
    }


def main():
    entries = [build_entry(p) for p in iter_zig_files()]
    doc = {
        "schema": "source_index",
        "version": 1,
        "root": str(ZIG_ROOT),
        "file_count": len(entries),
        "files": entries,
    }
    save_json(INDEX_PATH, doc)
    print("written:", len(entries))

    fresh = iter_zig_files()
    real_file_count = len(fresh)
    indexed_paths = {e["path"] for e in entries}
    fresh_paths = {str(p) for p in fresh}

    paths_exist = True
    sha_match = True
    line_count_ok = True
    non_empty_ok = True
    for entry in entries:
        path = entry["path"]
        if not os.path.isfile(path):
            paths_exist = False
            continue
        if sha256_file(path) != entry["sha256"]:
            sha_match = False
        lines = read_lines(path)
        if len(lines) != entry["line_count"]:
            line_count_ok = False
        if sum(1 for line in lines if line.strip()) != entry["non_empty_lines"]:
            non_empty_ok = False

    print("index_count:", len(entries))
    print("real_file_count:", real_file_count)
    print("paths_exist:", paths_exist)
    print("sha256_match:", sha_match)
    print("line_count:", line_count_ok)
    print("non_empty_lines:", non_empty_ok)
    print("index_subset_of_real:", indexed_paths <= fresh_paths)
    print("real_subset_of_index:", fresh_paths <= indexed_paths)

    ok = all([
        len(entries) == real_file_count,
        paths_exist,
        sha_match,
        line_count_ok,
        non_empty_ok,
        indexed_paths == fresh_paths,
    ])
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
