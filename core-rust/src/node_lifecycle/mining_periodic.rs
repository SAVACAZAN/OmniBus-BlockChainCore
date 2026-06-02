//! mining_periodic — fixed-interval block production loop.
//!
//! The Zig original (`core/node/mining_periodic.zig`, 582 LoC) is the main
//! mining loop: every block-time tick, drain the mempool, build a candidate
//! block, run validators, persist, gossip, save state.
//!
//! Ported from `core/node/mining_periodic.zig` (2026-06-02).
//!
//! This module exposes the interval constant, the background task launcher,
//! and all periodic helper functions that the main mining loop delegates to.
//! Each function corresponds to one `// ── …` section from the Zig original.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

/// Default block time = 1 second. Matches `BLOCK_TIME_MS` in `spark_invariants`.
pub const BLOCK_TIME_SEC: u64 = 1;

/// Canonical pair labels — mirrors `exchange_listPairs` RPC order.
/// Kept here so the WS broadcast helper does not depend on caller for the list.
pub const PAIR_LABELS: [&str; 7] = [
    "OMNI/USDC",
    "BTC/USDC",
    "LCX/USDC",
    "ETH/USDC",
    "OMNI/BTC",
    "OMNI/LCX",
    "OMNI/ETH",
];

/// Number of blocks in one "day" at 10s/block (8640 = 24h × 60min × 6blocks/min).
pub const BLOCKS_PER_DAY: u64 = 8_640;

/// How many blocks between uptime-minute credits (60 blocks ≈ 1 minute at 1s/block).
pub const UPTIME_CREDIT_INTERVAL: u64 = 60;

/// Default checkpoint interval — mirrors `finality_mod.CHECKPOINT_INTERVAL`.
pub const CHECKPOINT_INTERVAL: u64 = 100;

// ─── Background task handle ───────────────────────────────────────────────

pub struct MiningHandle {
    run: Arc<AtomicBool>,
}

impl MiningHandle {
    pub fn stop(self) {
        self.run.store(false, Ordering::Release);
    }
}

/// Start a tokio task that fires `mine_one` every `interval_sec` seconds.
/// The closure should drain the mempool, build a block, validate, persist,
/// and gossip. Errors are intentionally swallowed (TODO: surface via a
/// metrics channel).
pub fn start_mining_loop<F>(interval_sec: u64, mine_one: F) -> MiningHandle
where
    F: Fn() + Send + Sync + 'static,
{
    let run = Arc::new(AtomicBool::new(true));
    let run2 = run.clone();
    tokio::spawn(async move {
        while run2.load(Ordering::Acquire) {
            tokio::time::sleep(std::time::Duration::from_secs(interval_sec)).await;
            if !run2.load(Ordering::Acquire) {
                break;
            }
            mine_one();
        }
    });
    MiningHandle { run }
}

// ─── Periodic helpers (ported from Zig, called once per block) ─────────────

/// Returns current Unix timestamp in milliseconds.
#[inline]
fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Gate at the top of the mining loop: if the node is not yet ready for
/// mining (not enough peers), log status every 6 maintenance ticks,
/// and tell the caller to skip (returns `true`). Once ready, flip
/// `mining_started` to true (idempotent) and return `false` so the
/// caller proceeds with the rest of the loop body.
///
/// Mirrors `handleWaitForPeers` in the Zig original.
pub fn handle_wait_for_peers(
    ready_for_mining: bool,
    mining_started: &mut bool,
    maint_count: u32,
    peer_count: usize,
    needed_peers: usize,
    block_count: u64,
) -> bool {
    if !ready_for_mining && !*mining_started {
        if maint_count % 6 == 0 {
            eprintln!(
                "[NETWORK] Waiting for miners... {}/{} connected (need {} to start mining)",
                peer_count, needed_peers, needed_peers
            );
        }
        return true; // caller should continue/sleep
    }

    if !*mining_started && ready_for_mining {
        *mining_started = true;
        eprintln!(
            "[MINING] Network ready — {} peers connected, mining started (height {})\n",
            peer_count, block_count
        );
    }
    false
}

