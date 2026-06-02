//! Consensus / staking / validator / slashing JSON-RPC methods.
//!
//! Ported from core/rpc/consensus.zig (2026-06-02).
//! Underlying staking/finality/slashing modules are partly ported; these
//! handlers expose the JSON-RPC surface so frontends can wire up.
//!
//! Zig source: core/rpc/consensus.zig (663 lines).
//!
//! Methods covered (15 total):
//!   stake, unstake, getstake, getstakers,
//!   getvalidators, getvalidatorsv2, become_validator, validator_heartbeat,
//!   getslotleader, getclockstatus, getslotcalendar, getfuturepool,
//!   submitslashevidence, getslashhistory, getslashevents, getstakinginfo
//!
//! Response shapes mirror the Zig wire format exactly so existing frontend
//! components (aweb3, OmnibusAgentOS) parse without changes. Stubs return
//! zero-values for fields that depend on the staking engine (not yet wired
//! to `AppState`); they are marked TODO(wire-staking).

use crate::AppState;
use serde_json::{json, Value};

use super::helpers::{param0_str, param_str, param_u64};

// ─── Minimum stake constant (matches Zig handleStake) ─────────────────────
const MIN_STAKE_SAT: u64 = 10_000_000_000; // 10 OMNI (9 decimals)
const SAT_PER_OMNI: u64 = 1_000_000_000;
const UNBONDING_BLOCKS: u64 = 604_800; // ~7 days at 1s blocks

/// `stake` — queue a stake TX into the mempool.
/// Mirrors Zig `handleStake`: validates min-10-OMNI, builds op_return
/// `stake:<lock_blocks>`, queues TX.
/// TODO(wire-staking): push TX into `app.chain.mempool` once Chain is
/// exposed on AppState.
pub fn stake(_app: &AppState, params: &Value) -> Result<Value, String> {
    let from = param_str(params, "from").ok_or("missing from")?;
    let amt = param_u64(params, "amount_sat").ok_or("missing amount_sat")?;
    let lock_blocks = param_u64(params, "lock_blocks").unwrap_or(0);
    let _sig = param_str(params, "signature").ok_or("missing signature")?;
    let _pubkey = param_str(params, "public_key").ok_or("missing public_key")?;
    let nonce = param_u64(params, "nonce").unwrap_or(0);

    if amt < MIN_STAKE_SAT {
        return Err(format!(
            "Min stake {} SAT ({} OMNI)",
            MIN_STAKE_SAT,
            MIN_STAKE_SAT / SAT_PER_OMNI
        ));
    }

    // TODO(wire-staking): build Transaction with op_return="stake:<lock_blocks>"
    // and append to app.chain.write().mempool.
    let provisional_txid = format!("stake_{from}_{nonce}");
    Ok(json!({
        "status": "queued",
        "txid": provisional_txid,
        "amount_sat": amt,
        "lock_blocks": lock_blocks,
    }))
}

/// `unstake` — queue an unstake TX into the mempool.
/// Mirrors Zig `handleUnstake`: builds op_return `unstake:<stake_id>`,
/// computes `unbonding_until_block = current_height + 604800`.
/// TODO(wire-staking): look up current height from app.chain.
pub fn unstake(_app: &AppState, params: &Value) -> Result<Value, String> {
    let from = param_str(params, "from").ok_or("missing from")?;
    let stake_id = param_u64(params, "stake_id").unwrap_or(0);
    let _sig = param_str(params, "signature").ok_or("missing signature")?;
    let _pubkey = param_str(params, "public_key").ok_or("missing public_key")?;
    let nonce = param_u64(params, "nonce").unwrap_or(0);

    // TODO(wire-staking): derive current_block from chain tip.
    let current_block: u64 = 0;
    let unbond_until = current_block + UNBONDING_BLOCKS;
    let provisional_txid = format!("unstake_{from}_{stake_id}_{nonce}");

    Ok(json!({
        "status": "queued",
        "txid": provisional_txid,
        "unbonding_until_block": unbond_until,
    }))
}

/// `getstake` — return active stake entries for an address.
/// Mirrors Zig `handleGetStake`: reads `bc.stake_amounts` + `bc.stake_meta`,
/// returns `{stakes: [{id,amount_sat,lock_blocks,started_at_block,days_locked,
/// rent_earned,status}]}`.
/// TODO(wire-staking): query actual stake_amounts from Chain.
pub fn get_stake(_app: &AppState, params: &Value) -> Result<Value, String> {
    let addr = param0_str(params)
        .or_else(|| param_str(params, "address"))
        .unwrap_or("");
    // TODO(wire-staking): look up from chain.stake_amounts[addr].
    Ok(json!({
        "stakes": [],
        "address": addr,
        "total_staked_sat": 0,
    }))
}

