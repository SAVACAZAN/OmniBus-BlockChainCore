#pragma once
#include "types.hpp"
#include <string>
#include <vector>
#include <map>

namespace omnibus {

struct DNSSeed {
    std::string domain;
    std::string ip;
    u16 port;
    u64 last_seen;
    u32 version;
};

struct DNSRecord {
    std::string name;
    std::string type; // "A", "AAAA", "TXT"
    std::string value;
    u32 ttl;
};

class DNSManager {
    std::map<std::string, DNSSeed> seeds_;
    std::map<std::string, std::vector<DNSRecord>> records_;
    
public:
    bool add_seed(const std::string& domain, const std::string& ip, u16 port);
    bool remove_seed(const std::string& domain);
    std::vector<DNSSeed> get_seeds() const;
    
    // DNS resolution for peer discovery
    std::vector<std::pair<std::string, u16>> resolve_seeds(const std::vector<std::string>& seed_domains);
    
    // Onion/DNS seed support
    static const std::vector<std::string> DEFAULT_SEEDS;
};

} // namespace omnibus