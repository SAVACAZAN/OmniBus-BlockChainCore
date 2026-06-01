#pragma once
#include "../types.hpp"
#include <string>
#include <vector>
#include <map>

namespace omnibus::governance {

enum class ProposalState : u8 {
    PENDING = 0,
    ACTIVE = 1,
    PASSED = 2,
    REJECTED = 3,
    VETOED = 4,
    EXECUTED = 5
};

enum class VoteChoice : u8 {
    ABSTAIN = 0,
    YES = 1,
    NO = 2
};

struct Proposal {
    u64 proposal_id;
    std::string title;
    std::string description;
    std::vector<u8> actions; // serialized governance actions
    Hash160 proposer;
    u64 start_height;
    u64 end_height;
    u64 quorum; // minimum stake required
    u64 threshold; // percentage (basis points) needed to pass
    ProposalState state;
    
    std::map<Hash160, VoteChoice> votes;
    std::map<VoteChoice, u64> tally;
    
    void compute_tally();
    bool can_pass() const;
};

class Governance {
    std::map<u64, Proposal> proposals_;
    u64 next_id_ = 1;
    
public:
    u64 create_proposal(const Proposal& proposal);
    bool vote(u64 proposal_id, const Hash160& voter, VoteChoice choice, u64 stake);
    bool finalize_proposal(u64 proposal_id);
    bool execute_proposal(u64 proposal_id);
    std::optional<Proposal> get_proposal(u64 proposal_id) const;
};

} // namespace omnibus::governance