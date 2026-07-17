const std = @import("std");
const windows = std.os.windows;

// Minimal VE H test: register a VEH, then crash, see if we catch it
comptime {
    asm (
        \\.globl DllMainCRTStartup;
        \\.globl mainCRTStartup;
        \\.set mainCRTStartup, DllMainCRTStartup;
    );
}

export fn DllMainCRTStartup() callconv(.C) i32 {
    _ = windows.kernel32.AddVectoredExceptionHandler(0, handler);
    
    // Crash intentionally
    const ptr: *u32 = @ptrFromInt(@as(u64, 0));
    ptr.* = 42;
    
    return 0;
}

fn handler(info: *windows.EXCEPTION_POINTERS) callconv(.C) i32 {
    _ = info;
    return 0; // EXCEPTION_CONTINUE_SEARCH
}
