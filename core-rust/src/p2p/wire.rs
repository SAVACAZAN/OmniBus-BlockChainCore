//! Wire-protocol types and codecs for OmniBus P2P.
//!
//! BYTE-FOR-BYTE compatible with core/p2p/wire.zig. All multi-byte ints are
//! little-endian on the wire (matches Zig `std.mem.writeInt(... .little)`).
//!
//! Message frame:
//! ```text
//!   [0]    version    u8
//!   [1]    msg_type   u8
//!   [2..6] payload_len u32 LE
//!   [6..8] checksum   u16 LE
//!   [8]    flags      u8
//!   [9..]  payload    []u8
//! ```

use byteorder::{ByteOrder, LittleEndian};

use crate::p2p::{P2pError, Result};
use crate::types::{BloomFilter, SpvBlockHeader};

// ── Protocol constants ──────────────────────────────────────────────────────

/// Wire protocol version.
///
/// V3 (2026-04-26 PM): BlockHeader is 130 bytes — extra 42 bytes carry miner_id.
/// V2 (2026-04-26 AM): block hashes are 32 raw bytes, miner_id is 42 ASCII.
/// V1 was 80 bytes with 32-char hash trunchation.
pub const P2P_VERSION: u8 = 3;

/// Max P2P payload size (1 MB).
pub const P2P_MAX_MSG_BYTES: u32 = 1_048_576;

/// Fixed message header size.
pub const MSG_HEADER_SIZE: usize = 9;

// ── PEX constants ───────────────────────────────────────────────────────────

pub const PEX_MAX_PEERS: usize = 100;
pub const PEX_PEER_SIZE: usize = 6; // 4 bytes IP + 2 bytes port LE

// ── SPV constants ───────────────────────────────────────────────────────────

pub const SPV_HEADER_SIZE: usize = 124;
pub const SPV_MAX_HEADERS_PER_MSG: u32 = 2000;

// ── MessageType — mirror of network.zig MessageType enum ───────────────────
//
// The wire encoding is the enum's tag index as a u8 (Zig `@intFromEnum`).
// Order MUST match core/network.zig exactly.

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageType {
    Ping = 0,
    Pong = 1,
    Block = 2,
    Transaction = 3,
    SyncRequest = 4,
    SyncResponse = 5,
    PeerList = 6,
    MiningStart = 7,
    MiningStop = 8,
    // Gossip (B6)
    Inv = 9,
    GetData = 10,
    TxGossip = 11,
    BlockGossip = 12,
    GetBlocks = 13,
    // PEX (B12)
    GetPeers = 14,
    // SPV
    GetHeadersP2p = 15,
    HeadersP2p = 16,
    GetMerkleProofP2p = 17,
    MerkleProofP2p = 18,
    FilterLoad = 19,
    // 3-way handshake
    Hello = 20,
    Welcome = 21,
    Stable = 22,
}

impl MessageType {
    pub fn from_u8(v: u8) -> Option<Self> {
        use MessageType::*;
        Some(match v {
            0 => Ping,
            1 => Pong,
            2 => Block,
            3 => Transaction,
            4 => SyncRequest,
            5 => SyncResponse,
            6 => PeerList,
            7 => MiningStart,
            8 => MiningStop,
            9 => Inv,
            10 => GetData,
            11 => TxGossip,
            12 => BlockGossip,
            13 => GetBlocks,
            14 => GetPeers,
            15 => GetHeadersP2p,
            16 => HeadersP2p,
            17 => GetMerkleProofP2p,
            18 => MerkleProofP2p,
            19 => FilterLoad,
            20 => Hello,
            21 => Welcome,
            22 => Stable,
            _ => return None,
        })
    }
}

// ── Message header ──────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MsgHeader {
    pub version: u8,
    pub msg_type: u8,
    pub payload_len: u32,
    pub checksum: u16,
    pub flags: u8,
}

impl MsgHeader {
    pub fn encode(&self, buf: &mut [u8; MSG_HEADER_SIZE]) {
        buf[0] = self.version;
        buf[1] = self.msg_type;
        LittleEndian::write_u32(&mut buf[2..6], self.payload_len);
        LittleEndian::write_u16(&mut buf[6..8], self.checksum);
        buf[8] = self.flags;
    }

    pub fn decode(buf: &[u8; MSG_HEADER_SIZE]) -> Self {
        Self {
            version: buf[0],
            msg_type: buf[1],
            payload_len: LittleEndian::read_u32(&buf[2..6]),
            checksum: LittleEndian::read_u16(&buf[6..8]),
            flags: buf[8],
        }
    }
}

