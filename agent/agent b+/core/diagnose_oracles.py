"""Diagnose 4 failing oracles."""
import subprocess, tempfile, os
from pathlib import Path

FAILURES = {
    "binarySearch": '''const std = @import("std");
const testing = std.testing;

pub fn binarySearch(s: []const i32, v: i32) ?usize {
    var lo: usize = 0;
    var hi = s.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (s[mid] == v) return mid;
        if (s[mid] < v) lo = mid + 1;
        else hi = mid;
    }
    return null;
}

test "verify" {
    const a = [_]i32{1,2,3,4,5};
    try std.testing.expectEqual(@as(?usize,2), binarySearch(&a, 3));
    try std.testing.expectEqual(@as(?usize,null), binarySearch(&a, 6));
}''',

    "startsWith": '''const std = @import("std");
const testing = std.testing;

pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

pub fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (prefix.len > s.len) return false;
    return eql(s[0..prefix.len], prefix);
}

test "verify" {
    try std.testing.expect(startsWith("hello","hel"));
    try std.testing.expect(!startsWith("hello","xyz"));
}''',

    "endsWith": '''const std = @import("std");
const testing = std.testing;

pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

pub fn endsWith(s: []const u8, suffix: []const u8) bool {
    if (suffix.len > s.len) return false;
    return eql(s[s.len - suffix.len..], suffix);
}

test "verify" {
    try std.testing.expect(endsWith("hello","llo"));
    try std.testing.expect(!endsWith("hello","xyz"));
}''',

    "popCount": '''const std = @import("std");
const testing = std.testing;

pub fn popCount(mut x: u32) u32 {
    var c: u32 = 0;
    while (x != 0) : (x &= x - 1) {
        c += 1;
    }
    return c;
}

test "verify" {
    try std.testing.expectEqual(@as(u32,2), popCount(5));
    try std.testing.expectEqual(@as(u32,0), popCount(0));
}''',
}

for name, code in FAILURES.items():
    with tempfile.NamedTemporaryFile(suffix=".zig", mode="w", delete=False, encoding="utf-8") as f:
        f.write(code); f.flush(); tmp = f.name
    try:
        r = subprocess.run(["zig", "test", tmp], capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            print(f"  {name}: PASS")
        else:
            print(f"  {name}: FAIL")
            print(f"    stderr: {r.stderr[:500]}")
            print(f"    stdout: {r.stdout[:500]}")
    except Exception as e:
        print(f"  {name}: ERROR {e}")
    finally:
        try: os.unlink(tmp)
        except: pass
