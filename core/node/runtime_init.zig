// core/node/runtime_init.zig
//
// Bundle of 5 small init blocks extracted from main.zig (2026-05-31).
// Same args, same print lines, same behavior — pure refactor to reduce
// main.zig surface area.
//
// Helpers:
//   spawnFaucetRefillThread — Faza 5 faucet auto-refill thread.
//   buildAndStartNodeLauncher — NodeLauncher init + attachP2P + startSeed/Miner.
//   initOracleFetcher — global OracleFetcher (real exchange prices) + worker.
//   initMetrics — global performance Metrics, .start()'d.
//   loadPairRegistry — optional --pair-registry FILE loader.
//
// All globals (g_oracle_fetcher, g_metrics, g_pair_registry) are assigned
// by main.zig from the returned values (matches existing extraction pattern,
// see node/subsystems_init.zig).

const std = @import("std");

const node_launcher_mod  = @import("../node_launcher.zig");
const p2p_mod            = @import("../p2p.zig");
const faucet_thread_mod  = @import("faucet_thread.zig");
const blockchain_mod     = @import("../blockchain.zig");
const wallet_mod         = @import("../wallet.zig");
const oracle_fetcher_mod = @import("../oracle_fetcher.zig");
const benchmark_mod      = @import("../benchmark.zig");
const pair_registry_mod  = @import("../pair_registry.zig");
const ws_exchange_feed_mod = @import("../ws_exchange_feed.zig");
const reputation_manager_mod = @import("../reputation_manager.zig");
const orchestrator_mod   = @import("../orchestrator.zig");

const FAUCET_REFILL_THRESHOLD_SAT = faucet_thread_mod.FAUCET_REFILL_THRESHOLD_SAT;
const FAUCET_REFILL_AMOUNT_SAT    = faucet_thread_mod.FAUCET_REFILL_AMOUNT_SAT;

/// Spawn the faucet auto-refill thread (Faza 5) when the operator runs in
/// `--faucet-mode` and a faucet wallet is available. Top-up source is the
/// miner's primary wallet; threshold + amount come from the build-time
/// constants in faucet_thread.zig. No-op (returns) when faucet_mode is off
/// or no faucet wallet is configured. Returns true if a thread was spawned.
pub fn spawnFaucetRefillThread(
    allocator: std.mem.Allocator,
    faucet_mode: bool,
    grant_sat: u64,
    bc: *blockchain_mod.Blockchain,
    wallet: *wallet_mod.Wallet,
    faucet_wallet_opt: ?*wallet_mod.Wallet,
) bool {
    if (!(faucet_mode and faucet_wallet_opt != null)) return false;
    const refill_args = allocator.create(faucet_thread_mod.FaucetRefillArgs) catch return false;
    refill_args.* = .{
        .bc = bc,
        .miner_wallet = wallet,
        .faucet_wallet = faucet_wallet_opt.?,
        .grant_sat = grant_sat,
        .alloc = allocator,
    };
    const rt = std.Thread.spawn(.{}, faucet_thread_mod.faucetRefillLoop, .{refill_args}) catch |err| blk: {
        std.debug.print("[FAUCET-REFILL] thread spawn failed: {}\n", .{err});
        break :blk null;
    };
    if (rt) |th| {
        th.detach();
        std.debug.print("[FAUCET-REFILL] auto-refill thread started (threshold {d} SAT, top-up {d} SAT)\n",
            .{ FAUCET_REFILL_THRESHOLD_SAT, FAUCET_REFILL_AMOUNT_SAT });
        return true;
    }
    return false;
}

/// Build the NodeLauncher, attach the real P2PNode (broadcast() uses TCP
/// instead of print-only), and run the mode-specific start path:
///   .seed  → startSeedNode
///   .light → log + startSeedNode (reuse seed init: listener + bootstrap)
///   else   → startMinerNode
/// Returns the launcher by value; caller owns `defer launcher.deinit()`
/// and any later `launcher.startMining()`.
pub fn buildAndStartNodeLauncher(
    config: node_launcher_mod.NodeConfig,
    p2p: *p2p_mod.P2PNode,
) !node_launcher_mod.NodeLauncher {
    var launcher = node_launcher_mod.NodeLauncher.init(config);
    // Ataseaza P2PNode real la launcher — broadcast() va folosi TCP in loc de print-only
    launcher.attachP2PNode(p2p);

    if (config.mode == node_launcher_mod.NodeMode.seed) {
        try launcher.startSeedNode();
    } else if (config.mode == node_launcher_mod.NodeMode.light) {
        // Light mode: no mining, just header sync
        std.debug.print("[LIGHT] Node started in SPV mode — no mining, headers only\n", .{});
        try launcher.startSeedNode(); // reuse seed init (listener + bootstrap)
    } else {
        try launcher.startMinerNode();
    }
    return launcher;
}

