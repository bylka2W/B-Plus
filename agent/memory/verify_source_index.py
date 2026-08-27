import os, json, hashlib

root = r'C:\\B-Plus\\zig'
# real recursive .zig count
real_files = []
for dirpath, _, files in os.walk(root):
    if any(d in dirpath for d in ['node_modules','zig-cache','zig-out','.git','venv','dist','build']):
        continue
    for f in files:
        if f.endswith('.zig'):
            real_files.append(os.path.join(dirpath,f))
real_count = len(real_files)

with open(r'C:\\B-Plus\\agent\\memory\\source_index.json') as jf:
    index_data = json.load(jf)
index_files = index_data.get('files', [])
index_count = len(index_files)

ok = True
missing = []
hash_mismatch = []

for info in index_files:
    path = info['path']
    if not os.path.exists(path):
        missing.append(path)
        ok = False
        continue
    with open(path,'rb') as f:
        h = hashlib.sha256(f.read()).hexdigest()
    if h != info['sha256']:
        hash_mismatch.append(path)
        ok = False

# line count verification
line_mismatch = []
for info in index_files:
    path = info['path']
    if not os.path.exists(path):
        continue
    with open(path, 'r', encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()
    # we store number of lines in the json? not present - skip

print('real count:',real_count)
print('index count:',index_count)
print('missing:',missing)
print('hash mismatches:',hash_mismatch)
print('ok:',ok)
