#pragma once
#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <variant>
#include <vector>

namespace omnibus {

// Primitive aliases matching Zig / Rust conventions.
using u8  = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using u64 = uint64_t;
using i8  = int8_t;
using i16 = int16_t;
using i32 = int32_t;
using i64 = int64_t;

// Fixed-width byte arrays.
using Hash256   = std::array<u8, 32>;
using U256      = std::array<u8, 32>;   // 256-bit big-endian integer
using Hash160   = std::array<u8, 20>;   // RIPEMD-160 output
using Address20 = std::array<u8, 20>;
using PubKey33 = std::array<u8, 33>;
using PubKey65 = std::array<u8, 65>;
using PrivKey32 = std::array<u8, 32>;
using Sig64    = std::array<u8, 64>;
using ChainCode32 = std::array<u8, 32>;

// Network enum (mainnet / testnet / devnet / regtest).
enum class Network : u8 {
    Mainnet = 0,
    Testnet = 1,
    Devnet  = 2,
    Regtest = 3,
};

// Post-quantum scheme IDs (matching Rust / Zig enums).
enum class PqScheme : u8 {
    MlDsa87   = 0,  // ML-DSA-87  (LOVE domain)
    Falcon512 = 1,  // Falcon-512 (FOOD domain)
    SlhDsa    = 2,  // SLH-DSA-256s (RENT domain)
    MlKem768  = 3,  // ML-KEM-768 (VACATION domain)
};

// Utility: hex encode / decode.
inline std::string to_hex(const u8* data, size_t len) {
    static const char* hex = "0123456789abcdef";
    std::string out;
    out.reserve(len * 2);
    for (size_t i = 0; i < len; ++i) {
        out += hex[(data[i] >> 4) & 0xf];
        out += hex[data[i] & 0xf];
    }
    return out;
}

template <size_t N>
inline std::string to_hex(const std::array<u8, N>& a) {
    return to_hex(a.data(), N);
}

inline std::vector<u8> from_hex(const std::string& s) {
    std::vector<u8> out;
    out.reserve(s.size() / 2);
    for (size_t i = 0; i + 1 < s.size(); i += 2) {
        auto hex_char = [](char c) -> u8 {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return 0;
        };
        out.push_back((hex_char(s[i]) << 4) | hex_char(s[i+1]));
    }
    return out;
}

} // namespace omnibus

// std::hash specializations so Hash256 / Hash160 / Address20 can be used in
// unordered_map / unordered_set without a custom comparator.
namespace std {
template <size_t N>
struct hash<std::array<uint8_t, N>> {
    size_t operator()(const std::array<uint8_t, N>& a) const noexcept {
        size_t seed = 0;
        for (auto b : a) {
            seed ^= static_cast<size_t>(b) + 0x9e3779b9 + (seed << 6) + (seed >> 2);
        }
        return seed;
    }
};
} // namespace std
