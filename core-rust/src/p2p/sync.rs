//! Block sync state machine + sync messages.
//!
//! Port of core/sync.zig. Protocol:
//! `GetHeaders → Headers → GetBlocks → Blocks`. BlockHeader is the V3 130-byte
//! layout with miner_id (2026-04-26 upgrade).

use byteorder::{ByteOrder, LittleEndian};
use tracing::{debug, info};

use crate::p2p::{P2pError, Result};

// ── Wire size ───────────────────────────────────────────────────────────────

/// Max headers per GetHeaders response.
pub const MAX_HEADERS_PER_REQ: u16 = 2000;
/// Max blocks per GetBlocks response.
pub const MAX_BLOCKS_PER_REQ: u16 = 128;
/// Sync stall threshold (seconds without progress).
pub const STALL_THRESHOLD_SEC: i64 = 60;

// ── MsgGetHeaders ───────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
pub struct MsgGetHeaders {
    pub from_height: u64,
    pub max_count: u16,
}

impl MsgGetHeaders {
    pub const WIRE_SIZE: usize = 10;

    pub fn encode(&self) -> [u8; 10] {
        let mut buf = [0u8; 10];
        LittleEndian::write_u64(&mut buf[0..8], self.from_height);
        LittleEndian::write_u16(&mut buf[8..10], self.max_count);
        buf
    }

    pub fn decode(buf: &[u8]) -> Option<Self> {
        if buf.len() < 10 {
            return None;
        }
        Some(Self {
            from_height: LittleEndian::read_u64(&buf[0..8]),
            max_count: LittleEndian::read_u16(&buf[8..10]),
        })
    }
}

// ── BlockHeader (V3 130 bytes) ──────────────────────────────────────────────
//
// V3 (2026-04-26): 130 bytes per header. V2 was 88 bytes without miner_id.
// `prev_hash` and `merkle_root` are 32 raw bytes (hex-decoded). `miner_id` is
// the OmniBus wallet address as 42 ASCII bytes, zero-padded.

#[derive(Debug, Clone, Copy)]
pub struct BlockHeader {
    pub height: u64,
    pub timestamp: i64,
    pub prev_hash: [u8; 32],
    pub merkle_root: [u8; 32],
    pub nonce: u64,
    pub miner_id: [u8; 42],
}

impl BlockHeader {
    pub const WIRE_SIZE: usize = 130;

    pub fn encode(&self, buf: &mut [u8; 130]) {
        LittleEndian::write_u64(&mut buf[0..8], self.height);
        LittleEndian::write_i64(&mut buf[8..16], self.timestamp);
        buf[16..48].copy_from_slice(&self.prev_hash);
        buf[48..80].copy_from_slice(&self.merkle_root);
        LittleEndian::write_u64(&mut buf[80..88], self.nonce);
        buf[88..130].copy_from_slice(&self.miner_id);
    }

    pub fn decode(buf: &[u8]) -> Option<Self> {
        if buf.len() < 130 {
            return None;
        }
        let mut prev = [0u8; 32];
        let mut merkle = [0u8; 32];
        let mut mid = [0u8; 42];
        prev.copy_from_slice(&buf[16..48]);
        merkle.copy_from_slice(&buf[48..80]);
        mid.copy_from_slice(&buf[88..130]);
        Some(Self {
            height: LittleEndian::read_u64(&buf[0..8]),
            timestamp: LittleEndian::read_i64(&buf[8..16]),
            prev_hash: prev,
            merkle_root: merkle,
            nonce: LittleEndian::read_u64(&buf[80..88]),
            miner_id: mid,
        })
    }

    /// Trim trailing zero padding from miner_id.
    pub fn miner_id_slice(&self) -> &[u8] {
        let mut n = self.miner_id.len();
        while n > 0 && self.miner_id[n - 1] == 0 {
            n -= 1;
        }
        &self.miner_id[..n]
    }
}

// ── MsgHeaders ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct MsgHeaders {
    pub headers: Vec<BlockHeader>,
}

impl MsgHeaders {
    pub fn encode(&self) -> Vec<u8> {
        let count = (self.headers.len().min(MAX_HEADERS_PER_REQ as usize)) as u16;
        let size = 2 + (count as usize) * BlockHeader::WIRE_SIZE;
        let mut buf = vec![0u8; size];
        LittleEndian::write_u16(&mut buf[0..2], count);
        for i in 0..(count as usize) {
            let mut hbuf = [0u8; 130];
            self.headers[i].encode(&mut hbuf);
            let off = 2 + i * BlockHeader::WIRE_SIZE;
            buf[off..off + BlockHeader::WIRE_SIZE].copy_from_slice(&hbuf);
        }
        buf
    }

    pub fn decode(buf: &[u8]) -> Result<Self> {
        if buf.len() < 2 {
            return Err(P2pError::Truncated);
        }
        let count = LittleEndian::read_u16(&buf[0..2]) as usize;
        let need = 2 + count * BlockHeader::WIRE_SIZE;
        if buf.len() < need {
            return Err(P2pError::Truncated);
        }
        let mut headers = Vec::with_capacity(count);
        for i in 0..count {
            let start = 2 + i * BlockHeader::WIRE_SIZE;
            let h = BlockHeader::decode(&buf[start..start + BlockHeader::WIRE_SIZE])
                .ok_or(P2pError::InvalidHeader)?;
            headers.push(h);
        }
        Ok(Self { headers })
    }
}

// ── MsgBlocks (same shape as MsgHeaders on the wire) ───────────────────────

#[derive(Debug, Clone)]
pub struct MsgBlocks {
    pub headers: Vec<BlockHeader>,
}

