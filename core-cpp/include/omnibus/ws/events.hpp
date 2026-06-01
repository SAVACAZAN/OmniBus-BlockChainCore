#pragma once
#include <cstdint>
#include <string>

namespace omnibus::ws {

// 17 event types as bitmask (for subscription)
enum class EventType : uint16_t {
    NEW_BLOCK = 1 << 0,
    NEW_TRANSACTION = 1 << 1,
    DEX_FILL = 1 << 2,
    DEX_ORDER_BOOK_UPDATE = 1 << 3,
    VALIDATOR_SET_UPDATE = 1 << 4,
    GOVERNANCE_PROPOSAL = 1 << 5,
    GOVERNANCE_VOTE = 1 << 6,
    STAKING_REWARD = 1 << 7,
    IDENTITY_DID_REGISTER = 1 << 8,
    IDENTITY_KYC_VERIFIED = 1 << 9,
    TOKEN_TRANSFER = 1 << 10,
    TOKEN_MINT = 1 << 11,
    TOKEN_BURN = 1 << 12,
    CONTRACT_EVENT = 1 << 13,
    PEER_CONNECT = 1 << 14,
    PEER_DISCONNECT = 1 << 15,
    SYSTEM_STATUS = 1 << 16
};

// Bitmask for subscription (all 17 bits)
using EventMask = uint32_t;

inline constexpr EventMask ALL_EVENTS = 0x1FFFF;

struct Event {
    EventType type;
    uint64_t timestamp;
    std::string data;
    std::string topic; // optional topic for filtering
};

} // namespace omnibus::ws