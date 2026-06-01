#include "../../include/omnibus/storage/chain_db.hpp"
#include "../../include/omnibus/codec.hpp"
#include "../../include/omnibus/consensus/params.hpp"
#include <zlib.h> // for CRC32
#include <filesystem>
#include <stdexcept>

namespace omnibus::storage {

static u32 crc32_ieee(const u8* data, size_t len) {
    return static_cast<u32>(crc32(0L, data, len));
}

u32 ChainDB::crc32(const u8* data, size_t len) {
    return crc32_ieee(data, len);
}

ChainDB::ChainDB(const std::string& db_path) : path(db_path), version(consensus::DB_VERSION) {}

ChainDB::~ChainDB() { close(); }

bool ChainDB::open(Network net, bool create) {
    if (file.is_open()) return true;
    
    auto flags = std::ios::in | std::ios::out | std::ios::binary;
    if (create) flags |= std::ios::trunc;
    
    file.open(path, flags);
    if (!file.is_open() && create) {
        file.open(path, std::ios::out | std::ios::binary | std::ios::trunc);
        if (!file.is_open()) return false;
        file.close();
        file.open(path, flags);
    }
    
    return file.is_open();
}

void ChainDB::close() {
    if (file.is_open()) file.close();
}

void ChainDB::write_block(const consensus::Block& block) {
    if (!file.is_open()) throw std::runtime_error("DB not open");
    
    auto serialized = block.header.hash(); // Simplified: need full serialization
    u32 len = serialized.size();
    codec::write_le(len, const_cast<std::vector<u8>&>(reinterpret_cast<const std::vector<u8>&>(serialized)));
    file.write(reinterpret_cast<const char*>(serialized.data()), serialized.size());
    
    u32 checksum = crc32(serialized.data(), serialized.size());
    codec::write_le(checksum, const_cast<std::vector<u8>&>(reinterpret_cast<const std::vector<u8>&>(serialized)));
    file.write(reinterpret_cast<const char*>(&checksum), 4);
}

std::optional<consensus::Block> ChainDB::read_block(u32 height) {
    // Simplified: seek to position and read
    return std::nullopt; // Stub for demo
}

u32 ChainDB::tip_height() const {
    // Simplified: read last block
    return 0;
}

} // namespace omnibus::storage