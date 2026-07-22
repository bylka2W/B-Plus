import subprocess, tempfile, os, time, random, string, sys

BPC = r"C:\B-Plus\zig\bpc.exe"

rng = random.Random(42)

code = 'state Main { entry { print(42) } }'
with tempfile.NamedTemporaryFile(mode='w', suffix='.b+', delete=False, dir=tempfile.gettempdir(), encoding='utf-8') as f:
    f.write(code)
    tmp = f.name

print("test1: run...", flush=True)
t0 = time.time()
r = subprocess.run(
    [BPC, "dll", tmp],
    capture_output=True, timeout=10, stdin=subprocess.DEVNULL,
    creationflags=0x08000000
)
print(f"  exit={r.returncode} {time.time()-t0:.2f}s stderr={r.stderr.decode()[:100]}", flush=True)
try: os.unlink(tmp)
except: pass
exe = tmp.rsplit('.', 1)[0] + '.dll'
try:
    if os.path.exists(exe): os.unlink(exe)
except: pass

# Now try importing the fuzzer module
print("\ntest2: importing fuzzer module...", flush=True)
sys.path.insert(0, r"C:\B-Plus\zig\tests\fuzz")
import fuzzer as fz
fz.BPC = BPC

print(f"  BPC={fz.BPC}", flush=True)
print(f"  exists={os.path.exists(fz.BPC)}", flush=True)

# Run one test manually
print("\ntest3: manual compile_test...", flush=True)
code2 = fz.gen_random_program()
print(f"  code length={len(code2)}", flush=True)
print(f"  has import={'import' in code2}", flush=True)
t0 = time.time()
result = fz.compile_test(code2, 0)
dt = time.time() - t0
print(f"  exit={result['exit_code']} {dt:.2f}s timeout={result['timed_out']}", flush=True)
print(f"  stderr={result['stderr'][:100]}", flush=True)

print("\nDONE", flush=True)
