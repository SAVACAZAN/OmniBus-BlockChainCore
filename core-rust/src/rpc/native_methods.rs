// OmniBus native JSON-RPC methods — port of core/rpc_server.zig dispatch.
//
// Methods grouped roughly by subsystem (chain / wallet / NS / DEX / HTLC /
// PQ / identity / governance / oracle / bridge / consensus). JSON shape
// matches the Zig implementation 1:1 — clients depend on field names.
//
// Most handlers are STUBS at this stage: they validate params and return
// the correct schema (empty/zeroed) so frontends can wire up against the
// Rust node, but the underlying state machinery (mempool, NS registry,
// matching engine, HTLC store, identity hub, etc.) is being ported by
// other agents. Each stub is tagged `// TODO(port:<module>)`.
//
// Authoritative references:
//   * core/rpc_server.zig            (dispatch + handlers)
//   * core/rpc/*.zig                 (per-module handlers)
//   * API_REFERENCE.md               (canonical JSON schemas)
//   * BlockChainCore/CLAUDE.md       (DEX pair_id → maker/taker chains)

use crate::AppState;
use crate::state::parse_addr;
use serde_json::{json, Value};

pub async fn dispatch(app: &AppState, method: &str, params: Value) -> Result<Value, String> {
    match method {
        // ── Chain queries ─────────────────────────────────────────────────
        "getblockcount"        => get_block_count(app).await,
        "getlatestblock"       => get_latest_block(app).await,
        "getbestblockhash"     => get_best_block_hash(app).await,
        "getdifficulty"        => get_difficulty(app).await,
        "getblockhash"         => get_block_hash(app, &params).await,
        "getblock"             => get_block(app, &params).await,
        "getblockbyhash"       => get_block_by_hash(app, &params).await,
        "getblockbynumber"     => get_block_by_number(app, &params).await,
        "getblocks"            => get_blocks(app, &params).await,
        "getblockchaininfo"    => get_blockchain_info(app).await,
        "getchainmetrics"      => get_chain_metrics(app).await,
        "getstatus"            => get_status(app).await,
        "getheaders"           => Ok(json!([])),
        "getmerkleproof"       => Ok(json!({"proof": [], "index": 0})),
        "getperformance"       => Ok(json!({"rpc_calls": 0, "avg_latency_ms": 0})),

        // ── Mempool ───────────────────────────────────────────────────────
        "getmempoolsize"   => get_mempool_size(app).await,
        "getmempoolstats"  => get_mempool_stats(app).await,
        "getmempool" | "getmempoolinfo" | "getrawmempool"
            => get_mempool(app).await,
        "getpendingtxs"    => get_mempool_txs(app).await,
        "estimatefee"      => Ok(json!(1000)),

        // ── Wallet / address ──────────────────────────────────────────────
        "getbalance" | "getaddressbalance"
                              => get_balance(app, &params),
        "getwalletsummary"    => get_wallet_summary(app, &params),
        "listunspent"         => list_unspent(app, &params),
        "getrichlist"         => get_richlist(app, &params),
        "getnonce"            => get_nonce(app, &params),
        "gettransaction" | "gettxbyhash"
                              => get_transaction(app, &params),
        "gettransactions" | "listtransactions"
                              => Ok(json!([])),
        "getaddresshistory"   => Ok(json!([])),
        "getdailyactivity"    => Ok(json!({"sent": 0, "received": 0, "txs": 0})),
        "getschemestats"      => Ok(json!({"ecdsa": 0, "ml_dsa": 0, "falcon": 0, "slh_dsa": 0, "ml_kem": 0})),
        "sendtransaction"     => Err("sendtransaction: mempool not yet ported".into()),
        "sendrawtransaction"  => send_raw_transaction(app, &params).await,
        "sendopreturn"        => Err("sendopreturn: mempool not yet ported".into()),
        "minersendtx"         => Err("minersendtx: mempool not yet ported".into()),

        // ── Wallet key management (CLI/SDK helpers) ───────────────────────
        "derive-key" | "derive_key"  => derive_key(&params),
        "wallet-list" | "wallet_list" => wallet_list(&params),

        // ── Faucet ────────────────────────────────────────────────────────
        "claimfaucet"      => Err("claimfaucet: faucet module not yet ported".into()),
        "getfaucetstatus"  => Ok(json!({"available": false, "balance": 0})),

        // ── Name System (ENS-like, .omnibus) ──────────────────────────────
        "registername"        => register_name(app, &params),
        "transfername"        => Err("transfername: NS module not yet ported".into()),
        "updatename"          => Err("updatename: NS module not yet ported".into()),
        "renewname"           => Err("renewname: NS module not yet ported".into()),
        "resolvename"         => resolve_name(app, &params),
        "ns_resolveforsend"   => resolve_name(app, &params),
        "reverseresolvename"  => Ok(json!(Value::Null)),
        "listnames"           => Ok(json!([])),
        "getensfee"           => Ok(json!({"fee": 10_000_000, "tld": ".omnibus", "tier": "standard"})),
        "ns_listTlds"         => Ok(json!([".omnibus", ".arbitraje"])),
        "ns_yearTiers"        => Ok(json!({"1y": 10_000_000, "5y": 40_000_000, "10y": 70_000_000})),
        "ns_stats"            => Ok(json!({"total": 0, "active": 0, "expired": 0})),
        "ns_expiringSoon"     => Ok(json!([])),
        "ns_pruneExpired"     => Ok(json!({"pruned": 0})),
        "setpqaddress" | "setcategory" | "setpreferredslot"
                              => Err("NS phase-2 methods: not yet ported".into()),
        "getnamesbycategory"  => Ok(json!([])),

        // ── Native DEX (matching engine on-chain) ─────────────────────────
        "exchange_listPairs"   => exchange_list_pairs(),
        "exchange_pairInfo"    => exchange_pair_info(&params),
        "exchange_placeOrder" | "place_order"
                               => Err("exchange_placeOrder: matching engine not yet ported".into()),
        "exchange_cancelOrder" | "cancel_order" | "cancelOrder"
                               => Err("exchange_cancelOrder: matching engine not yet ported".into()),
        "exchange_getOrderbook" | "exchange_listOrders" | "exchange_orderbook"
                               => Ok(json!({"bids": [], "asks": [], "pair_id": 0})),
        "exchange_getUserOrders" | "exchange_getUserTrades"
                               => Ok(json!([])),
        "exchange_getTrades" | "exchange_getRecentTrades" | "exchange_trades"
                               => Ok(json!([])),
        "exchange_getStats"    => Ok(json!({"volume_24h": 0, "high_24h": 0, "low_24h": 0, "last": 0})),
        "exchange_getAuthNonce"     => Ok(json!({"nonce": "0"})),
        "exchange_login"            => Err("exchange_login: auth module not yet ported".into()),
        "exchange_createApiKey"     => Err("exchange_createApiKey: auth module not yet ported".into()),
        "exchange_listApiKeys"      => Ok(json!([])),
        "exchange_revokeApiKey"     => Err("exchange_revokeApiKey: auth module not yet ported".into()),
        "exchange_deposit" | "exchange_depositReal" | "exchange_depositDemo"
                                    => Err("exchange_deposit: settlement module not yet ported".into()),
        "exchange_withdraw"         => Err("exchange_withdraw: settlement module not yet ported".into()),
        "exchange_getBalance" | "exchange_getBalances"
                                    => Ok(json!([])),
        "exchange_getEscrowAddress" => Ok(json!({"address": "ob1qescrow0000000000000000000000000"})),

        // ── Grid trading (per CLAUDE.md "DEX Grid Trading") ───────────────
        "grid_create" => grid_create(&params),
        "grid_list"   => Ok(json!([])),
        "grid_cancel" => grid_cancel(&params),
        "grid_status" => grid_status(&params),

        // ── HTLC atomic swaps ─────────────────────────────────────────────
        "htlc_init"            => htlc_init(&params),
        "htlc_claim"           => Err("htlc_claim: htlc store not yet ported".into()),
        "htlc_refund"          => Err("htlc_refund: htlc store not yet ported".into()),
        "htlc_get"             => Ok(json!(Value::Null)),
        "htlc_listByAddress"   => Ok(json!([])),
        "htlc_listPending"     => Ok(json!([])),
        "htlc_btc_buildScript" => Err("htlc_btc_buildScript: bitcoin script builder not yet ported".into()),

        // ── PQ isolated wallets ───────────────────────────────────────────
        "pq_listSchemes"   => pq_list_schemes(),
        "pq_balance"       => Ok(json!({"balance": 0, "address": ""})),
        "pq_send"          => Err("pq_send: pq mempool not yet ported".into()),
        "pq_verify_test"   => Ok(json!({"ok": true})),
        "pq_attestation"   => Err("pq_attestation: pq sign not yet ported".into()),
        "getpqidentity"    => Ok(json!({"addresses": []})),
        "sendpqattest"     => Err("sendpqattest: pq mempool not yet ported".into()),

        // ── Identity layer (DID / OBM / facets / profile / MiCA) ──────────
        "getidentity"      => get_identity(&params),
        "identity_set"     => Err("identity_set: identity store not yet ported".into()),
        "identity_get"     => Ok(json!({"nick": "", "ens": "", "visible": true})),
        "identity_search"  => Ok(json!([])),
        "kyc_getStatus"    => Ok(json!({"status": "none"})),
        "kyc_attest"       => Err("kyc_attest: kyc module not yet ported".into()),
        "kyc_listIssuers"  => Ok(json!([])),
        "getdid"           => get_did(&params),
        "getobm"           => get_obm(&params),
        "getfacets"        => get_facets(&params),
        "profile_init"     => profile_init(&params),
        "profile_update"   => profile_update(&params),
        "profile_get"      => profile_get(&params),
        "mica_attest"      => mica_attest(&params),
        "mica_disclose"    => mica_disclose(&params),
        "disclose_post" | "disclose_cert" | "disclose_work"
                           => Err("disclose_*: selective disclosure not yet ported".into()),
        "getreputation"    => Ok(json!({"score": 0, "tier": "user", "love": 0, "food": 0, "rent": 0, "vacation": 0})),
        "getreputationtop" => Ok(json!([])),

        // ── Social / labels / POAP / subs / notarize / escrow ─────────────
        "applylabel" | "getlabels" | "removelabel"
            => Ok(json!([])),
        "follow" | "unfollow"
            => Err("social graph: not yet ported".into()),
        "getfollowers" | "getfollowing"
            => Ok(json!([])),
        "poap_createevent" | "poap_claim" | "poap_close"
            => Err("poap: not yet ported".into()),
        "getpoaps" | "getpoapevent"
            => Ok(json!([])),
        "sub_create" | "sub_cancel"
            => Err("subscriptions: not yet ported".into()),
        "getsubscriptions" => Ok(json!([])),
        "notarizedoc" | "verifynotarize" | "revokenotarize"
            => Err("notarize: not yet ported".into()),
        "getnotarizations" => Ok(json!([])),
        "escrow_create" | "escrow_release" | "escrow_refund" | "escrow_dispute"
            => Err("escrow: not yet ported".into()),
        "getescrow" | "getescrows"
            => Ok(json!([])),

        // ── Governance ────────────────────────────────────────────────────
        "gov_propose" | "gov_vote" | "gov_execute"
            => Err("governance: not yet ported".into()),
        "getproposals" | "getproposal"
            => Ok(json!([])),

        // ── Net / peers ───────────────────────────────────────────────────
        "getpeers" | "getnodelist" | "getpeerinfo"
            => get_peers(app).await,
        "getconnectioncount" => Ok(json!(app.peers.count().await)),
        "getnetworkinfo"     => Ok(json!({"version": "0.0.1-rust", "protocol": 1, "subversion": "/omnibus-rust:0.0.1/"})),
        "getsyncstatus"      => {
            let c = app.chain.read().await;
            Ok(json!({"synced": true, "height": c.height()}))
        },

        // ── Consensus / staking / validators ──────────────────────────────
        "getvalidators" | "getvalidatorsv2" | "getstakers"
            => Ok(json!([])),
        "getslotleader" | "getclockstatus" | "getslotcalendar" | "getfuturepool"
            => Ok(json!({})),
        "stake" | "unstake" | "become_validator" | "validator_heartbeat"
            => Err("consensus: not yet ported".into()),
        "getstake"          => Ok(json!({"amount": 0})),
        "getstakinginfo"    => Ok(json!({"total_staked": 0, "validator_count": 0})),
        "submitslashevidence" => Err("slashing: not yet ported".into()),
        "getslashhistory" | "getslashevents"
                            => Ok(json!([])),

        // ── Mining ────────────────────────────────────────────────────────
        "getminerstats" | "getminerinfo" | "getpoolstats" | "omnibus_getminers"
            => Ok(json!({"miners": [], "hashrate": 0})),
        "registerminer"   => Err("registerminer: mining module not yet ported".into()),
        "getmininginfo"   => Ok(json!({"blocks": app.state.block_number(), "difficulty": 1.0, "networkhashps": 0})),

        // ── Agents ────────────────────────────────────────────────────────
        "agent_list" | "getagents" => Ok(json!([])),
        "agent_register" | "agent_unregister" | "agent_edit" | "agent_follow"
            => Err("agents: not yet ported".into()),
        "agent_status" | "agent_pending_decisions" | "agent_report_execution"
            => Ok(json!({})),
        "getagent" => Ok(json!(Value::Null)),

        // ── Oracle / prices ───────────────────────────────────────────────
        "omnibus_getoracleprices" | "omnibus_getallprices" | "omnibus_getexchangefeed"
            => Ok(json!({})),
        "omnibus_getblockprices" | "omnibus_getpricerange"
            => Ok(json!([])),
        "omnibus_getfxrate"         => Ok(json!({"rate": 1.0})),
        "omnibus_getorderbook"      => Ok(json!({"bids": [], "asks": []})),
        "omnibus_getarbitrage"      => Ok(json!([])),
        "omnibus_getoraclepolicy"   => Ok(json!({"sources": ["chainlink", "pyth", "coingecko"]})),
        "omnibus_setoraclepolicy"   => Err("setoraclepolicy: oracle module not yet ported".into()),
        "omnibus_gettotalmined"     => Ok(json!({"total": 0})),
        "omnibus_getbridgestatus" | "getbridgestatus"
                                    => Ok(json!({"status": "operational", "chains": []})),
        "omnibus_bridge_limits"     => Ok(json!({"daily_max": 0, "tx_max": 0})),

        // ── Bridge (peg-out / fraud proofs) ───────────────────────────────
        "bridge_lock" | "bridge_unlock_request" | "bridge_fraud_challenge" | "bridge_settle"
            => Err("bridge: not yet ported".into()),

        // ── SPV / cross-chain oracle ──────────────────────────────────────
        "spv_btc_verifyTx" | "spv_eth_verifyEvent"
            => Err("spv: not yet ported".into()),
        "oracle_btcHeight" | "oracle_ethHeight"
            => Ok(json!({"height": 0})),
        "oracle_recordHeader" => Err("oracle_recordHeader: not yet ported".into()),

        // ── Cross-chain atomic-swap binding ───────────────────────────────
        "swap_open" | "swap_lockMaker" | "swap_lockTaker" | "swap_timeout" | "swap_proveSettle"
            => Err("swap binding: not yet ported".into()),
        "swap_status"   => Ok(json!(Value::Null)),
        "swap_listOpen" => Ok(json!([])),
        "intent_post" | "intent_fill_commit" | "intent_settle" | "intent_timeout"
            => Err("intents: not yet ported".into()),

        // ── Multisig / cold / timelock / covenant / treasury ──────────────
        "createmultisig" | "sendmultisig"
            => Err("multisig: not yet ported".into()),
        "coldwallet_add" | "coldwallet_remove"
            => Err("coldwallet: not yet ported".into()),
        "coldwallet_list" | "coldwallet_history"
            => Ok(json!([])),
        "timelock_create" | "timelock_spend"
            => Err("timelock: not yet ported".into()),
        "timelock_list"  => Ok(json!([])),
        "timelock_status" => Ok(json!({})),
        "covenant_create" | "covenant_remove"
            => Err("covenant: not yet ported".into()),
        "covenant_list"  => Ok(json!([])),
        "covenant_get"   => Ok(json!(Value::Null)),
        "treasury_create" | "treasury_distribute"
            => Err("treasury: not yet ported".into()),
        "treasury_list"  => Ok(json!([])),
        "treasury_status" => Ok(json!({})),

        // ── Lightning-style channels ──────────────────────────────────────
        "openchannel" | "channelpay" | "closechannel"
            => Err("payment channels: not yet ported".into()),
        "getchannels" => Ok(json!([])),

        // generatewallet explicitly disabled in Zig — keep that behaviour.
        "generatewallet" => Err("Use CLI wallet generation (derive-key / wallet-list)".into()),

        _ => Err(format!("Method not found: {method}")),
    }
}