/// Simple checksum: sum of bytes mod 2^16. Matches Zig `calcChecksum`.
pub fn calc_checksum(data: &[u8]) -> u16 {
    let mut sum: u32 = 0;
    for &b in data {
        sum = sum.wrapping_add(b as u32);
    }
    sum as u16
}

// ── MsgPing (41 bytes) ──────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
pub struct MsgPing {
    pub node_id: [u8; 32],
    pub height: u64,
    pub version: u8,
}

impl MsgPing {
    pub const WIRE_SIZE: usize = 41;

    pub fn encode(&self) -> Vec<u8> {
        let mut buf = vec![0u8; Self::WIRE_SIZE];
        buf[0..32].copy_from_slice(&self.node_id);
        LittleEndian::write_u64(&mut buf[32..40], self.height);
        buf[40] = self.version;
        buf
    }

    pub fn decode(data: &[u8]) -> Option<Self> {
        if data.len() < Self::WIRE_SIZE {
            return None;
        }
        let mut id = [0u8; 32];
        id.copy_from_slice(&data[0..32]);
        Some(Self {
            node_id: id,
            height: LittleEndian::read_u64(&data[32..40]),
            version: data[40],
        })
    }
}

// ── MsgHello (79 bytes) ─────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
pub struct MsgHello {
    pub node_id: [u8; 32],
    pub chain_magic: [u8; 4],
    pub listen_port: u16,
    pub height: u64,
    pub version: u8,
    pub genesis_hash: [u8; 32],
}

impl MsgHello {
    pub const WIRE_SIZE: usize = 79;

    pub fn encode(&self) -> Vec<u8> {
        let mut buf = vec![0u8; Self::WIRE_SIZE];
        buf[0..32].copy_from_slice(&self.node_id);
        buf[32..36].copy_from_slice(&self.chain_magic);
        LittleEndian::write_u16(&mut buf[36..38], self.listen_port);
        LittleEndian::write_u64(&mut buf[38..46], self.height);
        buf[46] = self.version;
        buf[47..79].copy_from_slice(&self.genesis_hash);
        buf
    }

    /// Decode; tolerates legacy 47-byte HELLO with zero genesis (matches Zig).
    pub fn decode(data: &[u8]) -> Option<Self> {
        if data.len() < 47 {
            return None;
        }
        let mut id = [0u8; 32];
        id.copy_from_slice(&data[0..32]);
        let mut magic = [0u8; 4];
        magic.copy_from_slice(&data[32..36]);
        let mut ghash = [0u8; 32];
        if data.len() >= 79 {
            ghash.copy_from_slice(&data[47..79]);
        }
        Some(Self {
            node_id: id,
            chain_magic: magic,
            listen_port: LittleEndian::read_u16(&data[36..38]),
            height: LittleEndian::read_u64(&data[38..46]),
            version: data[46],
            genesis_hash: ghash,
        })
    }
}

// ── MsgWelcome (46 bytes) ──────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
pub struct MsgWelcome {
    pub node_id: [u8; 32],
    pub chain_magic: [u8; 4],
    pub height: u64,
    pub accepted: u8,
    pub reason: u8,
}

impl MsgWelcome {
    pub const WIRE_SIZE: usize = 46;

    pub const REASON_OK: u8 = 0;
    pub const REASON_WRONG_CHAIN: u8 = 1;
    pub const REASON_TOO_MANY_PEERS: u8 = 2;
    pub const REASON_BANNED: u8 = 3;
    pub const REASON_DUPLICATE_ID: u8 = 4;

    pub fn encode(&self) -> Vec<u8> {
        let mut buf = vec![0u8; Self::WIRE_SIZE];
        buf[0..32].copy_from_slice(&self.node_id);
        buf[32..36].copy_from_slice(&self.chain_magic);
        LittleEndian::write_u64(&mut buf[36..44], self.height);
        buf[44] = self.accepted;
        buf[45] = self.reason;
        buf
    }

    pub fn decode(data: &[u8]) -> Option<Self> {
        if data.len() < Self::WIRE_SIZE {
            return None;
        }
        let mut id = [0u8; 32];
        id.copy_from_slice(&data[0..32]);
        let mut magic = [0u8; 4];
        magic.copy_from_slice(&data[32..36]);
        Some(Self {
            node_id: id,
            chain_magic: magic,
            height: LittleEndian::read_u64(&data[36..44]),
            accepted: data[44],
            reason: data[45],
        })
    }
}

