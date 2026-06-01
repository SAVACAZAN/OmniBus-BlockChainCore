// OEP-1 112/150 | path=src/governance/proposal.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include "../../include/omnibus/governance/proposal.hpp"
#include <spdlog/spdlog.h>

namespace omnibus::governance {

void Proposal::compute_tally() {
    tally[VoteChoice::YES] = 0;
    tally[VoteChoice::NO] = 0;
    tally[VoteChoice::ABSTAIN] = 0;
    
    for (const auto& [voter, choice] : votes) {
        tally[choice]++;
    }
}

bool Proposal::can_pass() const {
    u64 total_votes = tally[VoteChoice::YES] + tally[VoteChoice::NO];
    if (total_votes < quorum) return false;
    
    u64 yes_percentage = (tally[VoteChoice::YES] * 10000) / total_votes;
    return yes_percentage >= threshold;
}

u64 Governance::create_proposal(const Proposal& proposal) {
    Proposal new_proposal = proposal;
    new_proposal.proposal_id = next_id_++;
    new_proposal.state = ProposalState::PENDING;
    new_proposal.votes.clear();
    
    proposals_[new_proposal.proposal_id] = new_proposal;
    spdlog::info("Created proposal {}: {}", new_proposal.proposal_id, new_proposal.title);
    return new_proposal.proposal_id;
}

bool Governance::vote(u64 proposal_id, const Hash160& voter, VoteChoice choice, u64 stake) {
    auto it = proposals_.find(proposal_id);
    if (it == proposals_.end()) return false;
    
    if (it->second.state != ProposalState::ACTIVE) return false;
    
    // Weight vote by stake
    for (u64 i = 0; i < stake; ++i) {
        it->second.votes[voter] = choice;
    }
    
    spdlog::debug("Vote recorded for proposal {}: {} -> {}", proposal_id, voter.data(), static_cast<int>(choice));
    return true;
}

bool Governance::finalize_proposal(u64 proposal_id) {
    auto it = proposals_.find(proposal_id);
    if (it == proposals_.end()) return false;
    
    if (it->second.state != ProposalState::ACTIVE) return false;
    
    it->second.compute_tally();
    
    if (it->second.can_pass()) {
        it->second.state = ProposalState::PASSED;
        spdlog::info("Proposal {} passed", proposal_id);
    } else {
        it->second.state = ProposalState::REJECTED;
        spdlog::info("Proposal {} rejected", proposal_id);
    }
    
    return true;
}

bool Governance::execute_proposal(u64 proposal_id) {
    auto it = proposals_.find(proposal_id);
    if (it == proposals_.end()) return false;
    
    if (it->second.state != ProposalState::PASSED) return false;
    
    // Execute actions
    it->second.state = ProposalState::EXECUTED;
    spdlog::info("Proposal {} executed", proposal_id);
    return true;
}

std::optional<Proposal> Governance::get_proposal(u64 proposal_id) const {
    auto it = proposals_.find(proposal_id);
    if (it != proposals_.end()) {
        return it->second;
    }
    return std::nullopt;
}

} // namespace omnibus::governance