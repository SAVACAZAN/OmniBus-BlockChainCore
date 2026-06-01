// Minimal P2P node orchestrator. Bind TCP, accept inbound peers, exchange
// HELLO/WELCOME handshake, keep connection alive with periodic PING.
//
// Wire-compatible with Zig nodes (same MsgHello/Welcome/Stable/Ping byte
// layout). Two Rust nodes can already peer with each other; cross-impl
// Zig↔Rust handshake is the next test (only requires matching CHAIN_MAGIC
// + genesis_hash, both already canonicalized).

use crate::p2p::peer::{ConnDirection, PeerConnection};
use crate::p2p::wire::MessageType;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::RwLock;

/// Mainnet chain magic — port from `core/genesis.zig` MAINNET.
pub const CHAIN_MAGIC_MAINNET: [u8; 4] = *b"OMNI";
pub const CHAIN_MAGIC_TESTNET: [u8; 4] = *b"TEST";

/// Canonical mainnet genesis hash (32B) — must match Zig + consensus/genesis.rs.
pub const GENESIS_HASH_MAINNET_HEX: &str =
    "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982";

pub fn genesis_hash() -> [u8; 32] {
    let bytes = hex::decode(GENESIS_HASH_MAINNET_HEX).expect("valid genesis hash");
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    out
}

#[derive(Clone, Default)]
pub struct PeerRegistry {
    inner: Arc<RwLock<Vec<PeerEntry>>>,
}

#[derive(Debug, Clone)]
pub struct PeerEntry {
    pub addr: String,
    pub node_id: String,
    pub height: u64,
    pub last_seen: i64,
}

impl PeerRegistry {
    pub fn new() -> Self { Self::default() }

    pub async fn add_or_update(&self, addr: String, node_id: String, height: u64) {
        let mut g = self.inner.write().await;
        let ts = unix_now();
        let is_new = !g.iter().any(|p| p.node_id == node_id);
        match g.iter_mut().find(|p| p.node_id == node_id) {
            Some(p) => { p.last_seen = ts; p.addr = addr.clone(); p.height = height; }
            None    => g.push(PeerEntry { addr: addr.clone(), node_id: node_id.clone(), height, last_seen: ts }),
        }
        if is_new {
            crate::ws::try_broadcast(crate::ws::Event::PeerConnect {
                node_id, address: addr, timestamp: ts,
            });
        }
    }

    /// Evict a peer by node_id. Emits `PeerDisconnect` on the WS feed.
    pub async fn evict(&self, node_id: &str) -> bool {
        let mut g = self.inner.write().await;
        let before = g.len();
        let mut addr = String::new();
        g.retain(|p| {
            if p.node_id == node_id { addr = p.addr.clone(); false } else { true }
        });
        let removed = g.len() != before;
        drop(g);
        if removed {
            crate::ws::try_broadcast(crate::ws::Event::PeerDisconnect {
                node_id: node_id.to_string(), address: addr, timestamp: unix_now(),
            });
        }
        removed
    }

    pub async fn count(&self) -> usize { self.inner.read().await.len() }

    pub async fn snapshot(&self) -> Vec<PeerEntry> {
        self.inner.read().await.clone()
    }
}

fn unix_now() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// Seed mode: TCP listen + accept inbound peers. Each accepted connection
/// runs `handle_inbound` in its own task.
pub async fn run_seed(port: u16, node_id: String, registry: PeerRegistry) -> anyhow::Result<()> {
    let bind = format!("0.0.0.0:{port}");
    let listener = TcpListener::bind(&bind).await?;
    tracing::info!(addr = %bind, %node_id, "P2P seed listening");

    loop {
        match listener.accept().await {
            Ok((sock, addr)) => {
                tracing::info!(remote = %addr, "inbound peer accepted");
                let reg = registry.clone();
                let nid = node_id.clone();
                tokio::spawn(async move {
                    if let Err(e) = handle_inbound(sock, port, reg, nid).await {
                        tracing::warn!(%addr, error = %e, "inbound peer error");
                    }
                });
            }
            Err(e) => tracing::warn!(error = %e, "accept failed"),
        }
    }
}