// ─── helpers ───────────────────────────────────────────────────────────────

fn param_obj<'a>(p: &'a Value) -> Option<&'a serde_json::Map<String, Value>> {
    p.as_object().or_else(|| p.as_array().and_then(|a| a.get(0)).and_then(|v| v.as_object()))
}
fn param_str<'a>(p: &'a Value, key: &str) -> Option<&'a str> {
    param_obj(p).and_then(|o| o.get(key)).and_then(|v| v.as_str())
}
fn param_u64(p: &Value, key: &str) -> Option<u64> {
    param_obj(p).and_then(|o| o.get(key)).and_then(|v| v.as_u64())
}
fn param0_str(p: &Value) -> Option<&str> {
    p.as_array().and_then(|a| a.get(0)).and_then(|v| v.as_str())
}

// ─── chain ─────────────────────────────────────────────────────────────────

async fn get_block_count(app: &AppState) -> Result<Value, String> {
    Ok(json!(app.chain.read().await.height()))
}

async fn get_latest_block(app: &AppState) -> Result<Value, String> {
    let c = app.chain.read().await;
    let tip = c.tip();
    Ok(json!({
        "height": tip.index,
        "hash":   tip.hash.clone(),
        "time":   tip.timestamp,
        "txs":    tip.transactions.iter().map(|t| format!("0x{}", hex::encode(t.hash))).collect::<Vec<_>>(),
    }))
}

