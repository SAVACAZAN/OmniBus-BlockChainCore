//! runtime_init — central runtime wiring (chain + mempool + p2p + rpc).
//!
//! Ported from `core/node/runtime_init.zig` (2026-06-02).
//!
//! Bundle of small init blocks:
//!   - `spawn_faucet_refill_thread` — Faza 5 faucet auto-refill thread.
//!   - `build_and_start_node_launcher` — NodeLauncher init + attachP2P + startSeed/Miner.
//!   - `init_oracle_fetcher` — global OracleFetcher (real exchange prices).
//!   - `init_metrics` — global performance Metrics, .start()'d.
//!   - `load_pair_registry` — optional --pair-registry FILE loader.
//!   - `init_ws_exchange_feed` — Coinbase / Kraken / LCX WS feed.
//!   - `init_reputation_manager` — credit ledger init.
//!   - `init_time_state` — TimeOrchestrator + tip-tracking pair.
//!
//! TODO: full port pending Rust ports of `node_launcher`, `oracle_fetcher`,
//! `benchmark`, `pair_registry`, `ws_exchange_feed`, `reputation_manager`,
//! `orchestrator`. Surface lives here so main.rs can be split.

#[derive(Debug, Clone, Copy)]
pub enum LauncherMode {
    Seed,
    Miner,
    Light,
}

#[derive(Debug, Clone)]
pub struct LauncherConfig {
    pub mode: LauncherMode,
    pub node_id: String,
    pub host: String,
    pub port: u16,
}

/// Stub: build the NodeLauncher and run the mode-specific start path.
pub fn build_and_start_node_launcher(cfg: &LauncherConfig) {
    match cfg.mode {
        LauncherMode::Seed => eprintln!("[LAUNCHER] (stub) startSeedNode {}:{}", cfg.host, cfg.port),
        LauncherMode::Light => eprintln!("[LIGHT] Node started in SPV mode — no mining, headers only"),
        LauncherMode::Miner => eprintln!("[LAUNCHER] (stub) startMinerNode {} on {}:{}", cfg.node_id, cfg.host, cfg.port),
    }
}

#[derive(Debug, Clone, Copy)]
pub struct FaucetRefillConfig {
    pub faucet_mode: bool,
    pub grant_sat: u64,
}

/// Stub: spawn the faucet auto-refill thread.
/// Returns true when the thread was spawned (faucet_mode active + wallet present).
pub fn spawn_faucet_refill_thread(cfg: FaucetRefillConfig, faucet_wallet_present: bool) -> bool {
    if !(cfg.faucet_mode && faucet_wallet_present) { return false; }
    eprintln!(
        "[FAUCET-REFILL] auto-refill thread started (threshold {} SAT, top-up {} SAT)",
        super::faucet::FAUCET_AMOUNT_SAT, cfg.grant_sat,
    );
    true
}

/// Stub: init OracleFetcher.
pub fn init_oracle_fetcher() {
    eprintln!("[ORACLE-FETCHER] (stub) real price fetcher init pending oracle_fetcher port");
}

/// Stub: init performance Metrics + .start().
pub fn init_metrics() {
    eprintln!("[METRICS] Performance tracking initialized\n");
}

/// Stub: load `--pair-registry FILE`.
pub fn load_pair_registry(path_opt: Option<&str>) -> bool {
    match path_opt {
        Some(p) if std::path::Path::new(p).exists() => {
            eprintln!("[PAIR-REGISTRY] (stub) Loaded {p}");
            true
        }
        Some(p) => {
            eprintln!("[PAIR-REGISTRY] Load failed for {p}: not found");
            false
        }
        None => false,
    }
}

#[derive(Debug, Clone, Copy)]
pub struct WsFeedConfig {
    pub external_oracle: bool,
}

/// Stub: init live WS exchange feed.
pub fn init_ws_exchange_feed(cfg: WsFeedConfig) {
    if cfg.external_oracle {
        eprintln!(
            "[WS-FEED] external oracle enabled (OMNIBUS_EXTERNAL_ORACLE=1) \
             — in-process WS feed disabled. Bridging from omnibus-oracle on :28100"
        );
    } else {
        eprintln!("[WS-FEED] (stub) starting in-process WS feed");
    }
}

/// Stub: init ReputationManager + stamp `started_at_block`.
pub fn init_reputation_manager(_tip_height: u64) {
    eprintln!("[REPUTATION] (stub) manager init pending reputation_manager port");
}

#[derive(Debug, Clone, Copy)]
pub struct TimeState {
    pub last_tip_height: u64,
    pub tip_arrival_ms: i64,
}

/// Stub: build the time orchestrator.
pub fn init_time_state(chain_len: u64, now_ms: i64) -> TimeState {
    TimeState { last_tip_height: chain_len, tip_arrival_ms: now_ms }
}

/// Burst-smoothing constants. Caps how often WE produce two consecutive
/// blocks so a VPS scheduler pause doesn't create a thundering herd
/// after resume.
pub const MIN_BLOCK_GAP_MS: i64 = 800;

#[derive(Debug, Clone, Copy)]
pub struct BurstSmoothing {
    pub last_block_produced_ms: i64,
}

impl BurstSmoothing {
    pub fn new() -> Self { Self { last_block_produced_ms: 0 } }
}

impl Default for BurstSmoothing {
    fn default() -> Self { Self::new() }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parity_time_state_records_tip() {
        let t = init_time_state(42, 1234);
        assert_eq!(t.last_tip_height, 42);
        assert_eq!(t.tip_arrival_ms, 1234);
    }
}