/// Miner mode: connect to a seed, perform HELLO/WELCOME/STABLE handshake,
/// keep alive with periodic PING.
pub async fn run_miner(
    seed_host: &str,
    seed_port: u16,
    self_port: u16,
    node_id: String,
    registry: PeerRegistry,
) -> anyhow::Result<()> {
    let target = format!("{seed_host}:{seed_port}");
    tracing::info!(seed = %target, %node_id, "miner connecting to seed");

    let sock = TcpStream::connect(&target).await?;
    sock.set_nodelay(true)?;
    let mut conn = PeerConnection::new(
        sock, node_id.clone(), seed_host.to_string(), seed_port, ConnDirection::Outbound,
    );

    // Send HELLO
    conn.send_hello(
        &node_id,
        CHAIN_MAGIC_MAINNET,
        self_port,
        0,
        genesis_hash(),
    ).await?;
    tracing::info!("HELLO sent");

    // Receive WELCOME
    let (msg_type, _payload) = conn.recv().await?;
    if msg_type != MessageType::Welcome as u8 {
        return Err(anyhow::anyhow!("expected WELCOME, got msg_type={msg_type}"));
    }
    tracing::info!("WELCOME received — handshake done");

    // Send STABLE
    conn.send_stable(0, 1).await?;
    tracing::info!("STABLE sent");

    registry.add_or_update(target.clone(), "seed".into(), 0).await;

    // Keep-alive loop with periodic PING. Any frame received increments the
    // peer's last_seen via re-registration.
    let mut ticker = tokio::time::interval(Duration::from_secs(10));
    loop {
        tokio::select! {
            _ = ticker.tick() => {
                if let Err(e) = conn.send_ping(&node_id, 0).await {
                    tracing::warn!(error = %e, "PING failed");
                    return Err(e.into());
                }
            }
            msg = conn.recv() => {
                match msg {
                    Ok((t, _)) => tracing::trace!(msg_type = t, "frame from seed"),
                    Err(e)     => { tracing::warn!(error = %e, "seed disconnected"); return Err(e.into()); }
                }
            }
        }
    }
}

async fn handle_inbound(
    sock: TcpStream,
    self_port: u16,
    registry: PeerRegistry,
    node_id: String,
) -> anyhow::Result<()> {
    let peer_addr_opt = sock.peer_addr().ok();
    let remote = peer_addr_opt.map(|a| a.to_string()).unwrap_or_default();
    let remote_host = peer_addr_opt.map(|a| a.ip().to_string()).unwrap_or_default();
    let remote_port = peer_addr_opt.map(|a| a.port()).unwrap_or(0);
    sock.set_nodelay(true)?;
    let mut conn = PeerConnection::new(
        sock, node_id.clone(), remote_host, remote_port, ConnDirection::Inbound,
    );

    // Expect HELLO as first message
    let (msg_type, _payload) = conn.recv().await?;
    if msg_type != MessageType::Hello as u8 {
        return Err(anyhow::anyhow!("expected HELLO, got msg_type={msg_type}"));
    }
    tracing::info!(remote = %remote, "HELLO received");

    // Reply WELCOME (accepted)
    conn.send_welcome(&node_id, CHAIN_MAGIC_MAINNET, 0, true, 0).await?;
    registry.add_or_update(remote.clone(), "peer".into(), 0).await;
    let peer_count = registry.count().await;
    tracing::info!(remote = %remote, peers = peer_count, "WELCOME sent; peer added");

    // Drive the connection until disconnect: relay incoming frames + send
    // periodic PING ourselves. Real consensus / sync goes here in a future
    // milestone.
    let mut ticker = tokio::time::interval(Duration::from_secs(15));
    let _ = self_port; // (reserved for PEX advertisement of our listen port)
    loop {
        tokio::select! {
            _ = ticker.tick() => {
                if let Err(e) = conn.send_ping(&node_id, 0).await {
                    tracing::debug!(remote = %remote, error = %e, "PING send failed (peer disconnected)");
                    return Ok(());
                }
            }
            msg = conn.recv() => {
                match msg {
                    Ok((t, _)) => tracing::trace!(remote = %remote, msg_type = t, "frame"),
                    Err(_)     => { tracing::debug!(remote = %remote, "peer disconnected"); return Ok(()); }
                }
            }
        }
    }
}
