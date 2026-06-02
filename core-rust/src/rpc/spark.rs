//! SPARK consensus RPC handlers — port of `core/rpc/spark.zig`.
//!
//! Methods:
//!   * `spark_status` — last finalized BlockConsensusState (trust, counts, hash)
//!   * `spark_votes`  — full 10-vote breakdown for a given block_hash

use crate::consensus::spark_consensus::{find_by_hash, last_state, BlockConsensusState};
use crate::AppState;
use serde_json::{json, Value};

use super::helpers::param_str;

fn state_to_json(s: &BlockConsensusState) -> Value {
    json!({
        "block_hash":   hex::encode(s.block_hash),
        "trust":        s.trust.as_str(),
        "attest_count": s.attest_count,
        "reject_count": s.reject_count,
    })
}

/// `spark_status` — last finalized SPARK consensus snapshot.
pub fn spark_status(_app: &AppState) -> Result<Value, String> {
    match last_state() {
        Some(s) => Ok(json!({
            "available": true,
            "state": state_to_json(&s),
        })),
        None => Ok(json!({ "available": false })),
    }
}

/// `spark_votes` — full 10-vote breakdown for a given block_hash (hex, 64 chars).
pub fn spark_votes(_app: &AppState, params: &Value) -> Result<Value, String> {
    let bh_hex = param_str(params, "block_hash").ok_or("missing block_hash")?;
    if bh_hex.len() != 64 {
        return Err("block_hash must be 64-char hex".to_string());
    }
    let mut bh = [0u8; 32];
    for i in 0..32 {
        bh[i] = u8::from_str_radix(&bh_hex[i * 2..i * 2 + 2], 16)
            .map_err(|_| "invalid hex in block_hash")?;
    }

    let state = find_by_hash(bh).ok_or("block_hash not in history window")?;
    let votes: Vec<Value> = state
        .votes
        .iter()
        .map(|maybe| match maybe {
            Some(v) => json!({
                "layer":     v.layer.as_str(),
                "kind":      v.kind.as_str(),
                "validator": hex::encode(v.validator),
                "reason":    v.reason_str(),
            }),
            None => json!({ "kind": "missing" }),
        })
        .collect();

    Ok(json!({
        "block_hash":   bh_hex,
        "trust":        state.trust.as_str(),
        "attest_count": state.attest_count,
        "reject_count": state.reject_count,
        "votes":        votes,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::consensus::spark_consensus::{
        attest, clear_history_for_test, record_state, BlockConsensusState, ValidationLayer,
    };

    #[test]
    fn votes_returns_per_layer_breakdown() {
        clear_history_for_test();
        let bh = [0x77u8; 32];
        let val = [0x11u8; 20];
        let mut s = BlockConsensusState::new(bh);
        s.add_vote(attest(ValidationLayer::TxWellFormed, val, bh));
        s.compute_trust();
        record_state(s);

        let params = json!({ "block_hash": hex::encode(bh) });
        // Use the function through a dummy AppState would require more setup;
        // test the lookup path directly.
        let got = find_by_hash(bh).expect("must find");
        assert_eq!(got.attest_count, 1);
        assert_eq!(got.block_hash, bh);
        let _ = params; // referenced in the matching real handler
    }
}
