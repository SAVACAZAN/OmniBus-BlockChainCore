#include "../../include/omnibus/crypto/bip32.hpp"
#include "../../include/omnibus/crypto/sha256.hpp"
#include "../../include/omnibus/crypto/ripemd160.hpp"
#include "../../include/omnibus/crypto/secp256k1.hpp"
#include "../../include/omnibus/codec.hpp"
#include <openssl/hmac.h>
#include <openssl/evp.h>
#include <algorithm>
#include <sstream>
#include <iomanip>
#include <cstring>

namespace omnibus::crypto {

std::vector<u8> mnemonic_to_seed(const std::string& mnemonic, const std::string& passphrase) {
    std::string salt = "mnemonic" + passphrase;
    std::vector<u8> seed(64);
    PKCS5_PBKDF2_HMAC(mnemonic.c_str(), mnemonic.size(),
                      reinterpret_cast<const u8*>(salt.c_str()), salt.size(),
                      2048, EVP_sha512(), 64, seed.data());
    return seed;
}

static std::vector<u8> hmac_sha512(const std::vector<u8>& key, const std::vector<u8>& data) {
    std::vector<u8> result(64);
    HMAC(EVP_sha512(), key.data(), key.size(), data.data(), data.size(), result.data(), nullptr);
    return result;
}

ExtendedKey master_key_from_seed(const std::vector<u8>& seed) {
    auto I = hmac_sha512(std::vector<u8>(64, 0), seed);
    ExtendedKey key;
    key.depth = 0;
    key.fingerprint = 0;
    key.child_index = 0;
    key.chain_code.assign(I.begin() + 32, I.end());
    key.key.assign(I.begin(), I.begin() + 32);
    key.is_private = true;
    return key;
}

static u32 derive_child_index(u32 index, bool hardened) {
    if (hardened) return 0x80000000 | index;
    return index;
}

ExtendedKey derive_ckd(const ExtendedKey& parent, u32 index) {
    if (!parent.is_private) {
        throw std::runtime_error("Public derivation not fully implemented");
    }
    
    std::vector<u8> data;
    if (index & 0x80000000) {
        data.push_back(0);
        data.insert(data.end(), parent.key.begin(), parent.key.end());
        codec::write_le(index, data);
    } else {
        auto pubkey = secp256k1.pubkey_compress(parent.key);
        data.insert(data.end(), pubkey.begin(), pubkey.end());
        codec::write_le(index, data);
    }
    
    auto I = hmac_sha512(parent.chain_code, data);
    ExtendedKey child;
    child.depth = parent.depth + 1;
    child.child_index = index;
    child.is_private = true;
    child.chain_code.assign(I.begin() + 32, I.end());
    
    // Private key: parent_key + I_left mod n
    std::vector<u8> child_key(32);
    for (int i = 0; i < 32; ++i) {
        int sum = parent.key[i] + I[i];
        child_key[i] = sum & 0xFF;
        // Simplified mod n (not full curve order handling)
    }
    child.key = child_key;
    
    // Compute fingerprint for child
    auto pubkey = secp256k1.pubkey_compress(child.key);
    auto hash160_pub = secp256k1.hash160_pubkey(pubkey);
    child.fingerprint = static_cast<u32>(hash160_pub[0]) |
                       (static_cast<u32>(hash160_pub[1]) << 8) |
                       (static_cast<u32>(hash160_pub[2]) << 16) |
                       (static_cast<u32>(hash160_pub[3]) << 24);
    
    return child;
}

ExtendedKey derive_path(const ExtendedKey& root, const std::string& path) {
    if (path.empty() || path[0] != 'm') return root;
    
    ExtendedKey key = root;
    std::stringstream ss(path.substr(2));
    std::string part;
    while (std::getline(ss, part, '/')) {
        if (part.empty()) continue;
        bool hardened = part.back() == '\'';
        if (hardened) part.pop_back();
        u32 index = std::stoul(part);
        if (hardened) index |= 0x80000000;
        key = derive_ckd(key, index);
    }
    return key;
}

} // namespace omnibus::crypto