// OEP-1 18/33 | path=include/omnibus/consensus/pow.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "block.hpp"
#include "../crypto/sha256.hpp"
#include <bit>
#include <cstring>

namespace omnibus::consensus {

// Convert compact bits to target (256-bit)
inline U256 bits_to_target(u32 bits) {
    u32 exponent = bits >> 24;
    u32 mantissa = bits & 0x007FFFFF;
    U256 target{};
    if (exponent <= 3) {
        // small target, just mantissa >> 8*(3-exponent)
        // simplified: for bitcoin-style
        u64 val = mantissa;
        val <<= 8 * (exponent - 3);
        std::memcpy(target.data() + 32 - 8, &val, 8);
    } else {
        target[32 - exponent] = mantissa >> 16;
        target[32 - exponent + 1] = (mantissa >> 8) & 0xFF;
        target[32 - exponent + 2] = mantissa & 0xFF;
    }
    return target;
}

// Check if hash meets target (hash <= target)
inline bool check_pow(const Hash256& hash, u32 bits) {
    U256 target = bits_to_target(bits);
    return std::memcmp(hash.data(), target.data(), 32) <= 0;
}

// Mine a block header (nonce search)
inline void mine_block(BlockHeader& header, u32 max_nonce = 0xFFFFFFFF) {
    u32 nonce = header.nonce;
    while (nonce <= max_nonce) {
        header.nonce = nonce;
        Hash256 h = header.hash();
        if (check_pow(h, header.bits)) {
            header.nonce = nonce;
            return;
        }
        nonce++;
    }
    // nonce wrap or fail
    header.nonce = 0xFFFFFFFF;
}

} // namespace omnibus::consensus