impl MsgBlocks {
    pub fn encode(&self) -> Vec<u8> {
        MsgHeaders {
            headers: self.headers.clone(),
        }
        .encode()
    }

    pub fn decode(buf: &[u8]) -> Result<Self> {
        let h = MsgHeaders::decode(buf)?;
        Ok(Self { headers: h.headers })
    }
}

// ── MsgGetBlocks ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
pub struct MsgGetBlocks {
    pub from_height: u64,
    pub max_count: u16,
}

impl MsgGetBlocks {
    pub const WIRE_SIZE: usize = 10;

    pub fn encode(&self) -> [u8; 10] {
        let mut buf = [0u8; 10];
        LittleEndian::write_u64(&mut buf[0..8], self.from_height);
        LittleEndian::write_u16(&mut buf[8..10], self.max_count);
        buf
    }

    pub fn decode(buf: &[u8]) -> Option<Self> {
        if buf.len() < 10 {
            return None;
        }
        Some(Self {
            from_height: LittleEndian::read_u64(&buf[0..8]),
            max_count: LittleEndian::read_u16(&buf[8..10]),
        })
    }
}

// ── SyncState / SyncManager ────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncStatus {
    Idle,
    Requesting,
    Downloading,
    Synced,
}

#[derive(Debug, Clone, Copy)]
pub struct SyncState {
    pub status: SyncStatus,
    pub local_height: u64,
    pub peer_height: u64,
    pub blocks_pending: u64,
    pub started_at: i64,
    pub last_progress: i64,
}

impl SyncState {
    pub fn new(local_height: u64) -> Self {
        Self {
            status: SyncStatus::Idle,
            local_height,
            peer_height: 0,
            blocks_pending: 0,
            started_at: 0,
            last_progress: 0,
        }
    }

    pub fn is_behind(&self) -> bool {
        self.local_height < self.peer_height
    }

    pub fn progress_pct(&self) -> f64 {
        if self.peer_height == 0 {
            return 100.0;
        }
        (self.local_height as f64) / (self.peer_height as f64) * 100.0
    }
}

pub struct SyncManager {
    pub state: SyncState,
}

impl SyncManager {
    pub fn new(local_height: u64) -> Self {
        Self {
            state: SyncState::new(local_height),
        }
    }

    /// Notify peer's height. Returns encoded GetHeaders if we are behind.
    pub fn on_peer_height(&mut self, peer_height: u64) -> Option<[u8; 10]> {
        self.state.peer_height = peer_height;
        if !self.state.is_behind() {
            self.state.status = SyncStatus::Synced;
            return None;
        }
        self.state.status = SyncStatus::Requesting;
        self.state.started_at = now_secs();
        self.state.blocks_pending = peer_height - self.state.local_height;
        info!(
            "[SYNC] Behind by {} blocks — requesting headers from {}",
            self.state.blocks_pending, self.state.local_height
        );
        Some(
            MsgGetHeaders {
                from_height: self.state.local_height,
                max_count: MAX_HEADERS_PER_REQ,
            }
            .encode(),
        )
    }

    /// On headers received, decide what blocks to request.
    pub fn on_headers_received(&mut self, headers: &MsgHeaders) -> Option<[u8; 10]> {
        if headers.headers.is_empty() {
            self.state.status = SyncStatus::Synced;
            debug!("[SYNC] No new headers — already synced");
            return None;
        }
        self.state.status = SyncStatus::Downloading;
        info!(
            "[SYNC] Received {} headers — requesting blocks from {}",
            headers.headers.len(),
            self.state.local_height
        );
        Some(
            MsgGetBlocks {
                from_height: self.state.local_height,
                max_count: MAX_BLOCKS_PER_REQ,
            }
            .encode(),
        )
    }

    /// Notify a single block applied.
    pub fn on_block_applied(&mut self, new_height: u64) {
        self.state.local_height = new_height;
        self.state.last_progress = now_secs();
        if !self.state.is_behind() {
            self.state.status = SyncStatus::Synced;
            let elapsed = self.state.last_progress - self.state.started_at;
            info!("[SYNC] COMPLETE — {} blocks in {}s", new_height, elapsed);
        }
    }

    /// Notify a batch of `count` blocks applied.
    pub fn on_blocks_received(&mut self, count: u32) {
        if count == 0 {
            return;
        }
        self.state.local_height += count as u64;
        self.state.last_progress = now_secs();
        info!(
            "[SYNC] Received {} blocks — local_height now {}",
            count, self.state.local_height
        );
        if !self.state.is_behind() {
            self.state.status = SyncStatus::Synced;
            let elapsed = self.state.last_progress - self.state.started_at;
            info!(
                "[SYNC] COMPLETE — height {} in {}s",
                self.state.local_height, elapsed
            );
        }
    }

    /// True if downloading hasn't advanced for >STALL_THRESHOLD_SEC seconds.
    pub fn is_stalled(&self) -> bool {
        if self.state.status != SyncStatus::Downloading {
            return false;
        }
        now_secs() - self.state.last_progress > STALL_THRESHOLD_SEC
    }

    /// If stalled, reset status to Requesting for retry.
    pub fn retry_if_stalled(&mut self) -> bool {
        if !self.is_stalled() {
            return false;
        }
        info!("[SYNC] Stalled detected — resetting to requesting");
        self.state.status = SyncStatus::Requesting;
        self.state.last_progress = now_secs();
        true
    }

    pub fn is_synced(&self) -> bool {
        self.state.status == SyncStatus::Synced || !self.state.is_behind()
    }
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

// TODO(integrator): `buildHeadersResponse` + `applyBlock` need a real
// Blockchain type — port when chain storage lands in Rust.