async fn get_best_block_hash(app: &AppState) -> Result<Value, String> {
    Ok(json!(app.chain.read().await.tip().hash.clone()))
}

async fn get_difficulty(app: &AppState) -> Result<Value, String> {
    Ok(json!(app.chain.read().await.difficulty))
}

async fn get_block_hash(app: &AppState, params: &Value) -> Result<Value, String> {
    let h = params.as_array().and_then(|a| a.get(0)).and_then(|v| v.as_u64())
        .ok_or("missing height")?;
    let c = app.chain.read().await;
    match c.get_block_by_height(h) {
        Some(b) => Ok(json!(b.hash.clone())),
        None => Err(format!("no block at height {h}")),
    }
}

async fn get_block(app: &AppState, params: &Value) -> Result<Value, String> {
    let c = app.chain.read().await;
    if let Some(h) = param_u64(params, "height") {
        if let Some(b) = c.get_block_by_height(h) {
            return Ok(block_to_json(b));
        }
        return Err(format!("no block at height {h}"));
    }
    if let Some(hash) = param_str(params, "hash") {
        if let Some(b) = c.get_block_by_hash(hash) {
            return Ok(block_to_json(b));
        }
        return Err("not found".into());
    }
    if let Some(h) = params.as_array().and_then(|a| a.get(0)).and_then(|v| v.as_u64()) {
        if let Some(b) = c.get_block_by_height(h) {
            return Ok(block_to_json(b));
        }
        return Err(format!("no block at height {h}"));
    }
    if let Some(hash) = param0_str(params) {
        if let Some(b) = c.get_block_by_hash(hash) {
            return Ok(block_to_json(b));
        }
    }
    Err("missing height/hash".into())
}

