//! Votes — ballot enum + per-voter records.
//!
//! Quorum, threshold and veto math live on `Proposal::tally_result` in
//! `proposal.rs`. This module just defines the ballot shapes so the
//! engine and the RPC layer share a common vocabulary.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Vote {
    Yes = 1,
    No = 2,
    Abstain = 3,
    /// Cosmos-style "No with veto" — counts as No AND, if 1/3+ of
    /// non-abstain ballots vote this way, kills the proposal outright.
    NoWithVeto = 4,
}

impl Vote {
    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            1 => Some(Self::Yes),
            2 => Some(Self::No),
            3 => Some(Self::Abstain),
            4 => Some(Self::NoWithVeto),
            _ => None,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Yes => "yes",
            Self::No => "no",
            Self::Abstain => "abstain",
            Self::NoWithVeto => "no_with_veto",
        }
    }
}

/// Persisted record of a single vote. The engine itself only stores
/// aggregated tallies; this struct is used by RPC + audit log so we can
/// answer "what did validator X vote on proposal Y" without scanning the
/// whole chain.
#[derive(Debug, Clone, Copy)]
pub struct VoteRecord {
    pub voter_address: [u8; 32],
    pub proposal_id: u64,
    pub vote: Vote,
    /// Voting power at time of vote (snapshot — same value the engine
    /// added to the tally).
    pub voting_power: u64,
    pub block_height: u64,
}
