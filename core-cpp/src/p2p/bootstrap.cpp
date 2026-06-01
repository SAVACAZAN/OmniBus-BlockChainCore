#include "../../include/omnibus/p2p/bootstrap.hpp"
#include <random>
#include <spdlog/spdlog.h>

namespace omnibus::p2p {

PeerManager::PeerManager(Network net) : net_(net) {
    // Default seed peers (should be configurable)
    seed_peers_ = {
        {"seed1.omnibus.org", 9000},
        {"seed2.omnibus.org", 9000},
        {"seed3.omnibus.org", 9000}
    };
}

void PeerManager::add_peer(const std::string& addr, u16 port) {
    auto key = addr + ":" + std::to_string(port);
    if (known_peers_.find(key) == known_peers_.end()) {
        known_peers_[key] = {addr, port, 0};
        spdlog::debug("Added peer: {}", key);
    }
}

std::vector<std::pair<std::string, u16>> PeerManager::get_bootstrap_peers(size_t count) {
    std::vector<std::pair<std::string, u16>> result;
    
    // Add seeds first
    for (const auto& seed : seed_peers_) {
        result.push_back(seed);
        add_peer(seed.first, seed.second);
    }
    
    // Add some random known peers
    std::vector<PeerInfo> candidates;
    for (const auto& [key, info] : known_peers_) {
        candidates.push_back(info);
    }
    
    std::random_device rd;
    std::mt19937 g(rd());
    std::shuffle(candidates.begin(), candidates.end(), g);
    
    for (size_t i = 0; i < std::min(count, candidates.size()); ++i) {
        result.emplace_back(candidates[i].address, candidates[i].port);
    }
    
    // Anti-eclipse: ensure at least one /16 subnet diversity
    return result;
}

} // namespace omnibus::p2p