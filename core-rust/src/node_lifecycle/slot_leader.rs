//! slot_leader — picks the validator allowed to seal the next block in a slot.
//!
//! Ported from `core/node/slot_leader.zig` (2026-06-02).
//!
//! Three picker variants:
//!   1. `pick_leader_index`         — unbiased index ∈ [0, N).
//!   2. `pick_leader_weighted`      — stake-weighted index (sum-of-stakes
//!                                    cumulative distribution, no float math).
//!   3. `should_mine_this_slot`     — full liveness decision (leader missed
//!                                    timeout → lex-min validator takes over).
//!
//! Chain-coupling is kept behind the `SlotContext` trait so this module
//! tests deterministically without dragging the Chain struct in.

use sha2::{Digest, Sha256};

// ─── Unbiased index ──────────────────────────────────────────────────────────

/// Pick the slot leader index from `validator_count`, seeded by the previous
/// block hash and the slot number. Deterministic across all nodes that see
/// the same input. Returns `None` if there are no validators.
pub fn pick_leader_index(
    prev_block_hash: &[u8; 32],
    slot_number: u64,
    validator_count: usize,
) -> Option<usize> {
    if validator_count == 0 {
        return None;
    }
    let mut h = Sha256::new();
    h.update(prev_block_hash);
    h.update(slot_number.to_le_bytes());
    let digest = h.finalize();
    let r = u64::from_le_bytes(digest[..8].try_into().unwrap());
    Some((r % validator_count as u64) as usize)
}

// ─── Stake-weighted index ────────────────────────────────────────────────────

/// Pick the slot leader weighted by stake. Stakes are summed and the random
/// draw lands inside a cumulative slot. Higher stake = higher probability,
/// but never deterministic (a 90%-stake validator does NOT always win).
///
/// Algorithm:
///   total = Σ stakes
///   r     = sha256(prev || slot)[..8] mod total
///   walk: find smallest i where Σ stakes[0..=i] > r
///
/// Returns `None` if the slice is empty or every stake is zero.
pub fn pick_leader_weighted(
    prev_block_hash: &[u8; 32],
    slot_number: u64,
    stakes: &[u64],
) -> Option<usize> {
    if stakes.is_empty() {
        return None;
    }
    // u128 prevents overflow when many validators × max u64 stake.
    let total: u128 = stakes.iter().map(|&s| s as u128).sum();
    if total == 0 {
        return None;
    }
    let mut h = Sha256::new();
    h.update(prev_block_hash);
    h.update(slot_number.to_le_bytes());
    let digest = h.finalize();
    let r_u64 = u64::from_le_bytes(digest[..8].try_into().unwrap());
    let r: u128 = (r_u64 as u128) % total;

    let mut acc: u128 = 0;
    for (i, &s) in stakes.iter().enumerate() {
        acc += s as u128;
        if r < acc {
            return Some(i);
        }
    }
    // Unreachable when total > 0; fall back to last index defensively.
    Some(stakes.len() - 1)
}

// ─── Liveness fallback decision ──────────────────────────────────────────────

/// Decision returned by `should_mine_this_slot`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SlotDecision {
    /// Caller should fall through to produce the next block.
    Mine,
    /// Caller should `continue` the outer mining loop (skip this slot).
    Skip,
}

/// Inputs required for the liveness decision. Caller fills these from the
/// running Chain + clock + p2p state — keeping them in a plain struct keeps
/// this module decoupled from those types.
pub struct LivenessInputs<'a> {
    pub my_addr: &'a str,
    pub leader_addr: &'a str,
    /// Sorted list of currently-active validator addresses (lex-ordered).
    pub active_validators: &'a [&'a str],
    /// Wall-clock ms when the current tip arrived (resets every block).
    pub tip_arrival_ms: i64,
    pub now_ms: i64,
    /// Slot timeout in ms; after this, lex-min validator may produce.
    pub slot_timeout_ms: i64,
    /// Minimum gap between blocks produced by this node (anti-thrash).
    pub min_block_gap_ms: i64,
    /// Last time this node produced a block (ms). 0 = never.
    pub last_block_produced_ms: i64,
}

