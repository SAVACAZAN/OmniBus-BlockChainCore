// OEP-1 55/150 | path=src/p2p/scoring.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/p2p/scoring.hpp"
#include <fstream>
#include <spdlog/spdlog.h>

namespace omnibus::p2p {

void PeerReputation::record_good(const std::string& addr) {
    auto& score = scores_[addr];
    score = std::min(score + 10, 100);
}

void PeerReputation::record_bad(const std::string& addr) {
    auto& score = scores_[addr];
    score = std::max(score - 20, -100);
    if (score <= -50) {
        ban(addr);
    }
}

bool PeerReputation::is_banned(const std::string& addr) const {
    return banned_.find(addr) != banned_.end();
}

void PeerReputation::ban(const std::string& addr) {
    banned_.insert(addr);
    spdlog::warn("Banned peer: {}", addr);
    save_bans();
}

void PeerReputation::save_bans() const {
    std::ofstream file("bans.txt");
    for (const auto& addr : banned_) {
        file << addr << "\n";
    }
}

void PeerReputation::load_bans() {
    std::ifstream file("bans.txt");
    std::string addr;
    while (std::getline(file, addr)) {
        banned_.insert(addr);
    }
}

} // namespace omnibus::p2p