async fn get_block_by_hash(app: &AppState, params: &Value) -> Result<Value, String> {
    get_block(app, params).await
}
async fn get_block_by_number(app: &AppState, params: &Value) -> Result<Value, String> {
    get_block(app, params).await
}

async fn get_blocks(app: &AppState, params: &Value) -> Result<Value, String> {
    let from = param_u64(params, "from").unwrap_or(0);
    let limit = param_u64(params, "limit").unwrap_or(50).min(500);
    let c = app.chain.read().await;
    let mut out = Vec::new();
    for h in from..(from + limit) {
        match c.get_block_by_height(h) {
            Some(b) => out.push(block_to_json(b)),
            None => break,
        }
    }
    Ok(json!(out))
}

async fn get_blockchain_info(app: &AppState) -> Result<Value, String> {
    let c = app.chain.read().await;
    Ok(json!({
        "chain":        c.cfg.name,
        "blocks":       c.height(),
        "headers":      c.height(),
        "bestblockhash": c.tip().hash.clone(),
        "difficulty":   c.difficulty,
        "verificationprogress": 1.0,
        "chainwork":    "0x0",
        "size_on_disk": 0,
        "pruned":       false,
    }))
}

async fn get_chain_metrics(app: &AppState) -> Result<Value, String> {
    let c = app.chain.read().await;
    let tx_count: usize = c.blocks.iter().map(|b| b.transactions.len()).sum();
    Ok(json!({
        "height":         c.height(),
        "total_supply":   0,
        "total_burned":   0,
        "circulating":    0,
        "tx_count":       tx_count,
        "avg_block_time": 1.0,
    }))
}

