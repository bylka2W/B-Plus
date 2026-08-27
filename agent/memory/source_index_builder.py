import os, json, hashlib, datetime, re, sys

# Scan the B+ Zig project and build an index of .zig source files

root = r"C:\\B-Plus\\zig"
excluded_dirs = {
    "node_modules",
    "zig-cache",
    "zig-out",
    ".git",
    "venv",
    "dist",
    "build",
}

# ---------------------------------------------------------------------
# Helper to collect data for a single file
# ---------------------------------------------------------------------

def collect(path):
    info = {}
    info["path"] = path
    ext = os.path.splitext(path)[1].lower()
    language_map = {".zig": "zig", ".b+": "bplus", ".json": "json"}
    info["language"] = language_map.get(ext, "unknown")
    info["type"] = (
        "module" if ext == ".zig"
        else "program" if ext == ".b+"
        else "config"
    )
    st = os.stat(path)
    info["size"] = st.st_size
    info["last_write"] = datetime.datetime.fromtimestamp(st.st_mtime).isoformat()
    with open(path, "rb") as f:
        info["sha256"] = hashlib.sha256(f.read()).hexdigest()
    if ext == ".zig":
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()
        info["line_count"] = len(lines)
        info["non_empty_lines"] = sum(1 for l in lines if l.strip())
        content = "".join(lines)
        imports = re.findall(r'@import\s*\("(.*?)"\)', content)
        info["imports"] = imports
    else:
        info["imports"] = []
    return info

# ---------------------------------------------------------------------
# 1. Build index
# ---------------------------------------------------------------------

entries = []
for dirpath, dirnames, files in os.walk(root):
    # Skip excluded directories
    if any(ed in dirpath for ed in excluded_dirs):
        continue
    for f in files:
        if f.endswith(".zig"):
            entries.append(collect(os.path.join(dirpath, f)))

index_count = len(entries)

# ---------------------------------------------------------------------
# 2. Write index JSON
# ---------------------------------------------------------------------

json_path = r"C:\\B-Plus\\agent\\memory\\source_index.json"
with open(json_path, "w", encoding="utf-8") as jf:
    json.dump({"files": entries}, jf, indent=2)

# ---------------------------------------------------------------------
# 3. Fresh verification pass
# ---------------------------------------------------------------------

# Fresh real file count from fresh walk
fresh_file_count = 0
for dirpath, _, files in os.walk(root):
    if any(ed in dirpath for ed in excluded_dirs):
        continue
    for f in files:
        if f.endswith(".zig"):
            fresh_file_count += 1

print("written", index_count)
print("index_count", index_count)
print("real_file_count", fresh_file_count)

# Verify existence and hashes
paths_exist = True
sha256_match = True
real_line_count = True
non_empty_line_count = True
for info in entries:
    path = info["path"]
    if not os.path.exists(path):
        paths_exist = False
        continue
    # SHA256
    with open(path, "rb") as f:
        h = hashlib.sha256(f.read()).hexdigest()
    if h != info["sha256"]:
        sha256_match = False
    # Lines
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()
    if len(lines) != info.get("line_count"):
        real_line_count = False
    if sum(1 for l in lines if l.strip()) != info.get("non_empty_lines"):
        non_empty_line_count = False

print("paths_exist:", paths_exist)
print("sha256_match:", sha256_match)
print("real_line_count:", real_line_count)
print("non_empty_line_count:", non_empty_line_count)

# Exit with error if any check fails
if not (paths_exist and sha256_match and real_line_count and non_empty_line_count):
    sys.exit(1)

# ---------------------------------------------------------------------
# End of script
# ---------------------------------------------------------------------
