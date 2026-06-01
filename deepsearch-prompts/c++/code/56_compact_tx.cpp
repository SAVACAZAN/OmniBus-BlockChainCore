// OEP-1 52/150 | path=src/p2p/wire.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/p2p/wire.hpp"
#include "../../include/omnibus/codec.hpp"
#include <cstring>

namespace omnibus::p2p {

std::vector<u8> Hello::serialize() const {
    std::vector<u8> out;
    codec::write_le(version, out);
    codec::write_le(timestamp, out);
    codec::write_le(nonce, out);
    codec::write_lp(user_agent, out);
    out.push_back(static_cast<u8>(network));
    codec::write_le(height, out);
    return out;
}

Hello Hello::deserialize(const u8* data, size_t len) {
    Hello hello;
    const u8* ptr = data;
    size_t remaining = len;
    hello.version = codec::read_le<u32>(ptr, remaining);
    hello.timestamp = codec::read_le<u64>(ptr, remaining);
    hello.nonce = codec::read_le<u64>(ptr, remaining);
    hello.user_agent = codec::read_lp(ptr, remaining);
    hello.network = static_cast<Network>(*ptr++); remaining--;
    hello.height = codec::read_le<u32>(ptr, remaining);
    return hello;
}

} // namespace omnibus::p2p