/// Initialize the global OracleFetcher (LCX/Kraken/Coinbase × BTC/LCX) and
/// spawn its dedicated worker thread so the mining loop never blocks on
/// the network. Returns the fetcher by value; caller assigns to global
/// (g_oracle_fetcher = …). On worker spawn failure the fetcher is still
/// returned but prints the "disabled" line so RPC keeps reading an empty
/// snapshot rather than null.
pub fn initOracleFetcher(allocator: std.mem.Allocator) oracle_fetcher_mod.OracleFetcher {
    var f = oracle_fetcher_mod.OracleFetcher.init(allocator);
    f.startWorker() catch |err| {
        std.debug.print("[ORACLE-FETCHER] worker spawn failed: {} — fetcher disabled\n",
            .{err});
    };
    std.debug.print("[ORACLE-FETCHER] Real price fetcher initialized + worker thread started\n", .{});
    return f;
}

/// Initialize the global performance Metrics counter and stamp the start
/// time at runtime (timestamp() can't run at comptime, hence the explicit
/// .start() rather than relying on the comptime-default init()).
pub fn initMetrics() benchmark_mod.Metrics {
    var m = benchmark_mod.Metrics.init();
    m.start(); // set start_time at runtime (can't call timestamp() at comptime)
    std.debug.print("[METRICS] Performance tracking initialized\n\n", .{});
    return m;
}

/// Load the optional pair registry JSON given on the CLI as
/// `--pair-registry FILE`. Returns null when no path was provided OR when
/// the load failed (error is logged and the node continues with just the
/// hard-coded IMPORTANT_PAIRS list, matching legacy behavior).
pub fn loadPairRegistry(
    allocator: std.mem.Allocator,
    path_opt: ?[]const u8,
) ?pair_registry_mod.PairRegistry {
    const reg_path = path_opt orelse return null;
    if (pair_registry_mod.loadFile(allocator, reg_path)) |reg| {
        std.debug.print(
            "[PAIR-REGISTRY] Loaded {s}: lcx={d}, kraken={d}, coinbase={d} (total {d})\n",
            .{ reg_path, reg.lcx.len, reg.kraken.len, reg.coinbase.len, reg.totalRoutes() },
        );
        return reg;
    } else |err| {
        std.debug.print("[PAIR-REGISTRY] Load failed for {s}: {s} (continuing with IMPORTANT_PAIRS only)\n",
            .{ reg_path, @errorName(err) });
        return null;
    }
}

/// Initialize the live WebSocket exchange feed (Coinbase / Kraken / LCX).
///
/// Two modes:
///   - In-process WS feed (default): start 3 WS worker threads.
///   - External oracle mode (OMNIBUS_EXTERNAL_ORACLE=1): create an EMPTY
///     feed that the bridge poll thread fills from the standalone
///     omnibus-oracle on localhost:28100.
///
/// In external mode `start_oracle_bridge_fn` is invoked so the caller can
/// spawn the bridge thread (kept as a callback to avoid pulling the
/// oracle_bridge module into runtime_init's dep graph).
///
/// Returns the feed by value. Caller assigns to `g_ws_feed` and is
/// responsible for the (rare) shutdown path.
pub fn initWsExchangeFeed(
    allocator: std.mem.Allocator,
    pair_registry: ?*pair_registry_mod.PairRegistry,
    clock: *const orchestrator_mod.AtomicClock,
    start_oracle_bridge_fn: *const fn (std.mem.Allocator) anyerror!void,
) ws_exchange_feed_mod.ExchangeFeed {
    const external_oracle = std.process.getEnvVarOwned(
        allocator, "OMNIBUS_EXTERNAL_ORACLE",
    ) catch null;
    defer if (external_oracle) |s| allocator.free(s);
    const use_external = external_oracle != null and
        std.mem.eql(u8, external_oracle.?, "1");
    if (use_external) {
        std.debug.print(
            "[WS-FEED] external oracle enabled (OMNIBUS_EXTERNAL_ORACLE=1) " ++
            "— in-process WS feed disabled. Bridging from omnibus-oracle on :28100\n", .{});
        var feed = ws_exchange_feed_mod.ExchangeFeed.init(allocator);
        if (pair_registry) |reg| feed.setPairRegistry(reg);
        feed.setClock(clock);
        start_oracle_bridge_fn(allocator) catch |err| {
            std.debug.print("[ORACLE-BRIDGE] spawn failed: {} — feed will stay empty\n", .{err});
        };
        return feed;
    } else {
        var feed = ws_exchange_feed_mod.ExchangeFeed.init(allocator);
        if (pair_registry) |reg| feed.setPairRegistry(reg);
        // Wire the shared clock BEFORE start() — every PriceFetch.timestamp_ms
        // and circuit-breaker rate-limit timer flows through clock.nowMs(),
        // putting feed events on the same timeline as mining and matching.
        feed.setClock(clock);
        feed.start() catch |err| std.debug.print("[WS-FEED] start failed: {}\n", .{err});
        return feed;
    }
}

