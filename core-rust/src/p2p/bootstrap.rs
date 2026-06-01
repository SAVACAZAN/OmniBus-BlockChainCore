//! Peer discovery, seed nodes, and persistence.
//!
//! Port of core/bootstrap.zig. PEX message constants (0x10/0x11) match the
//! Zig values byte-for-byte. The persisted `peers.dat` file uses the same
//! `host:port\n` text format so Rust and Zig nodes can share it.

use std::fs;
use std::io::Write;
use std::path::Path;

use tracing::{debug, info, warn};

use crate::p2p::Result;

// ── PEX message types (out-of-band of MessageType enum) ────────────────────

/// PEX: request peer list (empty payload).
pub const MSG_GET_PEERS: u8 = 0x10;
/// PEX: peer list response.
pub const MSG_PEER_LIST: u8 = 0x11;

// ── PeerAddr ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct PeerAddr {
    pub ip: [u8; 4],
    pub port: u16,
}

impl PeerAddr {
    pub fn to_host_string(&self) -> String {
        format!("{}.{}.{}.{}", self.ip[0], self.ip[1], self.ip[2], self.ip[3])
    }
}

// ── Seeds + anti-eclipse constants ─────────────────────────────────────────

/// Hardcoded DNS-seed equivalents (Bitcoin pattern).
pub const SEED_PEERS: &[PeerAddr] = &[
    PeerAddr { ip: [127, 0, 0, 1], port: 8333 },
    PeerAddr { ip: [127, 0, 0, 1], port: 9000 },
    PeerAddr { ip: [127, 0, 0, 1], port: 9001 },
    PeerAddr { ip: [10, 0, 0, 1], port: 8333 },
    PeerAddr { ip: [10, 0, 0, 2], port: 8333 },
    PeerAddr { ip: [192, 168, 1, 100], port: 8333 },
];

/// Min distinct /16 subnets for eclipse resistance.
pub const MIN_DIVERSE_PEERS: usize = 4;
/// Max peers from same /16 subnet.
pub const MAX_PEERS_PER_SUBNET: usize = 2;

/// Default persist path.
pub const PEERS_DAT_PATH: &str = "data/peers.dat";

/// Max peers in known list.
pub const MAX_PEERS: usize = 32;

/// Periodic discovery interval (seconds).
pub const DISCOVERY_INTERVAL_S: i64 = 300;

/// Unresponsive peer timeout (seconds).
pub const PEER_TIMEOUT_S: i64 = 1800;

/// True if adding `new_peer` would not violate the /16 subnet diversity rule.
pub fn is_diverse_peer(new_peer: PeerAddr, existing: &[PeerAddr]) -> bool {
    let mut same_subnet = 0usize;
    for p in existing {
        if p.ip[0] == new_peer.ip[0] && p.ip[1] == new_peer.ip[1] {
            same_subnet += 1;
        }
    }
    same_subnet < MAX_PEERS_PER_SUBNET
}

// ── PeerInfo + PeerManager ─────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
pub struct PeerInfo {
    pub addr: PeerAddr,
    pub chain_height: u64,
    pub connected: bool,
    pub last_seen: i64,
}

pub struct PeerManager {
    pub known: Vec<PeerInfo>,
}

impl PeerManager {
    pub fn new() -> Self {
        Self { known: Vec::new() }
    }

    /// Add a peer if it is not already known (dedup by ip:port).
    pub fn add_peer(&mut self, addr: PeerAddr) {
        if self
            .known
            .iter()
            .any(|e| e.addr.ip == addr.ip && e.addr.port == addr.port)
        {
            return;
        }
        self.known.push(PeerInfo {
            addr,
            chain_height: 0,
            connected: false,
            last_seen: now_secs(),
        });
        debug!(
            "[PEER_MGR] Peer added {}.{}.{}.{}:{}",
            addr.ip[0], addr.ip[1], addr.ip[2], addr.ip[3], addr.port
        );
    }

    pub fn remove_peer(&mut self, addr: PeerAddr) {
        self.known
            .retain(|p| !(p.addr.ip == addr.ip && p.addr.port == addr.port));
    }

    pub fn connected_count(&self) -> usize {
        self.known.iter().filter(|p| p.connected).count()
    }

    /// Peer with highest chain_height among connected peers.
    pub fn best_peer(&self) -> Option<PeerInfo> {
        let mut best: Option<PeerInfo> = None;
        for p in &self.known {
            if !p.connected {
                continue;
            }
            match best {
                None => best = Some(*p),
                Some(b) if p.chain_height > b.chain_height => best = Some(*p),
                _ => {}
            }
        }
        best
    }

