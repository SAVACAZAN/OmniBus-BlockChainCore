// EVM execution layer built on revm.
//
// Boundary design:
//   * `db.rs`       — adapter from sled-backed `EvmState` to revm `Database` trait
//   * `executor.rs` — wraps `revm::Evm` for one-shot eth_call (read-only) and
//                     eth_sendRawTransaction (state-mutating, contract-aware).
//   * `logs.rs`     — Log struct + sled persistence keyed by tx_hash.
//
// This module is intentionally narrow so a future Zig-native EVM can replace
// revm without touching `block_exec.rs` / `rpc/eth_methods.rs` callers.

pub mod db;
pub mod executor;
pub mod interface;
pub mod logs;
#[cfg(test)]
mod tests;

pub use executor::{execute_call, execute_tx, ExecStatus};
pub use logs::{read_logs, write_logs, Log};
