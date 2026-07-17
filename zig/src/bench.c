#include <stdio.h>
#include <windows.h>

int main() {
    LARGE_INTEGER freq, start, end;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&start);
    
    // 100 миллионов пустых переходов (моделируем B+)
    for(volatile long long i = 0; i < 100000000; i++) {
        // ничего — просто счётчик
    }
    
    QueryPerformanceCounter(&end);
    double ns = (double)(end.QuadPart - start.QuadPart) * 1e9 / freq.QuadPart / 100000000;
    printf("C loop: %.2f ns/iter\n", ns);
    return 0;
}