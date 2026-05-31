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
