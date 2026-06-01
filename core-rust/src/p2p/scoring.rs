//! Peer scoring + persistent banlist.
//!
//! Port of core/peer_scoring.zig. Scoring matches Bitcoin Core's misbehavior
//! model: each peer accumulates ±delta per event; below `BAN_THRESHOLD` the
//! peer is auto-banned for `BAN_DURATION_SEC`. Bans survive eviction from the
//! in-memory scoring table via a separate persistent ban list.

use byteorder::{ByteOrder, LittleEndian};

use crate::p2p::{P2pError, Result};

// ── Constants ───────────────────────────────────────────────────────────────

pub const BAN_THRESHOLD: i32 = -100;
pub const BAN_DURATION_SEC: i64 = 86_400; // 24h
pub const MAX_TRACKED_PEERS: usize = 256;
pub const MAX_BANNED_PEERS: usize = 1024;

// ── ScoreEvent ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScoreEvent {
    ValidBlock,
    UsefulHeaders,
    PingResponse,
    ValidTx,
    Timeout,
    InvalidTx,
    InvalidBlock,
    MalformedData,
    DoubleSpendAttempt,
    InvalidHeaders,
}

impl ScoreEvent {
    pub fn delta(self) -> i32 {
        match self {
            ScoreEvent::ValidBlock => 1,
            ScoreEvent::UsefulHeaders => 2,
            ScoreEvent::PingResponse => 1,
            ScoreEvent::ValidTx => 1,
            ScoreEvent::Timeout => -5,
            ScoreEvent::InvalidTx => -10,
            ScoreEvent::InvalidBlock => -50,
            ScoreEvent::MalformedData => -20,
            ScoreEvent::DoubleSpendAttempt => -100,
            ScoreEvent::InvalidHeaders => -30,
        }
    }
}

// ── PeerScore ───────────────────────────────────────────────────────────────

pub type PeerId = [u8; 16];

#[derive(Debug, Clone, Copy)]
pub struct PeerScore {
    pub peer_id: PeerId,
    pub score: i32,
    pub valid_blocks: u32,
    pub violations: u32,
    pub banned: bool,
    pub ban_until: i64,
    pub first_seen: i64,
    pub last_active: i64,
}

impl PeerScore {
    pub fn new(peer_id: PeerId) -> Self {
        let now = now_secs();
        Self {
            peer_id,
            score: 0,
            valid_blocks: 0,
            violations: 0,
            banned: false,
            ban_until: 0,
            first_seen: now,
            last_active: now,
        }
    }

    pub fn apply_event(&mut self, event: ScoreEvent) {
        let d = event.delta();
        self.score += d;
        self.last_active = now_secs();
        if d > 0 {
            self.valid_blocks += 1;
        } else {
            self.violations += 1;
        }
        if self.score <= BAN_THRESHOLD && !self.banned {
            self.banned = true;
            self.ban_until = now_secs() + BAN_DURATION_SEC;
        }
    }

    pub fn is_ban_expired(&self) -> bool {
        if !self.banned {
            return true;
        }
        now_secs() >= self.ban_until
    }

    pub fn check_unban(&mut self) {
        if self.banned && self.is_ban_expired() {
            self.banned = false;
            self.score = 0;
            self.violations = 0;
        }
    }

    pub fn trust_level(&self) -> u8 {
        if self.banned {
            return 0;
        }
        if self.score <= 0 {
            return 10;
        }
        if self.score >= 100 {
            return 100;
        }
        self.score as u8
    }
}

// ── BanRecord (persistent) ──────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
pub struct BanRecord {
    pub peer_id: PeerId,
    pub ban_until: i64,
    pub violations: u32,
}

const BAN_RECORD_SIZE: usize = 16 + 8 + 4;

// ── PeerScoringEngine ──────────────────────────────────────────────────────

pub struct PeerScoringEngine {
    peers: Vec<PeerScore>,
    total_bans: u32,
    /// Persistent ban list — survives eviction from `peers`.
    banned: Vec<BanRecord>,
}

impl PeerScoringEngine {
    pub fn new() -> Self {
        Self {
            peers: Vec::with_capacity(MAX_TRACKED_PEERS),
            total_bans: 0,
            banned: Vec::with_capacity(MAX_BANNED_PEERS),
        }
    }

    fn find_banned(&self, peer_id: PeerId) -> Option<usize> {
        self.banned.iter().position(|b| b.peer_id == peer_id)
    }

    fn upsert_banned(&mut self, peer_id: PeerId, ban_until: i64, violations: u32) {
        if let Some(idx) = self.find_banned(peer_id) {
            if ban_until > self.banned[idx].ban_until {
                self.banned[idx].ban_until = ban_until;
            }
            self.banned[idx].violations = violations;
            return;
        }
        if self.banned.len() < MAX_BANNED_PEERS {
            self.banned.push(BanRecord {
                peer_id,
                ban_until,
                violations,
            });
            return;
        }
        // Full — overwrite the entry that expires soonest, but only if the new
        // ban lasts longer. Never silently drop an active ban for a shorter one.
        let mut oldest_idx = 0;
        let mut oldest_until = self.banned[0].ban_until;
        for (i, b) in self.banned.iter().enumerate() {
            if b.ban_until < oldest_until {
                oldest_until = b.ban_until;
                oldest_idx = i;
            }
        }
        if ban_until > self.banned[oldest_idx].ban_until {
            self.banned[oldest_idx] = BanRecord {
                peer_id,
                ban_until,
                violations,
            };
        }
    }

