#include "../include/omnibus/dns.hpp"
#include <spdlog/spdlog.h>
#include <random>

namespace omnibus {

const std::vector<std::string> DNSManager::DEFAULT_SEEDS = {
    "seed1.omnibus.org",
    "seed2.omnibus.org", 
    "seed3.omnibus.org",
    "seed.omnibus-testnet.org",
    "dnsseed.omnibus.org"
};

bool DNSManager::add_seed(const std::string& domain, const std::string& ip, u16 port) {
    DNSSeed seed;
    seed.domain = domain;
    seed.ip = ip;
    seed.port = port;
    seed.last_seen = std::time(nullptr);
    seed.version = 1;
    
    seeds_[domain] = seed;
    spdlog::info("Added DNS seed: {} -> {}:{}", domain, ip, port);
    return true;
}

bool DNSManager::remove_seed(const std::string& domain) {
    auto it = seeds_.find(domain);
    if (it != seeds_.end()) {
        seeds_.erase(it);
        spdlog::info("Removed DNS seed: {}", domain);
        return true;
    }
    return false;
}

std::vector<DNSSeed> DNSManager::get_seeds() const {
    std::vector<DNSSeed> result;
    for (const auto& [domain, seed] : seeds_) {
        result.push_back(seed);
    }
    return result;
}

std::vector<std::pair<std::string, u16>> DNSManager::resolve_seeds(const std::vector<std::string>& seed_domains) {
    std::vector<std::pair<std::string, u16>> results;
    
    for (const auto& domain : seed_domains) {
        // In production, would perform actual DNS lookup
        // For now, return default IPs
        if (domain.find("seed1") != std::string::npos) {
            results.emplace_back("34.120.45.210", 9000);
        } else if (domain.find("seed2") != std::string::npos) {
            results.emplace_back("34.120.46.211", 9000);
        } else if (domain.find("seed3") != std::string::npos) {
            results.emplace_back("34.120.47.212", 9000);
        } else {
            // Random IP for demo
            results.emplace_back("127.0.0.1", 9000);
        }
        
        spdlog::debug("Resolved seed {} -> {}:{}", domain, results.back().first, results.back().second);
    }
    
    // Shuffle results
    std::random_device rd;
    std::mt19937 g(rd());
    std::shuffle(results.begin(), results.end(), g);
    
    return results;
}

} // namespace omnibus