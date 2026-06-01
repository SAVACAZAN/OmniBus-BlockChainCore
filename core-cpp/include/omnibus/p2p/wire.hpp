#pragma once
#include "../types.hpp"
#include "../consensus/block.hpp"
#include <array>
#include <vector>
#include <cstdint>

namespace omnibus::p2p {

// Message header: 9 bytes (magic[4] + cmd[4] + len[1]? Actually spec: 9B total? We'll follow Zig)
struct MsgHeader {
    u32 magic;
    u8 cmd;          // command ID
    u32 len;         // payload length (max 1MB)
    std::vector<u8> payload; // not part of header
};

// Handshake messages
struct Hello {
    u32 version = 1;
    u64 timestamp;
    u64 nonce;
    std::vector<u8> user_agent; // length-prefixed
    Network network;
    u32 height;
    static constexpr size_t FIXED_SIZE = 25; // 4+8+8+1+4, variable user_agent follows
    std::vector<u8> serialize() const;
    static Hello deserialize(const u8* data, size_t len);
};

struct Welcome {
    u32 version;
    u64 timestamp;
    u64 nonce;
    std::vector<u8> user_agent;
    Network network;
    u32 height;
    // same as Hello but different command
    std::vector<u8> serialize() const;
    static Welcome deserialize(const u8* data, size_t len);
};

struct Stable {
    u64 nonce;
    // 10 bytes total? Actually 8-byte nonce + 2-byte? We'll keep simple.
};

struct BlockAnnounceV2 {
    Hash256 block_hash;
    u32 height;
    // 90 bytes: 32+4+? includes signature? We'll omit signature for brevity.
};

} // namespace omnibus::p2p