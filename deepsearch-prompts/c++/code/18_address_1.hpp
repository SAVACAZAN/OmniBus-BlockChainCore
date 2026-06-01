// OEP-1 14/33 | path=include/omnibus/consensus/params.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include <chrono>

namespace omnibus::consensus {

// Hard constants (from Zig core)
constexpr u64 BLOCK_REWARD_SAT = 8'333'333;
constexpr u64 HALVING_INTERVAL = 126'144'000;
constexpr u32 TARGET_BLOCK_TIME_SEC = 1;
constexpr u32 SUB_BLOCKS_PER_BLOCK = 10;
constexpr u32 SUB_BLOCK_INTERVAL_MS = 40;
constexpr u64 SAT_PER_OMNI = 1'000'000'000;
constexpr u64 MAX_SUPPLY_OMNI = 21'000'000;
constexpr u64 MAX_SUPPLY_SAT = MAX_SUPPLY_OMNI * SAT_PER_OMNI;
constexpr u32 DIFFICULTY_RETARGET_INTERVAL = 2016;
constexpr u32 MAX_BLOCK_SIZE_BYTES = 1'048'576;
constexpr u32 MAX_BLOCK_TX = 4096;
constexpr u32 COINBASE_MATURITY = 100;
constexpr u32 FEE_BURN_PERCENT = 50;
constexpr u32 DB_VERSION = 4;

// Network magic bytes (as 4-char strings)
inline u32 network_magic(Network net) {
    switch (net) {
        case Network::Mainnet: return 0x4F4D4E49; // 'OMNI'
        case Network::Testnet: return 0x54455354; // 'TEST'
        case Network::Devnet:  return 0x4445564E; // 'DEVN'
        case Network::Regtest: return 0x52454754; // 'REGT'
        default: return 0;
    }
}

// Difficulty retarget formula
inline u32 retarget_difficulty(u32 old_bits, u32 actual_timespan_sec) {
    u32 target_timespan = DIFFICULTY_RETARGET_INTERVAL * TARGET_BLOCK_TIME_SEC;
    u32 clamped = std::clamp(actual_timespan_sec, target_timespan / 4, target_timespan * 4);
    u64 new_target = (static_cast<u64>(old_bits) * clamped) / target_timespan;
    if (new_target > 0x1d00ffff) new_target = 0x1d00ffff;
    return static_cast<u32>(new_target);
}

} // namespace omnibus::consensus