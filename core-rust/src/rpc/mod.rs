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

use crate::AppState;
use serde_json::Value;

pub async fn dispatch(app: &AppState, method: &str, params: Value) -> Result<Value, String> {
    // eth_* + net_version routed to EVM-compat handlers.
    if method.starts_with("eth_") || method == "net_version" {
        return eth_methods::dispatch(app, method, params).await;
    }
    native_methods::dispatch(app, method, params).await
}
