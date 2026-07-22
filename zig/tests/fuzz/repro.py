import subprocess, tempfile, os
bpc = r"C:\B-Plus\zig\bpc.exe"
tests = {
    "empty_braces": "state Main { entry { { { { { { { { ",
    "unterminated_str": 'state Main { entry { var x = "hello',
    "unterminated_str2": 'state Main { entry { var x = "',
}
for label, code in tests.items():
    with tempfile.NamedTemporaryFile(mode='w', suffix='.b+', delete=False, dir=tempfile.gettempdir(), encoding='utf-8') as f:
        f.write(code)
        p = f.name
    r = subprocess.run([bpc, 'run', p], capture_output=True, timeout=5, creationflags=0x08000000)
    print(f"=== {label} ===")
    print(f"exit: {r.returncode}")
    stderr = r.stderr.decode(errors='replace')[:500]
    print(f"stderr: {stderr}")
    print()
    os.unlink(p)