/// IDLE re-check: if the node is marked idle (duplicate IP detected),
/// every 60 maintenance ticks re-run the knock-knock check. Returns
/// `true` when the duplicate has gone and normal mining should resume.
///
/// Mirrors `maybeRetryKnockKnock` in the Zig original.
pub fn maybe_retry_knock_knock(maint_count: u32, mut recheck_fn: impl FnMut() -> bool) -> bool {
    if maint_count % 60 == 0 {
        eprintln!("[IDLE] Re-verificare duplicat IP...");
        let alone = recheck_fn();
        if alone {
            eprintln!("[IDLE] Duplicat disparut — reactivare mining!\n");
        }
        return alone;
    }
    false
}

/// A single price snapshot entry for a block.
#[derive(Debug, Clone)]
pub struct BlockPriceEntry {
    pub exchange: String,
    pub pair: String,
    pub bid_micro_usd: u64,
    pub ask_micro_usd: u64,
    pub timestamp_ms: u64,
    pub success: bool,
}

/// Submit a PoUW (Proof-of-Useful-Work) mining work report.
/// Fills/volume/price counters left at 0; matching engine + oracle paths
/// update those independently. Mirrors `submitMiningWorkReport` in Zig.
pub fn submit_mining_work_report(
    block_count: u64,
    miner_addr: &str,
    mut submit_fn: impl FnMut(MiningWorkReport),
) {
    let report = MiningWorkReport {
        miner_address: miner_addr.to_string(),
        work_type: WorkType::Matching,
        block_height: block_count,
        timestamp_ms: now_ms(),
        fills_count: 0,
        volume_matched_sat: 0,
        price_updates: 0,
        settlements_count: 0,
    };
    submit_fn(report);
}

