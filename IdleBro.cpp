#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <sys/resource.h>
#include <unistd.h>

namespace {
volatile std::sig_atomic_t stopping = 0;
void stop(int) { stopping = 1; }
using Clock = std::chrono::steady_clock;
struct Config {
    int cpuLow = 15, cpuHigh = 25;
    int memoryLow = 32, memoryHigh = 96;
    int pauseAt = 5, resumeBelow = 2, idleSeconds = 5;
};
int integer(const std::string& value) {
    size_t end;
    int n = std::stoi(value, &end);
    if (value.find_first_not_of(" \t\r", end) != std::string::npos)
        throw std::runtime_error("Invalid integer: " + value);
    return n;
}
std::string trim(std::string s) {
    auto first = s.find_first_not_of(" \t\r");
    if (first == std::string::npos) return "";
    return s.substr(first, s.find_last_not_of(" \t\r") - first + 1);
}
Config readConfig(const std::string& path) {
    std::ifstream file(path);
    if (!file) throw std::runtime_error("Cannot open configuration: " + path);
    Config c;
    std::string line;
    while (std::getline(file, line)) {
        line = trim(line.substr(0, line.find('#')));
        if (line.empty()) continue;
        auto eq = line.find('=');
        if (eq == std::string::npos) throw std::runtime_error("Expected KEY=VALUE: " + line);
        auto key = trim(line.substr(0, eq));
        int n = integer(trim(line.substr(eq + 1)));
        if (key == "CPU_LOWER_LIMIT") c.cpuLow = n;
        else if (key == "CPU_UPPER_LIMIT") c.cpuHigh = n;
        else if (key == "MEMORY_LOWER_LIMIT") c.memoryLow = n;
        else if (key == "MEMORY_UPPER_LIMIT") c.memoryHigh = n;
        else if (key == "PAUSE_EXTERNAL_CPU") c.pauseAt = n;
        else if (key == "RESUME_EXTERNAL_CPU") c.resumeBelow = n;
        else if (key == "IDLE_SECONDS") c.idleSeconds = n;
        else if (key == "RANDOMNESS") throw std::runtime_error("RANDOMNESS was removed; see idlebro.conf");
        else throw std::runtime_error("Unknown configuration key: " + key);
    }
    if (c.cpuLow < 0 || c.cpuHigh > 100 || c.cpuLow > c.cpuHigh ||
        c.memoryLow < 0 || c.memoryHigh > 4096 || c.memoryLow > c.memoryHigh ||
        c.resumeBelow < 0 || c.pauseAt > 100 || c.resumeBelow >= c.pauseAt ||
        c.idleSeconds < 1 || c.idleSeconds > 3600)
        throw std::runtime_error("Configuration limits are invalid");
    return c;
}
struct ActivityGate {
    bool paused = true;
    Clock::time_point quietSince;
    explicit ActivityGate(Clock::time_point now) : quietSince(now) {}
    bool update(double external, const Config& c, Clock::time_point now) {
        if (external >= c.pauseAt) paused = true;
        if (external > c.resumeBelow) quietSince = now;
        if (paused && now - quietSince >= std::chrono::seconds(c.idleSeconds)) paused = false;
        return paused;
    }
};
struct Sample { uint64_t total = 0, busy = 0, self = 0; };
Sample sample() {
    Sample s;
    std::ifstream stat("/proc/stat");
    std::string label;
    uint64_t user, nice, system, idle, wait, irq, softirq, steal;
    if (!(stat >> label >> user >> nice >> system >> idle >> wait >> irq >> softirq >> steal))
        throw std::runtime_error("Cannot read /proc/stat");
    s.total = user + nice + system + idle + wait + irq + softirq + steal;
    s.busy = user + nice + system + irq + softirq + steal;
    std::ifstream self("/proc/self/stat");
    std::string line;
    std::getline(self, line);
    auto end = line.rfind(')');
    if (end == std::string::npos) throw std::runtime_error("Cannot read /proc/self/stat");
    std::istringstream fields(line.substr(end + 2));
    std::string value;
    for (int i = 0; i <= 12; ++i) {
        if (!(fields >> value)) throw std::runtime_error("Invalid /proc/self/stat");
        if (i == 11 || i == 12) s.self += std::stoull(value);
    }
    return s;
}
size_t availableMemory() {
    std::ifstream file("/proc/meminfo");
    std::string line;
    while (std::getline(file, line)) {
        std::istringstream fields(line);
        std::string key;
        size_t kb;
        if (fields >> key >> kb && key == "MemAvailable:") return kb * 1024;
    }
    return 0; // No reliable pressure information: do not allocate.
}
void worker(const std::atomic<double>& duty, const std::atomic<bool>& done) {
    // Small slices bound the delay when the controller requests a pause.
    volatile uint64_t state = 1;
    while (!done.load()) {
        auto start = Clock::now();
        auto until = start + std::chrono::microseconds(static_cast<int>(duty.load() * 100000));
        while (!done.load() && duty.load() > 0 && Clock::now() < until) {
            for (int i = 0; i < 256; ++i) state = state * 1664525 + 1013904223;
        }
        std::this_thread::sleep_until(start + std::chrono::milliseconds(100));
    }
}
}
int main(int argc, char** argv) {
    std::string path = "/etc/idlebro/idlebro.conf";
    bool check = false;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--config" && i + 1 < argc) path = argv[++i];
        else if (arg == "--check-config") check = true;
        else { std::cerr << "Usage: IdleBro [--config PATH] [--check-config]\n"; return 1; }
    }
    std::atomic<double> duty{0};
    std::atomic<bool> done{false};
    std::vector<std::thread> workers;
    int result = 0;
    try {
        Config c = readConfig(path);
        if (check) { std::cout << "Configuration OK\n"; return 0; }
        std::signal(SIGTERM, stop);
        std::signal(SIGINT, stop);
        if (setpriority(PRIO_PROCESS, 0, 19) != 0)
            throw std::runtime_error("Cannot set background scheduling priority");
        auto previous = sample();
        unsigned count = std::max(1u, std::thread::hardware_concurrency());
        for (unsigned i = 0; i < count; ++i) workers.emplace_back(worker, std::cref(duty), std::cref(done));
        std::mt19937 rng(std::random_device{}());
        std::uniform_int_distribution<int> cpu(c.cpuLow, c.cpuHigh), mem(c.memoryLow, c.memoryHigh);
        std::vector<unsigned char> memory;
        ActivityGate gate(Clock::now());
        auto nextTarget = Clock::now();
        double target = c.cpuLow;
        std::cout << "IdleBro started; CPU target " << c.cpuLow << '-' << c.cpuHigh << "%\n";
        while (!stopping) {
            std::this_thread::sleep_for(std::chrono::milliseconds(250));
            auto now = Clock::now();
            auto current = sample();
            double elapsed = current.total > previous.total ? current.total - previous.total : 0;
            double busy = current.busy >= previous.busy ? current.busy - previous.busy : 0;
            double own = current.self >= previous.self ? current.self - previous.self : 0;
            double external = elapsed > 0 ? 100 * std::max(0.0, busy - own) / elapsed : 100;
            previous = current;
            bool wasPaused = gate.paused;
            bool paused = gate.update(external, c, now);
            if (paused != wasPaused) {
                std::cout << (paused ? "Pausing for other processes\n" : "Resuming background load\n");
                if (!paused) nextTarget = now;
            }
            size_t available = availableMemory();
            constexpr size_t reserve = 512ull * 1024 * 1024;
            if (paused || available < reserve) {
                duty.store(0);
                std::vector<unsigned char>().swap(memory);
                continue;
            }
            if (now >= nextTarget) {
                target = cpu(rng);
                size_t bytes = static_cast<size_t>(mem(rng)) * 1024 * 1024;
                // Keep at least 512 MiB available; touch pages before holding them.
                bytes = std::min(bytes, (available - reserve) / 4);
                try { memory.assign(bytes, 1); }
                catch (const std::bad_alloc&) { std::vector<unsigned char>().swap(memory); }
                nextTarget = now + std::chrono::seconds(std::uniform_int_distribution<int>(5, 15)(rng));
            }
            double desired = std::clamp((target - external) / 100, 0.0, 1.0);
            // Feedback corrects loop overhead and scheduler delays.
            double measured = elapsed > 0 ? own / elapsed : 0;
            duty.store(std::clamp(duty.load() + 0.4 * (desired - measured), 0.0, 1.0));
        }
    } catch (const std::exception& e) {
        std::cerr << "IdleBro: " << e.what() << '\n';
        result = 1;
    }
    done.store(true);
    duty.store(0);
    for (auto& thread : workers) thread.join();
    return result;
}