async fn get_status(app: &AppState) -> Result<Value, String> {
    let c = app.chain.read().await;
    Ok(json!({
        "height":   c.height(),
        "synced":   true,
        "peers":    app.peers.count().await,
        "version":  "0.0.1-rust",
    }))
}

fn block_to_json(b: &crate::consensus::block::Block) -> Value {
    json!({
        "height":        b.index,
        "hash":          b.hash.clone(),
        "previous_hash": b.previous_hash.clone(),
        "time":          b.timestamp,
        "nonce":         b.nonce,
        "miner":         b.miner_address.clone(),
        "reward":        b.reward_sat,
        "tx_count":      b.transactions.len(),
        "txs":           b.transactions.iter().map(|t| format!("0x{}", hex::encode(t.hash))).collect::<Vec<_>>(),
    })
}

// ─── mempool ───────────────────────────────────────────────────────────────

async fn get_mempool_size(app: &AppState) -> Result<Value, String> {
    Ok(json!(app.chain.read().await.mempool.len()))
}

async fn get_mempool_stats(app: &AppState) -> Result<Value, String> {
    let c = app.chain.read().await;
    Ok(json!({
        "size":  c.mempool.len(),
        "bytes": c.mempool.total_bytes,
        "fee_avg": 0,
    }))
}

async fn get_mempool(app: &AppState) -> Result<Value, String> {
    let c = app.chain.read().await;
    let txs: Vec<_> = c.mempool.entries.iter()
        .map(|e| format!("0x{}", hex::encode(e.tx.hash)))
        .collect();
    Ok(json!({"size": txs.len(), "txs": txs}))
}

async fn get_mempool_txs(app: &AppState) -> Result<Value, String> {
    let c = app.chain.read().await;
    let txs: Vec<_> = c.mempool.entries.iter().map(|e| json!({
        "hash":   format!("0x{}", hex::encode(e.tx.hash)),
        "from":   e.tx.from_address.clone(),
        "to":     e.tx.to_address.clone(),
        "amount": e.tx.amount,
        "fee":    e.tx.fee,
        "nonce":  e.tx.nonce,
    })).collect();
    Ok(json!(txs))
}

