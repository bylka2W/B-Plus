const std = @import("std");
const windows = std.os.windows;

const kernel32 = windows.kernel32;

pub export fn print_i64(val: i64) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}\n", .{val}) catch "error";
    const handle = kernel32.GetStdHandle(windows.STD_OUTPUT_HANDLE) orelse return;
    var written: windows.DWORD = 0;
    _ = kernel32.WriteFile(handle, s.ptr, @intCast(s.len), &written, null);
}

pub export fn print_f64(val: f64) void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}\n", .{val}) catch "error";
    const handle = kernel32.GetStdHandle(windows.STD_OUTPUT_HANDLE) orelse return;
    var written: windows.DWORD = 0;
    _ = kernel32.WriteFile(handle, s.ptr, @intCast(s.len), &written, null);
}

pub export fn read_i64() i64 {
    var buf: [32]u8 = undefined;
    const handle = kernel32.GetStdHandle(windows.STD_INPUT_HANDLE) orelse return 0;
    var count: windows.DWORD = 0;
    if (kernel32.ReadFile(handle, &buf, @intCast(buf.len), &count, null) == 0) return 0;
    if (count > 0 and buf[count - 1] == '\n') count -= 1;
    if (count > 0 and buf[count - 1] == '\r') count -= 1;
    const trimmed = std.mem.trimRight(u8, buf[0..count], " \r\n");
    return std.fmt.parseInt(i64, trimmed, 10) catch 0;
}

pub export fn bplus_exit(code: i64) void {
    kernel32.ExitProcess(@intCast(code));
}

pub export fn bplus_malloc(size: i64) i64 {
    const heap = kernel32.GetProcessHeap() orelse return 0;
    const ptr = kernel32.HeapAlloc(heap, 0, @intCast(@as(usize, @intCast(size)))) orelse return 0;
    return @intCast(@intFromPtr(ptr));
}

pub export fn bplus_free(ptr: i64) void {
    const heap = kernel32.GetProcessHeap() orelse return;
    _ = kernel32.HeapFree(heap, 0, @ptrFromInt(@as(usize, @intCast(ptr))));
}

pub export fn bpc_read_line(buf_ptr: i64, buf_size: i64) i64 {
    const buf = @as([*]u8, @ptrFromInt(@as(usize, @intCast(buf_ptr))));
    const handle = kernel32.GetStdHandle(windows.STD_INPUT_HANDLE) orelse return 0;
    var count: windows.DWORD = 0;
    const max_read: u32 = @intCast(@min(@as(u64, @intCast(buf_size)), 256));
    if (kernel32.ReadFile(handle, buf, max_read, &count, null) == 0) return 0;
    if (count > 0 and buf[count - 1] == '\n') count -= 1;
    if (count > 0 and buf[count - 1] == '\r') count -= 1;
    buf[count] = 0;
    return @intCast(count);
}

pub export fn bpc_str_equal(a_ptr: i64, b_ptr: i64) i64 {
    const a = @as([*:0]const u8, @ptrFromInt(@as(usize, @intCast(a_ptr))));
    const b = @as([*:0]const u8, @ptrFromInt(@as(usize, @intCast(b_ptr))));
    var i: usize = 0;
    while (a[i] != 0 and b[i] != 0) : (i += 1) {
        if (a[i] != b[i]) return 0;
    }
    return if (a[i] == 0 and b[i] == 0) 1 else 0;
}

pub export fn print_str(ptr: i64) void {
    const s = @as([*:0]const u8, @ptrFromInt(@as(usize, @intCast(ptr))));
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    const handle = kernel32.GetStdHandle(windows.STD_OUTPUT_HANDLE) orelse return;
    var written: windows.DWORD = 0;
    _ = kernel32.WriteFile(handle, s, @intCast(len), &written, null);
}

