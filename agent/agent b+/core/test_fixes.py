"""Test fixed oracles for binarySearch and popCount."""
import subprocess, tempfile, os

FIXES = {
    "binarySearch_fixed": '''const std = @import("std");
const testing = std.testing;

pub fn binarySearch(s: []const i32, v: i32) ?usize {
    var lo: usize = 0;
    var hi = s.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (s[mid] == v) return mid;
        if (s[mid] < v) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return null;
}

test "verify" {
    const a = [_]i32{1,2,3,4,5};
    try std.testing.expectEqual(@as(?usize,2), binarySearch(&a, 3));
    try std.testing.expectEqual(@as(?usize,null), binarySearch(&a, 6));
    try std.testing.expectEqual(@as(?usize,0), binarySearch(&a, 1));
    try std.testing.expectEqual(@as(?usize,4), binarySearch(&a, 5));
}''',

    "popCount_fixed": '''const std = @import("std");
const testing = std.testing;

pub fn popCount(x_arg: u32) u32 {
    var x = x_arg;
    var c: u32 = 0;
    while (x != 0) : (x &= x - 1) {
        c += 1;
    }
    return c;
}

test "verify" {
    try std.testing.expectEqual(@as(u32,2), popCount(5));
    try std.testing.expectEqual(@as(u32,0), popCount(0));
    try std.testing.expectEqual(@as(u32,8), popCount(255));
    try std.testing.expectEqual(@as(u32,1), popCount(1));
}''',
}

for name, code in FIXES.items():
    with tempfile.NamedTemporaryFile(suffix=".zig", mode="w", delete=False, encoding="utf-8") as f:
        f.write(code); f.flush(); tmp = f.name
    try:
        r = subprocess.run(["zig", "test", tmp], capture_output=True, text=True, timeout=15)
        status = "PASS" if r.returncode == 0 else "FAIL"
        print(f"  {name}: {status}")
        if r.returncode != 0:
            print(f"    {r.stderr[:300]}")
    except Exception as e:
        print(f"  {name}: ERROR {e}")
    finally:
        try: os.unlink(tmp)
        except: pass
