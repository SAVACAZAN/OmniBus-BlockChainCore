#pragma once
#include "../consensus/block.hpp"
#include "../codec.hpp"
#include <fstream>
#include <vector>
#include <optional>

namespace omnibus::storage {

// chain.dat v4 format: 8 sections, each with 4-byte size + CRC32-IEEE
class ChainDB {
    std::fstream file;
    std::string path;
    u32 version;
public:
    explicit ChainDB(const std::string& db_path);
    ~ChainDB();

    bool open(Network net, bool create = true);
    void close();

    // Write block (append)
    void write_block(const consensus::Block& block);
    // Read block at height
    std::optional<consensus::Block> read_block(u32 height);
    u32 tip_height() const;

    // CRC32-IEEE (matching Zig's crc32)
    static u32 crc32(const u8* data, size_t len);
};

} // namespace omnibus::storage