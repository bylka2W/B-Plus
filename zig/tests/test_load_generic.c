#include <windows.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 2) { printf("Usage: %s <dllname>\n", argv[0]); return 1; }
    HMODULE h = LoadLibraryA(argv[1]);
    if (!h) { printf("LoadLibrary failed: %lu\n", GetLastError()); return 1; }
    FARPROC p = GetProcAddress(h, "TSS_Init");
    if (!p) { printf("GetProcAddress failed: %lu\n", GetLastError()); FreeLibrary(h); return 1; }
    printf("calling TSS_Init from %s...\n", argv[1]);
    DWORD ret = ((DWORD(*)())p)();
    printf("TSS_Init returned: %lu\n", ret);
    FreeLibrary(h);
    return 0;
}
