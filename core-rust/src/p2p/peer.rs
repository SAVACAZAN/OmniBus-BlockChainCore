//! Per-peer connection state + framed send/recv over async TCP.
//!
//! Port of core/p2p/peer.zig + knock-knock duplicate detection from
//! core/p2p/knock.zig. Uses `tokio::net::TcpStream` instead of Zig's
//! blocking `std.net.Stream`.

use std::io;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, UdpSocket};
use tokio::time::{timeout, Duration};
use tracing::{debug, warn};

use crate::p2p::wire::{
    calc_checksum, MessageType, MsgBlockAnnounce, MsgHello, MsgHeader, MsgPing, MsgStable,
    MsgWelcome, MSG_HEADER_SIZE, P2P_MAX_MSG_BYTES, P2P_VERSION,
};
use crate::p2p::{P2pError, Result, RATE_LIMIT_BYTES_PER_SEC, RATE_LIMIT_MSG_PER_SEC};

// ── Direction + rate limit ──────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnDirection {
    Inbound,
    Outbound,
}

/// Per-peer rate-limiting state. Window resets every wall-clock second.
#[derive(Debug, Clone)]
pub struct RateLimitState {
    pub msg_count: u32,
    pub byte_count: u64,
    pub window_start: i64,
}

impl RateLimitState {
    pub fn new() -> Self {
        Self {
            msg_count: 0,
            byte_count: 0,
            window_start: 0,
        }
    }

    /// Record a message. Returns `true` if within limits.
    pub fn record_message(&mut self, msg_size: usize) -> bool {
        let now = chrono_now_secs();
        if now != self.window_start {
            self.msg_count = 0;
            self.byte_count = 0;
            self.window_start = now;
        }
        self.msg_count += 1;
        self.byte_count += msg_size as u64;
        self.msg_count <= RATE_LIMIT_MSG_PER_SEC && self.byte_count <= RATE_LIMIT_BYTES_PER_SEC
    }
}

impl Default for RateLimitState {
    fn default() -> Self {
        Self::new()
    }
}

fn chrono_now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

// ── PeerConnection ──────────────────────────────────────────────────────────

/// Wire-level peer connection. Owns a `TcpStream` and per-peer metadata.
pub struct PeerConnection {
    pub stream: TcpStream,
    pub node_id: String,
    pub host: String,
    pub port: u16,
    pub height: u64,
    pub connected: bool,
    pub direction: ConnDirection,
    pub rate_limit: RateLimitState,
    pub ip_bytes: [u8; 4],
    /// Unix timestamp (seconds) of last message received. Used by slot-skip
    /// anti-fork check. Initialized to 0 (never seen).
    pub last_msg_ts: i64,
}

impl PeerConnection {
    pub fn new(
        stream: TcpStream,
        node_id: String,
        host: String,
        port: u16,
        direction: ConnDirection,
    ) -> Self {
        // Disable Nagle — Zig docs: 40ms/hop on small messages kills latency.
        let _ = stream.set_nodelay(true);
        Self {
            stream,
            node_id,
            host,
            port,
            height: 0,
            connected: true,
            direction,
            rate_limit: RateLimitState::new(),
            ip_bytes: [0; 4],
            last_msg_ts: 0,
        }
    }

    /// Send a framed message (header + payload). Mirror of Zig `send()`.
    pub async fn send(&mut self, msg_type: u8, payload: &[u8]) -> Result<()> {
        if !self.connected {
            return Err(P2pError::NotConnected);
        }
        if payload.len() > P2P_MAX_MSG_BYTES as usize {
            return Err(P2pError::PayloadTooLarge(payload.len() as u32));
        }

        let hdr = MsgHeader {
            version: P2P_VERSION,
            msg_type,
            payload_len: payload.len() as u32,
            checksum: calc_checksum(payload),
            flags: 0,
        };
        let mut header_buf = [0u8; MSG_HEADER_SIZE];
        hdr.encode(&mut header_buf);

        self.stream.write_all(&header_buf).await?;
        if !payload.is_empty() {
            self.stream.write_all(payload).await?;
        }
        self.stream.flush().await?;
        Ok(())
    }

