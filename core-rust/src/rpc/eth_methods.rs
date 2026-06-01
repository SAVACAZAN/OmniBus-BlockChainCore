// Ethereum-compat JSON-RPC methods (eth_*, net_*).
// Mirrors core/rpc/eth.zig. State backed by EvmState (sled trees).
//
// All eth_ numbers are returned as 0x-prefixed hex strings (per spec).
// All addresses/hashes lowercase 0x... (per spec).

use crate::AppState;
use crate::block_exec::apply_tx;
use crate::evm;
use crate::state::parse_addr;
use crate::tx::{parse_raw, TxKind, TxParsed};
use serde_json::{json, Value};

pub async fn dispatch(app: &AppState, method: &str, params: Value) -> Result<Value, String> {
    match method {
        "eth_chainId"               => Ok(hex_u64(app.state.chain_id())),
        "eth_blockNumber"           => Ok(hex_u64(app.state.block_number())),
        "net_version"               => Ok(json!(app.state.chain_id().to_string())),
        "eth_gasPrice"              => Ok(hex_u64(1_000_000_000)), // 1 gwei
        "eth_getBalance"            => eth_get_balance(app, &params),
        "eth_getTransactionCount"   => eth_get_tx_count(app, &params),
        "eth_getCode"               => eth_get_code(app, &params),
        "eth_getStorageAt"          => eth_get_storage_at(app, &params),
        "eth_sendRawTransaction"    => eth_send_raw_tx(app, &params).await,
        "eth_getTransactionReceipt" => eth_get_receipt(app, &params),
        "eth_getTransactionByHash"  => eth_get_tx(app, &params),
        "eth_getBlockByNumber"      => eth_get_block_by_number(app, &params),
        "eth_call"                  => eth_call(app, &params),
        "eth_estimateGas"           => eth_estimate_gas(app, &params),
        "eth_getLogs"               => eth_get_logs(app, &params),
        _ => Err(format!("Method not found: {method}")),
    }
}

fn hex_u64(n: u64) -> Value { json!(format!("0x{:x}", n)) }
fn hex_u128(n: u128) -> Value { json!(format!("0x{:x}", n)) }

fn param0_str(p: &Value) -> Option<&str> {
    p.as_array().and_then(|a| a.get(0)).and_then(|v| v.as_str())
}

fn eth_get_balance(app: &AppState, params: &Value) -> Result<Value, String> {
    let addr_str = param0_str(params).ok_or("missing address")?;
    let addr = parse_addr(addr_str).ok_or("bad address")?;
    Ok(hex_u128(app.state.balance(&addr)))
}

fn eth_get_tx_count(app: &AppState, params: &Value) -> Result<Value, String> {
    let addr_str = param0_str(params).ok_or("missing address")?;
    let addr = parse_addr(addr_str).ok_or("bad address")?;
    Ok(hex_u64(app.state.nonce(&addr)))
}

fn eth_get_code(app: &AppState, params: &Value) -> Result<Value, String> {
    let addr_str = param0_str(params).ok_or("missing address")?;
    let addr = parse_addr(addr_str).ok_or("bad address")?;
    let code = app.state.code(&addr);
    Ok(json!(format!("0x{}", hex::encode(code))))
}

fn eth_get_storage_at(app: &AppState, params: &Value) -> Result<Value, String> {
    let arr = params.as_array().ok_or("params must be array")?;
    let addr_str = arr.get(0).and_then(|v| v.as_str()).ok_or("missing address")?;
    let slot_str = arr.get(1).and_then(|v| v.as_str()).ok_or("missing slot")?;
    let addr = parse_addr(addr_str).ok_or("bad address")?;
    let raw = hex::decode(slot_str.trim_start_matches("0x")).map_err(|e| e.to_string())?;
    let mut slot = [0u8; 32];
    if raw.len() > 32 { return Err("slot too long".into()); }
    slot[32 - raw.len()..].copy_from_slice(&raw);
    let v = app.state.read_storage_slot(&addr, &slot);
    Ok(json!(format!("0x{}", hex::encode(v))))
}

