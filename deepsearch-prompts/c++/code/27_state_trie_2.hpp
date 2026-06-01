// OEP-1 23/33 | path=include/omnibus/storage/compact_tx.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include "../codec.hpp"
#include <vector>

namespace omnibus::storage {

// 161-byte compact transaction format (from Zig)
struct CompactTransaction {
    u32 version = 1;
    u32 locktime = 0;
    std::vector<u8> inputs;   // varint count + inputs
    std::vector<u8> outputs;  // varint count + outputs

    std::vector<u8> serialize() const;
    static CompactTransaction deserialize(const u8* data, size_t len);
    Hash256 txid() const;
    u64 total_output_value() const;
};

} // namespace omnibus::storage