// ── MsgStable (10 bytes) ────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
pub struct MsgStable {
    pub confirmed_height: u64,
    pub peer_count: u16,
}

impl MsgStable {
    pub const WIRE_SIZE: usize = 10;

    pub fn encode(&self) -> Vec<u8> {
        let mut buf = vec![0u8; Self::WIRE_SIZE];
        LittleEndian::write_u64(&mut buf[0..8], self.confirmed_height);
        LittleEndian::write_u16(&mut buf[8..10], self.peer_count);
        buf
    }

    pub fn decode(data: &[u8]) -> Option<Self> {
        if data.len() < Self::WIRE_SIZE {
            return None;
        }
        Some(Self {
            confirmed_height: LittleEndian::read_u64(&data[0..8]),
            peer_count: LittleEndian::read_u16(&data[8..10]),
        })
    }
}

// ── PEX (Peer Exchange) ─────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct MsgPeerAddr {
    pub ip: [u8; 4],
    pub port: u16,
}

/// Encode peer list: `[count:u16 LE][peer0: 4B ip + 2B port LE][peer1: ...]`
pub fn encode_peer_list(peers: &[MsgPeerAddr]) -> Vec<u8> {
    let count = peers.len().min(PEX_MAX_PEERS) as u16;
    let total = 2 + (count as usize) * PEX_PEER_SIZE;
    let mut buf = vec![0u8; total];
    LittleEndian::write_u16(&mut buf[0..2], count);
    for i in 0..(count as usize) {
        let off = 2 + i * PEX_PEER_SIZE;
        buf[off..off + 4].copy_from_slice(&peers[i].ip);
        LittleEndian::write_u16(&mut buf[off + 4..off + 6], peers[i].port);
    }
    buf
}

/// Decode peer list. Mirrors Zig `decodePeerList`.
pub fn decode_peer_list(data: &[u8]) -> Result<Vec<MsgPeerAddr>> {
    if data.len() < 2 {
        return Err(P2pError::InvalidPayload);
    }
    let count = LittleEndian::read_u16(&data[0..2]) as usize;
    if count > PEX_MAX_PEERS {
        return Err(P2pError::TooManyPeers);
    }
    if data.len() < 2 + count * PEX_PEER_SIZE {
        return Err(P2pError::InvalidPayload);
    }
    let mut peers = Vec::with_capacity(count);
    for i in 0..count {
        let off = 2 + i * PEX_PEER_SIZE;
        let mut ip = [0u8; 4];
        ip.copy_from_slice(&data[off..off + 4]);
        peers.push(MsgPeerAddr {
            ip,
            port: LittleEndian::read_u16(&data[off + 4..off + 6]),
        });
    }
    Ok(peers)
}

// ── MsgBlockAnnounce (90 bytes, V2 layout) ─────────────────────────────────
//
// [0..8]   block_height u64 LE
// [8..40]  block_hash   32 raw bytes
// [40..82] miner_id     42 ASCII (NUL-padded)
// [82..90] reward_sat   u64 LE

#[derive(Debug, Clone, Copy)]
pub struct MsgBlockAnnounce {
    pub block_height: u64,
    pub block_hash: [u8; 32],
    pub miner_id: [u8; 42],
    pub reward_sat: u64,
}

impl MsgBlockAnnounce {
    pub const WIRE_SIZE: usize = 90;

    pub fn encode(&self) -> Vec<u8> {
        let mut buf = vec![0u8; Self::WIRE_SIZE];
        LittleEndian::write_u64(&mut buf[0..8], self.block_height);
        buf[8..40].copy_from_slice(&self.block_hash);
        buf[40..82].copy_from_slice(&self.miner_id);
        LittleEndian::write_u64(&mut buf[82..90], self.reward_sat);
        buf
    }

    pub fn decode(data: &[u8]) -> Option<Self> {
        if data.len() < Self::WIRE_SIZE {
            return None;
        }
        let mut bh = [0u8; 32];
        bh.copy_from_slice(&data[8..40]);
        let mut mi = [0u8; 42];
        mi.copy_from_slice(&data[40..82]);
        Some(Self {
            block_height: LittleEndian::read_u64(&data[0..8]),
            block_hash: bh,
            miner_id: mi,
            reward_sat: LittleEndian::read_u64(&data[82..90]),
        })
    }

    /// Slice of miner_id without trailing zero padding.
    pub fn miner_id_slice(&self) -> &[u8] {
        let mut n = self.miner_id.len();
        while n > 0 && self.miner_id[n - 1] == 0 {
            n -= 1;
        }
        &self.miner_id[..n]
    }
}

