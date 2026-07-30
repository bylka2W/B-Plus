const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5;

extern fn GetStdHandle(nStdHandle: u32) i64;
extern fn WriteFile(hFile: i64, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) i32;
extern fn ExitProcess(uExitCode: u32) void;

pub export fn print_i64(val: i64) void {
    @setRuntimeSafety(false);
    var buf: [32]u8 = undefined;
    var len: u32 = 0;
    var tmp: i64 = val;
    if (tmp < 0) {
        buf[0] = '-';
        len = 1;
        tmp = -tmp;
    }
    var i: u32 = 0;
    var digits: [20]u8 = undefined;
    if (tmp == 0) {
        digits[0] = '0';
        i = 1;
    } else {
        while (tmp > 0) {
            const d = @as(u8, @intCast(@rem(tmp, 10)));
            digits[i] = d + '0';
            i += 1;
            tmp = @divTrunc(tmp, 10);
        }
    }
    while (i > 0) {
        i -= 1;
        buf[len] = digits[i];
        len += 1;
    }
    buf[len] = '\n';
    len += 1;

    const handle = GetStdHandle(STD_OUTPUT_HANDLE);
    if (handle == -1 or handle == 0) return;
    var written: u32 = 0;
    _ = WriteFile(handle, &buf, len, &written, null);
}

pub export fn print_str(ptr: i64) void {
    @setRuntimeSafety(false);
    if (ptr == 0) return;
    const s: [*:0]u8 = @ptrFromInt(@as(usize, @intCast(ptr)));
    var len: u32 = 0;
    while (s[@as(usize, @intCast(len))] != 0) : (len += 1) {}
    if (len == 0) return;

    const handle = GetStdHandle(STD_OUTPUT_HANDLE);
    if (handle == -1 or handle == 0) return;
    var written: u32 = 0;
    _ = WriteFile(handle, @as([*]const u8, s), len, &written, null);
    const newline = [1]u8{'\n'};
    _ = WriteFile(handle, &newline, 1, &written, null);
}

pub export fn bplus_exit(code: i64) void {
    ExitProcess(@as(u32, @intCast(code)));
}