async fn eth_send_raw_tx(app: &AppState, params: &Value) -> Result<Value, String> {
    let raw_str = param0_str(params).ok_or("missing raw tx")?;
    let raw = hex::decode(raw_str.trim_start_matches("0x")).map_err(|e| format!("hex: {e}"))?;
    let parsed = parse_raw(&raw)?;
    let _outcome = apply_tx(&app.state, &parsed)?;
    Ok(json!(format!("0x{}", hex::encode(parsed.hash))))
}

fn eth_get_receipt(app: &AppState, params: &Value) -> Result<Value, String> {
    let hash_str = param0_str(params).ok_or("missing hash")?;
    let raw = hex::decode(hash_str.trim_start_matches("0x")).map_err(|e| e.to_string())?;
    if raw.len() != 32 { return Err("hash must be 32 bytes".into()); }
    let mut hash = [0u8; 32]; hash.copy_from_slice(&raw);
    match app.state.read_receipt(&hash) {
        Some(r) => {
            let logs = evm::read_logs(&app.state, &hash);
            let logs_json: Vec<Value> = logs.iter().enumerate().map(|(i, l)| json!({
                "address":          format!("0x{}", hex::encode(l.address)),
                "topics":           l.topics.iter().map(|t| format!("0x{}", hex::encode(t))).collect::<Vec<_>>(),
                "data":             format!("0x{}", hex::encode(&l.data)),
                "blockNumber":      format!("0x{:x}", l.block),
                "transactionHash":  format!("0x{}", hex::encode(l.tx_hash)),
                "logIndex":         format!("0x{:x}", i),
                "removed":          false,
            })).collect();
            Ok(json!({
                "transactionHash": format!("0x{}", hex::encode(r.hash)),
                "blockNumber":     format!("0x{:x}", r.block),
                "gasUsed":         format!("0x{:x}", r.gas_used),
                "status":          format!("0x{:x}", r.status),
                "contractAddress": r.contract.map(|a| format!("0x{}", hex::encode(a))),
                "logs":            logs_json,
            }))
        }
        None => Ok(Value::Null),
    }
}

fn eth_get_tx(app: &AppState, params: &Value) -> Result<Value, String> {
    let hash_str = param0_str(params).ok_or("missing hash")?;
    let raw = hex::decode(hash_str.trim_start_matches("0x")).map_err(|e| e.to_string())?;
    if raw.len() != 32 { return Err("hash must be 32 bytes".into()); }
    let mut hash = [0u8; 32]; hash.copy_from_slice(&raw);
    match app.state.read_tx(&hash) {
        Some(t) => Ok(json!({
            "hash":        format!("0x{}", hex::encode(t.hash)),
            "blockNumber": format!("0x{:x}", t.block),
            "from":        format!("0x{}", hex::encode(t.from)),
            "to":          t.to.map(|a| format!("0x{}", hex::encode(a))),
            "nonce":       format!("0x{:x}", t.nonce),
            "value":       format!("0x{:x}", t.value),
            "input":       format!("0x{}", hex::encode(&t.data)),
        })),
        None => Ok(Value::Null),
    }
}

fn eth_get_block_by_number(app: &AppState, params: &Value) -> Result<Value, String> {
    let tag = param0_str(params).unwrap_or("latest");
    let num = if tag == "latest" || tag == "pending" {
        app.state.block_number()
    } else {
        u64::from_str_radix(tag.trim_start_matches("0x"), 16).map_err(|e| e.to_string())?
    };
    Ok(json!({
        "number":       format!("0x{:x}", num),
        "hash":         format!("0x{}", "0".repeat(64)),
        "parentHash":   format!("0x{}", "0".repeat(64)),
        "transactions": [],
        "gasLimit":     "0x1c9c380",
        "gasUsed":      "0x0",
        "timestamp":    "0x0",
    }))
}

// ---- contract-aware methods ----