/// Work report payload for PoUW.
#[derive(Debug, Clone)]
pub struct MiningWorkReport {
    pub miner_address: String,
    pub work_type: WorkType,
    pub block_height: u64,
    pub timestamp_ms: u64,
    pub fills_count: u32,
    pub volume_matched_sat: u64,
    pub price_updates: u32,
    pub settlements_count: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkType {
    Matching,
    Oracle,
    Settlement,
}

/// Broadcast fills (trades) for the just-mined block + orderbook snapshots
/// for every active pair. Mirrors `broadcastFillsAndOrderbook` in Zig.
///
/// `fills_for_block`: fills at the given block index.
/// `broadcast_trade`: callback to push a single trade event to WebSocket clients.
/// `broadcast_orderbook`: callback to push an orderbook snapshot.
pub fn broadcast_fills_and_orderbook(
    block_index: u32,
    block_count: u64,
    fills_for_block: &[(u16, u64, u64)], // (pair_id, price_micro_usd, amount_sat)
    best_bid: &dyn Fn(u16) -> u64,
    best_ask: &dyn Fn(u16) -> u64,
    order_count: &dyn Fn(u16) -> u32,
    broadcast_trade: &dyn Fn(u16, &str, u64, u64, &str, u64),
    broadcast_orderbook: &dyn Fn(u16, &str, u64, u64, u64, u32, u64),
) {
    // Broadcast fills for this block.
    for &(pair_id, price, amount) in fills_for_block {
        let label = PAIR_LABELS
            .get(pair_id as usize)
            .copied()
            .unwrap_or("OMNI/USDC");
        broadcast_trade(pair_id, label, price, amount, "buy", block_count);
    }
    let _ = block_index; // retained for future block-scoped fill lookup

    // Broadcast orderbook snapshots for all pairs.
    for (pid, &label) in PAIR_LABELS.iter().enumerate() {
        let pair_id = pid as u16;
        let bb = best_bid(pair_id);
        let ba = best_ask(pair_id);
        let oc = order_count(pair_id);
        if bb > 0 || ba > 0 || oc > 0 {
            let spread = ba.saturating_sub(bb);
            broadcast_orderbook(pair_id, label, bb, ba, spread, oc, block_count);
        }
    }
}

/// Per-block round engines tick: PoUW calculate+reset, AI agents tick,
/// price oracle reset, oracle fetcher periodic log every 10 blocks.
/// Mirrors `tickRoundEngines` in Zig.
///
/// The callbacks are injected so this module stays dependency-free.
pub fn tick_round_engines(
    block_count: u64,
    mut pouw_calculate_rewards: impl FnMut(u64),
    mut pouw_reset_block: impl FnMut(),
    mut agent_tick_all: impl FnMut(u64),
    mut price_oracle_reset_round: impl FnMut(),
    oracle_log_fn: Option<&dyn Fn(u64)>, // called every 10 blocks
) {
    pouw_calculate_rewards(block_count);
    pouw_reset_block();
    agent_tick_all(block_count);
    price_oracle_reset_round();

    if block_count % 10 == 0 {
        if let Some(f) = oracle_log_fn {
            f(block_count);
        }
    }
}

/// Log the BTC/USD and LCX/USD oracle median prices. Called from
/// `tick_round_engines` every 10 blocks.
pub fn log_oracle_medians(
    btc_median: Option<u64>,
    btc_ok: u8,
    lcx_median: Option<u64>,
    lcx_ok: u8,
    mut broadcast_oracle: impl FnMut(&str, u64, u8),
) {
    match btc_median {
        Some(m) => {
            eprintln!(
                "[ORACLE-FETCHER] BTC/USD median: ${}.{:04} ({}/3 exchanges)",
                m / 1_000_000,
                (m % 1_000_000) / 100,
                btc_ok
            );
            broadcast_oracle("BTC/USD", m, btc_ok);
        }
        None => eprintln!("[ORACLE-FETCHER] BTC: no prices available"),
    }
    match lcx_median {
        Some(m) => {
            eprintln!(
                "[ORACLE-FETCHER] LCX/USD median: ${}.{:04} ({}/3 exchanges)",
                m / 1_000_000,
                (m % 1_000_000) / 100,
                lcx_ok
            );
            broadcast_oracle("LCX/USD", m, lcx_ok);
        }
        None => eprintln!("[ORACLE-FETCHER] LCX: no prices available"),
    }
}

/// Register a shard header for the just-mined block and finalize the meta
/// block. Logs metachain height every 10 blocks.
/// Mirrors `registerMetaShard` in Zig.
pub fn register_meta_shard(
    block_count: u64,
    block_hash: [u8; 32],
    tx_count: u32,
    reward_sat: u64,
    miner_addr: &str,
    mut metachain_fn: impl FnMut(u64, [u8; 32], u32, u64, &str) -> u64, // returns new height
    num_shards: u32,
) {
    let new_height = metachain_fn(block_count, block_hash, tx_count, reward_sat, miner_addr);
    if block_count % 10 == 0 {
        eprintln!(
            "[METACHAIN] height={} active_shards={}",
            new_height, num_shards
        );
    }
}

/// Every-N-blocks periodic log lines for governance / DNS / guardian.
/// Mirrors `maybeLogPeriodic` in Zig.
pub fn maybe_log_periodic(
    block_count: u64,
    governance_proposal_count: u32,
    dns_active_count: u64,
    guardian_guarded_count: u64,
) {
    let _ = block_count;
    if governance_proposal_count > 0 {
        eprintln!(
            "[GOVERNANCE] Active proposals: {}",
            governance_proposal_count
        );
    }
    if dns_active_count > 0 {
        eprintln!("[DNS] Registered names: {}", dns_active_count);
    }
    if guardian_guarded_count > 0 {
        eprintln!("[GUARDIAN] Guarded accounts: {}", guardian_guarded_count);
    }
}

/// P2P maintenance: reconnect dead peers, evict expired bans, attempt
/// fork-recovery. Mirrors `p2pMaintenance` in Zig.
pub fn p2p_maintenance(
    mut process_reconnects: impl FnMut(),
    mut evict_expired_bans: impl FnMut(),
    mut try_fork_recovery: impl FnMut() -> bool,
) {
    process_reconnects();
    evict_expired_bans();
    let _ = try_fork_recovery();
}

/// Full maintenance cadence (every 30 maintenance ticks): launcher housekeeping,
/// P2P reconnects/evictions/fork-recovery, governance/DNS/guardian periodic
/// logs, gossip stats, sync-stalled recovery. Mirrors `periodicMaintenance30`.
#[allow(clippy::too_many_arguments)]
pub fn periodic_maintenance_30(
    block_count: u64,
    governance_proposal_count: u32,
    dns_active_count: u64,
    guardian_guarded_count: u64,
    total_peers: usize,
    total_miners: usize,
    is_synced: bool,
    tx_relayed: u64,
    blocks_relayed: u64,
    seen_tx: u64,
    seen_blocks: u64,
    sync_stalled: bool,
    mut process_reconnects: impl FnMut(),
    mut evict_expired_bans: impl FnMut(),
    mut try_fork_recovery: impl FnMut() -> bool,
    mut launcher_maintenance: impl FnMut(),
    mut clean_dead_peers: impl FnMut(),
    mut gossip_maintenance: impl FnMut(),
) {
    launcher_maintenance();

    p2p_maintenance(process_reconnects, evict_expired_bans, try_fork_recovery);

    maybe_log_periodic(
        block_count,
        governance_proposal_count,
        dns_active_count,
        guardian_guarded_count,
    );

    eprintln!(
        "[NETWORK] peers: {}  miners: {}  synced: {}",
        total_peers, total_miners, is_synced
    );

    clean_dead_peers();
    gossip_maintenance();

    if tx_relayed > 0 || blocks_relayed > 0 {
        eprintln!(
            "[GOSSIP] TX relayed: {} | Blocks relayed: {} | Seen TX: {} | Seen blocks: {}",
            tx_relayed, blocks_relayed, seen_tx, seen_blocks
        );
    }

    if sync_stalled {
        eprintln!("[SYNC] STALLED >60s — resetare sync");
    }
}

/// Notify sync manager when a P2P peer announces a higher chain height, and
/// request missing blocks. Mirrors `maybeRequestPeerSync` in Zig.
pub fn maybe_request_peer_sync(
    peer_chain_height: u64,
    local_height: u64,
    mut on_peer_height: impl FnMut(u64) -> bool,
    mut request_sync: impl FnMut(u64),
) {
    if peer_chain_height > local_height {
        if on_peer_height(peer_chain_height) {
            request_sync(local_height);
            eprintln!(
                "[SYNC] requestSync trimis (local={} peer={})",
                local_height, peer_chain_height
            );
        }
    }
}

/// Update state-trie account entry for the current wallet after each block.
/// Mirrors `updateStateTrie` in Zig.
pub fn update_state_trie(
    address: &str,
    balance: u64,
    block_count: u64,
    mut update_fn: impl FnMut([u8; 20], u64, u32),
) {
    let mut addr_buf = [0u8; 20];
    let bytes = address.as_bytes();
    let copy_len = bytes.len().min(20);
    addr_buf[..copy_len].copy_from_slice(&bytes[..copy_len]);
    update_fn(addr_buf, balance, block_count as u32);
}

/// Propose a finality checkpoint every `CHECKPOINT_INTERVAL` blocks and
/// self-attest. Mirrors `maybeProposeCheckpoint` in Zig.
pub fn maybe_propose_checkpoint(
    block_count: u64,
    block_hash: [u8; 32],
    last_justified_epoch: u64,
    last_finalized_epoch: u64,
    mut propose_fn: impl FnMut(u64, [u8; 32]),
    mut attest_fn: impl FnMut(u64, u64, [u8; 32]),
) {
    if block_count % CHECKPOINT_INTERVAL == 0 && block_count > 0 {
        let epoch = block_count / CHECKPOINT_INTERVAL;
        propose_fn(block_count, block_hash);
        attest_fn(epoch, last_justified_epoch, block_hash);
        eprintln!(
            "[FINALITY] Checkpoint epoch {} | justified={} finalized={}",
            epoch, last_justified_epoch, last_finalized_epoch
        );
    }
}

/// Distribute staking rewards every `reward_epoch_blocks` blocks.
/// Mirrors `maybeDistributeStakingRewards` in Zig.
pub fn maybe_distribute_staking_rewards(
    block_count: u64,
    reward_epoch_blocks: u64,
    active_count: u32,
    current_epoch: u64,
    total_staked: u64,
    reward_sat: u64,
    mut distribute_fn: impl FnMut(u64),
) {
    if block_count % reward_epoch_blocks == 0 && active_count > 0 {
        distribute_fn(reward_sat);
        eprintln!(
            "[STAKING] Epoch {} | validators={} | total_staked={}",
            current_epoch, active_count, total_staked
        );
    }
}

/// Credit reputation for the just-mined block across all 4 domains:
/// FOOD (every block), LOVE (uptime every 60 blocks + daily streak every
/// 8640 blocks), RENT (per active staker), VACATION (daily tick).
/// Mirrors `creditReputationForBlock` in Zig.
pub struct StakerInfo {
    pub address: String,
    pub omni_staked: u64, // in OMNI (not SAT)
}

#[allow(clippy::too_many_arguments)]
pub fn credit_reputation_for_block(
    miner_addr: &str,
    block_count: u64,
    stakers: &[StakerInfo],
    all_known_addrs: &[String],
    mut credit_mined_block: impl FnMut(&str, u64),
    mut credit_uptime_minutes: impl FnMut(&str, u64, u64),
    mut credit_daily_streak: impl FnMut(&str, u64),
    mut credit_stake_per_block: impl FnMut(&str, u64, u64),
    mut credit_vacation_day: impl FnMut(&str, u64, u64),
) {
    // FOOD — block mined credit
    credit_mined_block(miner_addr, block_count);

    // LOVE — uptime credit for active miner (60 blocks ≈ 1 minute at 1s/block)
    if block_count > 0 && block_count % UPTIME_CREDIT_INTERVAL == 0 {
        credit_uptime_minutes(miner_addr, 1, block_count);
    }
    // LOVE bonus — daily streak (every 8640 blocks = 1 day)
    if block_count > 0 && block_count % BLOCKS_PER_DAY == 0 {
        credit_daily_streak(miner_addr, block_count);
    }

    // RENT — credit per-block for each active staker
    for staker in stakers {
        if staker.omni_staked == 0 {
            continue;
        }
        credit_stake_per_block(&staker.address, staker.omni_staked, block_count);
    }

    // VACATION — daily tick for every known address
    if block_count > 0 && block_count % BLOCKS_PER_DAY == 0 {
        let total_days = block_count / BLOCKS_PER_DAY;
        for addr in all_known_addrs {
            credit_vacation_day(addr, total_days, block_count);
        }
    }
}

/// Per-block chainstate flush + companion registry persists
/// (DNS / HTLC / payment channels / intents). Disk failure logs + continues
/// mining (background thread will retry). Mirrors `flushChainstatePerBlock`.
pub fn flush_chainstate_per_block(
    block_count: u64,
    mut save_chainstate: impl FnMut() -> bool,
    mut save_dns: impl FnMut() -> bool,
    mut save_htlc: impl FnMut() -> bool,
    mut save_channels: impl FnMut() -> bool,
    mut save_intents: impl FnMut() -> bool,
) {
    if save_chainstate() {
        eprintln!("[DB] Saved chainstate after block #{}", block_count);
        // Companion saves piggyback on chain save cadence.
        if !save_dns() {
            eprintln!("[DNS] Save failed at block #{}", block_count);
        }
        if !save_htlc() {
            eprintln!("[HTLC] Save failed at block #{}", block_count);
        }
        if !save_channels() {
            eprintln!("[CHANNELS] Save failed at block #{}", block_count);
        }
        if !save_intents() {
            eprintln!("[INTENT] Save failed at block #{}", block_count);
        }
    } else {
        eprintln!(
            "[DB] Per-block save failed at #{} — continuing mining, 30s thread will retry",
            block_count
        );
    }
}

/// Refresh balance cache for every miner-pool entry from chain state.
/// Mirrors `updateMinerPoolBalances` in Zig.
///
/// `pool_addresses` is a snapshot of miner addresses; `get_balance` queries
/// the chain; `update_balance` writes back into the pool.
pub fn update_miner_pool_balances(
    pool_addresses: &[String],
    mut get_balance: impl FnMut(&str) -> u64,
    mut update_balance: impl FnMut(&str, u64),
) {
    for addr in pool_addresses {
        let bal = get_balance(addr);
        update_balance(addr, bal);
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handle_wait_for_peers_returns_true_when_not_ready() {
        let mut started = false;
        let skip = handle_wait_for_peers(false, &mut started, 0, 0, 3, 0);
        assert!(skip);
        assert!(!started);
    }

    #[test]
    fn handle_wait_for_peers_starts_mining_when_ready() {
        let mut started = false;
        let skip = handle_wait_for_peers(true, &mut started, 0, 4, 3, 10);
        assert!(!skip);
        assert!(started);
    }

    #[test]
    fn handle_wait_for_peers_idempotent() {
        let mut started = true;
        let skip = handle_wait_for_peers(true, &mut started, 0, 4, 3, 10);
        assert!(!skip);
        assert!(started);
    }

    #[test]
    fn checkpoint_fires_at_interval() {
        let mut proposed = false;
        maybe_propose_checkpoint(
            CHECKPOINT_INTERVAL,
            [1u8; 32],
            0,
            0,
            |_, _| { proposed = true; },
            |_, _, _| {},
        );
        assert!(proposed);
    }

    #[test]
    fn checkpoint_skips_at_zero() {
        let mut proposed = false;
        maybe_propose_checkpoint(0, [0u8; 32], 0, 0, |_, _| { proposed = true; }, |_, _, _| {});
        assert!(!proposed);
    }

    #[test]
    fn reputation_credits_food_every_block() {
        let mut food_count = 0u32;
        credit_reputation_for_block(
            "ob1qtest",
            5,
            &[],
            &[],
            |_, _| { food_count += 1; },
            |_, _, _| {},
            |_, _| {},
            |_, _, _| {},
            |_, _, _| {},
        );
        assert_eq!(food_count, 1);
    }

    #[test]
    fn reputation_credits_love_uptime_at_interval() {
        let mut uptime_count = 0u32;
        credit_reputation_for_block(
            "ob1qtest",
            UPTIME_CREDIT_INTERVAL,
            &[],
            &[],
            |_, _| {},
            |_, _, _| { uptime_count += 1; },
            |_, _| {},
            |_, _, _| {},
            |_, _, _| {},
        );
        assert_eq!(uptime_count, 1);
    }

    #[test]
    fn staking_rewards_fire_at_epoch() {
        let mut distributed = false;
        maybe_distribute_staking_rewards(100, 100, 3, 1, 1000, 500, |_| { distributed = true; });
        assert!(distributed);
    }

    #[test]
    fn staking_rewards_skip_when_no_active_validators() {
        let mut distributed = false;
        maybe_distribute_staking_rewards(100, 100, 0, 1, 0, 500, |_| { distributed = true; });
        assert!(!distributed);
    }

    #[test]
    fn update_miner_pool_balances_calls_update_for_each() {
        let addrs = vec!["ob1qa".to_string(), "ob1qb".to_string()];
        let mut updated = vec![];
        update_miner_pool_balances(
            &addrs,
            |_| 42,
            |addr, bal| updated.push((addr.to_string(), bal)),
        );
        assert_eq!(updated.len(), 2);
        assert!(updated.iter().all(|(_, b)| *b == 42));
    }

    #[test]
    fn pair_labels_count() {
        assert_eq!(PAIR_LABELS.len(), 7);
    }
}