// ── SPV codecs ──────────────────────────────────────────────────────────────

/// Encode getheaders_p2p: `[start_height:u32 LE][count:u32 LE]` = 8 bytes.
pub fn encode_get_headers(start_height: u32, count: u32, buf: &mut [u8; 8]) {
    LittleEndian::write_u32(&mut buf[0..4], start_height);
    LittleEndian::write_u32(&mut buf[4..8], count);
}

pub fn decode_get_headers(data: &[u8]) -> Option<(u32, u32)> {
    if data.len() < 8 {
        return None;
    }
    Some((
        LittleEndian::read_u32(&data[0..4]),
        LittleEndian::read_u32(&data[4..8]),
    ))
}

/// Serialize SPV header into 124-byte wire format.
/// Layout: index(8) + timestamp(8) + prev(32) + merkle(32) + hash(32) + difficulty(4) + nonce(8)
pub fn serialize_spv_header(header: &SpvBlockHeader, buf: &mut [u8; SPV_HEADER_SIZE]) {
    LittleEndian::write_u64(&mut buf[0..8], header.index);
    LittleEndian::write_i64(&mut buf[8..16], header.timestamp);
    buf[16..48].copy_from_slice(&header.previous_hash);
    buf[48..80].copy_from_slice(&header.merkle_root);
    buf[80..112].copy_from_slice(&header.hash);
    LittleEndian::write_u32(&mut buf[112..116], header.difficulty);
    LittleEndian::write_u64(&mut buf[116..124], header.nonce);
}

pub fn deserialize_spv_header(data: &[u8; SPV_HEADER_SIZE]) -> SpvBlockHeader {
    let mut h = SpvBlockHeader::zero();
    h.index = LittleEndian::read_u64(&data[0..8]);
    h.timestamp = LittleEndian::read_i64(&data[8..16]);
    h.previous_hash.copy_from_slice(&data[16..48]);
    h.merkle_root.copy_from_slice(&data[48..80]);
    h.hash.copy_from_slice(&data[80..112]);
    h.difficulty = LittleEndian::read_u32(&data[112..116]);
    h.nonce = LittleEndian::read_u64(&data[116..124]);
    h
}

/// Encode headers_p2p batch: `[count:u32 LE][header0:124]...`
pub fn encode_headers_batch(headers: &[SpvBlockHeader]) -> Vec<u8> {
    let count = (headers.len().min(SPV_MAX_HEADERS_PER_MSG as usize)) as u32;
    let total = 4 + (count as usize) * SPV_HEADER_SIZE;
    let mut buf = vec![0u8; total];
    LittleEndian::write_u32(&mut buf[0..4], count);
    for i in 0..(count as usize) {
        let off = 4 + i * SPV_HEADER_SIZE;
        let mut tmp = [0u8; SPV_HEADER_SIZE];
        serialize_spv_header(&headers[i], &mut tmp);
        buf[off..off + SPV_HEADER_SIZE].copy_from_slice(&tmp);
    }
    buf
}

pub fn decode_headers_batch(data: &[u8]) -> Result<Vec<SpvBlockHeader>> {
    if data.len() < 4 {
        return Err(P2pError::InvalidPayload);
    }
    let count = LittleEndian::read_u32(&data[0..4]) as usize;
    if count > SPV_MAX_HEADERS_PER_MSG as usize {
        return Err(P2pError::TooManyHeaders);
    }
    if data.len() < 4 + count * SPV_HEADER_SIZE {
        return Err(P2pError::InvalidPayload);
    }
    let mut headers = Vec::with_capacity(count);
    for i in 0..count {
        let off = 4 + i * SPV_HEADER_SIZE;
        let mut arr = [0u8; SPV_HEADER_SIZE];
        arr.copy_from_slice(&data[off..off + SPV_HEADER_SIZE]);
        headers.push(deserialize_spv_header(&arr));
    }
    Ok(headers)
}

/// Encode bloom filter: `[num_hash_funcs:u8][bits:512]` = 513 bytes.
pub fn encode_bloom_filter(filter: &BloomFilter, buf: &mut [u8; 513]) {
    buf[0] = filter.num_hash_funcs;
    buf[1..513].copy_from_slice(&filter.bits);
}

pub fn decode_bloom_filter(data: &[u8]) -> Option<BloomFilter> {
    if data.len() < 513 {
        return None;
    }
    let mut f = BloomFilter::new(data[0]);
    f.bits.copy_from_slice(&data[1..513]);
    Some(f)
}
