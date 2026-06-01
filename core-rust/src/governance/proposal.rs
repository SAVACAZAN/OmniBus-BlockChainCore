//! Proposal lifecycle — deposit → voting → tally → execute.
//!
//! Mirrors `core/governance.zig::GovernanceEngine`. Constants and
//! threshold math are kept byte-identical so a proposal that passes on
//! the Zig node also passes on the Rust node.

use super::voting::Vote;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ProposalType {
    /// Numeric parameter change (fee_burn_pct, ubi_rate, …).
    ParamChange = 1,
    /// Protocol upgrade (consensus, new feature flag).
    ProtocolUpgrade = 2,
    /// Emergency (freeze address, pause bridge).
    Emergency = 3,
    /// Non-binding signaling/discussion.
    TextSignal = 4,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ProposalStatus {
    DepositPeriod = 0,
    VotingActive = 1,
    Approved = 2,
    Rejected = 3,
    /// Quorum not reached in time.
    Expired = 4,
    /// Change has been applied to the live params.
    Executed = 5,
}

/// Governance parameters — themselves governed by governance (meta).
#[derive(Debug, Clone, Copy)]
pub struct GovernanceParams {
    /// Deposit window length in blocks (~1.17 d at 1 block/s).
    pub deposit_period_blocks: u64,
    /// Voting window length in blocks (~7 d at 1 block/s).
    pub voting_period_blocks: u64,
    /// Minimum deposit to create a proposal (SAT). 100 OMNI default.
    pub min_deposit_sat: u64,
    /// Quorum: min % of total voting power that must vote.
    pub quorum_pct: u8,
    /// Threshold: min % of non-abstain ballots that must be Yes.
    pub threshold_pct: u8,
    /// Veto threshold: if NoWithVeto / non_abstain >= veto_pct → Rejected.
    pub veto_pct: u8,
    /// Fee burn percentage (0-100), itself governed.
    pub fee_burn_pct: u8,
}

impl Default for GovernanceParams {
    fn default() -> Self {
        Self {
            deposit_period_blocks: 100_800,
            voting_period_blocks: 604_800,
            min_deposit_sat: 100_000_000_000,
            quorum_pct: 33,
            threshold_pct: 50,
            veto_pct: 33,
            fee_burn_pct: 0,
        }
    }
}

pub const MAX_PROPOSALS: usize = 256;
pub const MAX_TITLE_LEN: usize = 64;
pub const MAX_DESC_LEN: usize = 256;

#[derive(Debug, Clone)]
pub struct Proposal {
    pub id: u64,
    pub proposer: [u8; 32],
    pub proposal_type: ProposalType,
    pub title: String,
    pub description: String,
    /// Param being changed (for ParamChange).
    pub param_name: String,
    pub param_new_value: u64,
    pub deposit_sat: u64,
    pub created_block: u64,
    pub voting_start_block: u64,
    pub voting_end_block: u64,
    pub status: ProposalStatus,
    pub votes_yes: u64,
    pub votes_no: u64,
    pub votes_abstain: u64,
    pub votes_veto: u64,
    pub total_voted_power: u64,
}

impl Proposal {
    pub fn is_voting_active(&self, current_block: u64) -> bool {
        self.status == ProposalStatus::VotingActive
            && current_block >= self.voting_start_block
            && current_block <= self.voting_end_block
    }

    /// Tally the proposal against `total_voting_power` and the params.
    /// Returns the resulting status (Approved / Rejected / Expired).
    pub fn tally_result(
        &self,
        total_voting_power: u64,
        params: &GovernanceParams,
    ) -> ProposalStatus {
        if total_voting_power == 0 {
            return ProposalStatus::Expired;
        }
        let quorum_needed = total_voting_power * params.quorum_pct as u64 / 100;
        if self.total_voted_power < quorum_needed {
            return ProposalStatus::Expired;
        }

        let non_abstain = self.votes_yes + self.votes_no + self.votes_veto;
        if non_abstain == 0 {
            return ProposalStatus::Expired;
        }

        if self.votes_veto * 100 / non_abstain >= params.veto_pct as u64 {
            return ProposalStatus::Rejected;
        }

        if self.votes_yes * 100 / non_abstain > params.threshold_pct as u64 {
            ProposalStatus::Approved
        } else {
            ProposalStatus::Rejected
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum GovError {
    #[error("too many proposals")]
    TooManyProposals,
    #[error("insufficient deposit")]
    InsufficientDeposit,
    #[error("proposal not found")]
    ProposalNotFound,
    #[error("voting not active")]
    VotingNotActive,
    #[error("no voting power")]
    NoVotingPower,
    #[error("voting not ended")]
    VotingNotEnded,
    #[error("already executed")]
    AlreadyExecuted,
    #[error("not approved")]
    NotApproved,
}

/// In-memory governance engine. Persistence is left to the caller —
/// `Proposal` is `Clone` so it can be serialized into sled at each
/// state-change boundary.
#[derive(Debug, Clone)]
pub struct GovernanceEngine {
    pub params: GovernanceParams,
    pub next_proposal_id: u64,
    pub proposals: Vec<Proposal>,
}

impl GovernanceEngine {
    pub fn new(params: GovernanceParams) -> Self {
        Self {
            params,
            next_proposal_id: 1,
            proposals: Vec::with_capacity(MAX_PROPOSALS),
        }
    }

    /// Create a new proposal. The deposit must clear `min_deposit_sat`
    /// (the caller is responsible for actually locking the funds — the
    /// engine just records the amount).
    #[allow(clippy::too_many_arguments)]
    pub fn create_proposal(
        &mut self,
        proposer: [u8; 32],
        ptype: ProposalType,
        title: &str,
        description: &str,
        deposit_sat: u64,
        current_block: u64,
    ) -> Result<u64, GovError> {
        if self.proposals.len() >= MAX_PROPOSALS {
            return Err(GovError::TooManyProposals);
        }
        if deposit_sat < self.params.min_deposit_sat {
            return Err(GovError::InsufficientDeposit);
        }

        let id = self.next_proposal_id;
        let p = Proposal {
            id,
            proposer,
            proposal_type: ptype,
            title: truncate(title, MAX_TITLE_LEN).to_string(),
            description: truncate(description, MAX_DESC_LEN).to_string(),
            param_name: String::new(),
            param_new_value: 0,
            deposit_sat,
            created_block: current_block,
            voting_start_block: current_block,
            voting_end_block: current_block + self.params.voting_period_blocks,
            status: ProposalStatus::VotingActive,
            votes_yes: 0,
            votes_no: 0,
            votes_abstain: 0,
            votes_veto: 0,
            total_voted_power: 0,
        };
        self.proposals.push(p);
        self.next_proposal_id += 1;
        Ok(id)
    }

    /// Vote on a proposal. `voting_power` is the snapshot the caller took
    /// at the start of the voting window (typically the staked OMNI of
    /// the voter at `voting_start_block`).
    pub fn vote(
        &mut self,
        proposal_id: u64,
        ballot: Vote,
        voting_power: u64,
        current_block: u64,
    ) -> Result<(), GovError> {
        let p = self
            .proposals
            .iter_mut()
            .find(|p| p.id == proposal_id)
            .ok_or(GovError::ProposalNotFound)?;

        if !p.is_voting_active(current_block) {
            return Err(GovError::VotingNotActive);
        }
        if voting_power == 0 {
            return Err(GovError::NoVotingPower);
        }

        match ballot {
            Vote::Yes => p.votes_yes += voting_power,
            Vote::No => p.votes_no += voting_power,
            Vote::Abstain => p.votes_abstain += voting_power,
            Vote::NoWithVeto => p.votes_veto += voting_power,
        }
        p.total_voted_power += voting_power;
        Ok(())
    }

    /// Finalize a proposal after the voting window closes. Returns the
    /// new status (Approved / Rejected / Expired).
    pub fn finalize(
        &mut self,
        proposal_id: u64,
        total_voting_power: u64,
        current_block: u64,
    ) -> Result<ProposalStatus, GovError> {
        let params = self.params;
        let p = self
            .proposals
            .iter_mut()
            .find(|p| p.id == proposal_id)
            .ok_or(GovError::ProposalNotFound)?;

        if current_block <= p.voting_end_block {
            return Err(GovError::VotingNotEnded);
        }

        let result = p.tally_result(total_voting_power, &params);
        p.status = result;
        Ok(result)
    }

    /// Execute an Approved proposal. Stub for now — concrete dispatch
    /// (apply param change, schedule upgrade, etc.) is wired by the
    /// chain orchestrator once those subsystems are ported.
    pub fn execute(&mut self, proposal_id: u64) -> Result<(), GovError> {
        let p = self
            .proposals
            .iter_mut()
            .find(|p| p.id == proposal_id)
            .ok_or(GovError::ProposalNotFound)?;
        match p.status {
            ProposalStatus::Approved => {
                p.status = ProposalStatus::Executed;
                // TODO(chain-orchestrator): dispatch on proposal_type +
                // param_name + param_new_value into the live config.
                Ok(())
            }
            ProposalStatus::Executed => Err(GovError::AlreadyExecuted),
            _ => Err(GovError::NotApproved),
        }
    }

    pub fn get_proposal(&self, id: u64) -> Option<&Proposal> {
        self.proposals.iter().find(|p| p.id == id)
    }

    pub fn proposal_count(&self) -> usize {
        self.proposals.len()
    }
}

fn truncate(s: &str, max: usize) -> &str {
    if s.len() <= max {
        s
    } else {
        // Find a char boundary at or below max.
        let mut end = max;
        while !s.is_char_boundary(end) {
            end -= 1;
        }
        &s[..end]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn engine_default() -> GovernanceEngine {
        GovernanceEngine::new(GovernanceParams::default())
    }

    #[test]
    fn create_proposal_ok() {
        let mut g = engine_default();
        let id = g
            .create_proposal([0xAA; 32], ProposalType::ParamChange, "t", "d", 100_000_000_000, 1000)
            .unwrap();
        assert_eq!(id, 1);
        assert_eq!(g.proposal_count(), 1);
    }

    #[test]
    fn insufficient_deposit_fails() {
        let mut g = engine_default();
        assert!(matches!(
            g.create_proposal([0xBB; 32], ProposalType::TextSignal, "x", "x", 1, 1000),
            Err(GovError::InsufficientDeposit)
        ));
    }

    #[test]
    fn approved_majority_yes() {
        let mut params = GovernanceParams::default();
        params.quorum_pct = 10;
        let mut g = GovernanceEngine::new(params);
        let id = g
            .create_proposal([0xCC; 32], ProposalType::ParamChange, "t", "d", 100_000_000_000, 1000)
            .unwrap();
        g.vote(id, Vote::Yes, 700, 1001).unwrap();
        g.vote(id, Vote::No, 300, 1002).unwrap();
        let end = 1000 + params.voting_period_blocks + 1;
        let s = g.finalize(id, 10_000, end).unwrap();
        assert_eq!(s, ProposalStatus::Approved);
    }

    #[test]
    fn veto_kills() {
        let mut params = GovernanceParams::default();
        params.quorum_pct = 10;
        let mut g = GovernanceEngine::new(params);
        let id = g
            .create_proposal([0xDD; 32], ProposalType::ParamChange, "t", "d", 100_000_000_000, 1000)
            .unwrap();
        g.vote(id, Vote::Yes, 500, 1001).unwrap();
        g.vote(id, Vote::NoWithVeto, 500, 1002).unwrap();
        let s = g
            .finalize(id, 10_000, 1000 + params.voting_period_blocks + 1)
            .unwrap();
        assert_eq!(s, ProposalStatus::Rejected);
    }

    #[test]
    fn expired_no_quorum() {
        let mut params = GovernanceParams::default();
        params.quorum_pct = 50;
        let mut g = GovernanceEngine::new(params);
        let id = g
            .create_proposal([0xEE; 32], ProposalType::TextSignal, "t", "d", 100_000_000_000, 1000)
            .unwrap();
        g.vote(id, Vote::Yes, 100, 1001).unwrap();
        let s = g
            .finalize(id, 10_000, 1000 + params.voting_period_blocks + 1)
            .unwrap();
        assert_eq!(s, ProposalStatus::Expired);
    }

    #[test]
    fn cannot_finalize_early() {
        let mut g = engine_default();
        let id = g
            .create_proposal([0x11; 32], ProposalType::TextSignal, "t", "d", 100_000_000_000, 1000)
            .unwrap();
        assert!(matches!(g.finalize(id, 10_000, 1001), Err(GovError::VotingNotEnded)));
    }
}
