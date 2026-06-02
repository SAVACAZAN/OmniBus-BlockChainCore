// OEP-1 4/33 | path=include/omnibus/codec.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "types.hpp"
#include <vector>
#include <cstring>
#include <bit>
#include <stdexcept>

namespace omnibus::codec {

// LEB128 varint (unsigned)
inline std::vector<u8> encode_varint(u64 value) {
    std::vector<u8> out;
    do {
        u8 byte = value & 0x7F;
        value >>= 7;
        if (value != 0) byte |= 0x80;
        out.push_back(byte);
    } while (value != 0);
    return out;
}

inline u64 decode_varint(const u8*& data, size_t& len) {
    u64 result = 0;
    int shift = 0;
    while (len > 0) {
        u8 byte = *data++;
        len--;
        result |= (u64(byte & 0x7F) << shift);
        shift += 7;
        if ((byte & 0x80) == 0) return result;
        if (shift >= 64) throw std::runtime_error("varint too long");
    }
    throw std::runtime_error("incomplete varint");
}

// Little‑endian fixed‑size integers
template<typename T> requires std::is_integral_v<T>
inline void write_le(T value, std::vector<u8>& out) {
    for (size_t i = 0; i < sizeof(T); ++i) {
        out.push_back(static_cast<u8>(value >> (i * 8)));
    }
}

template<typename T> requires std::is_integral_v<T>
inline T read_le(const u8*& data, size_t& len) {
    if (len < sizeof(T)) throw std::runtime_error("not enough data");
    T value = 0;
    for (size_t i = 0; i < sizeof(T); ++i) {
        value |= static_cast<T>(*data++) << (i * 8);
    }
    len -= sizeof(T);
    return value;
}

// Length‑prefixed: varint length + bytes
inline void write_lp(const std::vector<u8>& bytes, std::vector<u8>& out) {
    auto len_enc = encode_varint(bytes.size());
    out.insert(out.end(), len_enc.begin(), len_enc.end());
    out.insert(out.end(), bytes.begin(), bytes.end());
}

inline std::vector<u8> read_lp(const u8*& data, size_t& len) {
    u64 sz = decode_varint(data, len);
    if (len < sz) throw std::runtime_error("incomplete LP data");
    std::vector<u8> result(data, data + sz);
    data += sz;
    len -= sz;
    return result;
}

// Fixed‑length 4‑byte prefix (used in chain.dat sections)
inline void write_lp4(u32 value, std::vector<u8>& out) {
    write_le(value, out);
}

inline u32 read_lp4(const u8*& data, size_t& len) {
    return read_le<u32>(data, len);
}

} // namespace omnibus::codec