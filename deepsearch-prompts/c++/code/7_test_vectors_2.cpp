
```cpp
// OEP-1 3/33 | path=include/omnibus/types.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include <array>
#include <cstdint>
#include <string>
#include <vector>
#include <optional>

namespace omnibus {

using u8  = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using u64 = uint64_t;
using i64 = int64_t;

using Hash256 = std::array<u8, 32>;
using Hash160 = std::array<u8, 20>;
using U256    = std::array<u8, 32>;   // big‑endian byte order for EVM
using U128    = std::array<u8, 16>;
using Sig64   = std::array<u8, 64>;   // compact signature (r,s)

enum class Network : u8 {
    Mainnet = 0,
    Testnet = 1,
    Devnet  = 2,
    Regtest = 3
};

struct CompactTransaction {
    u32 version;
    u32 locktime;
    std::vector<u8> inputs;   // varint + outpoint + scriptSig
    std::vector<u8> outputs;  // varint + amount + scriptPubKey
};

struct BlockHeader {
    u32 version;
    Hash256 prev_block;
    Hash256 merkle_root;
    u32 timestamp;
    u32 bits;          // compact target
    u32 nonce;
};

struct Block {
    BlockHeader header;
    std::vector<CompactTransaction> txs;
    Hash256 hash() const;  // double SHA256 of header
};

struct SubBlock {
    u32 index;          // 0..9 within block
    u64 timestamp_ms;
    Hash256 prev_hash;  // previous sub‑block hash or block hash
    Hash256 key_block_hash; // KeyBlock hash (if any)
    std::vector<CompactTransaction> txs;
};

struct KeyBlock : SubBlock {
    // identical layout to SubBlock, but contains validator set updates
};

} // namespace omnibus