#include <cstdio>
#include <chrono>

int main() {
    int x, y;
    auto start = std::chrono::high_resolution_clock::now();
    for(int i = 0; i < 100'000'000; i++) {
        x = 42;
        y = 24;
    }
    auto end = std::chrono::high_resolution_clock::now();
    auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
    printf("C++: %lld ns total, %.2f ns/iter\n", ns, (double)ns / 100'000'000);
    return x + y;
}