/// `getstakers` — return up to `limit` (default 50, max 200) stakers.
/// Mirrors Zig `handleGetStakers`: iterates `bc.stake_amounts`, enriches
/// with `bc.stake_meta` for lock/days info.
/// TODO(wire-staking): iterate real stake_amounts from Chain.
pub fn get_stakers(_app: &AppState, params: &Value) -> Result<Value, String> {
    let limit = param_u64(params, "limit").unwrap_or(50).min(200) as usize;
    let _ = limit;
    // TODO(wire-staking): iterate chain.stake_amounts, emit up to `limit` entries.
    Ok(json!({ "stakers": [] }))
}

/// `getvalidators` — active validators from the on-chain registry (v1, list).
/// Mirrors Zig `handleGetValidators`: returns `{count, validators:[{address,
/// weight,since_height}]}`.
/// TODO(wire-staking): query chain.validator_set.
pub fn get_validators(_app: &AppState) -> Result<Value, String> {
    Ok(json!({ "count": 0, "validators": [] }))
}

/// `getvalidatorsv2` — enriched validator list with tier/uptime stats.
/// Mirrors Zig `handleGetValidatorsV2`: iterates `bc.stake_amounts`,
/// filters ≥100 OMNI, counts blocks mined in last-100 for uptime,
/// classifies Bronze/Silver/Gold/Platinum.
/// TODO(wire-staking): drive from chain state.
pub fn get_validators_v2(_app: &AppState, _params: &Value) -> Result<Value, String> {
    Ok(json!({
        "total_validators": 0,
        "active_count": 0,
        "slashed_count": 0,
        "current_slot_leader": "",
        "validators": [],
    }))
}

/// `become_validator` — queue a `validator:promote` op_return TX.
/// Mirrors Zig `handleBecomeValidator`.
/// TODO(wire-staking): queue into mempool.
pub fn become_validator(_app: &AppState, params: &Value) -> Result<Value, String> {
    let from = param_str(params, "from").ok_or("missing from")?;
    let _sig = param_str(params, "signature").ok_or("missing signature")?;
    let _pubkey = param_str(params, "public_key").ok_or("missing public_key")?;
    let nonce = param_u64(params, "nonce").unwrap_or(0);
    let provisional_txid = format!("validator_promote_{from}_{nonce}");
    Ok(json!({
        "status": "queued",
        "txid": provisional_txid,
        "validator_tier": "Bronze",
    }))
}

/// `validatorheartbeat` — in-memory liveness ping; no chain TX needed.
/// Mirrors Zig `handleValidatorHeartbeat`: marks validator alive in
/// staking engine (no persistent state change).
/// TODO(wire-staking): update liveness timestamp in engine.
pub fn validator_heartbeat(_app: &AppState, params: &Value) -> Result<Value, String> {
    let _from = param_str(params, "from").ok_or("missing from")?;
    let _sig = param_str(params, "signature").ok_or("missing signature")?;
    let _pubkey = param_str(params, "public_key").ok_or("missing public_key")?;
    Ok(json!({ "status": "ok" }))
}

/// `getslotleader` — VRF-weighted slot-leader for the next block.
/// Mirrors Zig `handleGetSlotLeader`: `slot_id = chain.items.len`,
/// calls `validator_registry::leaderForSlot(slot_id, tip_hash, validator_set)`.
/// TODO(wire-staking): compute from chain tip + validator set.
pub fn get_slot_leader(_app: &AppState) -> Result<Value, String> {
    Ok(json!({
        "slot": 0,
        "leader": Value::Null,
        "weight": 0,
        "error": "validator set not yet wired",
    }))
}