// ─── wallet ────────────────────────────────────────────────────────────────

fn get_balance(app: &AppState, params: &Value) -> Result<Value, String> {
    let addr_str = param0_str(params).or_else(|| param_str(params, "address"))
        .ok_or("missing address")?;
    // OMNI bech32 (ob1...) is not yet a routable address here — for now we
    // only resolve EVM-style 0x... addresses against EvmState.
    // TODO(port:wallet) — once the native bech32 ledger lands, route here.
    if let Some(addr) = parse_addr(addr_str) {
        return Ok(json!(app.state.balance(&addr) as u64));
    }
    Ok(json!(0))
}

fn get_wallet_summary(_app: &AppState, params: &Value) -> Result<Value, String> {
    // Matches RPC `getwalletsummary` schema (memory: project_wallet_summary_rpc_2026-05-10).
    let addr = param0_str(params).or_else(|| param_str(params, "address")).unwrap_or("");
    Ok(json!({
        "address":    addr,
        "wallet":     0,
        "staked":     0,
        "in_orders":  0,
        "available":  0,
        "locks":      [],
        "open_orders": [],
    }))
}

fn list_unspent(_app: &AppState, params: &Value) -> Result<Value, String> {
    let _addrs: Vec<&str> = params.as_array()
        .and_then(|a| a.get(0))
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|x| x.as_str()).collect())
        .unwrap_or_default();
    // TODO(port:wallet) — UTXO set not yet implemented.
    Ok(json!([]))
}

fn get_richlist(_app: &AppState, params: &Value) -> Result<Value, String> {
    let _limit = params.as_array().and_then(|a| a.get(0)).and_then(|v| v.as_u64()).unwrap_or(100);
    // Schema must match API_REFERENCE.md exactly.
    Ok(json!({
        "entries": [],
        "total": 0,
        "shown": 0,
        "totalSupply": 0,
    }))
}

fn get_nonce(app: &AppState, params: &Value) -> Result<Value, String> {
    let addr_str = param0_str(params).or_else(|| param_str(params, "address"))
        .ok_or("missing address")?;
    if let Some(addr) = parse_addr(addr_str) {
        return Ok(json!(app.state.nonce(&addr)));
    }
    Ok(json!(0))
}

async fn get_peers(app: &AppState) -> Result<Value, String> {
    let peers = app.peers.snapshot().await;
    let out: Vec<_> = peers.iter().map(|p| json!({
        "addr": p.addr,
        "node_id": p.node_id,
        "height": p.height,
        "last_seen": p.last_seen,
    })).collect();
    Ok(json!(out))
}

fn get_transaction(app: &AppState, params: &Value) -> Result<Value, String> {
    let hash_str = param0_str(params).or_else(|| param_str(params, "txid"))
        .ok_or("missing txid")?;
    let raw = hex::decode(hash_str.trim_start_matches("0x")).map_err(|e| e.to_string())?;
    if raw.len() != 32 { return Err("bad hash".into()); }
    let mut h = [0u8; 32]; h.copy_from_slice(&raw);
    match app.state.read_tx(&h) {
        Some(t) => Ok(json!({
            "txid":   format!("0x{}", hex::encode(t.hash)),
            "block":  t.block,
            "from":   format!("0x{}", hex::encode(t.from)),
            "to":     t.to.map(|a| format!("0x{}", hex::encode(a))),
            "amount": t.value as u64,
            "nonce":  t.nonce,
        })),
        None => Ok(Value::Null),
    }
}

async fn send_raw_transaction(app: &AppState, params: &Value) -> Result<Value, String> {
    // Accept either {from, to, amount, fee, nonce, hash?} or hex-encoded blob.
    // Full canonical-TX parsing waits on the storage agent; meanwhile we accept
    // the structured form so the mempool layer is exercisable from the CLI.
    use crate::consensus::block::Tx;
    use sha2::{Digest, Sha256};

    let from = param_str(params, "from").ok_or("missing from")?;
    let to   = param_str(params, "to").ok_or("missing to")?;
    let amount = param_u64(params, "amount").ok_or("missing amount")?;
    let fee    = param_u64(params, "fee").unwrap_or(1);
    let nonce  = param_u64(params, "nonce").unwrap_or(0);
    let ts     = param_u64(params, "timestamp_ms").map(|x| x as i64).unwrap_or_else(|| {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64).unwrap_or(0)
    });

    // Deterministic placeholder hash until canonical TX encoder lands.
    let mut h = Sha256::new();
    h.update(from.as_bytes());
    h.update(to.as_bytes());
    h.update(&amount.to_le_bytes());
    h.update(&fee.to_le_bytes());
    h.update(&nonce.to_le_bytes());
    h.update(&ts.to_le_bytes());
    let mut hash = [0u8; 32];
    hash.copy_from_slice(&h.finalize());

    let tx = Tx {
        hash,
        from_address: from.to_string(),
        to_address: to.to_string(),
        amount,
        fee,
        nonce,
        timestamp_ms: ts,
        signature: Vec::new(),
    };
    let mut c = app.chain.write().await;
    c.add_tx(tx).map_err(|e| e.to_string())?;
    Ok(json!({"hash": format!("0x{}", hex::encode(hash))}))
}

