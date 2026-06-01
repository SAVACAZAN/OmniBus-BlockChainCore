#pragma once
#include "../types.hpp"
#include <cstddef>
#include <cstdint>

namespace omnibus::crypto {

// Simple Keccak-256 implementation (no external deps, for EVM)
class Keccak256 {
    static constexpr size_t ROUNDS = 24;
    static constexpr size_t STATE_SIZE = 200; // 1600 bits = 200 bytes
    u64 state[25] = {0};
    u8 buffer[144]; // 136 bytes for SHA3-256, but Keccak uses 1088 bit rate = 136 bytes
    size_t offset = 0;
    size_t rate = 136; // 1088 bits

    void keccak_f();
public:
    Keccak256();
    void update(const u8* data, size_t len);
    void finalize(u8* out);
    static Hash256 hash(const u8* data, size_t len);
};

inline Hash256 keccak256(const u8* data, size_t len) {
    return Keccak256::hash(data, len);
}

inline Hash256 keccak256(const std::vector<u8>& data) {
    return keccak256(data.data(), data.size());
}

} // namespace omnibus::crypto