    pub fn update_height(&mut self, addr: PeerAddr, height: u64) {
        for p in self.known.iter_mut() {
            if p.addr.ip == addr.ip && p.addr.port == addr.port {
                p.chain_height = height;
                p.last_seen = now_secs();
                return;
            }
        }
    }

    pub fn set_connected(&mut self, addr: PeerAddr, connected: bool) {
        for p in self.known.iter_mut() {
            if p.addr.ip == addr.ip && p.addr.port == addr.port {
                p.connected = connected;
                p.last_seen = now_secs();
                return;
            }
        }
    }
}

impl Default for PeerManager {
    fn default() -> Self {
        Self::new()
    }
}

// ── Disk persistence (text format: "A.B.C.D:port\n") ───────────────────────

pub fn save_peers_to_disk(manager: &PeerManager, path: &str) -> Result<()> {
    if let Some(parent) = Path::new(path).parent() {
        let _ = fs::create_dir_all(parent);
    }
    let mut file = fs::File::create(path)?;
    for p in &manager.known {
        writeln!(
            file,
            "{}.{}.{}.{}:{}",
            p.addr.ip[0], p.addr.ip[1], p.addr.ip[2], p.addr.ip[3], p.addr.port
        )?;
    }
    info!(
        "[PEERS] Saved {} peers to {}",
        manager.known.len(),
        path
    );
    Ok(())
}

pub fn load_peers_from_disk(manager: &mut PeerManager, path: &str) {
    let content = match fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) => {
            debug!("[PEERS] loadPeersFromDisk open: {} (normal on first run)", e);
            return;
        }
    };
    let mut loaded = 0usize;
    for raw in content.lines() {
        let line = raw.trim_end_matches('\r');
        if line.len() < 3 {
            continue;
        }
        let colon = match line.rfind(':') {
            Some(c) => c,
            None => continue,
        };
        if colon == 0 || colon >= line.len() - 1 {
            continue;
        }
        let host = &line[..colon];
        let port_str = &line[colon + 1..];
        let port: u16 = match port_str.parse() {
            Ok(p) => p,
            Err(_) => continue,
        };
        let ip = match parse_ipv4(host) {
            Some(ip) => ip,
            None => continue,
        };
        manager.add_peer(PeerAddr { ip, port });
        loaded += 1;
    }
    info!("[PEERS] Loaded {} peers from {}", loaded, path);
}

fn parse_ipv4(s: &str) -> Option<[u8; 4]> {
    let parts: Vec<&str> = s.split('.').collect();
    if parts.len() != 4 {
        return None;
    }
    let mut out = [0u8; 4];
    for (i, p) in parts.iter().enumerate() {
        out[i] = p.parse().ok()?;
    }
    Some(out)
}

// ── BootstrapNode (seed node bookkeeping) ──────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeStatus {
    Starting,
    WaitingForPeers,
    Syncing,
    Synchronized,
    Mining,
}

#[derive(Debug, Clone)]
pub struct SeedNodeConfig {
    pub node_id: String,
    pub host: String,
    pub port: u16,
    pub is_primary: bool,
    pub max_peers: u32,
}

#[derive(Debug, Clone)]
pub struct BootstrapPeer {
    pub node_id: String,
    pub host: String,
    pub port: u16,
    pub version: String,
    pub last_seen: i64,
    pub latency_ms: u32,
}

pub struct BootstrapNode {
    pub config: SeedNodeConfig,
    pub peers: Vec<BootstrapPeer>,
    pub status: NodeStatus,
    pub created_at: i64,
}

impl BootstrapNode {
    pub fn new(config: SeedNodeConfig) -> Self {
        Self {
            config,
            peers: Vec::new(),
            status: NodeStatus::Starting,
            created_at: now_secs(),
        }
    }

