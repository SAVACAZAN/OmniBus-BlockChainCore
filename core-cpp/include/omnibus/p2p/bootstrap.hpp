#pragma once
#include "../types.hpp"
#include <string>
#include <vector>
#include <map>

namespace omnibus::p2p {

struct PeerInfo {
    std::string address;
    u16 port;
    u32 last_seen;
};

class PeerManager {
    Network net_;
    std::vector<std::pair<std::string, u16>> seed_peers_;
    std::map<std::string, PeerInfo> known_peers_;
public:
    explicit PeerManager(Network net);
    void add_peer(const std::string& addr, u16 port);
    std::vector<std::pair<std::string, u16>> get_bootstrap_peers(size_t count = 10);
};

} // namespace omnibus::p2p