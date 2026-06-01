// OEP-1 36/150 | path=src/crypto/ripemd160.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/crypto/ripemd160.hpp"

#ifdef USE_OPENSSL
// OpenSSL implementation used
#else
// Manual implementation (public domain)
#include <cstring>
#include <algorithm>

namespace omnibus::crypto {

static const u32 K0 = 0x00000000;
static const u32 K1 = 0x5A827999;
static const u32 K2 = 0x6ED9EBA1;
static const u32 K3 = 0x8F1BBCDC;
static const u32 K4 = 0xA953FD4E;
static const u32 K5 = 0x50A28BE6;
static const u32 K6 = 0x5C4DD124;
static const u32 K7 = 0x6D703EF3;
static const u32 K8 = 0x7A6D76E9;
static const u32 K9 = 0x00000000;

static const int ROT[10] = {11, 14, 15, 12, 5, 8, 7, 9, 11, 13};

static inline u32 f1(u32 x, u32 y, u32 z) { return x ^ y ^ z; }
static inline u32 f2(u32 x, u32 y, u32 z) { return (x & y) | (~x & z); }
static inline u32 f3(u32 x, u32 y, u32 z) { return (x | ~y) ^ z; }
static inline u32 f4(u32 x, u32 y, u32 z) { return (x & z) | (y & ~z); }
static inline u32 f5(u32 x, u32 y, u32 z) { return x ^ (y | ~z); }

static inline u32 rol(u32 x, int n) { return (x << n) | (x >> (32 - n)); }

Hash160 ripemd160(const u8* data, size_t len) {
    u32 h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;
    
    size_t new_len = len + 1;
    while (new_len % 64 != 56) new_len++;
    new_len += 8;
    
    u8* padded = new u8[new_len];
    std::memcpy(padded, data, len);
    padded[len] = 0x80;
    std::memset(padded + len + 1, 0, new_len - len - 1 - 8);
    u64 bit_len = len * 8;
    for (int i = 0; i < 8; i++) {
        padded[new_len - 8 + i] = static_cast<u8>(bit_len >> (i * 8));
    }
    
    for (size_t i = 0; i < new_len; i += 64) {
        u32 w[16];
        for (int j = 0; j < 16; j++) {
            w[j] = static_cast<u32>(padded[i + j*4]) |
                   (static_cast<u32>(padded[i + j*4 + 1]) << 8) |
                   (static_cast<u32>(padded[i + j*4 + 2]) << 16) |
                   (static_cast<u32>(padded[i + j*4 + 3]) << 24);
        }
        
        u32 a1 = h0, b1 = h1, c1 = h2, d1 = h3, e1 = h4;
        u32 a2 = h0, b2 = h1, c2 = h2, d2 = h3, e2 = h4;
        
        for (int j = 0; j < 80; j++) {
            int idx;
            u32 f, k;
            if (j < 16) {
                idx = j;
                f = f1(b1, c1, d1);
                k = K0;
            } else if (j < 32) {
                idx = (j - 16) % 16;
                f = f2(b1, c1, d1);
                k = K1;
            } else if (j < 48) {
                idx = (j - 32) % 16;
                f = f3(b1, c1, d1);
                k = K2;
            } else if (j < 64) {
                idx = (j - 48) % 16;
                f = f4(b1, c1, d1);
                k = K3;
            } else {
                idx = (j - 64) % 16;
                f = f5(b1, c1, d1);
                k = K4;
            }
            
            u32 temp = rol(a1 + f + w[idx] + k, ROT[j % 10]) + e1;
            a1 = e1;
            e1 = d1;
            d1 = rol(c1, 10);
            c1 = b1;
            b1 = temp;
            
            // Parallel round
            if (j < 16) {
                idx = (j * 7 + 0) % 16;
                f = f5(b2, c2, d2);
                k = K5;
            } else if (j < 32) {
                idx = (j * 7 + 1) % 16;
                f = f4(b2, c2, d2);
                k = K6;
            } else if (j < 48) {
                idx = (j * 7 + 2) % 16;
                f = f3(b2, c2, d2);
                k = K7;
            } else if (j < 64) {
                idx = (j * 7 + 3) % 16;
                f = f2(b2, c2, d2);
                k = K8;
            } else {
                idx = (j * 7 + 4) % 16;
                f = f1(b2, c2, d2);
                k = K9;
            }
            
            temp = rol(a2 + f + w[idx] + k, ROT[(j + 4) % 10]) + e2;
            a2 = e2;
            e2 = d2;
            d2 = rol(c2, 10);
            c2 = b2;
            b2 = temp;
        }
        
        u32 t = h1 + c1 + d2;
        h1 = h2 + d1 + e2;
        h2 = h3 + e1 + a2;
        h3 = h4 + a1 + b2;
        h4 = h0 + b1 + c2;
        h0 = t;
    }
    
    delete[] padded;
    
    Hash160 result;
    for (int i = 0; i < 4; i++) result[i] = static_cast<u8>(h0 >> (i * 8));
    for (int i = 0; i < 4; i++) result[4 + i] = static_cast<u8>(h1 >> (i * 8));
    for (int i = 0; i < 4; i++) result[8 + i] = static_cast<u8>(h2 >> (i * 8));
    for (int i = 0; i < 4; i++) result[12 + i] = static_cast<u8>(h3 >> (i * 8));
    for (int i = 0; i < 4; i++) result[16 + i] = static_cast<u8>(h4 >> (i * 8));
    return result;
}

} // namespace omnibus::crypto
#endif