    pub fn register_peer(&mut self, peer: BootstrapPeer) -> std::result::Result<(), &'static str> {
        if self.peers.len() >= self.config.max_peers as usize {
            return Err("MaxPeersReached");
        }
        info!("[BOOTSTRAP] Peer registered: {}:{}", peer.host, peer.port);
        self.peers.push(peer);
        Ok(())
    }

    pub fn update_peer_status(
        &mut self,
        node_id: &str,
        latency_ms: u32,
    ) -> std::result::Result<(), &'static str> {
        for p in self.peers.iter_mut() {
            if p.node_id == node_id {
                p.last_seen = now_secs();
                p.latency_ms = latency_ms;
                return Ok(());
            }
        }
        Err("PeerNotFound")
    }

    /// Drop peers without heartbeat for 60s.
    pub fn remove_stale_peers(&mut self) {
        let now = now_secs();
        let before = self.peers.len();
        self.peers.retain(|p| now - p.last_seen <= 60);
        if self.peers.len() != before {
            debug!("[BOOTSTRAP] Removed {} stale peer(s)", before - self.peers.len());
        }
    }

    pub fn set_status(&mut self, status: NodeStatus) {
        self.status = status;
        info!("[BOOTSTRAP] Status changed to: {:?}", status);
    }
}

// ── Discovery orchestration (callbacks injected by integrator) ─────────────
//
// In Zig these touch the live P2PNode (connectToPeer, requestPeersFromAll,
// cleanDeadPeers). Until P2PNode lands in Rust we model them as trait
// callbacks the integrator wires up.

pub trait P2pNodeHandle {
    /// Dial a peer (TCP outbound). Best-effort.
    fn connect_to_peer(&mut self, host: &str, port: u16, node_id: &str) -> Result<()>;

    /// Send `get_peers` to every connected peer.
    fn request_peers_from_all(&mut self);

    /// Number of currently live peer connections.
    fn peer_count(&self) -> usize;

    /// Drop dead connections.
    fn clean_dead_peers(&mut self);
}

/// Auto-discovery on startup: load saved peers → seed nodes → PEX request.
pub fn autodiscover<H: P2pNodeHandle>(manager: &mut PeerManager, p2p: &mut H) {
    // 1. Load persisted
    load_peers_from_disk(manager, PEERS_DAT_PATH);

    // 2. Add seed nodes (dedup handles overlap)
    for seed in SEED_PEERS {
        manager.add_peer(*seed);
    }

    // 3. Try connecting up to MAX_PEERS
    let mut connected = p2p.peer_count();
    for peer in manager.known.iter_mut() {
        if connected >= MAX_PEERS {
            break;
        }
        if peer.connected {
            continue;
        }
        let host = peer.addr.to_host_string();
        if p2p
            .connect_to_peer(&host, peer.addr.port, "discovered")
            .is_err()
        {
            continue;
        }
        peer.connected = true;
        peer.last_seen = now_secs();
        connected += 1;
    }

    // 4. PEX request
    p2p.request_peers_from_all();

    info!(
        "[DISCOVERY] Auto-discover done: {} known, {} connected",
        manager.known.len(),
        connected
    );
}

/// Periodic discovery: drop unresponsive, PEX, refill, save.
pub fn periodic_discovery<H: P2pNodeHandle>(manager: &mut PeerManager, p2p: &mut H) {
    let now = now_secs();

    // 1. Drop unresponsive
    manager.known.retain(|p| {
        let alive = now - p.last_seen <= PEER_TIMEOUT_S;
        if !alive {
            warn!(
                "[DISCOVERY] Dropping unresponsive peer {}.{}.{}.{}:{}",
                p.addr.ip[0], p.addr.ip[1], p.addr.ip[2], p.addr.ip[3], p.addr.port
            );
        }
        alive
    });

    // 2. PEX
    p2p.request_peers_from_all();

    // 3. Refill
    let mut connected = p2p.peer_count();
    for peer in manager.known.iter_mut() {
        if connected >= MAX_PEERS {
            break;
        }
        if peer.connected {
            continue;
        }
        let host = peer.addr.to_host_string();
        if p2p
            .connect_to_peer(&host, peer.addr.port, "periodic")
            .is_err()
        {
            continue;
        }
        peer.connected = true;
        peer.last_seen = now;
        connected += 1;
    }

    // 4. Clean dead
    p2p.clean_dead_peers();

    // 5. Persist
    if let Err(e) = save_peers_to_disk(manager, PEERS_DAT_PATH) {
        warn!("[DISCOVERY] save failed: {}", e);
    }

    info!(
        "[DISCOVERY] Periodic: {} known, {} connected",
        manager.known.len(),
        connected
    );
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

// TODO(integrator): full kademlia DHT port — core/kademlia_dht.zig has
// 351 LOC of routing-table/k-bucket code. Per the brief, we stubbed it:
// once peer discovery is wired up via PEX + seeds we can revisit DHT.
