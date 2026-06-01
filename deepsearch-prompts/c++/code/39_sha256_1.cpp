// OEP-1 35/150 | path=src/crypto/keccak.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/crypto/keccak.hpp"
#include <cstring>
#include <algorithm>

namespace omnibus::crypto {

static const u64 ROUND_CONSTANTS[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL,
    0x8000000080008000ULL, 0x000000000000808bULL, 0x0000000080000001ULL,
    0x8000000080008081ULL, 0x8000000000008009ULL, 0x000000000000008aULL,
    0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
    0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL,
    0x8000000000008003ULL, 0x8000000000008002ULL, 0x8000000000000080ULL,
    0x000000000000800aULL, 0x800000008000000aULL, 0x8000000080008081ULL,
    0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL
};

static const int ROTATION_OFFSETS[5][5] = {
    {0, 36, 3, 41, 18},
    {1, 44, 10, 45, 2},
    {62, 6, 43, 15, 61},
    {28, 55, 25, 21, 56},
    {27, 20, 39, 8, 14}
};

void Keccak256::keccak_f() {
    u64 bc[5], t;
    for (int round = 0; round < 24; ++round) {
        // Theta
        for (int x = 0; x < 5; ++x) {
            bc[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20];
        }
        for (int x = 0; x < 5; ++x) {
            t = bc[(x + 4) % 5] ^ ((bc[(x + 1) % 5] << 1) | (bc[(x + 1) % 5] >> 63));
            for (int y = 0; y < 25; y += 5) {
                state[x + y] ^= t;
            }
        }
        
        // Rho and Pi
        u64 last = state[1];
        for (int x = 0; x < 5; ++x) {
            for (int y = 0; y < 5; ++y) {
                int curr_x = x, curr_y = y;
                for (int i = 0; i < (x + y * 5) % 7 + 1; ++i) {
                    int next_x = curr_y;
                    int next_y = (2 * curr_x + 3 * curr_y) % 5;
                    u64 temp = state[next_x + next_y * 5];
                    state[next_x + next_y * 5] = ((state[curr_x + curr_y * 5] << ROTATION_OFFSETS[curr_x][curr_y]) |
                                                  (state[curr_x + curr_y * 5] >> (64 - ROTATION_OFFSETS[curr_x][curr_y])));
                    curr_x = next_x;
                    curr_y = next_y;
                }
            }
        }
        
        // Chi
        for (int y = 0; y < 5; ++y) {
            for (int x = 0; x < 5; ++x) {
                bc[x] = state[x + y * 5];
            }
            for (int x = 0; x < 5; ++x) {
                state[x + y * 5] = bc[x] ^ ((~bc[(x + 1) % 5]) & bc[(x + 2) % 5]);
            }
        }
        
        // Iota
        state[0] ^= ROUND_CONSTANTS[round];
    }
}

Keccak256::Keccak256() {
    std::memset(state, 0, sizeof(state));
    std::memset(buffer, 0, sizeof(buffer));
    offset = 0;
}

void Keccak256::update(const u8* data, size_t len) {
    while (len > 0) {
        size_t take = std::min(len, rate - offset);
        std::memcpy(buffer + offset, data, take);
        offset += take;
        data += take;
        len -= take;
        
        if (offset == rate) {
            for (size_t i = 0; i < rate / 8; ++i) {
                u64 word = 0;
                for (size_t j = 0; j < 8; ++j) {
                    word |= static_cast<u64>(buffer[i * 8 + j]) << (j * 8);
                }
                state[i] ^= word;
            }
            keccak_f();
            offset = 0;
        }
    }
}

void Keccak256::finalize(u8* out) {
    buffer[offset] = 0x01;
    offset++;
    if (offset > rate - 1) {
        for (size_t i = 0; i < rate / 8; ++i) {
            u64 word = 0;
            for (size_t j = 0; j < 8; ++j) {
                word |= static_cast<u64>(buffer[i * 8 + j]) << (j * 8);
            }
            state[i] ^= word;
        }
        keccak_f();
        offset = 0;
        std::memset(buffer, 0, rate);
    }
    buffer[rate - 1] |= 0x80;
    
    for (size_t i = 0; i < rate / 8; ++i) {
        u64 word = 0;
        for (size_t j = 0; j < 8; ++j) {
            word |= static_cast<u64>(buffer[i * 8 + j]) << (j * 8);
        }
        state[i] ^= word;
    }
    keccak_f();
    
    for (size_t i = 0; i < 32; ++i) {
        size_t word_idx = i / 8;
        size_t byte_idx = i % 8;
        out[i] = static_cast<u8>((state[word_idx] >> (byte_idx * 8)) & 0xFF);
    }
}

Hash256 Keccak256::hash(const u8* data, size_t len) {
    Keccak256 hasher;
    hasher.update(data, len);
    Hash256 result;
    hasher.finalize(result.data());
    return result;
}

} // namespace omnibus::crypto