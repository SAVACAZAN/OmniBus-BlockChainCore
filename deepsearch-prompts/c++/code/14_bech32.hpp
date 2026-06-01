// OEP-1 10/33 | path=include/omnibus/crypto/bip32.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include <vector>
#include <string>
#include <optional>

namespace omnibus::crypto {

struct ExtendedKey {
    u8 depth;
    u32 fingerprint;
    u32 child_index;
    std::vector<u8> chain_code; // 32 bytes
    std::vector<u8> key;        // 33 bytes compressed pubkey or 32 bytes privkey
    bool is_private;
};

// BIP-39: mnemonic to seed
std::vector<u8> mnemonic_to_seed(const std::string& mnemonic, const std::string& passphrase = "");

// BIP-32: derive child key
ExtendedKey derive_ckd(const ExtendedKey& parent, u32 index);
ExtendedKey derive_path(const ExtendedKey& root, const std::string& path); // e.g., "m/44'/777'/0'/0/0"

// Master key from seed (BIP-32)
ExtendedKey master_key_from_seed(const std::vector<u8>& seed);

// Serialization (base58check)
std::string extended_key_to_base58(const ExtendedKey& key);
std::optional<ExtendedKey> extended_key_from_base58(const std::string& str);

} // namespace omnibus::crypto