//! On-chain governance — Rust port of `core/governance.zig`.
//!
//! Token holders vote on protocol changes:
//!   - parameter changes (UBI rate, fee burn %, block reward, …)
//!   - protocol upgrades (consensus type, block size, difficulty range)
//!   - emergency actions (freeze address, pause bridge)
//!   - text signals (non-binding)
//!
//! Inspired by Tezos (on-chain gov), Cosmos (proposal/deposit/vote),
//! EGLD (governance staking), Bitcoin BIP9 (version signaling).
//!
//! Status: functional in-memory engine. Sled persistence is layered on by
//! the caller via `proposal::Proposal::encode` / `decode` (CBOR-ish bincode
//! is out of scope here — keep encoding explicit). The validator module's
//! sled tree already demonstrates the pattern.

pub mod proposal;
pub mod voting;

pub use proposal::{
    GovernanceEngine, GovernanceParams, Proposal, ProposalStatus, ProposalType,
    MAX_PROPOSALS,
};
pub use voting::{Vote, VoteRecord};
