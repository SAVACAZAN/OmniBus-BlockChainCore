//! Pre-computed Slot Calendar (Solana PoH-style) — port of `core/slot_calendar.zig`.
//!
//! Computes and caches the next 60 future slots so that:
//!   1. Frontend can display "next leader: ob1qzhrauq0x in 2.3s"
//!   2. Future-block pool can route TXs with target_slot=N
//!   3. Anti-fork: validators know deterministically who delivers each slot
//!
//! Leader election: sha256(slot_id_le8 || tip_hash_32)[0..8] as u64 → mod N.

use sha2::{Digest, Sha256};

pub const MAX_CALENDAR_SLOTS: usize = 60;
pub const SLOT_INTERVAL_MS: i64 = 1000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum SlotState {
    Future = 0,
    InFlight = 1,
    Finalized = 2,
    Missed = 3,
}

impl SlotState {
    pub fn as_str(self) -> &'static str {
        match self {
            SlotState::Future => "future",
            SlotState::InFlight => "in_flight",
            SlotState::Finalized => "finalized",
            SlotState::Missed => "missed",
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct SlotEntry {
    pub slot_id: u64,
    /// ob1q address bytes — all zeros means no leader (empty validator set).
    pub leader_address: [u8; 20],
    /// Absolute timestamp (ms) when the block is expected to arrive.
    pub expected_arrival_ms: i64,
    /// SHA-256 of the block that landed — zero-filled until finalized.
    pub placeholder_hash: [u8; 32],
    pub state: SlotState,
}

impl Default for SlotEntry {
    fn default() -> Self {
        Self {
            slot_id: 0,
            leader_address: [0u8; 20],
            expected_arrival_ms: 0,
            placeholder_hash: [0u8; 32],
            state: SlotState::Future,
        }
    }
}

pub struct SlotCalendar {
    pub entries: [SlotEntry; MAX_CALENDAR_SLOTS],
    /// Ring buffer head — index of the oldest non-finalized slot.
    pub head: usize,
    pub tip_height: u64,
    pub tip_hash: [u8; 32],
    pub computed_at_ms: i64,
}

impl SlotCalendar {
    pub fn new() -> Self {
        Self {
            entries: [SlotEntry::default(); MAX_CALENDAR_SLOTS],
            head: 0,
            tip_height: 0,
            tip_hash: [0u8; 32],
            computed_at_ms: 0,
        }
    }

    /// Recompute all 60 future slots from the current chain tip.
    pub fn recompute(
        &mut self,
        tip_height: u64,
        tip_hash: [u8; 32],
        now_ms: i64,
        validator_set: &[[u8; 20]],
    ) {
        self.tip_height = tip_height;
        self.tip_hash = tip_hash;
        self.computed_at_ms = now_ms;
        self.head = 0;

        for i in 0..MAX_CALENDAR_SLOTS {
            let slot_id = tip_height + 1 + i as u64;
            let arrival_ms = now_ms + (i as i64 + 1) * SLOT_INTERVAL_MS;
            self.entries[i] = SlotEntry {
                slot_id,
                leader_address: leader_for_slot(slot_id, tip_hash, validator_set),
                expected_arrival_ms: arrival_ms,
                placeholder_hash: [0u8; 32],
                state: SlotState::Future,
            };
        }
    }

    /// Get the entry for a given slot_id (linear scan over 60 entries).
    pub fn get_slot(&self, slot_id: u64) -> Option<&SlotEntry> {
        self.entries.iter().find(|e| e.slot_id == slot_id)
    }

    /// Mark a slot as finalized when its block arrives. Advances head past
    /// consecutive finalized entries.
    pub fn finalize_slot(&mut self, slot_id: u64, block_hash: [u8; 32]) {
        for i in 0..MAX_CALENDAR_SLOTS {
            if self.entries[i].slot_id == slot_id {
                self.entries[i].placeholder_hash = block_hash;
                self.entries[i].state = SlotState::Finalized;
                while self.head < MAX_CALENDAR_SLOTS
                    && self.entries[self.head].state == SlotState::Finalized
                {
                    self.head += 1;
                    if self.head >= MAX_CALENDAR_SLOTS {
                        self.head = 0;
                        break;
                    }
                }
                return;
            }
        }
    }

    /// Mark expired slots as missed; in-window-but-past as in_flight.
    pub fn prune_missed(&mut self, now_ms: i64) {
        for e in self.entries.iter_mut() {
            if e.state == SlotState::Future || e.state == SlotState::InFlight {
                let overdue = now_ms - e.expected_arrival_ms;
                if overdue >= SLOT_INTERVAL_MS * 2 {
                    e.state = SlotState::Missed;
                } else if overdue >= 0 {
                    e.state = SlotState::InFlight;
                }
            }
        }
    }

    /// Serialize the full calendar to JSON for RPC output.
    pub fn to_json(&self) -> String {
        let mut out = String::with_capacity(8192);
        out.push_str("{\"tip_height\":");
        out.push_str(&self.tip_height.to_string());
        out.push_str(",\"computed_at_ms\":");
        out.push_str(&self.computed_at_ms.to_string());
        out.push_str(",\"entries\":[");
        for (i, e) in self.entries.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str("{\"slot_id\":");
            out.push_str(&e.slot_id.to_string());
            out.push_str(",\"leader\":\"");
            out.push_str(&hex::encode(e.leader_address));
            out.push_str("\",\"expected_arrival_ms\":");
            out.push_str(&e.expected_arrival_ms.to_string());
            out.push_str(",\"placeholder_hash\":\"");
            out.push_str(&hex::encode(e.placeholder_hash));
            out.push_str("\",\"state\":\"");
            out.push_str(e.state.as_str());
            out.push_str("\"}");
        }
        out.push_str("]}");
        out
    }
}

impl Default for SlotCalendar {
    fn default() -> Self {
        Self::new()
    }
}

/// Deterministic leader election (pure function, no state).
///
/// Algorithm: sha256(slot_id_le8 || tip_hash_32)[0..8] as u64 → mod N.
/// Returns all-zeros if validator_set is empty.
pub fn leader_for_slot(
    slot_id: u64,
    tip_hash: [u8; 32],
    validator_set: &[[u8; 20]],
) -> [u8; 20] {
    if validator_set.is_empty() {
        return [0u8; 20];
    }
    let mut hasher = Sha256::new();
    hasher.update(slot_id.to_le_bytes());
    hasher.update(tip_hash);
    let digest = hasher.finalize();
    let idx_u64 = u64::from_le_bytes(digest[0..8].try_into().unwrap());
    let idx = (idx_u64 % validator_set.len() as u64) as usize;
    validator_set[idx]
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn make_validator_set(n: usize) -> Vec<[u8; 20]> {
        (0..n)
            .map(|i| {
                let mut a = [0u8; 20];
                a[0] = (i as u8) + 1;
                a
            })
            .collect()
    }

    #[test]
    fn init_produces_60_future_entries() {
        let cal = SlotCalendar::new();
        assert_eq!(cal.head, 0);
        for e in cal.entries.iter() {
            assert_eq!(e.state, SlotState::Future);
        }
    }

    #[test]
    fn recompute_sets_arrival_ms_and_slot_ids() {
        let mut cal = SlotCalendar::new();
        let vs = make_validator_set(2);
        cal.recompute(100, [0u8; 32], 10_000_000, &vs);
        assert_eq!(cal.entries[0].expected_arrival_ms, 10_001_000);
        assert_eq!(cal.entries[1].expected_arrival_ms, 10_002_000);
        assert_eq!(cal.entries[59].expected_arrival_ms, 10_060_000);
        assert_eq!(cal.entries[0].slot_id, 101);
        assert_eq!(cal.entries[59].slot_id, 160);
    }

    #[test]
    fn leader_for_slot_is_deterministic() {
        let vs = make_validator_set(3);
        let mut tip = [0u8; 32];
        tip[0..4].copy_from_slice(&[0xde, 0xad, 0xbe, 0xef]);
        let r1 = leader_for_slot(42, tip, &vs);
        let r2 = leader_for_slot(42, tip, &vs);
        assert_eq!(r1, r2);
    }

    #[test]
    fn leader_for_slot_distributes() {
        let vs = make_validator_set(4);
        let mut counts = [0u32; 4];
        for slot in 1..=60u64 {
            let leader = leader_for_slot(slot, [0u8; 32], &vs);
            for (vi, v) in vs.iter().enumerate() {
                if &leader == v {
                    counts[vi] += 1;
                    break;
                }
            }
        }
        // Each validator should get roughly 15 of 60 slots; allow 5..35.
        for c in counts {
            assert!(c >= 5 && c <= 35, "count out of range: {c}");
        }
    }

    #[test]
    fn finalize_slot_stores_hash_and_state() {
        let mut cal = SlotCalendar::new();
        let vs = make_validator_set(1);
        cal.recompute(10, [0u8; 32], 0, &vs);
        let block_hash = [0xABu8; 32];
        cal.finalize_slot(11, block_hash);
        assert_eq!(cal.entries[0].state, SlotState::Finalized);
        assert_eq!(cal.entries[0].placeholder_hash, block_hash);
    }

    #[test]
    fn prune_missed_marks_overdue() {
        let mut cal = SlotCalendar::new();
        let vs = make_validator_set(1);
        let now_ms = 1_000_000i64;
        cal.recompute(0, [0u8; 32], now_ms, &vs);

        cal.prune_missed(now_ms + 5_000);
        assert_eq!(cal.entries[0].state, SlotState::Missed);
        assert_eq!(cal.entries[1].state, SlotState::Missed);
        assert_eq!(cal.entries[2].state, SlotState::Missed);
        assert_eq!(cal.entries[3].state, SlotState::InFlight);
        assert_eq!(cal.entries[4].state, SlotState::InFlight);
        assert_eq!(cal.entries[5].state, SlotState::Future);
    }

    #[test]
    fn get_slot_returns_none_outside_window() {
        let mut cal = SlotCalendar::new();
        let vs = make_validator_set(1);
        cal.recompute(100, [0u8; 32], 0, &vs);
        assert!(cal.get_slot(101).is_some());
        assert!(cal.get_slot(160).is_some());
        assert!(cal.get_slot(100).is_none());
        assert!(cal.get_slot(161).is_none());
        assert!(cal.get_slot(0).is_none());
    }

    #[test]
    fn empty_validator_set_gives_zero_leader() {
        let mut cal = SlotCalendar::new();
        cal.recompute(0, [0u8; 32], 0, &[]);
        for e in cal.entries.iter() {
            assert_eq!(e.leader_address, [0u8; 20]);
        }
    }

    #[test]
    fn ring_buffer_head_advances() {
        let mut cal = SlotCalendar::new();
        let vs = make_validator_set(1);
        cal.recompute(0, [0u8; 32], 0, &vs);
        assert_eq!(cal.head, 0);

        cal.finalize_slot(1, [0x01u8; 32]);
        assert_eq!(cal.head, 1);
        cal.finalize_slot(2, [0x02u8; 32]);
        assert_eq!(cal.head, 2);

        // Non-consecutive: slot 4 finalized but slot 3 (entries[2]) is still future.
        cal.finalize_slot(4, [0x04u8; 32]);
        assert_eq!(cal.head, 2);
    }

    #[test]
    fn to_json_is_parseable() {
        let mut cal = SlotCalendar::new();
        let vs = make_validator_set(2);
        cal.recompute(5, [0u8; 32], 12345, &vs);
        let json = cal.to_json();
        assert!(json.contains("\"entries\""));
        assert!(json.contains("\"slot_id\""));
        assert!(json.contains("\"state\""));
        assert!(json.contains("\"future\""));
        assert!(json.contains("\"tip_height\":5"));
        assert!(json.contains("\"computed_at_ms\":12345"));
        let parsed: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
        assert!(parsed.get("entries").is_some());
    }
}
