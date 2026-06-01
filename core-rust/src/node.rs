//! Top-level Node orchestrator — spawns P2P listener/dialer, EVM JSON-RPC
//! server, native JSON-RPC server, block-production loop (miner only), and
//! sync loop. Sibling of `core/main.zig` startup sequence (Zig).

use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use tokio::sync::RwLock;

use crate::chain::{Chain, SharedChain};
use crate::consensus::block::Block;
use crate::consensus::consensus::ConsensusEngine;
use crate::consensus::MAX_BLOCK_TX;
use crate::mining::pow::mine_block_nonce;
use crate::p2p::node::PeerRegistry;
use crate::state::EvmState;
use crate::AppState;
use crate::{p2p, CliArgs};

/// Max nonces to grind per outer-loop attempt before yielding.
const MINE_ATTEMPTS_PER_PASS: u64 = 200_000;

/// Run as a seed node: P2P listener + sync loop + RPC servers.
pub async fn run_seed(cli: CliArgs, app_state: AppState, registry: PeerRegistry) -> Result<()> {
    // Spawn EVM JSON-RPC.
    spawn_evm_rpc(app_state.clone(), cli.evm_port);

    // Spawn sync loop (best-effort; not driving the wire today).
    spawn_sync_loop(app_state.chain.clone(), registry.clone());

    tracing::info!(
        "seed: P2P :{}  native RPC :{}  EVM RPC :{}",
        cli.p2p_port,
        cli.rpc_port,
        cli.evm_port
    );

    // P2P listener (this call blocks until shutdown).
    p2p::node::run_seed(cli.p2p_port, cli.node_id.clone(), registry).await
}

/// Run as a miner node: P2P dialer + block-production loop + sync loop + RPC.
pub async fn run_miner(cli: CliArgs, app_state: AppState, registry: PeerRegistry) -> Result<()> {
    let seed_host = cli
        .seed_host
        .clone()
        .ok_or_else(|| anyhow::anyhow!("--mode miner requires --seed-host"))?;

    spawn_evm_rpc(app_state.clone(), cli.evm_port);
    spawn_block_producer(app_state.chain.clone(), registry.clone(), cli.node_id.clone());
    spawn_sync_loop(app_state.chain.clone(), registry.clone());

    tracing::info!(
        "miner: connecting to {}:{}  native RPC :{}  EVM RPC :{}",
        seed_host,
        cli.seed_port,
        cli.rpc_port,
        cli.evm_port
    );

    p2p::node::run_miner(
        &seed_host,
        cli.seed_port,
        cli.p2p_port,
        cli.node_id.clone(),
        registry,
    )
    .await
}

/// Spawn the EVM JSON-RPC server (axum). Same code path as `--mode evm`.
fn spawn_evm_rpc(app_state: AppState, port: u16) {
    tokio::spawn(async move {
        if let Err(e) = crate::run_evm_only(app_state, port).await {
            tracing::error!(error = %e, "EVM RPC exited");
        }
    });
}

/// Block-production loop. Wakes every TARGET_BLOCK_TIME (1s), drains the
/// mempool up to MAX_BLOCK_TX, builds a candidate block, runs PoW grind in
/// `spawn_blocking`, then `chain.add_block` + broadcasts the announce.
fn spawn_block_producer(chain: SharedChain, _registry: PeerRegistry, node_id: String) {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(1));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            ticker.tick().await;
            match produce_one_block(&chain, &node_id).await {
                Ok(Some((height, hash))) => {
                    tracing::info!(height, %hash, "mined block");
                    // TODO(p2p-broadcast): iterate PeerRegistry's live connections
                    // and call `announce_block`. The current PeerRegistry tracks
                    // peers but doesn't hold their `PeerConnection` handles — once
                    // a connection table lands (per-peer mpsc Sender), wire the
                    // MsgBlockAnnounce here.
                }
                Ok(None) => {
                    // No nonce found this pass — try again next tick.
                }
                Err(e) => {
                    tracing::error!(error = %e, "block production failed");
                }
            }
        }
    });
}

async fn produce_one_block(chain: &SharedChain, node_id: &str) -> Result<Option<(u64, String)>> {
    // Snapshot tip + drain mempool while holding the write lock briefly.
    let (mut candidate, difficulty) = {
        let mut c = chain.write().await;
        let tip = c.tip().clone();
        let txs = c.mempool.take_for_block(MAX_BLOCK_TX);
        let next_index = tip.index + 1;
        let prev_hash = tip.hash.clone();
        let ts = unix_now_secs();
        let mut b = Block::new(next_index, prev_hash, ts);
        b.transactions = txs;
        b.miner_address = node_id.to_string();
        b.reward_sat = crate::consensus::consensus::block_reward_at(next_index as u64);
        b.recompute_merkle();
        (b, c.difficulty)
    };

    // CPU-bound PoW grind off the runtime.
    let outcome = tokio::task::spawn_blocking(move || {
        let r = mine_block_nonce(&mut candidate, difficulty, 0, 1, MINE_ATTEMPTS_PER_PASS);
        (candidate, r)
    })
    .await?;

    let (mined_block, mine_result) = outcome;
    if mine_result.is_none() {
        return Ok(None);
    }

    let mut c = chain.write().await;
    let h = c.add_block(mined_block)?;
    let tip_hash = c.tip().hash.clone();
    Ok(Some((h, tip_hash)))
}

/// Sync loop — periodically asks the peer registry for the best peer height;
/// if local is behind, builds a `SyncManager` request. Actual wire calls go
/// out via the per-peer connection; full pipe will be wired when the peer
/// table stores connection handles.
fn spawn_sync_loop(chain: SharedChain, registry: PeerRegistry) {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(5));
        loop {
            ticker.tick().await;
            let local = chain.read().await.height();
            let peers = registry.snapshot().await;
            let best_peer_height = peers.iter().map(|p| p.height).max().unwrap_or(0);
            if best_peer_height > local + crate::p2p::IBD_GAP_TRIGGER {
                tracing::info!(local, best_peer_height, "sync: behind, requesting headers");
                // TODO(sync-wire): SyncManager::on_peer_height returns a
                // MsgGetHeaders payload. Send it to the best peer once the
                // PeerRegistry exposes per-peer send handles.
            }
        }
    });
}

fn unix_now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

// ── Convenience: validate a block that arrived over P2P ────────────────────

#[allow(dead_code)]
pub fn validate_inbound_block(b: &Block, parent: &Block, difficulty: u32) -> Result<()> {
    if b.index as u64 != parent.index as u64 + 1 {
        anyhow::bail!("bad height");
    }
    if b.previous_hash != parent.hash {
        anyhow::bail!("bad prev");
    }
    if !ConsensusEngine::is_block_hash_valid(&b.hash, difficulty) {
        anyhow::bail!("bad PoW");
    }
    Ok(())
}

pub fn new_shared_chain(c: Chain) -> SharedChain {
    Arc::new(RwLock::new(c))
}
