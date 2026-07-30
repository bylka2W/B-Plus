#include <windows.h>

__declspec(dllexport) void print_i64(long long val) {
    char buf[32];
    int len = 0;
    long long tmp = val;
    if (tmp < 0) {
        buf[len++] = '-';
        tmp = -tmp;
    }
    char digits[20];
    int i = 0;
    if (tmp == 0) {
        digits[i++] = '0';
    } else {
        while (tmp > 0) {
            digits[i++] = (char)(tmp % 10) + '0';
            tmp /= 10;
        }
    }
    while (i > 0) {
        buf[len++] = digits[--i];
    }
    buf[len++] = '\n';

    HANDLE handle = GetStdHandle(STD_OUTPUT_HANDLE);
    if (handle == INVALID_HANDLE_VALUE || handle == NULL) return;
    DWORD written;
    WriteFile(handle, buf, len, &written, NULL);
}

__declspec(dllexport) void print_str(long long ptr) {
    if (ptr == 0) return;
    const char *s = (const char *)(size_t)ptr;
    int len = 0;
    while (s[len]) len++;
    if (len == 0) return;

    HANDLE handle = GetStdHandle(STD_OUTPUT_HANDLE);
    if (handle == INVALID_HANDLE_VALUE || handle == NULL) return;
    DWORD written;
    WriteFile(handle, s, len, &written, NULL);
    WriteFile(handle, "\n", 1, &written, NULL);
}

__declspec(dllexport) void bplus_exit(long long code) {
    ExitProcess((UINT)code);
}
