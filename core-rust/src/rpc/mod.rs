// JSON-RPC dispatch — sibling of core/rpc_server.zig.
//
// Two method families:
//   * eth_*       → eth_methods.rs (Ethereum-compat, used by MetaMask/Hardhat)
//   * everything else → native_methods.rs (OmniBus native: chain, wallet,
//                       NS, DEX, HTLC, identity, governance, etc.)
//
// Wire format: identical to Zig — same field names, same casing, same types
// (balances as u128 numbers when small / strings when large; hex strings for
// hashes/addresses; arrays not maps where Zig used arrays). Clients are
// authoritative; we match them, not the other way around.

pub mod eth_methods;
pub mod native_methods;
pub mod server;

// Per-subsystem JSON-RPC handler modules (siblings of core/rpc/*.zig).
// Each exposes `pub fn <method>(&AppState, &Value) -> Result<Value, String>`.
// Wired into the dispatch match in `native_methods.rs` as the underlying
// chain/staking/governance/etc subsystems land.
pub mod helpers;
pub mod chain;
pub mod wallet;
pub mod consensus;
pub mod wallet_advanced;
pub mod social;
pub mod agents;
pub mod escrow;
pub mod mining;
pub mod lightning;
pub mod governance;
pub mod notarize;
pub mod subscription;
pub mod spv;
pub mod omniscript;
pub mod spark;
pub mod strategies;

pub use server::{RpcConfig, RpcServer};

use crate::AppState;
use serde_json::Value;

pub async fn dispatch(app: &AppState, method: &str, params: Value) -> Result<Value, String> {
    // eth_* + net_version routed to EVM-compat handlers.
    if method.starts_with("eth_") || method == "net_version" {
        return eth_methods::dispatch(app, method, params).await;
    }
    native_methods::dispatch(app, method, params).await
}
