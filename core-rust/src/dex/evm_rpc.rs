//! evm_rpc — blocking JSON-RPC helper for EVM chains.
//!
//! Wraps the four calls the DEX settler needs: nonce, gas price, chain id,
//! and send_raw_transaction. Uses reqwest blocking client so the settler
//! thread can call these synchronously without a tokio runtime.
//!
//! Ported from `core/bridge/evm_rpc_client.zig`.

use reqwest::blocking::Client;
use serde::Deserialize;
use serde_json::{json, Value};
use std::time::Duration;

#[derive(Debug, thiserror::Error)]
pub enum RpcError {
    #[error("http: {0}")]
    Http(#[from] reqwest::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("rpc error {0}: {1}")]
    Rpc(i64, String),
    #[error("missing result")]
    NoResult,
    #[error("parse hex: {0}")]
    ParseHex(String),
}

#[derive(Deserialize)]
struct RpcResp {
    result: Option<Value>,
    error: Option<RpcErrBody>,
}

#[derive(Deserialize)]
struct RpcErrBody {
    code: i64,
    message: String,
}

fn make_client() -> Client {
    Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
        .unwrap_or_default()
}

fn call(url: &str, method: &str, params: Value) -> Result<Value, RpcError> {
    let client = make_client();
    let body = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
    let resp: RpcResp = client.post(url).json(&body).send()?.json()?;
    if let Some(e) = resp.error {
        return Err(RpcError::Rpc(e.code, e.message));
    }
    resp.result.ok_or(RpcError::NoResult)
}

fn hex_to_u64(s: &str) -> Result<u64, RpcError> {
    let s = s.trim_start_matches("0x").trim_start_matches("0X");
    if s.is_empty() { return Ok(0); }
    u64::from_str_radix(s, 16)
        .map_err(|e| RpcError::ParseHex(e.to_string()))
}

/// `eth_getTransactionCount` — account nonce.
pub fn get_transaction_count(url: &str, addr: &str) -> Result<u64, RpcError> {
    let v = call(url, "eth_getTransactionCount", json!([addr, "latest"]))?;
    hex_to_u64(v.as_str().ok_or(RpcError::NoResult)?)
}

/// `eth_gasPrice` — current gas price in wei.
pub fn gas_price(url: &str) -> Result<u64, RpcError> {
    let v = call(url, "eth_gasPrice", json!([]))?;
    hex_to_u64(v.as_str().ok_or(RpcError::NoResult)?)
}

/// `eth_chainId` — network chain id.
pub fn chain_id(url: &str) -> Result<u64, RpcError> {
    let v = call(url, "eth_chainId", json!([]))?;
    hex_to_u64(v.as_str().ok_or(RpcError::NoResult)?)
}

/// `eth_sendRawTransaction` — broadcast signed tx. Returns "0x..." tx hash.
pub fn send_raw_transaction(url: &str, raw_hex: &str) -> Result<String, RpcError> {
    let v = call(url, "eth_sendRawTransaction", json!([raw_hex]))?;
    v.as_str().map(|s| s.to_owned()).ok_or(RpcError::NoResult)
}
