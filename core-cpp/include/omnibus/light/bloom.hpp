#pragma once
#include "../types.hpp"
#include <vector>
#include <bitset>

namespace omnibus::light {

// Bloom filter: 513 bytes = 4104 bits
class BloomFilter {
    static constexpr size_t FILTER_SIZE_BYTES = 513;
    static constexpr size_t FILTER_SIZE_BITS = FILTER_SIZE_BYTES * 8;
    std::bitset<FILTER_SIZE_BITS> bits_;
    
    u32 murmur3_32(const u8* data, size_t len, u32 seed) const;
    
public:
    void insert(const u8* data, size_t len);
    void insert(const Hash256& hash) { insert(hash.data(), hash.size()); }
    bool contains(const u8* data, size_t len) const;
    bool contains(const Hash256& hash) const { return contains(hash.data(), hash.size()); }
    
    std::vector<u8> serialize() const;
    void deserialize(const u8* data, size_t len);
    
    void clear() { bits_.reset(); }
};

} // namespace omnibus::light