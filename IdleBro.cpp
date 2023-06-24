#include <iostream>
#include <fstream>
#include <sstream>
#include <unistd.h>
#include <signal.h>
#include <random>

#define CONFIG_FILE_PATH "/etc/idlebro/idlebro.conf"
#define PID_FILE_PATH "/var/run/idlebro.pid"

// Function to handle termination signals
void signalHandler(int signum) {
    if (signum == SIGTERM) {
        std::cout << "Termination signal received. Exiting." << std::endl;
        remove(PID_FILE_PATH);
        exit(0);
    }
}

int main() {
    // Set signal handler for termination signals
    signal(SIGTERM, signalHandler);

    // Create PID file
    std::ofstream pidFile(PID_FILE_PATH);
    if (!pidFile) {
        std::cerr << "Failed to create PID file." << std::endl;
        return 1;
    }
    pidFile << getpid() << std::endl;
    pidFile.close();

    // Read from configuration file
    std::ifstream configFile(CONFIG_FILE_PATH);
    if (!configFile) {
        std::cerr << "Failed to open configuration file." << std::endl;
        remove(PID_FILE_PATH);
        return 1;
    }

    // Read and parse the configuration
    std::string configLine;
    int cpuLowerLimit = 5;
    int cpuUpperLimit = 10;
    int memoryLowerLimit = 50;
    int memoryUpperLimit = 100;
    int randomness = 10;

    while (std::getline(configFile, configLine)) {
        std::istringstream iss(configLine);
        std::string key, value;
        if (std::getline(iss, key, '=') && std::getline(iss, value)) {
            if (key == "CPU_LOWER_LIMIT") {
                cpuLowerLimit = std::stoi(value);
            } else if (key == "CPU_UPPER_LIMIT") {
                cpuUpperLimit = std::stoi(value);
            } else if (key == "MEMORY_LOWER_LIMIT") {
                memoryLowerLimit = std::stoi(value);
            } else if (key == "MEMORY_UPPER_LIMIT") {
                memoryUpperLimit = std::stoi(value);
            } else if (key == "RANDOMNESS") {
                randomness = std::stoi(value);
            }
        }
    }
    configFile.close();

    // Seed random number generator
    std::random_device rd;
    std::mt19937 rng(rd());
    std::uniform_int_distribution<int> distCpu(cpuLowerLimit, cpuUpperLimit);
    std::uniform_int_distribution<int> distMemory(memoryLowerLimit, memoryUpperLimit);

    // Infinite loop consuming CPU and memory
	// Infinite loop consuming CPU and memory
	while (true) {
        // Generate random CPU and memory values within the specified range
        int cpuPercent = distCpu(rng);
        int memoryMB = distMemory(rng);

        // Calculate the number of iterations for CPU consumption
        int iterations = 10000000 * cpuPercent / 100;

        // Allocate memory for consumption
        int* memoryBuffer = new int[memoryMB * 1024 * 256]; // Each int is 4 bytes

        // Consume CPU
        for (int x = 0; x < randomness; ++x) {
            for (volatile int i = 0; i < iterations; ++i) {
                // Do nothing, just consume CPU
            }
            // Sleep for 1/X seconds
            usleep(1000000 / randomness);
        }

        // Consume memory
        for (int x = 0; x < memoryMB * 1024 * 256; ++x) {
            memoryBuffer[x] = x;
        }

        // Cleanup allocated memory
        delete[] memoryBuffer;
	}
    //all done
	return 0;
}

