//! Anti-scam safety registry — Ethereum-style flagged addresses.
//!
//! Layered:
//!   * `flags`           — on-chain registry of flagged addresses, reasons,
//!                          evidence hash, reporters, dispute status.
//!   * `reputation`      — 0..1000 score per address; signals fold in.
//!   * `reporters`       — DAO-gated whitelist of who can file flags.
//!   * `oracle_blocklist`— periodic ingest from external feeds (OFAC, …).
//!   * `tx_guard`        — pre-flight `check_tx_safety()` called before
//!                          `block_exec::apply_tx`; returns
//!                          `Allowed / WarnSender / WarnReceiver / Block`.
//!
//! Wallets call `get_flag(addr)` + `get_reputation(addr)` before sending so
//! the UX warns about phishing / scam / sanctioned recipients.

pub mod flags;
pub mod reputation;
pub mod reporters;
pub mod oracle_blocklist;
pub mod tx_guard;

pub use flags::{
    DisputeStatus, FlagRecord, FlagSeverity, FlagsRegistry, FlagsError,
};
pub use reputation::{ReputationStore, ReputationError, ReputationEvent};
pub use reporters::{ReporterRegistry, ReporterRecord, ReportersError};
pub use tx_guard::{SafetyVerdict, check_tx_safety};