pub fn should_mine_this_slot(inp: &LivenessInputs<'_>) -> SlotDecision {
    // Enforce pacing first — even if we're the chosen leader.
    if inp.last_block_produced_ms > 0
        && inp.now_ms - inp.last_block_produced_ms < inp.min_block_gap_ms
    {
        return SlotDecision::Skip;
    }

    // Happy path: I am the elected leader.
    if inp.my_addr == inp.leader_addr {
        return SlotDecision::Mine;
    }

    // Liveness fallback: leader missed the slot → lex-min active validator
    // takes the slot. Without this, a 2-validator network freezes whenever
    // one is offline.
    let tip_age_ms = inp.now_ms - inp.tip_arrival_ms;
    if tip_age_ms < inp.slot_timeout_ms {
        return SlotDecision::Skip;
    }

    // I must be a validator at all to participate in the liveness fallback.
    if !inp.active_validators.iter().any(|&v| v == inp.my_addr) {
        return SlotDecision::Skip;
    }

    // Lex-min active validator wins the skip slot.
    let mut sorted: Vec<&str> = inp.active_validators.to_vec();
    sorted.sort_unstable();
    if sorted.first().copied() == Some(inp.my_addr) {
        SlotDecision::Mine
    } else {
        SlotDecision::Skip
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_validator_set_returns_none() {
        assert!(pick_leader_index(&[0u8; 32], 0, 0).is_none());
    }

    #[test]
    fn deterministic_for_same_input() {
        let h = [0xABu8; 32];
        let a = pick_leader_index(&h, 42, 10).unwrap();
        let b = pick_leader_index(&h, 42, 10).unwrap();
        assert_eq!(a, b);
        assert!(a < 10);
    }

    #[test]
    fn different_slot_changes_leader_eventually() {
        let h = [0u8; 32];
        let mut seen = std::collections::HashSet::new();
        for slot in 0..200u64 {
            seen.insert(pick_leader_index(&h, slot, 10).unwrap());
            if seen.len() > 1 {
                return;
            }
        }
        panic!("picker stuck on one validator across 200 slots");
    }

    // ── weighted ────────────────────────────────────────────────────────────

    #[test]
    fn weighted_empty_returns_none() {
        assert!(pick_leader_weighted(&[0u8; 32], 0, &[]).is_none());
    }

    #[test]
    fn weighted_all_zero_returns_none() {
        assert!(pick_leader_weighted(&[0u8; 32], 0, &[0, 0, 0]).is_none());
    }

    #[test]
    fn weighted_single_validator_wins() {
        let i = pick_leader_weighted(&[0u8; 32], 99, &[100]).unwrap();
        assert_eq!(i, 0);
    }

    #[test]
    fn weighted_zero_stake_never_picked() {
        // Validator 1 has stake 0 — should never be picked across many slots.
        let stakes = [50u64, 0, 50];
        let mut counts = [0u32; 3];
        for slot in 0..500u64 {
            let i = pick_leader_weighted(&[0u8; 32], slot, &stakes).unwrap();
            counts[i] += 1;
        }
        assert_eq!(counts[1], 0, "zero-stake validator should never win");
        assert!(counts[0] > 0 && counts[2] > 0);
    }

    #[test]
    fn weighted_high_stake_wins_more_often() {
        // 90/10 split: validator 0 should win the lion's share but not all.
        let stakes = [900u64, 100];
        let mut counts = [0u32; 2];
        for slot in 0..1000u64 {
            let i = pick_leader_weighted(&[0xAAu8; 32], slot, &stakes).unwrap();
            counts[i] += 1;
        }
        // SHA-256 distribution → expect ~900/100 ± noise. Allow generous margin.
        assert!(counts[0] > counts[1] * 4, "high-stake should win much more often");
        assert!(counts[1] > 0, "low-stake validator should still win some slots");
    }

    // ── liveness ───────────────────────────────────────────────────────────

    fn base_inp<'a>(my_addr: &'a str, leader: &'a str, vs: &'a [&'a str]) -> LivenessInputs<'a> {
        LivenessInputs {
            my_addr,
            leader_addr: leader,
            active_validators: vs,
            tip_arrival_ms: 0,
            now_ms: 0,
            slot_timeout_ms: 300,
            min_block_gap_ms: 0,
            last_block_produced_ms: 0,
        }
    }

    #[test]
    fn leader_mines_immediately() {
        let vs = ["alice", "bob"];
        let inp = base_inp("alice", "alice", &vs);
        assert_eq!(should_mine_this_slot(&inp), SlotDecision::Mine);
    }

    #[test]
    fn non_leader_skips_inside_timeout() {
        let vs = ["alice", "bob"];
        let mut inp = base_inp("bob", "alice", &vs);
        inp.now_ms = 100; // tip just landed, < SLOT_TIMEOUT_MS
        assert_eq!(should_mine_this_slot(&inp), SlotDecision::Skip);
    }

    #[test]
    fn lex_min_validator_takes_skipped_slot() {
        let vs = ["alice", "bob"];
        let mut inp = base_inp("alice", "carol", &vs); // carol = offline leader
        inp.now_ms = 1000; // 1000ms > slot_timeout_ms=300
        // Alice is lex-min and a validator → she takes the slot.
        assert_eq!(should_mine_this_slot(&inp), SlotDecision::Mine);
    }

    #[test]
    fn non_validator_never_takes_skipped_slot() {
        let vs = ["alice", "bob"];
        let mut inp = base_inp("eve", "carol", &vs); // eve isn't a validator
        inp.now_ms = 1000;
        assert_eq!(should_mine_this_slot(&inp), SlotDecision::Skip);
    }

    #[test]
    fn pacing_blocks_even_when_leader() {
        let vs = ["alice"];
        let mut inp = base_inp("alice", "alice", &vs);
        inp.min_block_gap_ms = 500;
        inp.last_block_produced_ms = 100;
        inp.now_ms = 300; // only 200ms since last block; cap is 500ms
        assert_eq!(should_mine_this_slot(&inp), SlotDecision::Skip);
        inp.now_ms = 700; // now we're past the gap
        assert_eq!(should_mine_this_slot(&inp), SlotDecision::Mine);
    }
}