fn parse_call_object(params: &Value) -> Result<TxParsed, String> {
    let arr = params.as_array().ok_or("params must be array")?;
    let obj = arr.get(0).and_then(|v| v.as_object()).ok_or("missing call object")?;

    let from = obj.get("from").and_then(|v| v.as_str())
        .and_then(parse_addr).unwrap_or([0u8; 20]);
    let to = obj.get("to").and_then(|v| v.as_str()).and_then(parse_addr);
    let data = obj.get("data").or_else(|| obj.get("input"))
        .and_then(|v| v.as_str())
        .map(|s| hex::decode(s.trim_start_matches("0x")).unwrap_or_default())
        .unwrap_or_default();
    let value: u128 = obj.get("value").and_then(|v| v.as_str())
        .and_then(|s| u128::from_str_radix(s.trim_start_matches("0x"), 16).ok())
        .unwrap_or(0);
    let gas_limit: u64 = obj.get("gas").and_then(|v| v.as_str())
        .and_then(|s| u64::from_str_radix(s.trim_start_matches("0x"), 16).ok())
        .unwrap_or(30_000_000);

    Ok(TxParsed {
        kind: TxKind::Eip1559,
        chain_id: 0,
        nonce: 0,
        gas_limit,
        to,
        value,
        data,
        from,
        hash: [0u8; 32],
    })
}

fn eth_call(app: &AppState, params: &Value) -> Result<Value, String> {
    let tx = parse_call_object(params)?;
    let res = evm::execute_call(&app.state, &tx)?;
    Ok(json!(format!("0x{}", hex::encode(&res.output))))
}

fn eth_estimate_gas(app: &AppState, params: &Value) -> Result<Value, String> {
    let mut tx = parse_call_object(params)?;
    tx.gas_limit = u64::MAX / 2;
    let res = evm::execute_call(&app.state, &tx)?;
    // Add a 10% buffer to be safe with state-dependent costs.
    let with_buf = res.gas_used.saturating_add(res.gas_used / 10).max(21_000);
    Ok(hex_u64(with_buf))
}

fn eth_get_logs(app: &AppState, params: &Value) -> Result<Value, String> {
    let arr = params.as_array().ok_or("params must be array")?;
    let filter = arr.get(0).and_then(|v| v.as_object());
    let latest = app.state.block_number();

    let parse_block_tag = |v: Option<&Value>| -> u64 {
        match v.and_then(|x| x.as_str()) {
            Some("latest") | Some("pending") | None => latest,
            Some("earliest") => 0,
            Some(s) => u64::from_str_radix(s.trim_start_matches("0x"), 16).unwrap_or(latest),
        }
    };

    let from_block = parse_block_tag(filter.and_then(|f| f.get("fromBlock")));
    let to_block = parse_block_tag(filter.and_then(|f| f.get("toBlock")));

    let address_filter: Option<[u8; 20]> = filter
        .and_then(|f| f.get("address"))
        .and_then(|v| v.as_str())
        .and_then(parse_addr);

    let topics_filter: Vec<Option<[u8; 32]>> = filter
        .and_then(|f| f.get("topics"))
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().map(|t| {
            t.as_str().and_then(|s| {
                let raw = hex::decode(s.trim_start_matches("0x")).ok()?;
                if raw.len() != 32 { return None; }
                let mut out = [0u8; 32]; out.copy_from_slice(&raw); Some(out)
            })
        }).collect())
        .unwrap_or_default();

    let logs = evm::logs::query_logs(&app.state, from_block, to_block, address_filter, &topics_filter);

    let out: Vec<Value> = logs.iter().enumerate().map(|(i, l)| json!({
        "address":         format!("0x{}", hex::encode(l.address)),
        "topics":          l.topics.iter().map(|t| format!("0x{}", hex::encode(t))).collect::<Vec<_>>(),
        "data":            format!("0x{}", hex::encode(&l.data)),
        "blockNumber":     format!("0x{:x}", l.block),
        "transactionHash": format!("0x{}", hex::encode(l.tx_hash)),
        "logIndex":        format!("0x{:x}", i),
        "removed":         false,
    })).collect();

    Ok(json!(out))
}
