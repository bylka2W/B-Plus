import os, hashlib, json, time
from pathlib import Path

SRC_ROOT = r"C:\\B-Plus\\zig\\src"
INDEX_PATH = r"C:\\B-Plus\\agent\\memory\\source_index.txt"


def compute_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()

def gather_files():
    index_entries = []
    extensions = {}
    total_dirs = set()
    start = time.time()
    for root, dirs, files in os.walk(SRC_ROOT):
        for d in dirs:
            total_dirs.add(os.path.relpath(os.path.join(root, d), SRC_ROOT))
        for f in files:
            path = os.path.join(root, f)
            rel = os.path.relpath(path, SRC_ROOT)
            ext = os.path.splitext(f)[1] or ""
            size = os.path.getsize(path)
            lines = 0
            with open(path, "r", encoding="utf-8", errors="ignore") as fh:
                for _ in fh:
                    lines += 1
            sha = compute_sha256(path)
            entry = {
                "FILE": rel,
                "EXTENSION": ext,
                "SIZE": size,
                "LINES": lines,
                "DIRECTORY": os.path.relpath(root, SRC_ROOT),
                "SHA256": sha,
                "STATUS": "DISCOVERED"
            }
            index_entries.append(entry)
            extensions[ext] = extensions.get(ext, 0) + 1
    total_files = len(index_entries)
    total_time = time.time() - start
    # Write index
    with open(INDEX_PATH, "w", encoding="utf-8") as out:
        for e in index_entries:
            out.write("FILE:\n{}\n".format(e["FILE"]))
            out.write("EXTENSION:\n{}\n".format(e["EXTENSION"]))
            out.write("SIZE:\n{}\n".format(e["SIZE"]))
            out.write("LINES:\n{}\n".format(e["LINES"]))
            out.write("DIRECTORY:\n{}\n".format(e["DIRECTORY"]))
            out.write("SHA256:\n{}\n".format(e["SHA256"]))
            out.write("STATUS:\n{}\n\n".format(e["STATUS" ]))
        out.write("TOTAL FILES:\n{}\n".format(total_files))
        out.write("TOTAL DIRECTORIES:\n{}\n".format(len(total_dirs)))
        out.write("EXTENSIONS:\n")
        for ext, count in extensions.items():
            out.write("{} = {}\n".format(ext, count))
        out.write("SCAN TIME:\n{}\n".format(total_time))

if __name__ == "__main__":
    gather_files()

