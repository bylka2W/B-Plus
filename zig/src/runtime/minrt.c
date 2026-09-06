#include <windows.h>

int _fltused = 1;

extern int main(void);

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

__declspec(dllexport) void print_f64(double val) {
    char buf[64];
    int len = 0;
    if (val < 0) {
        buf[len++] = '-';
        val = -val;
    }
    long long whole = (long long)val;
    double frac = val - (double)whole;
    char digits[20];
    int i = 0;
    if (whole == 0) {
        digits[i++] = '0';
    } else {
        long long tmp = whole;
        while (tmp > 0) {
            digits[i++] = (char)(tmp % 10) + '0';
            tmp /= 10;
        }
    }
    while (i > 0) {
        buf[len++] = digits[--i];
    }
    if (frac > 0.000001) {
        buf[len++] = '.';
        for (int d = 0; d < 6 && frac > 0.000001; d++) {
            frac *= 10.0;
            int digit = (int)frac;
            buf[len++] = (char)digit + '0';
            frac -= (double)digit;
        }
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

static int launched_by_bpc(void) {
    char buf[2];
    DWORD n = GetEnvironmentVariableA("BPC_RUN", buf, 2);
    return n > 0;
}

static void bplus_pause(void) {
    HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
    if (in == INVALID_HANDLE_VALUE || in == NULL) return;
    DWORD mode;
    if (!GetConsoleMode(in, &mode)) return;

    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD written;
    const char msg[] = "\nPress any key to continue...\n";
    if (out != INVALID_HANDLE_VALUE && out != NULL) {
        WriteFile(out, msg, (DWORD)(sizeof(msg) - 1), &written, NULL);
    }
    char ch;
    DWORD read;
    ReadFile(in, &ch, 1, &read, NULL);
}

__declspec(dllexport) void bplus_start(void) {
    int code = (int)main();
    if (!launched_by_bpc()) {
        bplus_pause();
    }
    ExitProcess((UINT)code);
}
