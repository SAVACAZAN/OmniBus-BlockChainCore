#pragma once
#include <map>
#include <set>
#include <string>

namespace omnibus::p2p {

class PeerReputation {
    std::map<std::string, int> scores_;
    std::set<std::string> banned_;
public:
    void record_good(const std::string& addr);
    void record_bad(const std::string& addr);
    bool is_banned(const std::string& addr) const;
    void ban(const std::string& addr);
    void save_bans() const;
    void load_bans();
};

} // namespace omnibus::p2p