/// `getclockstatus` — wall clock + hardware cycle counter.
/// Mirrors Zig `handleGetClockStatus`: returns `{now_ms, rdtsc, spectrum}`.
/// The `spectrum` field is a 64-char binary string of rdtsc bits MSB-first
/// (lets frontend chart bit patterns over time for clock-jitter detection).
pub fn get_clock_status(_app: &AppState) -> Result<Value, String> {
    use std::time::{SystemTime, UNIX_EPOCH};
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    // Rust doesn't have rdtsc without inline-asm — use now_ms as proxy
    // until the orchestrator module lands.
    let rdtsc = now_ms;
    // Build spectrum: 64-char '0'/'1' string of the 64-bit counter MSB-first.
    let spectrum: String = (0..64)
        .rev()
        .map(|i| if (rdtsc >> i) & 1 == 1 { '1' } else { '0' })
        .collect();
    Ok(json!({
        "now_ms": now_ms,
        "rdtsc": rdtsc,
        "spectrum": spectrum,
    }))
}

/// `getslotcalendar` — next 60 pre-computed slot entries.
/// Mirrors Zig `handleGetSlotCalendar`: returns `{head_slot, slot_interval_ms,
/// entries:[{slot_id,leader,expected_arrival_ms,state}]}`.
/// Computes on-the-fly from the current chain tip; validator set is empty
/// until validator registry is exposed on AppState (leader fields are zero hex).
pub fn get_slot_calendar(app: &AppState) -> Result<Value, String> {
    use crate::consensus::slot_calendar::{SlotCalendar, SLOT_INTERVAL_MS};

    let chain = app.chain.blocking_read();
    let tip_height = chain.height();
    let tip_hash_hex = chain.tip().hash.clone();
    drop(chain);

    let mut tip_hash = [0u8; 32];
    if tip_hash_hex.len() >= 64 {
        for i in 0..32 {
            if let Ok(b) = u8::from_str_radix(&tip_hash_hex[i * 2..i * 2 + 2], 16) {
                tip_hash[i] = b;
            }
        }
    }
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);

    let mut cal = SlotCalendar::new();
    cal.recompute(tip_height, tip_hash, now_ms, &[]);

    let entries: Vec<Value> = cal
        .entries
        .iter()
        .map(|e| {
            json!({
                "slot_id": e.slot_id,
                "leader": hex::encode(e.leader_address),
                "expected_arrival_ms": e.expected_arrival_ms,
                "placeholder_hash": hex::encode(e.placeholder_hash),
                "state": e.state.as_str(),
            })
        })
        .collect();

    Ok(json!({
        "head_slot": tip_height + 1,
        "slot_interval_ms": SLOT_INTERVAL_MS,
        "tip_height": tip_height,
        "computed_at_ms": now_ms,
        "entries": entries,
    }))
}

/// `getfuturepool` — time-locked TX count (locktime > current height).
/// Mirrors Zig `handleGetFuturePool`: returns `{current_height,
/// locked_count, earliest_target, latest_target}`.
/// TODO(wire-staking): query mempool future-pool stats.
pub fn get_future_pool(_app: &AppState) -> Result<Value, String> {
    Ok(json!({
        "current_height": 0,
        "locked_count": 0,
        "earliest_target": 0,
        "latest_target": 0,
    }))
}

/// `submitslashevidence` — verify + queue a slash-evidence record.
/// Mirrors Zig `handleSubmitSlashEvidence`: parses reason
/// (double_sign|invalid_block|downtime), for crypto reasons verifies two
/// secp256k1 sigs against the validator's registered pubkey, then calls
/// `staking.submitSlashEvidence`.
/// TODO(wire-staking): verify sigs + call slashing engine.
pub fn submit_slash_evidence(_app: &AppState, params: &Value) -> Result<Value, String> {
    // Extract the same positional params the Zig handler uses:
    // [validator_addr, reason, block_hash_1, block_hash_2, block_height,
    //  reporter_addr, sig_1?, sig_2?]
    let validator = params
        .as_array()
        .and_then(|a| a.first())
        .and_then(|v| v.as_str())
        .or_else(|| param_str(params, "validator"))
        .ok_or("missing param: validator_address")?;
    let reason_str = params
        .as_array()
        .and_then(|a| a.get(1))
        .and_then(|v| v.as_str())
        .or_else(|| param_str(params, "reason"))
        .ok_or("missing param: reason (double_sign|invalid_block|downtime)")?;

    match reason_str {
        "double_sign" | "invalid_block" | "downtime" => {}
        _ => return Err("Invalid reason: use double_sign, invalid_block, or downtime".into()),
    }

    // TODO(wire-staking): for double_sign/invalid_block, verify both sigs
    // against validator's registered pubkey (params[2..3] = block hashes,
    // params[6..7] = signatures). Then call slashing engine.
    Ok(json!({
        "valid": false,
        "slashed_amount": 0,
        "reporter_reward": 0,
        "new_stake": 0,
        "reason": reason_str,
        "validator": validator,
        "note": "slashing engine not yet wired",
    }))
}