    /// Receive a framed message. Returns (msg_type, payload).
    pub async fn recv(&mut self) -> Result<(u8, Vec<u8>)> {
        if !self.connected {
            return Err(P2pError::NotConnected);
        }

        let mut header_buf = [0u8; MSG_HEADER_SIZE];
        match self.stream.read_exact(&mut header_buf).await {
            Ok(_) => {}
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => {
                return Err(P2pError::ConnectionClosed);
            }
            Err(e) => return Err(P2pError::Io(e)),
        }

        let hdr = MsgHeader::decode(&header_buf);
        if hdr.version != P2P_VERSION {
            return Err(P2pError::ProtocolMismatch);
        }
        if hdr.payload_len > P2P_MAX_MSG_BYTES {
            return Err(P2pError::PayloadTooLarge(hdr.payload_len));
        }

        let mut payload = vec![0u8; hdr.payload_len as usize];
        if hdr.payload_len > 0 {
            match self.stream.read_exact(&mut payload).await {
                Ok(_) => {}
                Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => {
                    return Err(P2pError::ConnectionClosed);
                }
                Err(e) => return Err(P2pError::Io(e)),
            }
        }

        if calc_checksum(&payload) != hdr.checksum {
            return Err(P2pError::ChecksumMismatch);
        }

        self.last_msg_ts = chrono_now_secs();
        Ok((hdr.msg_type, payload))
    }

    /// Send PING with current chain height.
    pub async fn send_ping(&mut self, node_id: &str, height: u64) -> Result<()> {
        let mut id_buf = [0u8; 32];
        let n = node_id.len().min(32);
        id_buf[..n].copy_from_slice(&node_id.as_bytes()[..n]);

        let ping = MsgPing {
            node_id: id_buf,
            height,
            version: P2P_VERSION,
        };
        let payload = ping.encode();
        self.send(MessageType::Ping as u8, &payload).await
    }

    /// Send HELLO ("WE ARE HERE!!") — first dialer→acceptor message.
    pub async fn send_hello(
        &mut self,
        node_id: &str,
        chain_magic: [u8; 4],
        listen_port: u16,
        height: u64,
        genesis_hash: [u8; 32],
    ) -> Result<()> {
        let mut id_buf = [0u8; 32];
        let n = node_id.len().min(32);
        id_buf[..n].copy_from_slice(&node_id.as_bytes()[..n]);

        let hello = MsgHello {
            node_id: id_buf,
            chain_magic,
            listen_port,
            height,
            version: P2P_VERSION,
            genesis_hash,
        };
        let payload = hello.encode();
        self.send(MessageType::Hello as u8, &payload).await
    }

    /// Send WELCOME ("WE WANT TO WORK" / "WE DON'T") — acceptor reply.
    pub async fn send_welcome(
        &mut self,
        node_id: &str,
        chain_magic: [u8; 4],
        height: u64,
        accepted: bool,
        reason: u8,
    ) -> Result<()> {
        let mut id_buf = [0u8; 32];
        let n = node_id.len().min(32);
        id_buf[..n].copy_from_slice(&node_id.as_bytes()[..n]);

        let welcome = MsgWelcome {
            node_id: id_buf,
            chain_magic,
            height,
            accepted: if accepted { 1 } else { 0 },
            reason,
        };
        let payload = welcome.encode();
        self.send(MessageType::Welcome as u8, &payload).await
    }

    /// Send STABLE ("WE ARE STABLE") — confirmation after sync settles.
    pub async fn send_stable(&mut self, confirmed_height: u64, peer_count: u16) -> Result<()> {
        let msg = MsgStable {
            confirmed_height,
            peer_count,
        };
        let payload = msg.encode();
        self.send(MessageType::Stable as u8, &payload).await
    }

