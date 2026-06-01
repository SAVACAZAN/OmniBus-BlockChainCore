#pragma once
#include "../crypto/bip32.hpp"
#include "../types.hpp"
#include <string>

namespace omnibus::wallet {

using namespace crypto;

// BIP-44 coin types
constexpr u32 OMNI_COIN_TYPE = 777;
constexpr u32 EVM_COIN_TYPE  = 60;

// Derive native Omni address (bech32 ob1...)
std::string omni_address(const ExtendedKey& master, u32 account = 0, u32 change = 0, u32 index = 0);
// Derive EVM address (EIP-55)
std::string evm_address(const ExtendedKey& master, u32 account = 0, u32 change = 0, u32 index = 0);
// Derive PQ address (soulbound vs transferable) with prefixes
std::string pq_address(const ExtendedKey& master, PqScheme scheme, u32 index, bool soulbound = true);

} // namespace omnibus::wallet