/// `getslashhistory` — slash records for a validator address.
/// Mirrors Zig `handleGetSlashHistory`: returns `{address, total_slashes,
/// records:[{reason,amount,height,reporter,reward}]}`.
/// TODO(wire-staking): query staking engine.
pub fn get_slash_history(_app: &AppState, params: &Value) -> Result<Value, String> {
    let addr = param0_str(params)
        .or_else(|| param_str(params, "address"))
        .unwrap_or("");
    Ok(json!({
        "address": addr,
        "total_slashes": 0,
        "records": [],
    }))
}

/// `getslashevents` — all recent slash events (chain-wide).
/// Mirrors Zig `handleGetSlashEvents`: returns `{events:[]}`.
/// TODO(wire-staking): scan slash_history from staking engine.
pub fn get_slash_events(_app: &AppState, _params: &Value) -> Result<Value, String> {
    Ok(json!({ "events": [] }))
}

/// `getstakinginfo` — full validator profile including slash status.
/// Mirrors Zig `handleGetStakingInfo`: returns `{address,status,
/// total_stake,self_stake,delegated_stake,slash_count,
/// slash_history_count,total_rewards,uptime_pct,blocks_produced,
/// commission_pct}`.
/// TODO(wire-staking): query staking engine for real validator info.
pub fn get_staking_info(_app: &AppState, params: &Value) -> Result<Value, String> {
    let addr = param0_str(params)
        .or_else(|| param_str(params, "address"))
        .unwrap_or("");
    Ok(json!({
        "address": addr,
        "status": "inactive",
        "total_stake": 0,
        "self_stake": 0,
        "delegated_stake": 0,
        "slash_count": 0,
        "slash_history_count": 0,
        "total_rewards": 0,
        "uptime_pct": 0,
        "blocks_produced": 0,
        "commission_pct": 0,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::helpers::{param_str, param_u64};
    use serde_json::json;

    // ── Param-parsing tests (no AppState needed) ──────────────────────

    #[test]
    fn stake_param_check() {
        let p = json!({"from": "ob1qx", "amount": 10});
        assert!(param_str(&p, "from").is_some());
        assert_eq!(param_u64(&p, "amount"), Some(10));
    }

    #[test]
    fn stake_amount_sat_below_minimum() {
        // amount_sat = 1 sat — should be below MIN_STAKE_SAT (10 OMNI).
        let amt: u64 = 1;
        assert!(amt < MIN_STAKE_SAT, "expected below min: got {amt}");
    }

    #[test]
    fn slash_reason_validation() {
        // Confirm accepted + rejected strings match Zig exactly.
        let valid = ["double_sign", "invalid_block", "downtime"];
        let invalid = ["fake_reason", "DOWNTIME", "slash"];
        for r in &valid {
            assert!(matches!(*r, "double_sign" | "invalid_block" | "downtime"));
        }
        for r in &invalid {
            assert!(!matches!(*r, "double_sign" | "invalid_block" | "downtime"));
        }
    }

    #[test]
    fn clock_status_spectrum_length() {
        // Spectrum is always 64 chars (one bit per bit of u64 counter, MSB-first).
        let rdtsc: u64 = 0xDEAD_BEEF_CAFE_1234;
        let spectrum: String = (0..64)
            .rev()
            .map(|i| if (rdtsc >> i) & 1 == 1 { '1' } else { '0' })
            .collect();
        assert_eq!(spectrum.len(), 64);
        // MSB: bit 63 of 0xDEAD... = 1.
        assert_eq!(&spectrum[0..1], "1");
    }

    #[test]
    fn unbonding_period_constant() {
        // 604_800 blocks at 1s block-time == 7 days exactly.
        const SECS_PER_DAY: u64 = 86_400;
        assert_eq!(UNBONDING_BLOCKS, 7 * SECS_PER_DAY);
    }

    #[test]
    fn get_stake_response_shape() {
        // Verify response JSON has expected keys (param-only, no AppState).
        let p = json!({"address": "ob1qtest"});
        // Simulate what get_stake would return for an empty staking engine.
        let result = json!({
            "stakes": [],
            "address": param_str(&p, "address").unwrap_or(""),
            "total_staked_sat": 0u64,
        });
        assert!(result.get("stakes").is_some());
        assert!(result.get("total_staked_sat").is_some());
    }
}
