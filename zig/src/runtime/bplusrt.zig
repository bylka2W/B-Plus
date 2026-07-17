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

