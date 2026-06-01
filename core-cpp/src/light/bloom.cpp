#include "../../include/omnibus/light/bloom.hpp"
#include <cstring>

namespace omnibus::light {

static const u32 MURMUR_SEED = 0xbc9f1d34;

u32 BloomFilter::murmur3_32(const u8* data, size_t len, u32 seed) const {
    u32 h = seed;
    const u32 c1 = 0xcc9e2d51;
    const u32 c2 = 0x1b873593;
    
    size_t nblocks = len / 4;
    for (size_t i = 0; i < nblocks; ++i) {
        u32 k = static_cast<u32>(data[i*4]) |
               (static_cast<u32>(data[i*4+1]) << 8) |
               (static_cast<u32>(data[i*4+2]) << 16) |
               (static_cast<u32>(data[i*4+3]) << 24);
        
        k *= c1;
        k = (k << 15) | (k >> 17);
        k *= c2;
        
        h ^= k;
        h = (h << 13) | (h >> 19);
        h = h * 5 + 0xe6546b64;
    }
    
    size_t remaining = len % 4;
    if (remaining > 0) {
        u32 k = 0;
        for (size_t i = 0; i < remaining; ++i) {
            k |= static_cast<u32>(data[nblocks*4 + i]) << (i * 8);
        }
        k *= c1;
        k = (k << 15) | (k >> 17);
        k *= c2;
        h ^= k;
    }
    
    h ^= static_cast<u32>(len);
    h ^= h >> 16;
    h *= 0x85ebca6b;
    h ^= h >> 13;
    h *= 0xc2b2ae35;
    h ^= h >> 16;
    
    return h;
}

void BloomFilter::insert(const u8* data, size_t len) {
    for (u32 i = 0; i < 3; ++i) { // 3 hash functions
        u32 hash = murmur3_32(data, len, MURMUR_SEED + i);
        size_t bit = hash % FILTER_SIZE_BITS;
        bits_.set(bit);
    }
}

bool BloomFilter::contains(const u8* data, size_t len) const {
    for (u32 i = 0; i < 3; ++i) {
        u32 hash = murmur3_32(data, len, MURMUR_SEED + i);
        size_t bit = hash % FILTER_SIZE_BITS;
        if (!bits_.test(bit)) return false;
    }
    return true;
}

std::vector<u8> BloomFilter::serialize() const {
    std::vector<u8> result(FILTER_SIZE_BYTES);
    for (size_t i = 0; i < FILTER_SIZE_BITS; ++i) {
        if (bits_.test(i)) {
            result[i / 8] |= (1 << (i % 8));
        }
    }
    return result;
}

void BloomFilter::deserialize(const u8* data, size_t len) {
    if (len != FILTER_SIZE_BYTES) return;
    bits_.reset();
    for (size_t i = 0; i < FILTER_SIZE_BITS; ++i) {
        if (data[i / 8] & (1 << (i % 8))) {
            bits_.set(i);
        }
    }
}

} // namespace omnibus::light