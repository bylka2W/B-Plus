#include <windows.h>
#include <stdio.h>

int main() {
    HMODULE h = LoadLibraryA("test_dll_body.dll");
    if (!h) { printf("LoadLibrary failed: %lu\n", GetLastError()); return 1; }
    FARPROC p = GetProcAddress(h, "TSS_Init");
    if (!p) { printf("GetProcAddress failed: %lu\n", GetLastError()); FreeLibrary(h); return 1; }
    printf("TSS_Init at %p, calling...\n", p);
    DWORD ret = ((DWORD(*)())p)();
    printf("TSS_Init returned: %lu\n", ret);
    FreeLibrary(h);
    return 0;
}
