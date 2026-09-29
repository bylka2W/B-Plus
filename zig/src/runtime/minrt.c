                                             
                              
                                                                           
                                                                              
                                                                              
                                                                               
                                                                             

typedef unsigned long DWORD;
typedef void *HANDLE;
extern void __stdcall ExitProcess(unsigned int);
extern HANDLE __stdcall GetStdHandle(unsigned long);
extern DWORD __stdcall WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
extern int main(void);

#define MAXDIG 1100

static void s_mul2(char *s, int *len) {
    int carry = 0;
    for (int i = *len - 1; i >= 0; i--) {
        int d = (s[i] - '0') * 2 + carry;
        s[i] = (char)('0' + d % 10);
        carry = d / 10;
    }
    if (carry) {
        for (int i = *len; i > 0; i--) s[i] = s[i - 1];
        s[0] = (char)('0' + carry);
        *len += 1;
    }
}

static void s_mul5(char *s, int *len) {
    int carry = 0;
    for (int i = *len - 1; i >= 0; i--) {
        int d = (s[i] - '0') * 5 + carry;
        s[i] = (char)('0' + d % 10);
        carry = d / 10;
    }
    if (carry) {
        for (int i = *len; i > 0; i--) s[i] = s[i - 1];
        s[0] = (char)('0' + carry);
        *len += 1;
    }
}

static int s_div2(char *s, int *len) {
    int rem = 0;
    for (int i = 0; i < *len; i++) {
        int cur = rem * 10 + (s[i] - '0');
        s[i] = (char)('0' + cur / 2);
        rem = cur % 2;
    }
    while (*len > 1 && s[0] == '0') {
        for (int i = 0; i < *len - 1; i++) s[i] = s[i + 1];
        *len -= 1;
    }
    return rem;
}

static void s_set_u64(char *s, int *len, unsigned long long v) {
    char tmp[24];
    int n = 0;
    if (v == 0) { tmp[n++] = '0'; }
    while (v) { tmp[n++] = (char)('0' + v % 10); v /= 10; }
    for (int i = 0; i < n; i++) s[i] = tmp[n - 1 - i];
    *len = n;
}

void print_i64(long long val) {
    char buf[32]; int len = 0;
    int neg = val < 0;
    unsigned long long v = (unsigned long long)val;
    if (neg) v = 0ULL - v;
    char t[24]; int tl = 0;
    if (v == 0) t[tl++] = '0';
    while (v) { t[tl++] = (char)('0' + v % 10); v /= 10; }
    if (neg) buf[len++] = '-';
    for (int i = tl - 1; i >= 0; i--) buf[len++] = t[i];
    buf[len++] = '\n';
    HANDLE h = GetStdHandle((unsigned long)-11);
    if (h == (void*)-1 || h == 0) return;
    DWORD w; WriteFile(h, buf, (DWORD)len, &w, 0);
}

void print_str(long long ptr) {
    if (ptr == 0) return;
    const char *s = (const char *)(unsigned long long)ptr;
    int len = 0; while (s[len]) len++;
    if (len == 0) return;
    HANDLE h = GetStdHandle((unsigned long)-11);
    if (h == (void*)-1 || h == 0) return;
    DWORD w; WriteFile(h, s, (DWORD)len, &w, 0);
    char nl = '\n'; WriteFile(h, &nl, 1, &w, 0);
}

void bplus_exit(long long code) { ExitProcess((unsigned int)code); }

void puts(const char *s) {
    HANDLE h = (HANDLE)GetStdHandle(-11);
    DWORD w; int len = 0;
    while (s[len]) len++;
    WriteFile(h, s, (DWORD)len, &w, 0);
    char nl = '\n'; WriteFile(h, &nl, 1, &w, 0);
}

void *memcpy(void *d, const void *s, unsigned long long n) {
    char *dd = (char *)d; const char *ss = (const char *)s;
    for (unsigned long long i = 0; i < n; i++) dd[i] = ss[i];
    return d;
}

void *memmove(void *d, const void *s, unsigned long long n) {
    char *dd = (char *)d; const char *ss = (const char *)s;
    if (dd < ss) {
        for (unsigned long long i = 0; i < n; i++) dd[i] = ss[i];
    } else {
        for (unsigned long long i = n; i > 0; i--) dd[i - 1] = ss[i - 1];
    }
    return d;
}

void print_f64(double val) {
    char buf[64]; int L = 0;
    unsigned long long bits;
    {
        const unsigned char *p = (const unsigned char *)&val;
        unsigned long long b = 0;
        for (int i = 7; i >= 0; i--) b = (b << 8) | (unsigned long long)p[i];
        bits = b;
    }
    if (bits == 0) {
        buf[L++] = '0'; buf[L++] = '\n'; goto emit;
    }
    if ((bits >> 63) & 1ULL) buf[L++] = '-';
    int e = (int)((bits >> 52) & 0x7FF);
    unsigned long long m = bits & 0xFFFFFFFFFFFFFULL;
    if (e == 0x7FF) {
        if (m != 0) {
            if (L > 0 && buf[L - 1] == '-') L--;
            buf[L++] = 'N'; buf[L++] = 'a'; buf[L++] = 'N';
        } else {
            buf[L++] = 'I'; buf[L++] = 'n'; buf[L++] = 'f';
        }
        buf[L++] = '\n'; goto emit;
    }
    {
        unsigned long long mant;
        int k;
        if (e == 0) { mant = m; k = 1074; }
        else { mant = m | 0x10000000000000ULL; k = 1075 - e; }
        if (k <= 0) {
            char s[MAXDIG]; int sl = 0;
            s_set_u64(s, &sl, mant);
            for (int i = 0; i < -k; i++) s_mul2(s, &sl);
            for (int i = 0; i < sl; i++) buf[L++] = s[i];
        } else {
            char s[MAXDIG]; int sl = 0;
            s_set_u64(s, &sl, mant);
            for (int i = 0; i < k; i++) s_div2(s, &sl);
            if (sl == 1 && s[0] == '0') buf[L++] = '0';
            else for (int i = 0; i < sl; i++) buf[L++] = s[i];
            buf[L++] = '.';
            int start = L;
            int guard = k < 6 ? k : 6;
            for (int i = 1; i <= guard; i++) {
                char num[MAXDIG]; int nl = 0;
                s_set_u64(num, &nl, mant);
                for (int j = 0; j < i; j++) s_mul5(num, &nl);
                for (int j = 0; j < k - i; j++) s_div2(num, &nl);
                buf[L++] = num[nl - 1];
            }
            while (L > start && buf[L - 1] == '0') L--;
            if (L == start) L--;
        }
    }
    buf[L++] = '\n';
emit:
    {
        HANDLE h = GetStdHandle((unsigned long)-11);
        if (h == (void*)-1 || h == 0) return;
        DWORD w; WriteFile(h, buf, (DWORD)L, &w, 0);
    }
}

void bplus_start(void) {
    int code = main();
    ExitProcess((unsigned int)code);
}