#include <windows.h>
#include <stdio.h>

int main() {
    HMODULE h = LoadLibraryA("test_dll_exit.dll");
    if (!h) { printf("LoadLibrary failed: %lu\n", GetLastError()); return 1; }
    FARPROC p = GetProcAddress(h, "TSS_Init");
    if (!p) { printf("GetProcAddress failed: %lu\n", GetLastError()); FreeLibrary(h); return 1; }
    printf("calling TSS_Init (should exit with 42)...\n");
    ((void(*)())p)();
    printf("SURVIVED - ExitProcess did NOT execute!\n");
    FreeLibrary(h);
    return 0;
}