    /// Announce a new block. `hash_hex` is the 64-char hex digest; decoded
    /// to 32 raw bytes for the V2 wire layout. `miner_id` is the OmniBus
    /// wallet address (max 42 chars, zero-padded).
    pub async fn announce_block(
        &mut self,
        height: u64,
        hash_hex: &str,
        miner_id: &str,
        reward_sat: u64,
    ) -> Result<()> {
        let mut bh = [0u8; 32];
        if hash_hex.len() >= 64 {
            for i in 0..32 {
                let pair = &hash_hex[i * 2..i * 2 + 2];
                match u8::from_str_radix(pair, 16) {
                    Ok(v) => bh[i] = v,
                    Err(_) => break,
                }
            }
        }
        let mut mi = [0u8; 42];
        let n = miner_id.len().min(42);
        mi[..n].copy_from_slice(&miner_id.as_bytes()[..n]);

        let ann = MsgBlockAnnounce {
            block_height: height,
            block_hash: bh,
            miner_id: mi,
            reward_sat,
        };
        let payload = ann.encode();
        self.send(MessageType::Block as u8, &payload).await
    }

    pub fn close(&mut self) {
        if self.connected {
            // tokio TcpStream is dropped on close
            self.connected = false;
        }
    }
}

// ── Knock-knock (anti-Sybil UDP duplicate detection) ───────────────────────
//
// Port of core/p2p/knock.zig. Each miner broadcasts `OMNI:we are here:<node_id>:<height>`
// on UDP, then listens ~3s. If another packet arrives from a different node_id
// on the same IP, this miner enters IDLE state (1 miner per public IP).

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KnockResult {
    /// First miner on this IP — can mine.
    Alone,
    /// Another miner detected on the same IP — must idle.
    DuplicateIp([u8; 4]),
    /// Broadcast failed (firewall/VPN/etc.) — best-effort continue.
    BroadcastFailed,
}

/// Send a UDP broadcast packet on `port` (255.255.255.255).
pub async fn knock_udp(msg: &[u8], port: u16) -> Result<()> {
    let sock = UdpSocket::bind("0.0.0.0:0").await?;
    sock.set_broadcast(true)?;
    let dest = format!("255.255.255.255:{}", port);
    sock.send_to(msg, dest).await?;
    Ok(())
}

/// Listen on UDP `port` for `timeout_ms` ms. If a packet arrives from a
/// different node_id (parsed from "OMNI:we are here:<id>:<h>"), return
/// `DuplicateIp(src_ip)`. Otherwise `Alone`.
pub async fn listen_knock_udp(own_node_id: &str, port: u16, timeout_ms: u64) -> KnockResult {
    let sock = match UdpSocket::bind(format!("0.0.0.0:{}", port)).await {
        Ok(s) => s,
        Err(e) => {
            warn!("[KNOCK] bind failed: {}", e);
            return KnockResult::BroadcastFailed;
        }
    };

    let mut buf = [0u8; 1024];
    let deadline = Duration::from_millis(timeout_ms);

    let start = std::time::Instant::now();
    while start.elapsed() < deadline {
        let remaining = deadline.saturating_sub(start.elapsed());
        match timeout(remaining, sock.recv_from(&mut buf)).await {
            Ok(Ok((n, addr))) => {
                let pkt = &buf[..n];
                // Parse "OMNI:we are here:<id>:<h>"
                if !pkt.starts_with(b"OMNI:we are here:") {
                    continue;
                }
                let body = &pkt[b"OMNI:we are here:".len()..];
                // node_id is everything before the next ':'
                let id_end = body
                    .iter()
                    .position(|&c| c == b':')
                    .unwrap_or(body.len());
                let other_id = &body[..id_end];
                if other_id == own_node_id.as_bytes() {
                    // Our own reflection — ignore.
                    continue;
                }
                let ip = match addr.ip() {
                    std::net::IpAddr::V4(v4) => v4.octets(),
                    _ => continue,
                };
                debug!("[KNOCK] duplicate detected from {:?}", ip);
                return KnockResult::DuplicateIp(ip);
            }
            Ok(Err(e)) => {
                warn!("[KNOCK] recv error: {}", e);
                return KnockResult::BroadcastFailed;
            }
            Err(_) => return KnockResult::Alone, // timeout
        }
    }
    KnockResult::Alone
}

// TODO(integrator): full knockKnock orchestration (broadcast on 3 ports then
// listen) lives on P2PNode in Zig — port that when P2PNode is brought over.