    /// Drop expired ban records. Returns number dropped.
    pub fn cleanup_expired_bans(&mut self, now: i64) -> usize {
        let before = self.banned.len();
        self.banned.retain(|b| b.ban_until > now);
        before - self.banned.len()
    }

    /// Get or create peer score. If peer is in persistent ban list and ban is
    /// active, the returned `PeerScore` will reflect `banned=true`.
    pub fn get_or_create(&mut self, peer_id: PeerId) -> &mut PeerScore {
        if let Some(pos) = self.peers.iter().position(|p| p.peer_id == peer_id) {
            return &mut self.peers[pos];
        }

        let mut fresh = PeerScore::new(peer_id);
        if let Some(idx) = self.find_banned(peer_id) {
            let rec = self.banned[idx];
            if rec.ban_until > now_secs() {
                fresh.banned = true;
                fresh.ban_until = rec.ban_until;
                fresh.score = BAN_THRESHOLD;
                fresh.violations = rec.violations;
            }
        }

        if self.peers.len() < MAX_TRACKED_PEERS {
            self.peers.push(fresh);
            let idx = self.peers.len() - 1;
            return &mut self.peers[idx];
        }

        // Eviction: prefer non-banned peer with lowest score. If all are
        // banned, persist them and evict the one whose ban expires soonest.
        let mut lowest_idx: Option<usize> = None;
        let mut lowest_score = i32::MAX;
        for (i, p) in self.peers.iter().enumerate() {
            if p.banned {
                continue;
            }
            if p.score < lowest_score {
                lowest_score = p.score;
                lowest_idx = Some(i);
            }
        }
        let evict_idx = if let Some(i) = lowest_idx {
            i
        } else {
            // All slots banned — copy each into persistent list first.
            let snapshot: Vec<(PeerId, i64, u32)> = self
                .peers
                .iter()
                .map(|p| (p.peer_id, p.ban_until, p.violations))
                .collect();
            let mut oldest_idx = 0;
            let mut oldest_until = self.peers[0].ban_until;
            for (i, p) in self.peers.iter().enumerate() {
                if p.ban_until < oldest_until {
                    oldest_until = p.ban_until;
                    oldest_idx = i;
                }
            }
            for (pid, bu, v) in snapshot {
                self.upsert_banned(pid, bu, v);
            }
            oldest_idx
        };
        self.peers[evict_idx] = fresh;
        &mut self.peers[evict_idx]
    }

    pub fn score_event(&mut self, peer_id: PeerId, event: ScoreEvent) {
        let was_banned;
        let (became_banned, ban_until, violations) = {
            let peer = self.get_or_create(peer_id);
            was_banned = peer.banned;
            peer.apply_event(event);
            (!was_banned && peer.banned, peer.ban_until, peer.violations)
        };
        if became_banned {
            self.total_bans += 1;
            self.upsert_banned(peer_id, ban_until, violations);
        }
    }

    /// Persistent ban list first, then in-memory table.
    pub fn is_allowed(&mut self, peer_id: PeerId) -> bool {
        let now = now_secs();
        if let Some(idx) = self.find_banned(peer_id) {
            if self.banned[idx].ban_until > now {
                return false;
            }
            self.cleanup_expired_bans(now);
        }
        for p in self.peers.iter_mut() {
            if p.peer_id == peer_id {
                p.check_unban();
                return !p.banned;
            }
        }
        true // unknown peer = allowed
    }

    pub fn banned_count(&self) -> usize {
        self.peers.iter().filter(|p| p.banned).count()
    }

    pub fn persistent_ban_count(&self) -> usize {
        self.banned.len()
    }

    pub fn total_bans(&self) -> u32 {
        self.total_bans
    }

    /// Serialize persistent ban list. Layout:
    /// `[count:u32 LE][peer_id:16][ban_until:i64 LE][violations:u32 LE]...`
    pub fn serialize_bans(&self, out: &mut [u8]) -> Result<usize> {
        let need = 4 + self.banned.len() * BAN_RECORD_SIZE;
        if out.len() < need {
            return Err(P2pError::BufferTooSmall);
        }
        LittleEndian::write_u32(&mut out[0..4], self.banned.len() as u32);
        let mut off = 4;
        for b in &self.banned {
            out[off..off + 16].copy_from_slice(&b.peer_id);
            LittleEndian::write_i64(&mut out[off + 16..off + 24], b.ban_until);
            LittleEndian::write_u32(&mut out[off + 24..off + 28], b.violations);
            off += BAN_RECORD_SIZE;
        }
        Ok(need)
    }

    /// Restore persistent bans from a buffer. Expired entries are dropped.
    pub fn deserialize_bans(&mut self, buf: &[u8]) -> Result<()> {
        if buf.len() < 4 {
            return Err(P2pError::Truncated);
        }
        let count = LittleEndian::read_u32(&buf[0..4]) as usize;
        if buf.len() < 4 + count * BAN_RECORD_SIZE {
            return Err(P2pError::Truncated);
        }
        let now = now_secs();
        self.banned.clear();
        let mut off = 4;
        for _ in 0..count {
            if self.banned.len() >= MAX_BANNED_PEERS {
                break;
            }
            let mut pid = [0u8; 16];
            pid.copy_from_slice(&buf[off..off + 16]);
            let ban_until = LittleEndian::read_i64(&buf[off + 16..off + 24]);
            let violations = LittleEndian::read_u32(&buf[off + 24..off + 28]);
            off += BAN_RECORD_SIZE;
            if ban_until > now {
                self.banned.push(BanRecord {
                    peer_id: pid,
                    ban_until,
                    violations,
                });
            }
        }
        Ok(())
    }
}

impl Default for PeerScoringEngine {
    fn default() -> Self {
        Self::new()
    }
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
