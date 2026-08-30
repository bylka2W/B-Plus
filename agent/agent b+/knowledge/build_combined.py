"""
Re-run large verified builder, save to separate files.
Then combine with spec-based B+ dataset.
"""
import json, re, os, subprocess, tempfile, hashlib, time
from pathlib import Path
from collections import defaultdict

OUT_DIR = Path(r"C:\B-Plus\agent\agent b+\knowledge\dataset")

FUNCTIONS = [
    ("Напиши функцию add, складывающую два i32.", "pub fn add(a: i32, b: i32) i32 { return a + b; }", ["test \"add\" { try std.testing.expectEqual(@as(i32,5), add(2,3)); try std.testing.expectEqual(@as(i32,0), add(0,0)); }"]),
    ("Напиши функцию sub, вычитающую b из a.", "pub fn sub(a: i32, b: i32) i32 { return a - b; }", ["test \"sub\" { try std.testing.expectEqual(@as(i32,1), sub(3,2)); try std.testing.expectEqual(@as(i32,-1), sub(1,2)); }"]),
    ("Напиши функцию mul, умножающую два i32.", "pub fn mul(a: i32, b: i32) i32 { return a * b; }", ["test \"mul\" { try std.testing.expectEqual(@as(i32,6), mul(2,3)); try std.testing.expectEqual(@as(i32,0), mul(0,5)); }"]),
    ("Напиши функцию max, возвращающую максимум.", "pub fn max(a: i32, b: i32) i32 { return if (a > b) a else b; }", ["test \"max\" { try std.testing.expectEqual(@as(i32,5), max(5,3)); try std.testing.expectEqual(@as(i32,5), max(3,5)); }"]),
    ("Напиши функцию min, возвращающую минимум.", "pub fn min(a: i32, b: i32) i32 { return if (a < b) a else b; }", ["test \"min\" { try std.testing.expectEqual(@as(i32,3), min(5,3)); try std.testing.expectEqual(@as(i32,3), min(3,5)); }"]),
    ("Напиши функцию abs, абсолютное значение.", "pub fn abs(x: i32) i32 { return if (x < 0) -x else x; }", ["test \"abs\" { try std.testing.expectEqual(@as(i32,5), abs(5)); try std.testing.expectEqual(@as(i32,5), abs(-5)); try std.testing.expectEqual(@as(i32,0), abs(0)); }"]),
    ("Напиши функцию negate, меняющую знак.", "pub fn negate(x: i32) i32 { return -x; }", ["test \"negate\" { try std.testing.expectEqual(@as(i32,-5), negate(5)); try std.testing.expectEqual(@as(i32,5), negate(-5)); }"]),
    ("Напиши функцию square, квадрат числа.", "pub fn square(x: i32) i32 { return x * x; }", ["test \"square\" { try std.testing.expectEqual(@as(i32,25), square(5)); try std.testing.expectEqual(@as(i32,0), square(0)); }"]),
    ("Напиши функцию cube, куб числа.", "pub fn cube(x: i32) i32 { return x * x * x; }", ["test \"cube\" { try std.testing.expectEqual(@as(i32,27), cube(3)); try std.testing.expectEqual(@as(i32,-8), cube(-2)); }"]),
    ("Напиши функцию clamp, ограничивающую значение.", "pub fn clamp(v: i32, lo: i32, hi: i32) i32 { if (v < lo) return lo; if (v > hi) return hi; return v; }", ["test \"clamp\" { try std.testing.expectEqual(@as(i32,5), clamp(5,0,10)); try std.testing.expectEqual(@as(i32,0), clamp(-1,0,10)); try std.testing.expectEqual(@as(i32,10), clamp(15,0,10)); }"]),
    ("Напиши функцию lerp, линейную интерполяцию.", "pub fn lerp(a: f64, b: f64, t: f64) f64 { return a + (b - a) * t; }", ["test \"lerp\" { try std.testing.expectApproxEqAbs(@as(f64,2.5), lerp(0,5,0.5), 0.001); }"]),
    ("Напиши функцию factorial, факториал u64.", "pub fn factorial(n: u64) u64 { if (n <= 1) return 1; var r: u64 = 1; var i: u64 = 2; while (i <= n) : (i += 1) { r *= i; } return r; }", ["test \"factorial\" { try std.testing.expectEqual(@as(u64,1), factorial(0)); try std.testing.expectEqual(@as(u64,120), factorial(5)); }"]),
    ("Напиши функцию fibonacci, число Фибоначчи.", "pub fn fibonacci(n: u32) u64 { if (n == 0) return 0; if (n == 1) return 1; var a: u64 = 0; var b: u64 = 1; var i: u32 = 2; while (i <= n) : (i += 1) { const c = a + b; a = b; b = c; } return b; }", ["test \"fib\" { try std.testing.expectEqual(@as(u64,0), fibonacci(0)); try std.testing.expectEqual(@as(u64,1), fibonacci(1)); try std.testing.expectEqual(@as(u64,55), fibonacci(10)); }"]),
    ("Напиши функцию gcd, наибольший общий делитель.", "pub fn gcd(a: u32, b: u32) u32 { var x = a; var y = b; while (y != 0) { const t = y; y = x % y; x = t; } return x; }", ["test \"gcd\" { try std.testing.expectEqual(@as(u32,6), gcd(12,18)); try std.testing.expectEqual(@as(u32,1), gcd(7,13)); }"]),
    ("Напиши функцию pow, возведение в степень.", "pub fn pow(base: u64, exp: u32) u64 { var result: u64 = 1; var e = exp; var b = base; while (e > 0) { if (e & 1 == 1) result *= b; b *= b; e >>= 1; } return result; }", ["test \"pow\" { try std.testing.expectEqual(@as(u64,1), pow(2,0)); try std.testing.expectEqual(@as(u64,8), pow(2,3)); try std.testing.expectEqual(@as(u64,1024), pow(2,10)); }"]),
    ("Напиши функцию isPrime, проверку на простоту.", "pub fn isPrime(n: u32) bool { if (n < 2) return false; if (n < 4) return true; if (n % 2 == 0 or n % 3 == 0) return false; var i: u32 = 5; while (i * i <= n) : (i += 6) { if (n % i == 0 or n % (i + 2) == 0) return false; } return true; }", ["test \"isPrime\" { try std.testing.expect(!isPrime(0)); try std.testing.expect(isPrime(2)); try std.testing.expect(isPrime(13)); try std.testing.expect(!isPrime(15)); }"]),
    ("Напиши функцию sumSlice, сумму среза i32.", "pub fn sumSlice(s: []const i32) i32 { var t: i32 = 0; for (s) |x| t += x; return t; }", ["test \"sumSlice\" { const a = [_]i32{1,2,3,4,5}; try std.testing.expectEqual(@as(i32,15), sumSlice(&a)); }"]),
    ("Напиши функцию contains, проверку наличия элемента.", "pub fn contains(s: []const i32, v: i32) bool { for (s) |x| { if (x == v) return true; } return false; }", ["test \"contains\" { const a = [_]i32{1,2,3}; try std.testing.expect(contains(&a, 2)); try std.testing.expect(!contains(&a, 5)); }"]),
    ("Напиши функцию indexOf, индекс элемента.", "pub fn indexOf(s: []const i32, v: i32) ?usize { for (s, 0..) |x, i| { if (x == v) return i; } return null; }", ["test \"indexOf\" { const a = [_]i32{10,20,30}; try std.testing.expectEqual(@as(?usize,1), indexOf(&a, 20)); try std.testing.expectEqual(@as(?usize,null), indexOf(&a, 50)); }"]),
    ("Напиши функцию findMax, максимум в срезе.", "pub fn findMax(s: []const i32) ?i32 { if (s.len == 0) return null; var m = s[0]; for (s[1..]) |x| { if (x > m) m = x; } return m; }", ["test \"findMax\" { const a = [_]i32{3,1,4,1,5,9}; try std.testing.expectEqual(@as(?i32,9), findMax(&a)); }"]),
    ("Напиши функцию findMin, минимум в срезе.", "pub fn findMin(s: []const i32) ?i32 { if (s.len == 0) return null; var m = s[0]; for (s[1..]) |x| { if (x < m) m = x; } return m; }", ["test \"findMin\" { const a = [_]i32{3,1,4,1,5,9}; try std.testing.expectEqual(@as(?i32,1), findMin(&a)); }"]),
    ("Напиши функцию count, подсчёт вхождений символа.", "pub fn count(s: []const u8, c: u8) usize { var n: usize = 0; for (s) |x| { if (x == c) n += 1; } return n; }", ["test \"count\" { try std.testing.expectEqual(@as(usize,3), count(\"hello world\", \'l\')); }"]),
    ("Напиши функцию reverse, переворот на месте.", "pub fn reverse(s: []u8) void { var i: usize = 0; var j = s.len; while (i < j) { j -= 1; const t = s[i]; s[i] = s[j]; s[j] = t; i += 1; } }", ["test \"reverse\" { var buf = [_]u8{1,2,3,4,5}; reverse(&buf); try std.testing.expectEqual([_]u8{5,4,3,2,1}, buf); }"]),
    ("Напиши функцию sort, сортировку пузырьком.", "pub fn sort(s: []i32) void { var i: usize = 0; while (i < s.len) : (i += 1) { var j = i + 1; while (j < s.len) : (j += 1) { if (s[i] > s[j]) { const t = s[i]; s[i] = s[j]; s[j] = t; } } } }", ["test \"sort\" { var a = [_]i32{5,3,1,4,2}; sort(&a); try std.testing.expectEqual([_]i32{1,2,3,4,5}, a); }"]),
    ("Напиши функцию binarySearch, бинарный поиск.", "pub fn binarySearch(s: []const i32, v: i32) ?usize { var lo: usize = 0; var hi = s.len; while (lo < hi) { const mid = lo + (hi - lo) / 2; if (s[mid] == v) return mid; if (s[mid] < v) lo = mid + 1; else hi = mid; } return null; }", ["test \"binarySearch\" { const a = [_]i32{1,2,3,4,5}; try std.testing.expectEqual(@as(?usize,2), binarySearch(&a, 3)); }"]),
    ("Напиши функцию flatten, выравнивание вложенного среза.", "pub fn flatten(comptime T: type, nested: []const []const T, alloc: std.mem.Allocator) ![]T { var list = try std.ArrayList(T).initCapacity(alloc, 16); defer list.deinit(); for (nested) |inner| { try list.appendSlice(inner); } return try list.toOwnedSlice(); }", ["test \"flatten\" { const a = [_]i32{1,2}; const b = [_]i32{3,4,5}; const nested = [_][]const i32{&a,&b}; const r = try flatten(i32, &nested, std.testing.allocator); defer std.testing.allocator.free(r); try std.testing.expectEqual(@as(usize,5), r.len); }"]),
    ("Напиши функцию unique, удаление дубликатов.", "pub fn unique(s: []const i32, out: []i32) usize { if (s.len == 0) return 0; out[0] = s[0]; var j: usize = 1; for (s[1..]) |x| { if (x != out[j - 1]) { out[j] = x; j += 1; } } return j; }", ["test \"unique\" { const a = [_]i32{1,1,2,3,3,3,4}; var buf: [7]i32 = undefined; const n = unique(&a, &buf); try std.testing.expectEqual(@as(usize,4), n); }"]),
    ("Напиши функцию reverseCopy, копию перевёрнутого среза.", "pub fn reverseCopy(src: []const u8, dst: []u8) void { var i: usize = 0; var j = src.len; while (j > 0) { j -= 1; dst[i] = src[j]; i += 1; } }", ["test \"revCopy\" { const src = [_]u8{1,2,3}; var dst: [3]u8 = undefined; reverseCopy(&src, &dst); try std.testing.expectEqual([_]u8{3,2,1}, dst); }"]),
    ("Напиши функцию rotateLeft, циклический сдвиг влево.", "pub fn rotateLeft(s: []u32, k: usize) void { const n = s.len; if (n == 0) return; const shift = k % n; var i: usize = 0; while (i < shift) : (i += 1) { const first = s[0]; var j: usize = 0; while (j < n - 1) : (j += 1) { s[j] = s[j + 1]; } s[n - 1] = first; } }", ["test \"rotateLeft\" { var a = [_]u32{1,2,3,4,5}; rotateLeft(&a, 2); try std.testing.expectEqual([_]u32{3,4,5,1,2}, a); }"]),
    ("Напиши функцию cumulativeSum, накопленные суммы.", "pub fn cumulativeSum(s: []const i32, out: []i32) void { var acc: i32 = 0; for (s, 0..) |x, i| { acc += x; out[i] = acc; } }", ["test \"cumSum\" { const a = [_]i32{1,2,3,4}; var out: [4]i32 = undefined; cumulativeSum(&a, &out); try std.testing.expectEqual([_]i32{1,3,6,10}, out); }"]),
    ("Напиши функцию diff, разности соседних элементов.", "pub fn diff(s: []const i32, out: []i32) void { var i: usize = 0; while (i + 1 < s.len) : (i += 1) { out[i] = s[i + 1] - s[i]; } }", ["test \"diff\" { const a = [_]i32{1,3,6,10}; var out: [3]i32 = undefined; diff(&a, &out); try std.testing.expectEqual([_]i32{2,3,4}, out); }"]),
    ("Напиши функцию window, скользящее окно.", "pub fn window(s: []const i32, size: usize, out: []i32) usize { var j: usize = 0; var i: usize = 0; while (i + size <= s.len) : (i += 1) { var sum: i32 = 0; var k: usize = 0; while (k < size) : (k += 1) { sum += s[i + k]; } out[j] = sum; j += 1; } return j; }", ["test \"window\" { const a = [_]i32{1,2,3,4,5}; var out: [3]i32 = undefined; const n = window(&a, 3, &out); try std.testing.expectEqual(@as(usize,3), n); }"]),
    ("Напиши функцию partition, разделение по предикату.", "pub fn partition(s: []i32, pred: *const fn(i32)bool) usize { var i: usize = 0; var j = s.len; while (i < j) { if (pred(s[i])) { i += 1; } else { j -= 1; const t = s[i]; s[i] = s[j]; s[j] = t; } } return i; }", ["fn isNeg(x: i32) bool { return x < 0; } test \"partition\" { var a = [_]i32{3,-1,4,-2,5}; const p = partition(&a, &isNeg); try std.testing.expectEqual(@as(usize,2), p); }"]),
    ("Напиши функцию interleave, чередование элементов.", "pub fn interleave(a: []const i32, b: []const i32, out: []i32) usize { var j: usize = 0; var i: usize = 0; while (i < a.len and i < b.len) : (i += 1) { out[j] = a[i]; j += 1; out[j] = b[i]; j += 1; } while (i < a.len) : (i += 1) { out[j] = a[i]; j += 1; } while (i < b.len) : (i += 1) { out[j] = b[i]; j += 1; } return j; }", ["test \"interleave\" { const a = [_]i32{1,3}; const b = [_]i32{2,4}; var out: [4]i32 = undefined; const n = interleave(&a, &b, &out); try std.testing.expectEqual(@as(usize,4), n); }"]),
    ("Напиши функцию eql, сравнение строк.", "pub fn eql(a: []const u8, b: []const u8) bool { if (a.len != b.len) return false; for (a, b) |ca, cb| { if (ca != cb) return false; } return true; }", ["test \"eql\" { try std.testing.expect(eql(\"hello\",\"hello\")); try std.testing.expect(!eql(\"hello\",\"world\")); }"]),
    ("Напиши функцию toUpper, перевод в верхний регистр.", "pub fn toUpper(s: []const u8, out: []u8) void { for (s, 0..) |c, i| { out[i] = if (c >= \'a\' and c <= \'z\') c - 32 else c; } }", ["test \"toUpper\" { const s = \"hello\"; var out: [5]u8 = undefined; toUpper(s, &out); try std.testing.expectEqualStrings(\"HELLO\", &out); }"]),
    ("Напиши функцию toLower, перевод в нижний регистр.", "pub fn toLower(s: []const u8, out: []u8) void { for (s, 0..) |c, i| { out[i] = if (c >= \'A\' and c <= \'Z\') c + 32 else c; } }", ["test \"toLower\" { const s = \"HELLO\"; var out: [5]u8 = undefined; toLower(s, &out); try std.testing.expectEqualStrings(\"hello\", &out); }"]),
    ("Напиши функцию trimStart, удаление начальных пробелов.", "pub fn trimStart(s: []const u8) []const u8 { var i: usize = 0; while (i < s.len and (s[i] == \' \' or s[i] == \'\\t\')) : (i += 1) {} return s[i..]; }", ["test \"trimStart\" { try std.testing.expectEqualStrings(\"hello\", trimStart(\"  hello\")); }"]),
    ("Напиши функцию trimEnd, удаление конечных пробелов.", "pub fn trimEnd(s: []const u8) []const u8 { var end = s.len; while (end > 0 and (s[end - 1] == \' \' or s[end - 1] == \'\\t\')) : (end -= 1) {} return s[0..end]; }", ["test \"trimEnd\" { try std.testing.expectEqualStrings(\"hello\", trimEnd(\"hello  \")); }"]),
    ("Напиши функцию startsWith, проверку начала строки.", "pub fn startsWith(s: []const u8, prefix: []const u8) bool { if (prefix.len > s.len) return false; return eql(s[0..prefix.len], prefix); }", ["test \"startsWith\" { try std.testing.expect(startsWith(\"hello\",\"hel\")); try std.testing.expect(!startsWith(\"hello\",\"xyz\")); }"]),
    ("Напиши функцию endsWith, проверку конца строки.", "pub fn endsWith(s: []const u8, suffix: []const u8) bool { if (suffix.len > s.len) return false; return eql(s[s.len - suffix.len..], suffix); }", ["test \"endsWith\" { try std.testing.expect(endsWith(\"hello\",\"llo\")); try std.testing.expect(!endsWith(\"hello\",\"xyz\")); }"]),
    ("Напиши функцию repeat, повторение строки.", "pub fn repeat(s: []const u8, n: usize, alloc: std.mem.Allocator) ![]u8 { var result = try std.ArrayList(u8).initCapacity(alloc, s.len * n); defer result.deinit(); var i: usize = 0; while (i < n) : (i += 1) { try result.appendSlice(s); } return try result.toOwnedSlice(); }", ["test \"repeat\" { const r = try repeat(\"ab\", 3, std.testing.allocator); defer std.testing.allocator.free(r); try std.testing.expectEqualStrings(\"ababab\", r); }"]),
    ("Напиши функцию join, склейка строк.", "pub fn join(parts: []const []const u8, sep: []const u8, alloc: std.mem.Allocator) ![]u8 { var result = try std.ArrayList(u8).initCapacity(alloc, 64); defer result.deinit(); for (parts, 0..) |p, i| { if (i > 0) try result.appendSlice(sep); try result.appendSlice(p); } return try result.toOwnedSlice(); }", ["test \"join\" { const parts = [_][]const u8{\"a\",\"b\",\"c\"}; const r = try join(&parts, \", \", std.testing.allocator); defer std.testing.allocator.free(r); try std.testing.expectEqualStrings(\"a, b, c\", r); }"]),
    ("Напиши функцию replace, замена символа.", "pub fn replace(s: []const u8, from: u8, to: u8, out: []u8) void { for (s, 0..) |c, i| { out[i] = if (c == from) to else c; } }", ["test \"replace\" { const s = \"hello\"; var out: [5]u8 = undefined; replace(s, \'l\', \'x\', &out); try std.testing.expectEqualStrings(\"hexxo\", &out); }"]),
    ("Напиши функцию strip, удаление символа.", "pub fn strip(s: []const u8, c: u8, out: []u8) usize { var j: usize = 0; for (s) |ch| { if (ch != c) { out[j] = ch; j += 1; } } return j; }", ["test \"strip\" { const s = \"h_e_l_l_o\"; var out: [5]u8 = undefined; const n = strip(s, \'_\', &out); try std.testing.expectEqualStrings(\"hello\", out[0..n]); }"]),
    ("Напиши функцию countWords, подсчёт слов.", "pub fn countWords(s: []const u8) usize { var n: usize = 0; var inWord = false; for (s) |c| { if (c != \' \') { if (!inWord) n += 1; inWord = true; } else { inWord = false; } } return n; }", ["test \"countWords\" { try std.testing.expectEqual(@as(usize,3), countWords(\"hello world foo\")); try std.testing.expectEqual(@as(usize,0), countWords(\"\")); }"]),
    ("Напиши функцию isPalindrome, проверку палиндрома.", "pub fn isPalindrome(s: []const u8) bool { var i: usize = 0; var j = s.len; while (i < j) { j -= 1; if (s[i] != s[j]) return false; i += 1; } return true; }", ["test \"isPalindrome\" { try std.testing.expect(isPalindrome(\"racecar\")); try std.testing.expect(!isPalindrome(\"hello\")); }"]),
    ("Напиши функцию longestCommonPrefix, длиннейший общий префикс.", "pub fn longestCommonPrefix(a: []const u8, b: []const u8) usize { var i: usize = 0; while (i < a.len and i < b.len and a[i] == b[i]) : (i += 1) {} return i; }", ["test \"lcp\" { try std.testing.expectEqual(@as(usize,3), longestCommonPrefix(\"hello\",\"help\")); }"]),
    ("Напиши функцию unwrapOrDefault, извлечение значения или дефолт.", "pub fn unwrapOrDefault(opt: ?i32, default: i32) i32 { return opt orelse default; }", ["test \"unwrap\" { try std.testing.expectEqual(@as(i32,5), unwrapOrDefault(@as(?i32,5), 0)); try std.testing.expectEqual(@as(i32,0), unwrapOrDefault(null, 0)); }"]),
    ("Напиши функцию mapError, трансформация ошибки.", "pub fn mapError(val: anyerror!i32) i32 { return val catch -1; }", ["test \"mapError\" { try std.testing.expectEqual(@as(i32,5), mapError(@as(anyerror!i32, 5))); try std.testing.expectEqual(@as(i32,-1), mapError(error.Foo)); }"]),
    ("Напиши функцию safeDiv, деление с ошибкой.", "pub fn safeDiv(a: i32, b: i32) !i32 { if (b == 0) return error.DivisionByZero; return @divTrunc(a, b); }", ["test \"safeDiv\" { try std.testing.expectEqual(@as(i32,5), try safeDiv(10,2)); try std.testing.expectError(error.DivisionByZero, safeDiv(1,0)); }"]),
    ("Напиши функцию safeIndex, безопасный доступ по индексу.", "pub fn safeIndex(s: []const i32, idx: usize) !i32 { if (idx >= s.len) return error.OutOfBounds; return s[idx]; }", ["test \"safeIndex\" { const a = [_]i32{10,20,30}; try std.testing.expectEqual(@as(i32,20), try safeIndex(&a, 1)); try std.testing.expectError(error.OutOfBounds, safeIndex(&a, 5)); }"]),
    ("Напиши функцию setBit, установка бита.", "pub fn setBit(val: u32, pos: u5) u32 { return val | (@as(u32, 1) << pos); }", ["test \"setBit\" { try std.testing.expectEqual(@as(u32,5), setBit(4,0)); }"]),
    ("Напиши функцию clearBit, очистка бита.", "pub fn clearBit(val: u32, pos: u5) u32 { return val & ~(@as(u32, 1) << pos); }", ["test \"clearBit\" { try std.testing.expectEqual(@as(u32,4), clearBit(5,0)); }"]),
    ("Напиши функцию toggleBit, переключение бита.", "pub fn toggleBit(val: u32, pos: u5) u32 { return val ^ (@as(u32, 1) << pos); }", ["test \"toggleBit\" { try std.testing.expectEqual(@as(u32,5), toggleBit(4,0)); }"]),
    ("Напиши функцию getBit, чтение бита.", "pub fn getBit(val: u32, pos: u5) bool { return (val & (@as(u32, 1) << pos)) != 0; }", ["test \"getBit\" { try std.testing.expect(getBit(5,0)); try std.testing.expect(!getBit(5,1)); }"]),
    ("Напиши функцию popCount, подсчёт установленных бит.", "pub fn popCount(mut x: u32) u32 { var count: u32 = 0; while (x != 0) : (x &= x - 1) { count += 1; } return count; }", ["test \"popCount\" { try std.testing.expectEqual(@as(u32,2), popCount(5)); try std.testing.expectEqual(@as(u32,0), popCount(0)); }"]),
    ("Напиши функцию isPowerOf2, проверка степени двойки.", "pub fn isPowerOf2(x: u32) bool { return x != 0 and (x & (x - 1)) == 0; }", ["test \"isPowerOf2\" { try std.testing.expect(isPowerOf2(1)); try std.testing.expect(isPowerOf2(2)); try std.testing.expect(!isPowerOf2(3)); }"]),
    ("Напиши функцию nextPowerOf2, следующая степень двойки.", "pub fn nextPowerOf2(x: u32) u32 { if (x == 0) return 1; var v = x - 1; v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16; return v + 1; }", ["test \"np2\" { try std.testing.expectEqual(@as(u32,1), nextPowerOf2(0)); try std.testing.expectEqual(@as(u32,4), nextPowerOf2(3)); }"]),
    ("Напиши функцию log2Floor, целая часть логарифма.", "pub fn log2Floor(x: u32) u32 { if (x == 0) return 0; var result: u32 = 0; var v = x; while (v > 1) : (v >>= 1) { result += 1; } return result; }", ["test \"log2\" { try std.testing.expectEqual(@as(u32,0), log2Floor(1)); try std.testing.expectEqual(@as(u32,3), log2Floor(8)); }"]),
    ("Напиши функцию byteSwap, замена байтов.", "pub fn byteSwap(x: u32) u32 { return @byteSwap(x); }", ["test \"byteSwap\" { try std.testing.expectEqual(@as(u32,0x01020304), byteSwap(0x04030201)); }"]),
    ("Напиши функцию alignForward, выравнивание вперёд.", "pub fn alignForward(addr: usize, alignment: usize) usize { return (addr + alignment - 1) & ~(alignment - 1); }", ["test \"alignFwd\" { try std.testing.expectEqual(@as(usize,8), alignForward(5, 8)); }"]),
    ("Напиши функцию alignBackward, выравнивание назад.", "pub fn alignBackward(addr: usize, alignment: usize) usize { return addr & ~(alignment - 1); }", ["test \"alignBwd\" { try std.testing.expectEqual(@as(usize,8), alignBackward(9, 8)); }"]),
    ("Напиши функцию maxOfAny, максимум через anytype.", "pub fn maxOfAny(a: anytype, b: @TypeOf(a)) @TypeOf(a) { return if (a > b) a else b; }", ["test \"maxAny\" { try std.testing.expectEqual(@as(i32,5), maxOfAny(@as(i32,3), @as(i32,5))); }"]),
    ("Напиши функцию sizeOf, размер типа в байтах.", "pub fn sizeOf(comptime T: type) usize { return @sizeOf(T); }", ["test \"sizeOf\" { try std.testing.expectEqual(@as(usize,4), sizeOf(i32)); }"]),
]


