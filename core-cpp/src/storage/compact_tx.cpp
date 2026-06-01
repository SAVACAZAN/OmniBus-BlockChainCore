#include "../../include/omnibus/storage/compact_tx.hpp"
#include "../../include/omnibus/crypto/sha256.hpp"
#include <numeric>

namespace omnibus::storage {

std::vector<u8> CompactTransaction::serialize() const {
    std::vector<u8> out;
    codec::write_le(version, out);
    codec::write_le(locktime, out);
    codec::write_lp(inputs, out);
    codec::write_lp(outputs, out);
    return out;
}

CompactTransaction CompactTransaction::deserialize(const u8* data, size_t len) {
    CompactTransaction tx;
    const u8* ptr = data;
    size_t remaining = len;
    tx.version = codec::read_le<u32>(ptr, remaining);
    tx.locktime = codec::read_le<u32>(ptr, remaining);
    tx.inputs = codec::read_lp(ptr, remaining);
    tx.outputs = codec::read_lp(ptr, remaining);
    return tx;
}

Hash256 CompactTransaction::txid() const {
    auto serialized = serialize();
    return crypto::sha256d(serialized);
}

u64 CompactTransaction::total_output_value() const {
    // Simplified: parse outputs and sum amounts
    return 0;
}

} // namespace omnibus::storage