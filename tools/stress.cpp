#include <iostream>
#include <vector>
#include <thread>
#include <cmath>
#include <atomic>

std::atomic<bool> stop_flag(false);

void cpu_load_task() {
    double result = 0.0;
    while (!stop_flag.load()) {
        for (int i = 0; i < 1000000; ++i) {
            result += std::sin(i) * std::cos(i);
        }
    }
}

int main() {
    unsigned int num_threads = std::thread::hardware_concurrency();
    std::cout << "Нагружаем " << num_threads << " потоков(а)...\n";
    std::cout << "Нажмите Enter для остановки.";

    std::vector<std::thread> threads;
    for (unsigned int i = 0; i < num_threads; ++i) {
        threads.emplace_back(cpu_load_task);
    }

    std::cin.get();
    stop_flag = true;

    for (auto& t : threads) {
        t.join();
    }

    std::cout << "Программа завершена. Нагрузка снята.\n";
    return 0;
}