def zig_test(code, timeout=8):
    with tempfile.NamedTemporaryFile(suffix=".zig", mode="w", delete=False, encoding="utf-8") as f:
        f.write(code); f.flush(); tmp = f.name
    try:
        r = subprocess.run(["zig", "test", tmp], capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0
    except: return False
    finally:
        try:
            os.unlink(tmp)
            for ext in [".o", ".pdb", ".exe"]:
                p = Path(tmp).with_suffix(ext)
                if p.exists(): p.unlink()
        except: pass


def make_id(kind, name):
    return hashlib.sha256(f"{kind}:{name}".encode()).hexdigest()[:16]


def main():
    print("COMBINED DATASET BUILDER")
    print("=" * 60)
    t0 = time.time()

    # 1. Generate and verify self-contained functions
    sc_examples = []
    verified = 0
    for i, (instruction, code, oracle_tests) in enumerate(FUNCTIONS):
        m = re.search(r'pub fn (\w+)', code)
        fn_name = m.group(1) if m else f"func_{i}"
        tests = "\n".join(oracle_tests)
        harness = f'const std = @import("std");\nconst testing = std.testing;\n\n{code}\n\n{tests}\n'

        ok = zig_test(harness)
        if ok:
            verified += 1
            sc_examples.extend([
                {"id": make_id("sw", fn_name), "type": "instruction_write", "instruction": instruction, "context": "", "output": code, "category": "code_write", "source_tag": "generated", "file": "", "symbol": fn_name, "evidence": "", "verified": True, "oracle": tests},
                {"id": make_id("sc", fn_name), "type": "instruction_complete", "instruction": f"Допиши реализацию {fn_name}:\n```zig\n{code.split(chr(10))[0]}\n```", "context": "", "output": code, "category": "code_complete", "source_tag": "generated", "file": "", "symbol": fn_name, "evidence": "", "verified": True, "oracle": tests},
                {"id": make_id("se", fn_name), "type": "instruction_explain", "instruction": f"Объясни функцию {fn_name}.", "context": "", "output": f"`{fn_name}`:\n```zig\n{code}\n```", "category": "code_explain", "source_tag": "generated", "file": "", "symbol": fn_name, "evidence": "", "verified": True},
                {"id": make_id("st", fn_name), "type": "instruction_test", "instruction": f"Напиши тест для {fn_name}.", "context": f"```zig\n{code}\n```", "output": tests, "category": "code_test", "source_tag": "generated", "file": "", "symbol": fn_name, "evidence": "", "verified": True},
            ])
    print(f"Self-contained: {verified}/{len(FUNCTIONS)} verified -> {len(sc_examples)} examples")

    # 2. Load spec-based B+ dataset
    spec_path = Path(r"C:\B-Plus\agent\agent b+\knowledge\dataset\instruction_train.jsonl")
    spec_examples = []
    if spec_path.exists():
        for line in open(spec_path, encoding="utf-8"):
            if line.strip():
                ex = json.loads(line)
                cat = ex.get("category", "")
                if cat in ("bplus_locate", "bplus_arch", "zig_syntax", "code_explain"):
                    spec_examples.append(ex)
    print(f"Spec-based B+ loaded: {len(spec_examples)}")

    # 3. Combine
    combined = sc_examples + spec_examples
    seen = set()
    deduped = []
    for ex in combined:
        key = ex.get("instruction", "")[:80]
        if key not in seen:
            seen.add(key)
            deduped.append(ex)

    # Split
    split_idx = int(len(deduped) * 0.8)
    train = deduped[:split_idx]
    val = deduped[split_idx:]

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, data in [("combined_train", train), ("combined_val", val)]:
        with open(OUT_DIR / f"{name}.jsonl", "w", encoding="utf-8") as f:
            for ex in data:
                f.write(json.dumps(ex, ensure_ascii=False) + "\n")

    elapsed = time.time() - t0
    cats = defaultdict(int)
    for ex in train: cats[ex.get("category", "?")] += 1
    v = sum(1 for ex in train if ex.get("verified"))
    print(f"\n{'='*60}")
    print(f"DONE in {elapsed:.0f}s")
    print(f"{'='*60}")
    for c, n in sorted(cats.items(), key=lambda x: -x[1]):
        print(f"  {c}: {n}")
    print(f"  Verified: {v}/{len(train)} ({v*100//max(1,len(train))}%)")
    print(f"  Train: {len(train)} | Val: {len(val)}")


if __name__ == "__main__":
    main()
