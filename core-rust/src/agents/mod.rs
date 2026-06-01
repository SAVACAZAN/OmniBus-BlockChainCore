//! agents/ — autonomous AI agents on-chain.
//!
//! Sibling port of `core/agent_{tier,config,wallet,executor,manager}.zig`.
//! Same semantics: each agent gets a HD-derived wallet (BIP-44
//! m/44'/777'/0'/0/wallet_index), a tier computed from total capital
//! (with hysteresis), a strategy + user rules, and emits Decisions that
//! the host node turns into signed TX (native venue) or queues for the
//! external client (CEX/DEX venues).
//!
//! Layout mirrors the Zig modules:
//!   - tier.rs     — `Tier` enum + thresholds + hysteresis
//!   - config.rs   — `AgentConfig`, `Strategy`, `Rule`, `RiskLimits`
//!   - wallet.rs   — `AgentWallet` (BIP-44 derivation, soulbound-aware)
//!   - executor.rs — `AgentExecutor` (per-tick decision engine)
//!   - manager.rs  — `AgentManager` (lifecycle + pending-decision queue)
//!
//! Agent licensing (per ecosystem CLAUDE.md) is a JSON smart-contract
//! type — agents register via the `agent_register` RPC; this module is
//! the runtime side that consumes those registrations.

pub mod config;
pub mod executor;
pub mod manager;
pub mod tier;
pub mod wallet;

#[allow(unused_imports)]
pub use config::{Action, AgentConfig, AgentBundle, Metric, Op, RiskLimits, Rule, Strategy};
#[allow(unused_imports)]
pub use executor::{
    AgentExecutor, AgentState, Decision, DecisionKind, OracleSnapshot, Venue,
};
#[allow(unused_imports)]
pub use manager::{
    AgentManager, AgentSlot, AgentStats, ExecReceipt, ExecStatus, PendingDecision,
};
#[allow(unused_imports)]
pub use tier::{Tier, TierTransition, FAUCET_GRANT_SAT, T2_MIN_SAT, T3_MIN_SAT, T4_MIN_SAT};
#[allow(unused_imports)]
pub use wallet::AgentWallet;