/// Initialize the ReputationManager and stamp `started_at_block` at the
/// current chain tip. Caller runs `backfillReputationFromChain` separately
/// (kept out of this helper because the backfill function lives in the
/// agents module and pulling it in would create a circular dep).
pub fn initReputationManager(
    allocator: std.mem.Allocator,
    tip_height: usize,
) reputation_manager_mod.ReputationManager {
    var rep = reputation_manager_mod.ReputationManager.init(allocator);
    rep.started_at_block = @intCast(tip_height);
    return rep;
}

/// Build the single source of time used by every subsystem. Wraps the
/// global AtomicClock in a TimeOrchestrator and configures the stabilizer
/// timer (slot + sub-block timers remain driven by their existing logic;
/// cut over incrementally).
///
/// Also returns the initial tip-tracking pair (`last_tip_height`,
/// `tip_arrival_ms`) — millisecond-resolution wall-clock for the current
/// tip, refreshed each loop iteration when the chain extends. The on-chain
/// `tip.timestamp` is in seconds (too coarse for sub-second slot-failover).
pub const TimeState = struct {
    orch: orchestrator_mod.TimeOrchestrator,
    last_tip_height: usize,
    tip_arrival_ms: i64,
};

pub fn initTimeState(
    clock: *orchestrator_mod.AtomicClock,
    chain_len: usize,
) TimeState {
    var orch = orchestrator_mod.TimeOrchestrator.init(clock);
    orch.configure(.stabilizer, 60_000);
    return .{
        .orch = orch,
        .last_tip_height = chain_len,
        .tip_arrival_ms = clock.nowMs(),
    };
}

/// Burst-smoothing state. Caps how often WE produce two consecutive
/// blocks so a VPS scheduler pause doesn't create a "thundering herd"
/// after resume. See main.zig for the full rationale (800 ms gap maps
/// to the whitepaper 60-blocks/min target).
pub const BurstSmoothing = struct {
    pub const MIN_BLOCK_GAP_MS: i64 = 800;
    last_block_produced_ms: i64,

    pub fn init() BurstSmoothing {
        return .{ .last_block_produced_ms = 0 };
    }
};

/// Block-rate stabilizer state.
///
/// Ring buffer of the last RATE_RING_SIZE block-arrival timestamps. Used
/// to (1) report rolling rates (1-min and 60-min windows) and (2) feed
/// an adaptive SLOT_TIMEOUT_MS multiplier — under target we shrink the
/// timeout (faster failover); over target we relax it (less wasted CPU).
///
/// 3600 entries × 8 bytes = 28.8 KB fixed; at 1 block/s that's 60 minutes
/// of history — exactly the "blocks in last 60min" stat the operator
/// reads.
pub const StabilizerState = struct {
    pub const RATE_RING_SIZE: usize = 3600;
    pub const TARGET_BLOCKS_PER_MIN: f64 = 60.0;

    rate_ring: [RATE_RING_SIZE]i64,
    rate_ring_head: usize,
    rate_ring_count: usize,
    stabilizer_last_report_ms: i64,
    stabilizer_timeout_mult: f64,

    pub fn init(clock: *orchestrator_mod.AtomicClock) StabilizerState {
        return .{
            .rate_ring = std.mem.zeroes([RATE_RING_SIZE]i64),
            .rate_ring_head = 0,
            .rate_ring_count = 0,
            .stabilizer_last_report_ms = clock.nowMs(),
            .stabilizer_timeout_mult = 1.0,
        };
    }
};
