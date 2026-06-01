#include "../../include/omnibus/identity/salt.hpp"
#include <fstream>
#include <random>
#include <sys/stat.h>
#include <spdlog/spdlog.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

namespace omnibus::identity {

SaltFile::SaltFile(const std::string& path) : path_(path) {}

SaltFile::~SaltFile() {}

bool SaltFile::load_or_create() {
    std::ifstream file(path_, std::ios::binary);
    if (file.is_open()) {
        file.seekg(0, std::ios::end);
        size_t size = file.tellg();
        if (size == 32) {
            file.seekg(0, std::ios::beg);
            salt_.resize(32);
            file.read(reinterpret_cast<char*>(salt_.data()), 32);
            return true;
        }
    }
    
    create_salt();
    return true;
}

void SaltFile::create_salt() {
    std::random_device rd;
    std::mt19937_64 gen(rd());
    std::uniform_int_distribution<u64> dist;
    
    salt_.resize(32);
    for (size_t i = 0; i < 32; i += 8) {
        u64 val = dist(gen);
        std::memcpy(salt_.data() + i, &val, 8);
    }
    
    std::ofstream file(path_, std::ios::binary);
    if (file.is_open()) {
        file.write(reinterpret_cast<const char*>(salt_.data()), 32);
        set_permissions();
        spdlog::info("Created new salt file: {}", path_);
    } else {
        spdlog::error("Failed to create salt file: {}", path_);
    }
}

void SaltFile::set_permissions() const {
#ifndef _WIN32
    chmod(path_.c_str(), 0600);
#else
    // Windows: set file to read-only for current user only
    // Simplified for demo
#endif
}

void SaltFile::regenerate() {
    create_salt();
}

} // namespace omnibus::identity