// ─── key derivation helpers ────────────────────────────────────────────────

fn derive_key(params: &Value) -> Result<Value, String> {
    // Inputs: { mnemonic, index, passphrase? } — derives BIP-44 OMNI key.
    let _mn = param_str(params, "mnemonic").ok_or("missing mnemonic")?;
    let _idx = param_u64(params, "index").unwrap_or(0);
    // TODO(port:wallet) — depends on omnibus-crypto-core Rust bindings.
    Err("derive-key: omnibus-crypto-core bindings not yet wired".into())
}

fn wallet_list(params: &Value) -> Result<Value, String> {
    let _mn = param_str(params, "mnemonic").ok_or("missing mnemonic")?;
    let _count = param_u64(params, "count").unwrap_or(10);
    // TODO(port:wallet) — depends on omnibus-crypto-core Rust bindings.
    Err("wallet-list: omnibus-crypto-core bindings not yet wired".into())
}

// ─── identity ──────────────────────────────────────────────────────────────

fn get_identity(params: &Value) -> Result<Value, String> {
    let addr = param0_str(params).or_else(|| param_str(params, "address")).unwrap_or("");
    Ok(json!({
        "address": addr,
        "did":     "",
        "obm":     "",
        "facets":  {},
    }))
}

fn get_did(params: &Value) -> Result<Value, String> {
    let addr = param0_str(params).or_else(|| param_str(params, "address")).unwrap_or("");
    Ok(json!({"address": addr, "did": format!("did:omnibus:{}", addr), "manifest_root": format!("0x{}", "0".repeat(64))}))
}

fn get_obm(params: &Value) -> Result<Value, String> {
    let addr = param0_str(params).or_else(|| param_str(params, "address")).unwrap_or("");
    // OmniBus Manifest root (Merkle root over 10 leaves per memory).
    Ok(json!({
        "address":       addr,
        "manifest_root": format!("0x{}", "0".repeat(64)),
        "leaves":        10,
        "version":       1,
    }))
}

fn get_facets(params: &Value) -> Result<Value, String> {
    let addr = param0_str(params).or_else(|| param_str(params, "address")).unwrap_or("");
    Ok(json!({
        "address": addr,
        "social":       {"root": format!("0x{}", "0".repeat(64)), "items": []},
        "professional": {"root": format!("0x{}", "0".repeat(64)), "items": []},
        "cultural":     {"root": format!("0x{}", "0".repeat(64)), "items": []},
        "economic":     {"root": format!("0x{}", "0".repeat(64)), "items": []},
    }))
}

fn profile_init(_params: &Value) -> Result<Value, String> {
    // TODO(port:identity) — emits PROFILE_INIT TX, updates Manifest leaves 6-9.
    Err("profile_init: identity hub not yet ported".into())
}
fn profile_update(_params: &Value) -> Result<Value, String> {
    Err("profile_update: identity hub not yet ported".into())
}
fn profile_get(params: &Value) -> Result<Value, String> {
    let addr = param0_str(params).or_else(|| param_str(params, "address")).unwrap_or("");
    Ok(json!({
        "address": addr,
        "social":       {},
        "professional": {},
        "cultural":     {},
        "economic":     {},
    }))
}
fn mica_attest(_params: &Value) -> Result<Value, String> {
    Err("mica_attest: identity hub not yet ported".into())
}
fn mica_disclose(_params: &Value) -> Result<Value, String> {
    // TODO(port:identity) — selective disclosure: returns Merkle proof for the
    // disclosed leaf only, never the underlying PII.
    Err("mica_disclose: identity hub not yet ported".into())
}

// ─── name system ───────────────────────────────────────────────────────────

fn register_name(_app: &AppState, _params: &Value) -> Result<Value, String> {
    // TODO(port:ns) — emits NS_REGISTER op_return TX with fee burn.
    Err("registername: NS module not yet ported".into())
}

fn resolve_name(_app: &AppState, params: &Value) -> Result<Value, String> {
    let name = param0_str(params).or_else(|| param_str(params, "name"))
        .ok_or("missing name")?;
    Ok(json!({
        "name":    name,
        "address": Value::Null,
        "expires": 0,
        "owner":   Value::Null,
    }))
}

// ─── DEX / grid ────────────────────────────────────────────────────────────

fn exchange_list_pairs() -> Result<Value, String> {
    // pair_id assignments are FIXED forever per CLAUDE.md "DEX Grid Trading"
    Ok(json!([
        {"pair_id": 0, "base": "OMNI", "quote": "USDC"},
        {"pair_id": 2, "base": "LCX",  "quote": "USDC"},
        {"pair_id": 3, "base": "ETH",  "quote": "USDC"},
        {"pair_id": 5, "base": "OMNI", "quote": "LCX"},
        {"pair_id": 6, "base": "OMNI", "quote": "ETH"},
    ]))
}

fn exchange_pair_info(params: &Value) -> Result<Value, String> {
    let pair_id = param_u64(params, "pair_id")
        .or_else(|| params.as_array().and_then(|a| a.get(0)).and_then(|v| v.as_u64()))
        .ok_or("missing pair_id")?;
    // Schema MUST include maker_chains[]/taker_chains[] per project_omnibus_dex_multichain.
    let (base, quote, maker, taker): (&str, &str, &[&str], &[&str]) = match pair_id {
        0 => ("OMNI", "USDC", &["omnibus"],          &["base-sepolia", "sepolia"]),
        2 => ("LCX",  "USDC", &["liberty"],          &["base-sepolia", "sepolia"]),
        3 => ("ETH",  "USDC", &["sepolia", "base-sepolia"], &["base-sepolia", "sepolia"]),
        5 => ("OMNI", "LCX",  &["omnibus"],          &["liberty"]),
        6 => ("OMNI", "ETH",  &["omnibus"],          &["sepolia", "base-sepolia"]),
        _ => return Err(format!("unknown pair_id: {pair_id}")),
    };
    Ok(json!({
        "pair_id":      pair_id,
        "base":         base,
        "quote":        quote,
        "maker_chains": maker,
        "taker_chains": taker,
        "tick_size":    1,
        "min_size":     1,
        "fee_bps":      10,
    }))
}

fn grid_create(params: &Value) -> Result<Value, String> {
    // Param schema per CLAUDE.md: pair_id, price_low, price_high, levels,
    // total_base, total_quote, owner.
    let _pair = param_u64(params, "pair_id").ok_or("missing pair_id")?;
    let _lo   = param_u64(params, "price_low").ok_or("missing price_low")?;
    let _hi   = param_u64(params, "price_high").ok_or("missing price_high")?;
    let _lvl  = param_u64(params, "levels").ok_or("missing levels")?;
    let _tb   = param_u64(params, "total_base").ok_or("missing total_base")?;
    let _tq   = param_u64(params, "total_quote").ok_or("missing total_quote")?;
    let _own  = param_str(params, "owner").ok_or("missing owner")?;
    // TODO(port:grid) — depends on grid_engine.zig port.
    Err("grid_create: grid engine not yet ported".into())
}

fn grid_cancel(params: &Value) -> Result<Value, String> {
    let _id = param_u64(params, "grid_id").ok_or("missing grid_id")?;
    Err("grid_cancel: grid engine not yet ported".into())
}

fn grid_status(params: &Value) -> Result<Value, String> {
    let id = param_u64(params, "grid_id").ok_or("missing grid_id")?;
    Ok(json!({
        "grid_id":      id,
        "status":       "idle",
        "fills":        0,
        "profit":       0,
        "active_orders": 0,
    }))
}

// ─── HTLC ──────────────────────────────────────────────────────────────────

fn htlc_init(params: &Value) -> Result<Value, String> {
    // Params: { pair_id, side, amount, counterparty, timelock }.
    // CRITICAL: preimage is generated in backend and NEVER returned to caller
    // (see CLAUDE.md HTLC rules). Caller only ever sees hash_lock.
    let _pair = param_u64(params, "pair_id").ok_or("missing pair_id")?;
    let _side = param_str(params, "side").ok_or("missing side")?;
    let _amt  = param_u64(params, "amount").ok_or("missing amount")?;
    // TODO(port:htlc) — depends on swap_registry + preimage generator.
    Err("htlc_init: htlc store not yet ported".into())
}

// ─── PQ ────────────────────────────────────────────────────────────────────

fn pq_list_schemes() -> Result<Value, String> {
    // 5 schemes per project memory + soulbound 4 transferable 4 quantum subs.
    Ok(json!([
        {"id": "ml_dsa_87",   "label": "ML-DSA-87",   "prefix": "obk1_"},
        {"id": "falcon_512",  "label": "Falcon-512",  "prefix": "obf5_"},
        {"id": "slh_dsa_256", "label": "SLH-DSA-256", "prefix": "obs3_"},
        {"id": "ml_kem_768",  "label": "ML-KEM-768",  "prefix": "obd5_"},
        {"id": "ecdsa_secp256k1", "label": "ECDSA",   "prefix": "ob1q"},
    ]))
}
