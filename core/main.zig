const std     = @import("std");
const builtin = @import("builtin");

// Re-export the EVM build flag at root scope so that sub-modules
// (evm_executor.zig) can probe it via `@hasDecl(@import("root"), …)`.
// build.zig wires `build_options` into this exe via `addOptions()`.
pub const build_options_evm_enabled: bool = @import("build_options").evm_enabled;

// ── Single-instance lock — un singur miner per masina ────────────────────────
// Windows: lock file exclusiv  omnibus-miner.lock (in directorul curent)
// Linux/macOS: flock()         /tmp/omnibus-miner.lock
fn acquireSingleInstanceLock() void {
    if (comptime builtin.os.tag == .windows) {
        windows_lock.acquire();
        // handle ramas deschis pana la exit — OS il elibereaza + sterge fisierul
    } else {
        // Linux / macOS / BSD: flock pe /tmp/omnibus-miner.lock
        const lock_path = "/tmp/omnibus-miner.lock";
        var file = std.fs.createFileAbsolute(lock_path, .{}) catch {
            std.debug.print("[LOCK] Nu pot crea {s} — continuam fara lock\n", .{lock_path});
            return;
        };
        // flock(fd, LOCK_EX | LOCK_NB) = 6
        const rc = std.posix.flock(file.handle, 6) catch {
            std.debug.print("\n[BLOCKED] Un miner OmniBus ruleaza deja pe acest PC!\n", .{});
            std.debug.print("          Un singur miner per masina — regula de retea.\n", .{});
            std.debug.print("          Opreste instanta curenta inainte sa pornesti alta.\n\n", .{});
            std.process.exit(1);
            return;
        };
        _ = rc;
        // Scrie PID in lock file
        var pid_buf: [32]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d}\n",
            .{std.os.linux.getpid()}) catch "";
        file.writeAll(pid_str) catch {};
        // NU inchidem — lock activ pana la exit procesului (intentional leak)
        std.mem.doNotOptimizeAway(&file);
    }
}
const blockchain_mod  = @import("blockchain.zig");
const rpc_mod         = @import("rpc_server.zig");
const wallet_mod      = @import("wallet.zig");
const cli_mod         = @import("cli.zig");
const node_launcher   = @import("node_launcher.zig");
const vault_reader    = @import("vault_reader.zig");
const database_mod    = @import("database.zig");
const genesis_mod     = @import("genesis.zig");
const mempool_mod     = @import("mempool.zig");
const consensus_mod   = @import("consensus.zig");
const p2p_mod         = @import("p2p.zig");
const sub_block_mod   = @import("sub_block.zig");
const sync_mod        = @import("sync.zig");
const metachain_mod   = @import("metachain.zig");
const shard_mod       = @import("shard_coordinator.zig");
const miner_wallet_mod = @import("miner_wallet.zig");
const benchmark_mod    = @import("benchmark.zig");

const Blockchain           = blockchain_mod.Blockchain;
const Wallet               = wallet_mod.Wallet;
const CLI                  = cli_mod.CLI;
const PersistentBlockchain = database_mod.PersistentBlockchain;
// NOTE: NetworkConfig (din genesis.zig) este DEPRECATED — inlocuit cu ChainConfig.
// A3 (agent genesis) va actualiza GenesisState.init sa accepte ChainConfig.
const GenesisState         = genesis_mod.GenesisState;
const ChainConfig          = @import("chain_config.zig").ChainConfig;
const ChainId              = @import("chain_config.zig").ChainId;
const Mempool              = mempool_mod.Mempool;
const ConsensusConfig      = consensus_mod.ConsensusConfig;
const ConsensusEngine      = consensus_mod.ConsensusEngine;
const P2PNode              = p2p_mod.P2PNode;
const SubBlockEngine       = sub_block_mod.SubBlockEngine;
const SyncManager          = sync_mod.SyncManager;
const ws_mod               = @import("ws_server.zig");
const WsServer             = ws_mod.WsServer;
const rpc_mod_ctx          = @import("rpc_server.zig");
const bootstrap_mod        = @import("bootstrap.zig");

// ── Subsystems integrated into node ─────────────────────────────────────────
const finality_mod     = @import("finality.zig");
const governance_mod   = @import("governance.zig");
const staking_mod      = @import("staking.zig");
const chain_config_mod = @import("chain_config.zig");
const validator_mod    = @import("validator_registry.zig");
const state_trie_mod   = @import("state_trie.zig");
const tx_receipt_mod   = @import("tx_receipt.zig");
const guardian_mod     = @import("guardian.zig");
const dns_mod          = @import("dns_registry.zig");
const registrar_mod    = @import("registrar_addresses.zig");
const peer_scoring_mod = @import("peer_scoring.zig");
const compact_mod      = @import("compact_blocks.zig");
const kademlia_mod     = @import("kademlia_dht.zig");
const key_enc_mod      = @import("key_encryption.zig");
const light_client_mod = @import("light_client.zig");
const light_miner_mod  = @import("light_miner.zig");
const payment_mod      = @import("payment_channel.zig");
const bread_mod        = @import("bread_ledger.zig");
const schnorr_mod      = @import("schnorr.zig");
const multisig_mod     = @import("multisig.zig");
const bls_mod          = @import("bls_signatures.zig");
const matching_mod     = @import("matching_engine.zig");
const price_oracle_mod = @import("price_oracle.zig");
const pouw_mod         = @import("consensus_pouw.zig");
const orderbook_sync_mod = @import("orderbook_sync.zig");
const oracle_fetcher_mod = @import("oracle_fetcher.zig");
const ws_exchange_feed_mod = @import("ws_exchange_feed.zig");
const pair_registry_mod = @import("pair_registry.zig");
const reputation_mod = @import("reputation.zig");
const reputation_manager_mod = @import("reputation_manager.zig");
const oracle_policy_mod  = @import("oracle_policy.zig");
const evm_executor_mod   = @import("evm_executor.zig");
// AI Agent BRAIN — trăiește în nod (decizii on-chain provable).
// EXECUTION external (LCX/Kraken/Coinbase/Uniswap) e făcut de un client Python
// separat în 2_SDK/omnibus-sdk/agent/ care interogheaza prin RPC ce trebuie
// executat și raportează rezultatul înapoi.
const agent_tier_mod     = @import("agent_tier.zig");
const agent_config_mod   = @import("agent_config.zig");
const agent_executor_mod = @import("agent_executor.zig");
const agent_manager_mod  = @import("agent_manager.zig");

// Single-source-of-time module — feeds slot/sub_block/stabilizer/ws
// timers from one AtomicClock so cross-component latencies are real
// rather than the result of unsynchronized OS clock reads.
const orchestrator_mod = @import("orchestrator.zig");
const chainstate_mod   = @import("store/chainstate.zig");

// Force compilation of all subsystems (ensures tests are included in full build)
comptime {
    _ = finality_mod; _ = governance_mod; _ = staking_mod;
    // chain_config_mod is now actively used via ChainConfig/ChainId re-imports above
    _ = state_trie_mod; _ = tx_receipt_mod;
    _ = guardian_mod; _ = dns_mod; _ = peer_scoring_mod;
    _ = compact_mod; _ = kademlia_mod; _ = key_enc_mod;
    _ = light_client_mod; _ = light_miner_mod; _ = payment_mod;
    _ = bread_mod; _ = schnorr_mod; _ = multisig_mod; _ = bls_mod;
    _ = miner_wallet_mod; _ = benchmark_mod;
    _ = price_oracle_mod; _ = pouw_mod; _ = orderbook_sync_mod;
    _ = oracle_fetcher_mod;
    _ = oracle_policy_mod;
    _ = pair_registry_mod;
    _ = reputation_mod; _ = reputation_manager_mod;
    _ = agent_tier_mod; _ = agent_config_mod;
    _ = agent_executor_mod; _ = agent_manager_mod;
    _ = @import("witness_data.zig"); _ = @import("compact_transaction.zig");
    _ = @import("os_mode.zig"); _ = @import("synapse_priority.zig");
    _ = @import("omni_brain.zig"); _ = @import("oracle.zig");
    _ = @import("bridge_relay.zig"); _ = @import("domain_minter.zig");
    _ = @import("ubi_distributor.zig");
}

const LEGACY_DB_PATH = "omnibus-chain.dat";  // mainnet fallback only

// ── Graceful Shutdown — Ctrl+C / SIGINT handler ─────────────────────────────
// Atomic flag checked by the mining loop; set by OS signal handler.
var g_shutdown = std.atomic.Value(bool).init(false);

fn installShutdownHandler() void {
    if (comptime builtin.os.tag == .windows) {
        // Windows: use std.os.windows.SetConsoleCtrlHandler wrapper
        std.os.windows.SetConsoleCtrlHandler(&windows_handlers.windowsCtrlHandler, true) catch {
            std.debug.print("[SHUTDOWN] Failed to install Ctrl+C handler\n", .{});
        };
    } else {
        // POSIX: catch SIGINT + SIGTERM
        // empty_sigset removed in Zig 0.15 — use zeroes for portable empty mask.
        const act = std.posix.Sigaction{
            .handler = .{ .handler = posixSignalHandler },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    }
}

// Windows-only handler — wrapped in a struct so std.os.windows.DWORD/BOOL
// type references don't get resolved on non-Windows targets.
const windows_handlers = if (builtin.os.tag == .windows) struct {
    pub fn windowsCtrlHandler(dwCtrlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
        _ = dwCtrlType;
        g_shutdown.store(true, .monotonic);
        return std.os.windows.TRUE; // handled, don't terminate immediately
    }
} else struct {};

// Windows-only single-instance lock via CreateFileW exclusive — wrapped so
// kernel32 symbol references don't leak into non-Windows builds.
const windows_lock = if (builtin.os.tag == .windows) struct {
    pub fn acquire() void {
        const lock_path_w = std.unicode.utf8ToUtf16LeStringLiteral("omnibus-miner.lock");
        const handle = std.os.windows.kernel32.CreateFileW(
            lock_path_w,
            std.os.windows.GENERIC_WRITE,
            0, // ShareMode = 0 → exclusiv, alt proces nu poate deschide
            null,
            std.os.windows.OPEN_ALWAYS,
            std.os.windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
            std.debug.print("\n[BLOCKED] Un miner OmniBus ruleaza deja pe acest PC!\n", .{});
            std.debug.print("          Un singur miner per masina — regula de retea.\n", .{});
            std.debug.print("          Opreste instanta curenta inainte sa pornesti alta.\n\n", .{});
            std.process.exit(1);
        }
    }
} else struct {
    pub fn acquire() void {}
};

fn posixSignalHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    g_shutdown.store(true, .monotonic);
}

const NUM_SHARDS: u8 = 4;

// ── Global Miner Wallet Pool — shared intre RPC thread si mining loop ───────
// Round-robin: fiecare bloc e minat de alt miner din pool
// F8: fiecare miner are key pair real (secp256k1) si poate semna TX-uri
pub const MinerWalletPool = miner_wallet_mod.MinerWalletPool;
pub var g_miner_pool = MinerWalletPool{};

// ── Global Performance Metrics — shared intre RPC thread si mining loop ────
pub var g_metrics = benchmark_mod.Metrics.init();

// ── Global Payment Channel Manager ─────────────────────────────────────────
pub var g_channel_mgr = payment_mod.ChannelManager.init();

// ── Global Exchange Modules — PoUW matching, oracle, sync ──────────────────
pub var g_pouw_engine = pouw_mod.PoUWEngine.init();
pub var g_price_oracle = price_oracle_mod.DistributedPriceOracle.init();
// Note: MatchingEngine and OrderbookSyncManager are ~3MB+ each, allocated in mining loop

// ── Global AI Agent Manager ─────────────────────────────────────────────────
// Holds all AI agents loaded from `--agent-config <file>`. Each agent has its
// own tier, strategy, and rules. Tick-uri rulate din mining loop la fiecare
// bloc nou (vezi agentTickAll mai jos).
pub var g_agent_manager = agent_manager_mod.AgentManager.init();
// True = at least one agent loaded, run agentTickAll() on every block.
pub var g_agents_active: bool = false;

// ── Global Oracle Fetcher — real exchange prices from LCX, Kraken, Coinbase ──
// Initialized in main() with a real allocator (needs HTTP client)
pub var g_oracle_fetcher: ?oracle_fetcher_mod.OracleFetcher = null;

// ── Global AtomicClock — single source of time across the whole node ───────
// Initialised lazily at runtime entry (initReal() reads OS clock which
// can't run at comptime). Subsystems started after main() entry attach to
// this via &g_clock. On baremetal we'll swap the backend to TSC.
pub var g_clock: orchestrator_mod.AtomicClock = undefined;

// ── Global TSC frequency (cycles per second) — measured once at startup ────
// Populated by calibrateTscPerSec() in main(). Stays constant for the
// process lifetime because invariant TSC is invariant. Used by the
// stabilizer to convert raw rdtsc cycle deltas into seconds without
// re-calibrating per slot.
pub var g_tsc_freq: u64 = 0;

// ── Global ChainState — Bitcoin-style WAL+memtable persistent store ────────
//
// Phase C.4: alongside (NOT replacing) bc.balances, every applyBlock-time
// balance/nonce mutation now also flows through g_chainstate. The
// chainstate has its own append-only WAL (durable across crashes) and
// a periodic snapshot that lets the next startup load in O(1) instead
// of replaying the whole chain.
//
// Lifecycle:
//   - opened in main() right after pbc.restoreInto, before mining starts
//   - written on every put_balance / put_nonce inside applyBlock
//   - checkpointed by the state-save thread every 60 s
//   - audited by the stabilizer once a minute (chainstate vs bc.balances)
//   - closed at graceful shutdown
//
// Once a release cycle of clean audits passes, a follow-up commit deletes
// bc.balances + bc.nonces entirely and chainstate becomes the only path.
pub var g_chainstate: ?chainstate_mod.ChainState = null;

// ── State save thread — band-aid before Bitcoin-style storage refactor ─────
//
// Background thread that calls saveBlockchain() on a fixed interval. Decoupled
// from the mining loop so a slow disk write never blocks block production.
// The mining loop holds bc.mutex briefly while applying TXs; the saver also
// takes that mutex to read a coherent snapshot, then writes outside the lock.
//
// Why this exists: commit b363095 disabled in-mining-loop saves to recover
// the p99 latency we lost to "every block does a 50 MB rewrite". The
// trade-off was that balances which weren't materialised as on-chain TXs
// (faucet grants written directly to bc.balances) didn't survive restart.
// Faucet recipients lost ~51 testnet balances at the next restart.
//
// This thread is the temporary fix. The proper fix is the Bitcoin-style
// storage refactor (blocks/blkNNNNN.dat append + chainstate/ KV) tracked
// in arch/leveldb-storage. See ARCH_BITCOIN_STORAGE.md for the full plan.
pub var g_state_save_run: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var g_state_save_thread: ?std.Thread = null;

// Reduced 60s → 30s ca extra safety net pe langa per-block save (vezi
// fix-ul din mining loop dupa applyBlock). Pana cand storage-ul devine
// incremental (Bitcoin-style blkNNNNN.dat), saveToDisc face un rewrite
// monolitic, dar la ~hundreds-of-ms ramane sub block time. Daca per-block
// save esueaza tranzitoriu, thread-ul ăsta prinde state-ul in 30s.
const STATE_SAVE_INTERVAL_SEC: i64 = 30;

fn stateSaveLoop(bc: *blockchain_mod.Blockchain) void {
    // First save runs after the interval, not at startup, because the
    // chain has just been restored from disk — saving immediately would
    // be a no-op write of identical bytes. We sleep first.
    while (g_state_save_run.load(.acquire)) {
        var slept_s: i64 = 0;
        while (slept_s < STATE_SAVE_INTERVAL_SEC and g_state_save_run.load(.acquire)) : (slept_s += 1) {
            std.Thread.sleep(1 * std.time.ns_per_s);
        }
        if (!g_state_save_run.load(.acquire)) break;

        // saveToDisc takes bc.mutex internally for the snapshot read; it
        // does NOT hold it during the actual file write, so a slow disk
        // doesn't stall the mining loop. Worst case the saver itself waits
        // for the mining loop to release the mutex (~ms), which is fine.
        bc.saveToDisc() catch |err| {
            std.debug.print("[DB] Background save failed: {}\n", .{err});
        };
    }
}

pub fn startStateSaveThread(bc: *blockchain_mod.Blockchain) !void {
    if (g_state_save_run.load(.acquire)) return;
    g_state_save_run.store(true, .release);
    g_state_save_thread = try std.Thread.spawn(.{}, stateSaveLoop, .{bc});
    std.debug.print(
        "[DB] Background state-save thread started (interval = {d}s)\n",
        .{STATE_SAVE_INTERVAL_SEC},
    );
}

pub fn stopStateSaveThread() void {
    g_state_save_run.store(false, .release);
    if (g_state_save_thread) |t| {
        t.join();
        g_state_save_thread = null;
    }
}

// ── Global Slot Calendar — pre-computed next 60 slots (PoH-style) ─────────
// Rebuilt after each block from the validator set + tip hash. Read-only
// from frontend (RPC endpoint `getslotcalendar`) and from the mining
// loop (which uses `nextFutureSlot()` for "what's next" hints).
pub var g_slot_calendar: orchestrator_mod.SlotCalendar =
    orchestrator_mod.SlotCalendar.empty();

// ── Global WS Exchange Feed — live BTC + LCX bid/ask via WebSocket ──────────
// Initialized in main() after all other inits, before mining loop
pub var g_ws_feed: ?ws_exchange_feed_mod.ExchangeFeed = null;
/// Optional pair registry loaded from `--pair-registry FILE`. Owned by main()
/// — lives until process exit. WS feed holds a borrow.
pub var g_pair_registry: ?pair_registry_mod.PairRegistry = null;

// Reputation manager — tracks 4 paharele (LOVE/FOOD/RENT/VACATION) per address.
// Initialized lazy in main() with allocator (HashMap needs alloc).
pub var g_reputation: ?reputation_manager_mod.ReputationManager = null;

// ── Global Oracle Policy — per-node price-deviation validation thresholds ──
// Defaults are applied at startup based on chain (mainnet=strict, regtest=off)
// and CLI flags can override individual knobs. Modified atomically via the
// `omnibus_setoraclepolicy` RPC method (protected by g_oracle_policy_mutex).
pub var g_oracle_policy: oracle_policy_mod.OraclePolicy = .{};
pub var g_oracle_policy_mutex: std.Thread.Mutex = .{};

// Thread RPC — pornit din main, detach
const RPCThreadArgs = struct {
    bc:       *Blockchain,
    wallet:   *Wallet,
    /// Optional faucet wallet (loaded only when --faucet-mode is set).
    /// Forwarded to the RPC server so handler `claimFaucet` can sign
    /// 0.1-OMNI grants without touching the miner's primary key.
    faucet_wallet: ?*Wallet,
    /// Per-claim grant in SAT. 0 means faucet is disabled at runtime.
    faucet_grant_sat: u64,
    /// On-chain DNS / ENS registry — names like "alice.omnibus" → ob1q…
    dns:      *dns_mod.DnsRegistry,
    alloc:    std.mem.Allocator,
    mempool:  *mempool_mod.Mempool,
    p2p:      *p2p_mod.P2PNode,
    sync_mgr: *sync_mod.SyncManager,
    metrics:  *benchmark_mod.Metrics,
    channel_mgr: *payment_mod.ChannelManager,
    staking:  *staking_mod.StakingEngine,
    chain_id: u32,
    /// RPC port from chain config — 8332/18332/28332/38332.
    /// Without this all chains collide on hardcoded 8332.
    rpc_port: u16,
    /// Bind address. "127.0.0.1" by default for safety, "0.0.0.0" only for
    /// nodes intended to be public RPC endpoints.
    rpc_bind: []const u8,
    /// Optional bearer token. When set, non-loopback requests must include
    /// `Authorization: Bearer <token>`.
    rpc_token: ?[]const u8,
    /// Native DEX matching engine. Allocated once at startup, shared across
    /// RPC threads. Null = exchange disabled (light nodes).
    exchange: ?*matching_mod.MatchingEngine,
    /// Paper-trading matching engine (separate from real-money). Same lock,
    /// different state. Null when paper trader is disabled.
    exchange_paper: ?*matching_mod.MatchingEngine,
    /// Path to `data/<chain>/orders.jsonl`. Empty = in-memory only (regtest).
    orders_path: ?[]const u8,
    /// Path to `data/<chain>/exchange-users.jsonl`. Stores apikeys + balances.
    users_path: ?[]const u8,
    /// Path to `data/<chain>/identities.jsonl`. Stores public nickname /
    /// ENS-pref / visibility per address.
    identities_path: ?[]const u8,
    /// Path to `data/<chain>/kyc-attestations.jsonl`. Signed level proofs.
    kyc_path: ?[]const u8,
    /// Address of the KYC issuer (registrar slot 4 = `kyc.omnibus`).
    /// Null = node accepts no KYC issuance (read-only KYC).
    kyc_issuer_address: ?[]const u8,
};

fn rpcThread(args: RPCThreadArgs) void {
    rpc_mod.startHTTPEx(args.bc, args.wallet, args.alloc, .{
        .mempool  = args.mempool,
        .p2p      = args.p2p,
        .sync_mgr = args.sync_mgr,
        .metrics  = args.metrics,
        .channel_mgr = args.channel_mgr,
        .staking  = args.staking,
        .chain_id = args.chain_id,
        .port     = args.rpc_port,
        .bind_host = args.rpc_bind,
        .auth_token = args.rpc_token,
        .faucet_wallet = args.faucet_wallet,
        .faucet_grant_sat = args.faucet_grant_sat,
        .dns = args.dns,
        .exchange = args.exchange,
        .exchange_paper = args.exchange_paper,
        .orders_path = args.orders_path,
        .users_path = args.users_path,
        .identities_path = args.identities_path,
        .kyc_path = args.kyc_path,
        .kyc_issuer_address = args.kyc_issuer_address,
    }) catch |err| {
        std.debug.print("[RPC] startHTTP error: {}\n", .{err});
    };
}

/// F8: Auto-TX — pick two funded miners and send a small TX between them.
/// Called from the mining loop every N blocks to create organic traffic.
fn autoTxBetweenMiners(bc: *Blockchain, block_count: u32, allocator: std.mem.Allocator) void {
    const pair = g_miner_pool.pickAutoTxPair(10000) orelse return;
    const sender_wallet = g_miner_pool.getWalletAt(pair.sender) orelse return;
    const receiver_wallet = g_miner_pool.getWalletAt(pair.receiver) orelse return;

    // Deterministic "random" amount: 1000-10000 SAT based on block number
    const auto_amount: u64 = 1000 + (@as(u64, block_count) * 7 + 13) % 9001;
    const auto_fee: u64 = 1;
    const auto_nonce = bc.getNextAvailableNonce(sender_wallet.getAddress());
    const auto_tx_id: u32 = 1_000_000 + block_count * 10;

    var auto_tx = sender_wallet.createSignedTx(
        receiver_wallet.getAddress(), auto_amount, auto_tx_id, auto_nonce, auto_fee, allocator,
    ) catch return;
    _ = &auto_tx;

    bc.addTransaction(auto_tx) catch |err| {
        std.debug.print("[AUTO-TX] Mempool reject: {}\n", .{err});
        return;
    };

    if (block_count % 50 == 0) {
        std.debug.print("[AUTO-TX] {s}... -> {s}... | {d} SAT\n", .{
            sender_wallet.getAddress()[0..@min(20, sender_wallet.address_len)],
            receiver_wallet.getAddress()[0..@min(20, receiver_wallet.address_len)],
            auto_amount,
        });
    }
}

// ─── Faucet auto-refill (Faza 5) ────────────────────────────────────────────
//
// When the faucet wallet's balance dips below FAUCET_REFILL_THRESHOLD_SAT,
// transfer FAUCET_REFILL_AMOUNT_SAT from the miner's primary wallet
// (savacazan or whoever runs --faucet-mode) into the faucet wallet. This
// keeps the faucet replenished automatically as the operator mines blocks.
//
// Both thresholds are deliberately conservative for testnet — operator with
// 1 OMNI of mining rewards can sustain ~10 refills before their primary
// wallet goes empty.

/// Below this SAT count, kick a refill on the next tick.
const FAUCET_REFILL_THRESHOLD_SAT: u64 = 500_000_000; // 0.5 OMNI
/// Send this much to faucet on each refill (=10 claims worth at 0.1 OMNI).
const FAUCET_REFILL_AMOUNT_SAT: u64 = 1_000_000_000; // 1 OMNI
/// Loop tick interval — slow enough not to spam the chain, fast enough
/// that a busy faucet stays funded.
const FAUCET_REFILL_TICK_S: u64 = 30;

const FaucetRefillArgs = struct {
    bc: *Blockchain,
    miner_wallet: *Wallet,
    faucet_wallet: *Wallet,
    grant_sat: u64,
    alloc: std.mem.Allocator,
};

fn faucetRefillLoop(args: *FaucetRefillArgs) void {
    defer args.alloc.destroy(args);
    var tx_counter: u32 = 9_000_000; // unique-ish nonce range for refill TXs
    // Exponential backoff after consecutive failures so we don't spam the
    // mempool when something is structurally wrong (e.g. miner balance
    // already pinned by an earlier rejected TX). Resets to base on success.
    var backoff_multiplier: u32 = 1;
    const MAX_BACKOFF_MULT: u32 = 32; // 30s × 32 = 16 minutes max sleep

    while (true) {
        const sleep_s = FAUCET_REFILL_TICK_S * backoff_multiplier;
        std.Thread.sleep(sleep_s * std.time.ns_per_s);

        const faucet_bal = args.bc.getAddressBalance(args.faucet_wallet.address);
        if (faucet_bal >= FAUCET_REFILL_THRESHOLD_SAT) {
            // Faucet is fine. Reset backoff so we react quickly when it drains.
            backoff_multiplier = 1;
            continue;
        }

        // Effective miner balance = on-chain balance MINUS amount already
        // committed by pending mempool TXs. If a previous refill is still
        // sitting in the mempool, asking for another would fail validation
        // (insufficient available balance) and lock the loop in retry hell.
        const miner_bal = args.bc.getAddressBalance(args.miner_wallet.address);
        const fee_sat: u64 = mempool_mod.TX_MIN_FEE_SAT;

        // Skip if miner already has a pending TX that hasn't confirmed —
        // adding another refill while one is in flight just multiplies the
        // failure. Waiting one more tick lets the queued one mine first.
        const next_nonce = args.bc.getNextAvailableNonce(args.miner_wallet.address);
        const chain_nonce = args.bc.nonces.get(args.miner_wallet.address) orelse 0;
        if (next_nonce > chain_nonce) {
            std.debug.print(
                "[FAUCET-REFILL] miner has {d} pending TX(s) — waiting for them to mine\n",
                .{next_nonce - chain_nonce},
            );
            backoff_multiplier = @min(backoff_multiplier * 2, MAX_BACKOFF_MULT);
            continue;
        }

        if (miner_bal < FAUCET_REFILL_AMOUNT_SAT + fee_sat) {
            std.debug.print(
                "[FAUCET-REFILL] miner balance {d} too low to top up faucet (needs {d}+{d}), backing off\n",
                .{ miner_bal, FAUCET_REFILL_AMOUNT_SAT, fee_sat },
            );
            backoff_multiplier = @min(backoff_multiplier * 2, MAX_BACKOFF_MULT);
            continue;
        }

        tx_counter +%= 1;
        var tx = args.miner_wallet.createTransactionFull(
            args.faucet_wallet.address,
            FAUCET_REFILL_AMOUNT_SAT,
            tx_counter,
            next_nonce,
            fee_sat,
            0,
            "",
            args.alloc,
        ) catch |err| {
            std.debug.print("[FAUCET-REFILL] sign error: {}\n", .{err});
            backoff_multiplier = @min(backoff_multiplier * 2, MAX_BACKOFF_MULT);
            continue;
        };
        if (!tx.isValid()) {
            std.debug.print("[FAUCET-REFILL] TX failed isValid\n", .{});
            backoff_multiplier = @min(backoff_multiplier * 2, MAX_BACKOFF_MULT);
            continue;
        }

        args.bc.registerPubkey(args.miner_wallet.address, args.miner_wallet.addresses[0].public_key_hex) catch {};
        args.bc.addTransaction(tx) catch |err| {
            std.debug.print("[FAUCET-REFILL] mempool refused: {} (backoff {d}x)\n", .{ err, backoff_multiplier });
            backoff_multiplier = @min(backoff_multiplier * 2, MAX_BACKOFF_MULT);
            continue;
        };

        std.debug.print(
            "[FAUCET-REFILL] queued top-up: miner -> faucet {d} SAT (faucet bal was {d}, miner bal {d})\n",
            .{ FAUCET_REFILL_AMOUNT_SAT, faucet_bal, miner_bal },
        );
        // Success — reset backoff for next round.
        backoff_multiplier = 1;
    }
}

// ── AI Agent System: load config + tick on every block ─────────────────────
//
// `loadAgentConfig` is called once at startup from main() if --agent-config is
// passed. `agentTickAll` is called from the mining loop on every new block.
//
// Adresa wallet pentru fiecare agent este derivata din mnemonic + wallet_index
// (BIP-44). Pentru MVP, folosim adresa miner-ului ca placeholder — derivarea
// reala per-agent va fi adaugata cand integram cu wallet.zig deriveByIndex.

fn loadAgentConfig(
    path: []const u8,
    mnemonic: []const u8,
    fallback_address: []const u8,
    allocator: std.mem.Allocator,
) void {
    const bundle = agent_config_mod.loadFile(allocator, path) catch |err| {
        std.debug.print("[AGENT] Eroare incarcare {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    if (bundle.count == 0) {
        std.debug.print("[AGENT] Fisier {s} nu contine agenti.\n", .{path});
        return;
    }
    var added: u8 = 0;
    for (bundle.agents[0..bundle.count]) |cfg| {
        // Derivare wallet propriu per-agent (BIP-44 cu wallet_index unic).
        // Daca derivarea esueaza, fallback la addAgent fara wallet (compat).
        if (g_agent_manager.addAgentFromMnemonic(cfg, mnemonic, allocator)) |slot| {
            std.debug.print(
                "[AGENT] Loaded {s} | wallet_index={d} | addr={s} | tier={s}\n",
                .{ cfg.getName(), cfg.wallet_index, slot.getAddress(), @tagName(slot.executor.state.tier) },
            );
            added += 1;
        } else |err| {
            std.debug.print(
                "[AGENT] Wallet derivation failed for {s} (idx={d}): {s} — fallback la fallback_address\n",
                .{ cfg.getName(), cfg.wallet_index, @errorName(err) },
            );
            _ = g_agent_manager.addAgent(cfg, fallback_address) catch |err2| {
                std.debug.print("[AGENT] Skip {s}: {s}\n", .{ cfg.getName(), @errorName(err2) });
                continue;
            };
            added += 1;
        }
    }
    if (added > 0) {
        g_agents_active = true;
        std.debug.print("[AGENT] {d} agent(i) incarcati din {s}.\n", .{ added, path });
    }
}

/// Snapshot oracle din state-ul global pentru a-l hrani agentilor.
fn buildOracleSnapshot(block_height: u64) agent_executor_mod.OracleSnapshot {
    var snap = agent_executor_mod.OracleSnapshot{ .block_height = block_height };
    if (g_oracle_fetcher) |*fetcher| {
        if (fetcher.getMedianPrice()) |btc| {
            snap.btc_usd_micro = btc;
            snap.fresh = true;
        }
        if (fetcher.getMedianLcxPrice()) |lcx| {
            snap.lcx_usd_micro = lcx;
        }
    }
    return snap;
}

/// Counter pentru tx_id la TX-urile generate automat de agenți.
/// Range mare ca să nu coliziune cu auto-TX miner (1_000_000+) și cu RPC-uri.
var g_agent_tx_id_counter: u32 = 5_000_000;

/// Submit TX automat pentru o decizie nativă. Returneaza eroare daca:
///   - agentul n-are wallet propriu (canSign() == false)
///   - kind nu cere TX (mine/halt/none — log-only)
///   - createSignedTx esueaza (privkey corupt)
///   - mempool respinge (insufficient funds, nonce conflict, etc.)
/// MVP: doar `claim_faucet` (transfer din faucet) si stake-mock (transfer self).
/// Stake/unstake real necesita staking_engine API extins — TODO.
fn submitNativeTx(bc: *Blockchain, slot: *agent_manager_mod.AgentSlot, decision: agent_executor_mod.Decision) !void {
    if (!slot.canSign()) return error.NoWallet;
    const w = &slot.wallet.?;

    // Pentru MVP, mapăm doar kind-urile care produc TX simple ON-CHAIN:
    //   - claim_faucet: agent emite intent, dar faucet-ul real se face prin
    //     RPC `claimFaucet` (handshake) — aici doar logăm intentul.
    //   - stake / unstake: necesită staking RPC dedicat (TODO).
    //   - mine / halt / none: nu produc TX.
    // Acum implementăm doar transfer-self ca demo (agentul își trimite 1 SAT
    // la el însuși ca să probeze că semnarea funcționează end-to-end).
    const should_emit_tx = switch (decision.kind) {
        .stake, .unstake => false, // TODO: staking_engine API
        .claim_faucet => false, // RPC handshake separat
        .mine, .halt, .none => false,
        // Pentru transfer/buy/sell/lp pe venue native, generăm un transfer demo
        // (până când staking_engine + LP module sunt wired). În producție, aici
        // se construiește TX-ul real cu logica corespunzătoare kind-ului.
        .buy, .sell, .provide_liquidity, .withdraw_liquidity => true,
    };
    if (!should_emit_tx) return;

    const balance = bc.getAddressBalance(w.getAddress());
    const reserve: u64 = 1_000; // 1000 SAT minim pentru fee
    if (balance <= reserve) return error.InsufficientFunds;

    const amount = @min(decision.amount_sat, balance - reserve);
    if (amount == 0) return error.AmountZero;

    const fee: u64 = 1;
    const nonce = bc.getNextAvailableNonce(w.getAddress());
    g_agent_tx_id_counter += 1;
    const tx_id = g_agent_tx_id_counter;

    // Transfer self ca demo. Producția: routare după kind.
    var tx = try w.createSignedTx(w.getAddress(), amount, tx_id, nonce, fee, bc.allocator);
    _ = &tx;

    // Înregistrează pubkey-ul agentului pe chain pt validare semnătură
    // (idempotent — daca există deja, e no-op).
    bc.registerPubkey(w.getAddress(), &w.public_key_hex) catch {};

    try bc.addTransaction(tx);
    slot.stats.txs_submitted += 1;
    std.debug.print(
        "[AGENT-TX] {s} signed tx_id={d} amount={d} nonce={d}\n",
        .{ slot.config.getName(), tx_id, amount, nonce },
    );
}

/// Tick toti agentii. Apelat din mining loop pe fiecare bloc nou.
///
/// Routing dupa venue:
///   * `omnibus_native` / `none` → executat in nod (log doar; TX submission
///     urmeaza dupa wallet derivation per-agent).
///   * `lcx` / `kraken` / `coinbase` / `omnibus_ex` / `uniswap` → pus in
///     `g_agent_manager.pending` queue, ridicat de clientul extern Python/Rust
///     prin RPC `agent_pending_decisions`.
fn agentTickAll(bc: *Blockchain, block_height: u64) void {
    if (!g_agents_active) return;
    const oracle = buildOracleSnapshot(block_height);

    var idx: usize = 0;
    while (idx < agent_manager_mod.MAX_AGENTS) : (idx += 1) {
        const slot = &g_agent_manager.slots[idx];
        if (!slot.used) continue;

        const balance = bc.getAddressBalance(slot.getAddress());
        // TODO: track stake + LP locked per agent (necesita staking API extins).
        slot.executor.updateBalance(balance, 0, 0, 0);

        const decision = g_agent_manager.tickOne(idx, oracle, block_height) orelse continue;
        if (decision.kind == .none) continue;

        // Tier transition log (o singura data per transition).
        if (slot.last_transition) |tr| {
            if (tr.block_height == block_height) {
                std.debug.print(
                    "[AGENT] {s} tier transition {s} -> {s} @ block {d} cap={d} SAT\n",
                    .{ slot.config.getName(), @tagName(tr.from), @tagName(tr.to), tr.block_height, tr.capital_sat },
                );
            }
        }

        // Routing dupa venue.
        const native = decision.venue == .omnibus_native or decision.venue == .none;
        if (native) {
            std.debug.print(
                "[AGENT-NATIVE] {s} tier={s} kind={s} amount={d} reason={s}\n",
                .{
                    slot.config.getName(),
                    @tagName(slot.executor.state.tier),
                    @tagName(decision.kind),
                    decision.amount_sat,
                    decision.getReason(),
                },
            );
            // Submit TX automat dacă agentul are wallet propriu și kind-ul cere TX.
            submitNativeTx(bc, slot, decision) catch |err| {
                std.debug.print("[AGENT-NATIVE] {s} TX skip: {s}\n", .{ slot.config.getName(), @errorName(err) });
            };
        } else {
            const decision_id = g_agent_manager.queueDecision(slot.config.wallet_index, block_height, decision);
            std.debug.print(
                "[AGENT-QUEUE] id={d} {s} venue={s} kind={s} pair={s} amount={d} reason={s}\n",
                .{
                    decision_id,
                    slot.config.getName(),
                    decision.venue.name(),
                    @tagName(decision.kind),
                    decision.getPair(),
                    decision.amount_sat,
                    decision.getReason(),
                },
            );
        }
    }
}

/// Retro backfill — scan all blocks at startup, count blocks per miner,
/// assign FOOD + VACATION to each miner address. One-shot: doar la primul
/// boot al binarului cu reputation system. Nu reaplică pentru blocuri viitoare
/// (care primesc credit incremental in mining loop via creditMinedBlock).
fn backfillReputationFromChain(
    bc: *Blockchain,
    rep_mgr: *reputation_manager_mod.ReputationManager,
) void {
    const total_blocks: u64 = @intCast(bc.chain.items.len);
    if (total_blocks == 0) return;
    const current_height: u64 = total_blocks - 1;

    // Tally blocks-per-miner + first-block-per-miner.
    // We use the same allocator as the chain — short-lived.
    const alloc = bc.allocator;
    var counts = std.StringHashMap(u64).init(alloc);
    defer counts.deinit();
    var first_seen = std.StringHashMap(u64).init(alloc);
    defer first_seen.deinit();

    for (bc.chain.items, 0..) |blk, idx| {
        const miner = blk.miner_address;
        if (miner.len == 0) continue;
        const gop = counts.getOrPut(miner) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        const fs = first_seen.getOrPut(miner) catch continue;
        if (!fs.found_existing) fs.value_ptr.* = idx;
    }

    var miners_seen: u64 = 0;
    var it = counts.iterator();
    while (it.next()) |entry| {
        const miner = entry.key_ptr.*;
        const n_blocks = entry.value_ptr.*;
        const first_block = first_seen.get(miner) orelse 0;
        rep_mgr.backfill(miner, n_blocks, first_block, current_height);
        miners_seen += 1;
    }
    std.debug.print(
        "[REPUTATION] Retro backfill complete: {d} miners, {d} blocks scanned (current height {d})\n",
        .{ miners_seen, total_blocks, current_height },
    );
}

pub fn main() !void {
    // Initialise the global AtomicClock first — every subsystem started
    // below (RPC, WS, mining) attaches to it. Done at runtime entry
    // because initReal() reads OS time which can't run at comptime.
    g_clock = orchestrator_mod.AtomicClock.initReal();

    // Calibrate the CPU's invariant TSC frequency once at startup.
    // The result is logged for the operator and made available via
    // g_tsc_freq for the stabilizer's "GHz reading". 100ms is enough
    // to absorb scheduler noise without delaying boot noticeably.
    g_tsc_freq = orchestrator_mod.calibrateTscPerSec(100);
    std.debug.print("[CLOCK] TSC calibrated: {d} Hz ({d:.3} GHz)\n",
        .{ g_tsc_freq, @as(f64, @floatFromInt(g_tsc_freq)) / 1e9 });

    // Single-instance lock dezactivat — permite multiple instante pe acelasi PC
    // pentru testare retea cu N mineri. In productie, reactivati acquireSingleInstanceLock().
    // acquireSingleInstanceLock();

    // Install Ctrl+C / SIGINT handler for graceful shutdown
    installShutdownHandler();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ── CLI args (parse mai intai — chain selection depinde de flags) ────────
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cli = CLI.init(allocator);
    const parsed = cli.parseArgsFull(args) catch |err| {
        switch (err) {
            error.HelpRequested => return,
            else => {
                std.debug.print("[ERROR] {}\n", .{err});
                return err;
            }
        }
    };
    // Alias for back-compat with all existing `config.X` references below.
    const config = parsed.node;

    // ── Chain config — unified ChainConfig via parsed.chain_mode ────────────
    // ChainMode enum only exposes mainnet/testnet/regtest — devnet not yet
    // wired through CLI (see cli.zig comment). Use ChainConfig.devnet() directly
    // if/when ChainMode.devnet is added.
    const net_cfg: ChainConfig = switch (parsed.chain_mode) {
        .mainnet => ChainConfig.mainnet(),
        .testnet => ChainConfig.testnet(),
        .regtest => ChainConfig.regtest(),
    };

    // ── Oracle policy — per-chain defaults overridden by CLI flags ──────────
    // Defaults: mainnet strict (5% reject), testnet relaxed (10%), regtest off.
    // CLI: --price-deviation-{warn,reject,fillgap} <f64>, --no-price-validation
    {
        var pol = oracle_policy_mod.defaultsFor(net_cfg.chain_id);
        if (parsed.price_warn_pct) |v| pol.warn_pct = v;
        if (parsed.price_reject_pct) |v| pol.reject_pct = v;
        if (parsed.price_fillgap_pct) |v| pol.fillgap_pct = v;
        if (parsed.price_validation_disabled) pol.enabled = false;
        g_oracle_policy = pol;
        std.debug.print(
            "[ORACLE-POLICY] warn={d:.1}% reject={d:.1}% fillgap={d:.1}% enabled={s}\n",
            .{ pol.warn_pct, pol.reject_pct, pol.fillgap_pct, if (pol.enabled) "true" else "false" },
        );
    }

    std.debug.print(
        \\
        \\╔══════════════════════════════════════════════════════╗
        \\║              OmniBus Network Config                  ║
        \\╚══════════════════════════════════════════════════════╝
        \\  Network:     {s}
        \\  Chain ID:    {d}
        \\  Genesis:     {d} (Unix)
        \\  Genesis Hash:{s}
        \\  Max Supply:  {d} SAT (21,000,000 OMNI)
        \\  Reward/bloc: {d} SAT (0.08333333 OMNI)
        \\  Halving at:  {d} blocuri
        \\  Block time:  {d}ms
        \\  Difficulty:  {d} (leading zeros)
        \\  P2P port:    {d}
        \\  RPC port:    {d}
        \\  WS port:     {d}
        \\  Sub-blocks:  {d} per key-block
        \\
        \\
    , .{
        net_cfg.name,
        @intFromEnum(net_cfg.chain_id),
        net_cfg.genesis_timestamp,
        net_cfg.genesis_hash,
        net_cfg.max_supply_sat,
        net_cfg.initial_reward_sat,
        net_cfg.halving_interval,
        net_cfg.block_time_ms,
        net_cfg.initial_difficulty,
        net_cfg.p2p_port,
        net_cfg.rpc_port,
        net_cfg.ws_port,
        net_cfg.sub_blocks_per_block,
    });

    std.debug.print("[NETWORK] Mode: {}  ID: {s}  Host: {s}:{d}\n\n",
        .{ config.mode, config.node_id, config.host, config.port });

    if (config.testnet) {
        std.debug.print("[TESTNET] Single-miner mode — mining without peers\n", .{});
    }

    // ── Mnemonic — CLI flag → SuperVault Named Pipe → env var → dev default ──
    const mnemonic = if (config.mnemonic) |m|
        try allocator.dupe(u8, m)
    else
        try vault_reader.readMnemonic(allocator);

    if (config.mnemonic != null) {
        std.debug.print("[WALLET] Using mnemonic from --mnemonic CLI flag\n", .{});
    }

    // ── DB path selection per chain ──────────────────────────────────────────
    const chain_name = net_cfg.name; // e.g. "omnibus-mainnet" / "omnibus-testnet"
    const short_name = blk: {
        // strip "omnibus-" prefix → "mainnet" / "testnet" / "regtest"
        const prefix = "omnibus-";
        if (std.mem.startsWith(u8, chain_name, prefix)) {
            break :blk chain_name[prefix.len..];
        } else {
            break :blk chain_name;
        }
    };

    // Mainnet only: prefer legacy file if it exists (back-compat).
    // Testnet/regtest/devnet: ALWAYS use data/{chain}/chain.dat — never legacy.
    const db_path: []u8 = blk: {
        if (std.mem.eql(u8, short_name, "mainnet")) {
            const legacy_exists = std.fs.cwd().access(LEGACY_DB_PATH, .{}) catch null;
            if (legacy_exists != null) {
                std.debug.print("[DB] Using legacy mainnet DB at {s}\n", .{LEGACY_DB_PATH});
                break :blk try allocator.dupe(u8, LEGACY_DB_PATH);
            }
        }
        const new_path = try database_mod.dbPathForChain(allocator, short_name);
        std.debug.print("[DB] Using chain DB at {s}\n", .{new_path});
        break :blk new_path;
    };
    defer allocator.free(db_path);

    // ── Init database (persistent storage) ───────────────────────────────────
    var pbc = try PersistentBlockchain.loadFromDisk(allocator, db_path);
    defer pbc.deinit();
    const loaded_stats = pbc.getStats();
    std.debug.print("[DB] Loaded: {d} blocks, {d} addresses from {s}\n",
        .{ loaded_stats.total_blocks, loaded_stats.total_addresses, db_path });

    // ── Init blockchain cu Genesis oficial ───────────────────────────────────
    // A4 added GenesisState.fromChainConfig — accepts ChainConfig directly.
    // Old GenesisState.init(NetworkConfig, ...) kept for legacy/test back-compat.
    const gs = GenesisState.fromChainConfig(net_cfg, allocator);
    var bc = try gs.buildBlockchain();
    defer bc.deinit();

    // Valideaza genesis — daca e gresit, oprim nodul
    if (!gs.validateGenesisBlock(&bc)) {
        std.debug.print("[FATAL] Genesis block invalid! Oprire nod.\n", .{});
        return error.InvalidGenesis;
    }

    // Reincarca blocurile si balantele salvate anterior (continua lantul)
    pbc.restoreInto(&bc, db_path) catch |err| {
        std.debug.print("[DB] Restore failed ({}) — pornire de la genesis\n", .{err});
    };

    // Attach persistent database to blockchain for auto-save support
    bc.persistent_db = &pbc;
    bc.db_path = db_path;
    bc.last_save_time = std.time.timestamp();

    // PHASE C.3 — rebuild UTXO set from full chain replay at startup.
    // The legacy persistence layer saves bc.balances + nonces but NOT
    // bc.utxo_set, so a restart loaded balances from disk and started
    // with an empty UTXO set. The audit then surfaces a divergence
    // for every address that had non-trivial pre-restart history.
    // recalculateFromHeight wipes balances + replays every block from
    // genesis, which now also rebuilds the UTXO set (Phase B updated
    // recalculateFromHeight to do that). After this call, the audit
    // and stray-write counters start clean.
    bc.recalculateFromHeight(0) catch |err| {
        std.debug.print("[DB] UTXO rebuild after restore failed: {}\n", .{err});
    };

    // ── PHASE C.4 — open the Bitcoin-style chainstate KV ──────────────
    //
    // Persistent WAL+snapshot store under data/<chain>/chainstate.{wal,snap}.
    // The chain's RAM cache (bc.balances, bc.nonces) keeps running
    // unchanged; chainstate is a *parallel* writer for now. Once an audit
    // soak shows zero divergence between RAM and chainstate, the RAM
    // mirrors will be deleted and chainstate becomes the only source.
    const cs_base = std.fmt.allocPrint(allocator, "data/{s}/chainstate", .{short_name}) catch null;
    if (cs_base) |path| {
        defer allocator.free(path);
        if (chainstate_mod.ChainState.open(allocator, path)) |cs| {
            g_chainstate = cs;
            std.debug.print(
                "[CHAINSTATE] opened at data/{s}/chainstate ({d} balance entries loaded)\n",
                .{ short_name, g_chainstate.?.balanceCount() },
            );
        } else |err| {
            std.debug.print("[CHAINSTATE] open failed: {} — running without persistent KV\n", .{err});
        }
    }
    // Sync chainstate from the freshly-recalculated bc.balances. This
    // handles two cases: (a) first run, chainstate is empty; (b) restart,
    // chainstate may already have state but bc.balances was just rebuilt
    // from chain replay so it's the authoritative source for now.
    if (g_chainstate) |*cs| {
        var it = bc.balances.iterator();
        var synced: usize = 0;
        while (it.next()) |kv| {
            cs.putBalance(kv.key_ptr.*, kv.value_ptr.*) catch |err| {
                std.debug.print("[CHAINSTATE] initial putBalance failed: {}\n", .{err});
            };
            synced += 1;
        }
        std.debug.print("[CHAINSTATE] initial sync: {d} balances written from RAM\n", .{synced});
    }

    // Start the background state-save thread. This is the band-aid fix
    // for the post-b363095 data-loss bug: balances that weren't on-chain
    // TXs (faucet grants, in particular) didn't survive restart because
    // the in-mining-loop save had been removed for performance. A
    // dedicated background thread saves every 60 s without blocking
    // block production. See ARCH_BITCOIN_STORAGE.md for the long-term
    // Bitcoin-style refactor that replaces this with proper incremental
    // chainstate updates.
    try startStateSaveThread(&bc);

    std.debug.print("[INIT] Blockchain initialized\n", .{});
    std.debug.print("  Genesis: {s}\n", .{net_cfg.genesis_hash[0..16]});
    std.debug.print("  Difficulty: {d}  Chain: {d} block(s) (height {d})\n\n",
        .{ bc.difficulty, bc.chain.items.len, bc.chain.items.len - 1 });

    // ── Init wallet ───────────────────────────────────────────────────────────
    var wallet = try Wallet.fromMnemonic(mnemonic, "", allocator);
    defer wallet.deinit();

    std.debug.print("[WALLET] Address: {s}\n", .{wallet.address});
    if (config.wallet_index > 0) {
        std.debug.print("[WALLET] Derivation index: {d} (BIP-44 m/44'/777'/{d}'/0/0)\n", .{ config.wallet_index, config.wallet_index });
    }
    std.debug.print("[WALLET] Balance: {d} SAT ({d:.4} OMNI)\n\n",
        .{ wallet.balance, @as(f64, @floatFromInt(wallet.balance)) / 1e9 });

    // ── Faucet wallet (optional) ────────────────────────────────────────
    // SECURITY: faucet wallet is loaded from a RAW PRIVATE KEY (env var
    // OMNIBUS_FAUCET_PRIVKEY, 64 hex chars), NOT from the miner mnemonic.
    // Why: a faucet runs 24/7 on a public server. Using the miner mnemonic
    // would expose ALL derived wallets (savacazan, sava.omnibus, etc.) if
    // the server is compromised. With a single-purpose private key, an
    // attacker who steals the file gets only the faucet's small balance
    // (≤ a few OMNI) and cannot touch the rest of the user's wallet
    // family. Same model Bitcoin uses for hot wallets (HSM-style isolation).
    var faucet_wallet_opt: ?Wallet = null;
    if (config.faucet_mode) {
        const fpk_hex_owned = std.process.getEnvVarOwned(allocator, "OMNIBUS_FAUCET_PRIVKEY") catch null;
        defer if (fpk_hex_owned) |s| allocator.free(s);
        if (fpk_hex_owned) |fpk_hex| {
            const trimmed = std.mem.trim(u8, fpk_hex, " \t\n\r");
            if (Wallet.parsePrivateKeyHex(trimmed)) |fpk| {
                if (Wallet.fromPrivateKey(fpk, allocator)) |fw| {
                    faucet_wallet_opt = fw;
                    std.debug.print("[FAUCET] Faucet wallet loaded from OMNIBUS_FAUCET_PRIVKEY (no mnemonic exposure)\n", .{});
                    std.debug.print("[FAUCET] Faucet address: {s}\n", .{fw.address});
                    std.debug.print("[FAUCET] Per-claim grant: {d} SAT ({d:.4} OMNI)\n\n",
                        .{ config.faucet_grant_sat, @as(f64, @floatFromInt(config.faucet_grant_sat)) / 1e9 });
                } else |err| {
                    std.debug.print("[FAUCET] fromPrivateKey failed: {} — faucet disabled\n", .{err});
                }
            } else |err| {
                std.debug.print("[FAUCET] OMNIBUS_FAUCET_PRIVKEY parse failed: {} (expected 64 hex chars) — faucet disabled\n", .{err});
            }
        } else {
            std.debug.print("[FAUCET] --faucet-mode set but OMNIBUS_FAUCET_PRIVKEY env var missing — faucet disabled\n", .{});
        }
    }
    defer if (faucet_wallet_opt) |*fw| fw.deinit();
    _ = config.faucet_wallet_index; // retained on NodeConfig for future BIP-32 path; not used by privkey loader

    // Configure on-disk persistence for faucet claim ledger. Same dir as
    // chain.dat so testnet/regtest/mainnet ledgers stay separated. Without
    // this call, claim counter is in-memory only and resets on every node
    // restart — letting attackers re-claim repeatedly.
    if (faucet_wallet_opt != null) {
        const chain_subdir: []const u8 = if (config.testnet) "testnet" else if (config.regtest) "regtest" else "mainnet";
        const ledger_path = std.fmt.allocPrint(allocator, "data/{s}/faucet-claims.json", .{chain_subdir}) catch null;
        if (ledger_path) |p| {
            // Ensure data/<chain> exists (chain.dat path mirrors this).
            std.fs.cwd().makePath(std.fs.path.dirname(p) orelse ".") catch {};
            rpc_mod.faucetSetPersistPath(p);
            std.debug.print("[FAUCET] claim ledger: {s}\n", .{p});
            allocator.free(p);
        }
    }

    // ── Effective miner address ─────────────────────────────────────────
    // Production setup: pass --miner-address to redirect block rewards to
    // a wallet whose mnemonic stays OFFLINE (Liberty Suite, hardware
    // wallet, paper). The local wallet derived above signs nothing at
    // mining time and can be ephemeral. Legacy: if --miner-address is
    // not set, we fall back to wallet.address (mnemonic-on-miner).
    const effective_miner_addr: []const u8 = if (config.miner_address) |a| a else wallet.address;
    if (config.miner_address != null) {
        std.debug.print("[MINER] Reward address (from --miner-address): {s}\n", .{effective_miner_addr});
        std.debug.print("[MINER] (mnemonic-derived wallet {s} stays unused for rewards)\n\n", .{wallet.address});
    }

    // Inregistreaza adresa minerului efectiv ca primul miner in pool.
    //
    // BUG FIX (2026-04-27): the legacy `register(addr)` path created a
    // RANDOM secp256k1 keypair under the address. Then F8 (mining loop)
    // every block called `bc.registerPubkey(maddr, random_pubkey_hex)`,
    // which polluted `pubkey_registry` with a pubkey that DID NOT match
    // the real wallet. When user then called `sendtransaction`, the TX
    // got signed with the REAL private key but verified against the
    // random pubkey → "[VALIDATE] FAIL: ECDSA signature verification".
    //
    // Fix: when `effective_miner_addr` matches the local wallet derived
    // from the same mnemonic, register with the actual mnemonic so the
    // pool's pubkey_hex matches the real key. Otherwise — when miner_addr
    // is an external --miner-address — fall back to address-only registry
    // and skip the mining-loop pubkey publishing so we don't poison the
    // registry with a key that can't sign anything anyway.
    if (std.mem.eql(u8, effective_miner_addr, wallet.address)) {
        // Local mnemonic IS the miner — use it so pool pubkey is real.
        _ = g_miner_pool.registerWithMnemonic(effective_miner_addr, mnemonic, allocator) catch
            g_miner_pool.register(effective_miner_addr);
    } else {
        // External miner address (operator's offline wallet). Register the
        // address only; the pool can't sign on its behalf anyway, and the
        // F8 pubkey-publish path is now skipped for entries whose pubkey
        // we don't actually own (see g_miner_pool.wallets[pi].is_real).
        g_miner_pool.register(effective_miner_addr);
    }

    // ── AI Agents: load --agent-config <file> if provided ─────────────────────
    // Pass nodul mnemonic ca să derivăm wallet propriu per-agent (BIP-44
    // m/44'/777'/0'/0/wallet_index). Fiecare agent are adresă, balance, P&L
    // separate. Fallback la miner address daca derivation eșuează.
    //
    // Opt-out via env var OMNIBUS_EXTERNAL_AGENTS=1. When set, the chain
    // process does NOT load agents into its own AgentManager — a separate
    // omnibus-agents process is expected to be running, watching the chain
    // via RPC and submitting TXs through sendrawtransaction. This frees
    // the mining loop from running agentTickAll on every block.
    const external_agents = std.process.getEnvVarOwned(
        allocator, "OMNIBUS_EXTERNAL_AGENTS",
    ) catch null;
    defer if (external_agents) |s| allocator.free(s);
    const agents_use_external = external_agents != null and
        std.mem.eql(u8, external_agents.?, "1");
    if (agents_use_external) {
        std.debug.print(
            "[AGENT] external agents enabled (OMNIBUS_EXTERNAL_AGENTS=1) " ++
            "— in-process agent manager disabled. Expect omnibus-agents on :28200\n", .{});
    } else if (parsed.agent_config_path) |agent_path| {
        loadAgentConfig(agent_path, mnemonic, effective_miner_addr, allocator);
    }

    // ── Init Mempool FIFO ─────────────────────────────────────────────────────
    var mempool = Mempool.init(allocator);
    defer mempool.deinit();
    std.debug.print("[MEMPOOL] FIFO init | Max: {d} TX / {d} KB | Expiry: 14 days\n\n",
        .{ mempool_mod.MEMPOOL_MAX_TX, mempool_mod.MEMPOOL_MAX_BYTES / 1024 });

    // ── Init Consensus Engine ─────────────────────────────────────────────────
    const consensus_cfg = ConsensusConfig.init(.ProofOfWork, 1);
    const consensus = ConsensusEngine.init(consensus_cfg, allocator);
    consensus_cfg.print();

    // ── Init Metachain + ShardCoordinator (Sprint 1) ──────────────────────────
    var metachain = try metachain_mod.Metachain.init(allocator, NUM_SHARDS);
    defer metachain.deinit();
    std.debug.print("[METACHAIN] Init | {d} shards | genesis MetaBlock height 0\n\n", .{NUM_SHARDS});

    // ── Init State Trie (account state compression) ──────────────────────────
    var state_trie = state_trie_mod.StateTrie.init(allocator);
    defer state_trie.deinit();

    // ── Init Finality Engine (Casper FFG checkpoints) ────────────────────────
    var finality = finality_mod.FinalityEngine.init(1000); // initial voting power
    std.debug.print("[FINALITY] Casper FFG init | checkpoint every {d} blocks | soft finality: {d} confirms\n",
        .{ finality_mod.CHECKPOINT_INTERVAL, finality_mod.SOFT_FINALITY_CONFIRMS });

    // ── Init Staking Engine ──────────────────────────────────────────────────
    var staking = staking_mod.StakingEngine.init();
    std.debug.print("[STAKING] Engine init | min stake: {d} SAT | unbonding: {d} blocks\n",
        .{ staking_mod.VALIDATOR_MIN_STAKE, staking_mod.UNBONDING_PERIOD });

    // ── Init Governance ──────────────────────────────────────────────────────
    const governance = governance_mod.GovernanceEngine.init(governance_mod.GovernanceParams{});
    std.debug.print("[GOVERNANCE] Init | quorum: {d}% | threshold: {d}% | veto: {d}%\n",
        .{ governance.params.quorum_pct, governance.params.threshold_pct, governance.params.veto_pct });

    // ── Init Peer Scoring ────────────────────────────────────────────────────
    var peer_scoring = peer_scoring_mod.PeerScoringEngine.init();

    // ── Init DNS Registry + persist file (per-chain) ────────────────────────
    var dns = dns_mod.DnsRegistry.init();
    // Persist file per chain: data/<chain>/dns_registry.bin
    var dns_persist_path_buf: [256]u8 = undefined;
    const dns_persist_path = std.fmt.bufPrint(
        &dns_persist_path_buf,
        "data/{s}/dns_registry.bin",
        .{@tagName(parsed.chain_mode)},
    ) catch "data/dns_registry.bin";
    dns.loadFromFile(dns_persist_path) catch |err| {
        std.debug.print("[DNS] Load from {s} failed: {s} (starting empty)\n",
            .{ dns_persist_path, @errorName(err) });
    };
    if (dns.entry_count > 0) {
        std.debug.print("[DNS] Loaded {d} names from {s}\n", .{ dns.entry_count, dns_persist_path });
    }

    // Set treasury = ens.omnibus address from the canonical registrar table.
    //
    // The 10 registrar slots act as native "smart contracts" — they have
    // an on-chain address but NO private key. The chain itself enforces
    // their rules deterministically (pay-to-claim for ens, drip for faucet,
    // grid orders for exchange treasury, etc.). We never derive these from
    // a node-local mnemonic — every node reads the same hardcoded strings
    // and produces the same consensus. Same model Hyperliquid uses for its
    // protocol-owned addresses.
    const ens_treasury_addr = registrar_mod.addressOf(.ens) orelse {
        std.debug.print("[DNS] FATAL: ens slot empty in registrar_addresses.zig\n", .{});
        return error.MissingRegistrarSlot;
    };
    dns.setTreasury(ens_treasury_addr);
    // Pe testnet & regtest: fee_enforcement OFF (compat cu Kimi scripts).
    // Pe mainnet: fee_enforcement ON.
    dns.enableFee(parsed.chain_mode == .mainnet);
    std.debug.print("[DNS] Treasury: {s} | fee_enforcement: {}\n",
        .{ ens_treasury_addr, dns.fee_enforcement });

    // Attach the registry to the blockchain so applyBlock can run pay-to-claim:
    // every TX with op_return `ns_claim:<name>.<tld>` paying ens.omnibus the
    // right fee gets the name auto-registered to its sender. See
    // dns_registry.claimByPayment + blockchain.applyBlock for the full flow.
    bc.dns_registry = &dns;

    // ── Init Guardian System ─────────────────────────────────────────────────
    var guardian = guardian_mod.GuardianEngine.init();

    std.debug.print("[SUBSYSTEMS] StateTrie + Finality + Staking + Governance + PeerScoring + DNS + Guardian\n\n", .{});

    // ── Init P2P Node ─────────────────────────────────────────────────────────
    // P2PNode is ~1.5 MB. We allocate on the heap AND populate in-place via
    // initInPlace() — never via `heap.* = init(...)` because that intermediate
    // value still lives on the stack inside init() and overruns the Linux
    // guard page (silent SEGV right after [SUBSYSTEMS] log).
    const p2p_heap = try allocator.create(P2PNode);
    p2p_heap.initInPlace(config.node_id, config.host, config.port, allocator);
    p2p_heap.setChainMagic(chain_config_mod.NetworkMagic.forChain(net_cfg.chain_id).bytes);
    defer {
        p2p_heap.deinit();
        allocator.destroy(p2p_heap);
    }
    const p2p = p2p_heap;
    // Conecteaza la seed node daca e miner (best-effort, nu blocheaza)
    if (config.seed_host) |sh| {
        if (config.seed_port) |sp| {
            p2p.connectToPeer(sh, sp, "seed-primary") catch |err| {
                std.debug.print("[P2P] Seed connect failed (va incerca mai tarziu): {}\n", .{err});
            };
        }
    }
    p2p.printStatus();

    // ── TCP Listener inbound — accepta conexiuni de la alti mineri ────────────
    p2p.startListener() catch |err| {
        std.debug.print("[P2P] Listener failed (port ocupat?): {} — fara inbound\n", .{err});
    };

    // ── Heartbeat — PING periodic catre peers cu inaltimea curenta. Fara asta
    // peer.height ramane stale dupa handshake si IBD se opreste cand consumam
    // toate blocurile vazute la HELLO, chiar daca peer-ul a urcat intre timp.
    p2p.startHeartbeat() catch |err| {
        std.debug.print("[P2P] Heartbeat failed: {} — peer heights vor fi stale\n", .{err});
    };

    // ── Knock Knock — anunta reteaua + verifica duplicat pe acelasi IP ────────
    const knock_result = p2p.knockKnock();
    switch (knock_result) {
        .alone => std.debug.print("[KNOCK] Miner activ — singur pe acest IP\n\n", .{}),
        .duplicate_ip => std.debug.print(
            "[KNOCK] IDLE — alt miner detectat pe acelasi IP\n" ++
            "        Acest nod monitorizeaza reteaua dar NU minaza\n\n", .{}),
        .broadcast_failed => std.debug.print(
            "[KNOCK] Broadcast indisponibil (VPN/firewall?) — continuam\n\n", .{}),
    }

    // ── SubBlock Engine — 10 × 0.1s → 1 Key-Block ────────────────────────────
    var sb_engine = SubBlockEngine.init(config.node_id, 0, allocator);
    std.debug.print("[SUB-BLOCK] Engine init | {d} sub-blocks × {d}ms = 1s bloc\n\n", .{
        sub_block_mod.SUB_BLOCKS_PER_BLOCK,
        sub_block_mod.SUB_BLOCK_INTERVAL_MS,
    });

    // ── Sync Manager — sincronizare blockchain cu peerii ──────────────────────
    var sync_mgr = SyncManager.init(@intCast(bc.chain.items.len), allocator);
    std.debug.print("[SYNC] Manager init | local height: {d}\n\n", .{bc.chain.items.len});

    // Ataseaza blockchain + sync_mgr la nodul P2P — necesar pentru sync real
    p2p.attachBlockchain(&bc, &sync_mgr);

    // ── Light Client (SPV) — only for --mode light ──────────────────────────
    var light_client = light_client_mod.LightClient.init(allocator);
    defer light_client.deinit();
    const is_light = (config.mode == node_launcher.NodeMode.light);
    if (is_light) {
        p2p.attachLightClient(&light_client);
        std.debug.print("[LIGHT] SPV light client mode — headers only, no full blocks\n\n", .{});
    }

    // ── EVM Engine (revm) — initialize before RPC so eth_* methods work ──────
    evm_executor_mod.init() catch |err| {
        std.debug.print("[EVM] init failed: {} — eth_* RPC methods will return errors\n", .{err});
    };
    defer evm_executor_mod.shutdown();
    std.debug.print("[EVM] Engine initialized (revm)\n", .{});

    // ── WebSocket + RPC — pornite pe TOATE nodurile ─────────────────────────────
    // Minerii AU NEVOIE de RPC/WS pentru ca UI (Liberty Suite) sa poata afisa
    // IBD progress, balance, mining stats pt nodul LOCAL — fara aceasta UI
    // arata doar starea seed-ului, nu a minerului propriu. Pentru a evita
    // conflict de port cand rulezi seed + miner pe aceeasi masina, miner-ul
    // foloseste rpc_port+1 / ws_port+1.
    const is_seed = (config.mode == node_launcher.NodeMode.seed);
    const ws_port  = if (is_seed) net_cfg.ws_port  else net_cfg.ws_port  + 1;
    const rpc_port = if (is_seed) net_cfg.rpc_port else net_cfg.rpc_port + 1;

    var ws_srv = WsServer.init(ws_port, allocator);
    defer ws_srv.deinit();
    ws_srv.attachBlockchain(&bc);
    ws_srv.start() catch |err| {
        std.debug.print("[WS] Server start failed on port {d}: {} — continuam fara WS\n", .{ ws_port, err });
    };
    p2p.attachWsServer(&ws_srv);
    // Tell P2P which wallet address mines on this node, so block
    // announcements carry the WALLET address as `miner_id` (which is
    // what peers validate against the slot leader). Without this, peers
    // saw `local_id` ("vps-testnet" etc.) and rejected every block.
    p2p.attachMinerAddress(effective_miner_addr);

    // RPC bind + auth — read from env vars OMNIBUS_RPC_BIND / OMNIBUS_RPC_TOKEN.
    // Default bind = "127.0.0.1" so a fresh node is NOT exposed to the public
    // internet by accident. Public nodes (VPS) must explicitly opt in via
    // OMNIBUS_RPC_BIND=0.0.0.0 + OMNIBUS_RPC_TOKEN=<long-random-string>.
    // ServerCtx now copies the auth token into its own static buffer so we
    // are free to drop the env-allocated string after startHTTPEx returns.
    const rpc_bind = std.process.getEnvVarOwned(allocator, "OMNIBUS_RPC_BIND") catch
        try allocator.dupe(u8, "127.0.0.1");
    const rpc_token: ?[]const u8 = std.process.getEnvVarOwned(allocator, "OMNIBUS_RPC_TOKEN") catch null;

    // ── Native DEX matching engine ─────────────────────────────────────────
    // The MatchingEngine is ~3MB (10K orders × 2 sides + 1K fills). Allocate
    // on the heap once at startup and share across RPC threads; mutex lives
    // inside ServerCtx. orders.jsonl is per-chain so testnet/regtest don't
    // pollute each other's books. Disabled on light nodes via env var.
    const exchange_disabled = std.process.hasEnvVar(allocator, "OMNIBUS_EXCHANGE_OFF") catch false;
    var exchange_engine: ?*matching_mod.MatchingEngine = null;
    var orders_path_owned: ?[]u8 = null;
    if (!exchange_disabled) {
        // Use page_allocator for the 3MB MatchingEngine — it's a single
        // long-lived object and the gpa's small-bin path doesn't help. Goes
        // straight to mmap() on Linux which is what we want for big blocks.
        const page_alloc = std.heap.page_allocator;
        exchange_engine = page_alloc.create(matching_mod.MatchingEngine) catch null;
        if (exchange_engine) |e| {
            // Zero the whole struct in place, then set the scalar fields.
            // `e.* = .init()` would materialize a 3MB temporary on the stack
            // and segfault. `@memset` is byte-wise so it can't blow the stack.
            const bytes = std.mem.asBytes(e);
            @memset(bytes, 0);
            e.next_order_id = 1;
            e.next_fill_id = 1;
            const chain_subdir: []const u8 = if (config.testnet) "testnet"
                else if (config.regtest) "regtest" else "mainnet";
            orders_path_owned = std.fmt.allocPrint(allocator, "data/{s}/orders.jsonl", .{chain_subdir}) catch null;
            if (orders_path_owned) |p| {
                std.fs.cwd().makePath(std.fs.path.dirname(p) orelse ".") catch {};
                std.debug.print("[EXCHANGE] DEX matching engine ON — orders.jsonl: {s}\n", .{p});
            } else {
                std.debug.print("[EXCHANGE] DEX matching engine ON (in-memory only)\n", .{});
            }
        }
    } else {
        std.debug.print("[EXCHANGE] disabled by OMNIBUS_EXCHANGE_OFF\n", .{});
    }

    // Paper-trading matching engine — same shape as real, isolated state.
    // Lets users practice strategies with OMNI_DEMO without touching real
    // funds. Disabled with OMNIBUS_PAPER_OFF (rare — most nodes want it).
    const paper_disabled = std.process.hasEnvVar(allocator, "OMNIBUS_PAPER_OFF") catch false;
    var exchange_paper_engine: ?*matching_mod.MatchingEngine = null;
    if (!exchange_disabled and !paper_disabled) {
        const page_alloc = std.heap.page_allocator;
        exchange_paper_engine = page_alloc.create(matching_mod.MatchingEngine) catch null;
        if (exchange_paper_engine) |e| {
            const bytes = std.mem.asBytes(e);
            @memset(bytes, 0);
            e.next_order_id = 1;
            e.next_fill_id = 1;
            std.debug.print("[EXCHANGE] paper-trading engine ON\n", .{});
        }
    }

    // Registrar slots are hardcoded in registrar_addresses.zig — no run-time
    // loop here (Linux + Zig 0.15 segfault on the const-array iteration; see
    // chain wipe history 2026-04-29). Operator can `cat core/registrar_addresses.zig`
    // for the canonical map. Each slot is a native smart contract: on-chain
    // address, no private key, chain enforces the rules.

    // Exchange-users journal (api keys + internal balances). Always
    // present (even when matching engine is off) because login + balance
    // queries are useful by themselves.
    var users_path_owned: ?[]u8 = null;
    var identities_path_owned: ?[]u8 = null;
    var kyc_path_owned: ?[]u8 = null;
    {
        const chain_subdir: []const u8 = if (config.testnet) "testnet"
            else if (config.regtest) "regtest" else "mainnet";
        users_path_owned = std.fmt.allocPrint(allocator, "data/{s}/exchange-users.jsonl", .{chain_subdir}) catch null;
        if (users_path_owned) |p| {
            std.fs.cwd().makePath(std.fs.path.dirname(p) orelse ".") catch {};
            std.debug.print("[EXCHANGE] users journal: {s}\n", .{p});
        }
        identities_path_owned = std.fmt.allocPrint(allocator, "data/{s}/identities.jsonl", .{chain_subdir}) catch null;
        kyc_path_owned = std.fmt.allocPrint(allocator, "data/{s}/kyc-attestations.jsonl", .{chain_subdir}) catch null;
        if (identities_path_owned) |p| std.debug.print("[IDENTITY] journal: {s}\n", .{p});
        if (kyc_path_owned) |p| std.debug.print("[KYC] journal: {s}\n", .{p});
    }

    // KYC issuer address: the wallet at registrar slot 4 (`kyc.omnibus`).
    // We re-derive from the same mnemonic the local wallet was built from.
    // On testnet that's enough; mainnet would also cross-check against the
    // hardcoded constant in `registrar_addresses.zig:REGISTRAR_ADDRESSES`.
    const bip32_wallet_mod = @import("bip32_wallet.zig");
    var kyc_issuer_owned: ?[]u8 = null;
    {
        var bip32 = bip32_wallet_mod.BIP32Wallet.initFromMnemonic(mnemonic, allocator) catch null;
        if (bip32) |*w| {
            kyc_issuer_owned = w.deriveAddressForDomain(777, 4, "ob", allocator) catch null;
            if (kyc_issuer_owned) |addr| {
                std.debug.print("[KYC] issuer (slot 4 / kyc.omnibus): {s}\n", .{addr});
            }
        }
    }

    const t = try std.Thread.spawn(.{}, rpcThread, .{RPCThreadArgs{
        .bc       = &bc,
        .wallet   = &wallet,
        .alloc    = allocator,
        .mempool  = &mempool,
        .p2p      = p2p,
        .sync_mgr = &sync_mgr,
        .metrics  = &g_metrics,
        .channel_mgr = &g_channel_mgr,
        .staking  = &staking,
        .chain_id = @intFromEnum(net_cfg.chain_id),
        .rpc_port = rpc_port,
        .rpc_bind = rpc_bind,
        .rpc_token = rpc_token,
        .faucet_wallet = if (faucet_wallet_opt) |*fw| fw else null,
        .faucet_grant_sat = if (config.faucet_mode) config.faucet_grant_sat else 0,
        .dns = &dns,
        .exchange = exchange_engine,
        .exchange_paper = exchange_paper_engine,
        .orders_path = orders_path_owned,
        .users_path = users_path_owned,
        .identities_path = identities_path_owned,
        .kyc_path = kyc_path_owned,
        .kyc_issuer_address = kyc_issuer_owned,
    }});
    t.detach();
    std.debug.print("[RPC] Server pornit pe port {d} ({s}) bind={s} auth={s}\n\n", .{
        rpc_port,
        if (is_seed) "seed" else "miner",
        rpc_bind,
        if (rpc_token != null) "ON" else "off (loopback only safe)",
    });

    // ── Faucet auto-refill thread (Faza 5) ─────────────────────────────────
    // When --faucet-mode is on AND the miner's primary wallet (savacazan)
    // has been mining and accumulating rewards, periodically top up the
    // faucet from the miner wallet so claims keep working without manual
    // intervention. Threshold + amount tunable via config.faucet_grant_sat.
    if (config.faucet_mode and faucet_wallet_opt != null) {
        const refill_args = allocator.create(FaucetRefillArgs) catch null;
        if (refill_args) |ra| {
            ra.* = .{
                .bc = &bc,
                .miner_wallet = &wallet,
                .faucet_wallet = &faucet_wallet_opt.?,
                .grant_sat = config.faucet_grant_sat,
                .alloc = allocator,
            };
            const rt = std.Thread.spawn(.{}, faucetRefillLoop, .{ra}) catch |err| blk: {
                std.debug.print("[FAUCET-REFILL] thread spawn failed: {}\n", .{err});
                break :blk null;
            };
            if (rt) |th| {
                th.detach();
                std.debug.print("[FAUCET-REFILL] auto-refill thread started (threshold {d} SAT, top-up {d} SAT)\n",
                    .{ FAUCET_REFILL_THRESHOLD_SAT, FAUCET_REFILL_AMOUNT_SAT });
            }
        }
    }

    // ── Node launcher ─────────────────────────────────────────────────────────
    var launcher = node_launcher.NodeLauncher.init(config);
    defer launcher.deinit();

    // Ataseaza P2PNode real la launcher — broadcast() va folosi TCP in loc de print-only
    launcher.attachP2PNode(p2p);

    if (config.mode == node_launcher.NodeMode.seed) {
        try launcher.startSeedNode();
    } else if (config.mode == node_launcher.NodeMode.light) {
        // Light mode: no mining, just header sync
        std.debug.print("[LIGHT] Node started in SPV mode — no mining, headers only\n", .{});
        try launcher.startSeedNode(); // reuse seed init (listener + bootstrap)
    } else {
        try launcher.startMinerNode();
    }

    std.debug.print("[STATUS] Node running | Blocks: {d} | Mempool: {d}\n\n",
        .{ bc.chain.items.len, mempool.size() });

    // ── Light client SPV sync loop ─────────────────────────────────────────
    var maint_counter_light: u32 = 0;
    if (is_light) {
        std.debug.print("[LIGHT] Entering SPV header sync loop...\n\n", .{});
        // Send initial Bloom filter + getheaders to all peers
        p2p.sendBloomFilter();
        p2p.syncHeaders();

        while (!g_shutdown.load(.monotonic)) {
            // Periodically request new headers (every 10s = 1 block time)
            std.Thread.sleep(10 * std.time.ns_per_s);
            p2p.syncHeaders();

            const height = light_client.getHeight();
            const hdr_count = light_client.getHeaderCount();
            if (maint_counter_light % 6 == 0) {
                std.debug.print("[LIGHT] SPV status: {d} headers, height {d}, peers {d}\n",
                    .{ hdr_count, height, p2p.peers.items.len });
            }
            maint_counter_light +%= 1;
        }
        std.debug.print("[LIGHT] SPV sync loop exited — shutdown\n", .{});
        return;
    }

    // ── Mining loop (1s per bloc, conform net_cfg) ────────────────────────────
    std.debug.print("[LOOP] Starting mining loop ({d}ms blocks)...\n\n",
        .{net_cfg.block_time_ms});
    std.debug.print("[POUW] Proof-of-Useful-Work engine initialized\n", .{});
    std.debug.print("[ORACLE] Distributed price oracle initialized\n", .{});

    // ── Oracle Fetcher: real prices from LCX, Kraken, Coinbase ────────────────
    //
    // Spawns a dedicated worker thread that owns all blocking HTTPS work
    // (6 sequential GETs to LCX, Kraken, Coinbase × BTC, LCX). The mining
    // loop only reads the latest snapshot under a tiny mutex — never
    // blocks on the network. This removed the periodic 8–9 s block-time
    // spikes the operator observed (every 10th block sat in fetchAll()
    // for the worst-case sum of 6 HTTPS timeouts).
    g_oracle_fetcher = oracle_fetcher_mod.OracleFetcher.init(allocator);
    if (g_oracle_fetcher) |*f| {
        f.startWorker() catch |err| {
            std.debug.print("[ORACLE-FETCHER] worker spawn failed: {} — fetcher disabled\n",
                .{err});
        };
    }
    std.debug.print("[ORACLE-FETCHER] Real price fetcher initialized + worker thread started\n", .{});

    // ── Performance Metrics init ───────────────────────────────────────────────
    g_metrics = benchmark_mod.Metrics.init();
    g_metrics.start(); // set start_time at runtime (can't call timestamp() at comptime)
    std.debug.print("[METRICS] Performance tracking initialized\n\n", .{});

    // ── Pair registry (optional — extends WS subscriptions to all common pairs) ──
    if (parsed.pair_registry_path) |reg_path| {
        if (pair_registry_mod.loadFile(allocator, reg_path)) |reg| {
            g_pair_registry = reg;
            std.debug.print(
                "[PAIR-REGISTRY] Loaded {s}: lcx={d}, kraken={d}, coinbase={d} (total {d})\n",
                .{ reg_path, reg.lcx.len, reg.kraken.len, reg.coinbase.len, reg.totalRoutes() },
            );
        } else |err| {
            std.debug.print("[PAIR-REGISTRY] Load failed for {s}: {s} (continuing with IMPORTANT_PAIRS only)\n",
                .{ reg_path, @errorName(err) });
        }
    }

    // ── WS Exchange Feed: live bid/ask from Coinbase, Kraken, LCX ──
    //
    // Opt-out via env var OMNIBUS_EXTERNAL_ORACLE=1. When set, the chain
    // process skips spawning the 3 WebSocket worker threads (Coinbase,
    // Kraken, LCX) and the price hashmap; a separate `omnibus-oracle`
    // process is expected to be running on localhost:28100 and the
    // chain queries it via JSON-RPC when prices are needed.
    //
    // BTC pattern: chain-only daemon, oracle is a separate service.
    // Frees ~3 threads + 1 MB resident from the chain process and
    // removes mutex contention between mining and WS workers.
    const external_oracle = std.process.getEnvVarOwned(
        allocator, "OMNIBUS_EXTERNAL_ORACLE",
    ) catch null;
    defer if (external_oracle) |s| allocator.free(s);
    const use_external = external_oracle != null and
        std.mem.eql(u8, external_oracle.?, "1");
    if (use_external) {
        std.debug.print(
            "[WS-FEED] external oracle enabled (OMNIBUS_EXTERNAL_ORACLE=1) " ++
            "— in-process feed disabled. Expect omnibus-oracle on :28100\n", .{});
    } else {
        g_ws_feed = ws_exchange_feed_mod.ExchangeFeed.init(allocator);
        if (g_pair_registry) |*reg| g_ws_feed.?.setPairRegistry(reg);
        // Wire the shared clock BEFORE start() — every PriceFetch.timestamp_ms
        // and circuit-breaker rate-limit timer flows through g_clock.nowMs(),
        // putting feed events on the same timeline as mining and matching.
        g_ws_feed.?.setClock(&g_clock);
        g_ws_feed.?.start() catch |err| std.debug.print("[WS-FEED] start failed: {}\n", .{err});
    }

    // ── Reputation Manager + retro backfill din chain history ──
    g_reputation = reputation_manager_mod.ReputationManager.init(allocator);
    g_reputation.?.started_at_block = @intCast(bc.chain.items.len - 1);
    backfillReputationFromChain(&bc, &g_reputation.?);

    // Porneste block_count de la inaltimea curenta a lantului (continua, nu de la 0)
    var block_count: u32 = @intCast(bc.chain.items.len - 1);
    var maint_count: u32 = 0;
    var mining_started: bool = false;

    // ── Single source of time ──────────────────────────────────────────
    // All slot/sub-block/stabilizer/ws timing reads from this clock.
    // On baremetal we'll swap the backend to TSC-based; nothing else
    // in the loop changes. Uses the global g_clock so subsystems
    // started earlier (WS feed, RPC) share the same timeline.
    var orch = orchestrator_mod.TimeOrchestrator.init(&g_clock);
    // Stabilizer timer wired up immediately. Slot + sub-block timers
    // remain driven by the existing logic for now (see Step 2 plan) —
    // we cut over incrementally to keep regressions contained.
    orch.configure(.stabilizer, 60_000);

    // Tip arrival tracker (millisecond resolution, in-memory only).
    // The on-chain `tip.timestamp` is in seconds — too coarse for sub-second
    // slot-failover. This captures the wall-clock ms when we observed the
    // current tip height, refreshed each iteration if the tip changed.
    var last_tip_height: usize = bc.chain.items.len;
    var tip_arrival_ms: i64 = g_clock.nowMs();

    // ── Burst smoothing ──────────────────────────────────────────────────
    // Minimum interval between two consecutive blocks WE produce. Without
    // this, a VPS scheduler pause of 9s creates a "thundering herd" of
    // ~7 blocks back-to-back in the same wall-clock second when the
    // process resumes — visible as a 9s gap then a clump in the block
    // explorer. The smoothing limit doesn't reduce average throughput
    // (recovered gaps are still recovered) but distributes blocks
    // uniformly so the chain looks healthy in the UI.
    //
    // 800 ms gap = 60 blocks/min wall-clock (whitepaper spec).
    //
    // Math: a measured block produces ~190 ms of unavoidable overhead
    // (10 sub-block ticks + state apply + p2p broadcast + ws_server
    // event + reputation credit + meta-block header). At 1000 ms gap
    // that overhead ate into every slot, dropping us to ~50/min.
    // Setting the gap to 800 ms compensates: 800 ms sleep + ~200 ms
    // of in-loop work = ~1.0 s wall-clock per block, locked to the
    // 60/min target and the whitepaper halving / total-supply schedule.
    //
    // The hardware ceiling is ~180/min on this VPS (measured uncapped),
    // so we have ~3× headroom. That margin absorbs scheduler pauses
    // and catches up after them without falling behind wall-clock.
    const MIN_BLOCK_GAP_MS: i64 = 800;
    var last_block_produced_ms: i64 = 0;

    // ── Block-rate stabilizer ────────────────────────────────────────────
    // Target: 60 blocks/min (1 block/sec, like Solana slot time).
    //
    // Ring buffer of the last N block-arrival timestamps. Used to:
    //   1) report rolling rates (1-min and 60-min windows) to the operator
    //   2) feed an adaptive SLOT_TIMEOUT_MS multiplier — when we're under
    //      target we shrink the timeout (faster failover); when over, we
    //      relax it (less wasted CPU on tight polling).
    //
    // Why a ring of 3600: at 1 block/s that's 60 minutes of history,
    // exactly enough for the "blocks in last 60min" stat the user asked
    // for. At 8 bytes per i64 ms timestamp it's a fixed 28.8 KB — no
    // allocator pressure, no GC tail.
    const RATE_RING_SIZE: usize = 3600;
    const TARGET_BLOCKS_PER_MIN: f64 = 60.0;
    var rate_ring: [RATE_RING_SIZE]i64 = std.mem.zeroes([RATE_RING_SIZE]i64);
    var rate_ring_head: usize = 0;
    var rate_ring_count: usize = 0;
    var stabilizer_last_report_ms: i64 = g_clock.nowMs();
    // Adaptive multiplier for SLOT_TIMEOUT_MS, clamped to [0.2, 2.0]. Updated
    // once per stabilizer report based on observed-vs-target ratio.
    var stabilizer_timeout_mult: f64 = 1.0;

    while (launcher.is_running and !g_shutdown.load(.monotonic)) {
        if (!launcher.readyForMining() and !mining_started) {
            maint_count += 1;
            if (maint_count % 6 == 0) {
                const peer_count: usize = p2p.peers.items.len;
                const needed = node_launcher.NodeLauncher.MIN_PEERS_FOR_MINING;
                std.debug.print("[NETWORK] Waiting for miners... {d}/{d} connected (need {d} to start mining)\n",
                    .{ peer_count, needed, needed });
                if (launcher.getBootstrapStatus()) |bstats| {
                    std.debug.print("  bootstrap status: {}  peers: {d}\n",
                        .{ bstats.status, bstats.peer_count });
                }
            }
            std.Thread.sleep(10 * std.time.ns_per_s);
            continue;
        }

        if (!mining_started and launcher.readyForMining()) {
            try launcher.startMining();
            mining_started = true;
            std.debug.print("[MINING] Network ready — {d} peers connected, mining started (height {d})\n\n",
                .{ p2p.peers.items.len, block_count });
        }

        // ── IDLE check — duplicat detectat pe acelasi IP, nu minaza ─────────
        if (p2p.is_idle) {
            // Nodul e IDLE: primeste blocuri, sincronizeaza, dar NU minaza
            // Re-verifica la fiecare 60s daca duplicatul a disparut
            if (maint_count % 60 == 0) {
                std.debug.print("[IDLE] Re-verificare duplicat IP...\n", .{});
                const recheck = p2p.knockKnock();
                if (recheck == .alone) {
                    std.debug.print("[IDLE] Duplicat disparut — reactivare mining!\n\n", .{});
                }
            }
            std.Thread.sleep(1 * std.time.ns_per_s);
            maint_count += 1;
            continue;
        }

        // ── IBD (Initial Block Download) check ──────────────────────
        // Like Bitcoin: if we are >IBD_GAP_TRIGGER blocks behind a peer,
        // p2p.is_syncing is set. Skip the ENTIRE sub-block + mining cycle
        // (not just the final mineBlockForMiner call) — otherwise we still
        // waste 1s/iter running 10 sub-block ticks on a stale tip while
        // sync is racing to catch up. Just sleep until sync_response brings
        // us within IBD_TOLERANCE, then resume.
        if (p2p.is_syncing.load(.acquire)) {
            std.Thread.sleep(1 * std.time.ns_per_s);
            continue;
        }

        // ── Slot-leader gate (with liveness fallback) ───────────────
        // 1. Normal: only the slot's deterministic leader produces.
        // 2. Liveness: if the slot leader hasn't produced in
        //    SLOT_TIMEOUT_MS, ANY active validator can take the slot
        //    (Tendermint-style "leader skip"). Without this, a network
        //    of 2 validators would freeze whenever one is offline.
        //
        // Sub-second timeout: target 1s/block, so a 300ms timeout is
        // 30% of a slot — long enough to let the leader's block
        // propagate before we step in, short enough to keep block
        // rate >50/min when the leader misses. We measure with the
        // in-memory tip_arrival_ms (ms resolution) — the on-chain
        // tip.timestamp is in seconds, far too coarse.
        const SLOT_TIMEOUT_MS: i64 = 300;
        {
            const tip = bc.chain.items[bc.chain.items.len - 1];
            const slot_id: u64 = @intCast(bc.chain.items.len); // = next block index
            const leader = validator_mod.leaderForSlot(
                slot_id,
                tip.hash,
                bc.validator_set.items,
            );
            const my_addr = effective_miner_addr;

            // Refresh tip_arrival_ms whenever the chain extended (tip changed).
            // Bumping it to "now" effectively restarts the slot timer at every
            // block — the leader for slot N gets SLOT_TIMEOUT_MS *after* slot
            // N-1 landed, not from some absolute past wall-clock.
            if (bc.chain.items.len != last_tip_height) {
                last_tip_height = bc.chain.items.len;
                tip_arrival_ms = g_clock.nowMs();
            }

            // Am I a validator at all? (Required for liveness fallback.)
            var i_am_validator = false;
            for (bc.validator_set.items) |v| {
                if (std.mem.eql(u8, v.address, my_addr)) { i_am_validator = true; break; }
            }

            // Has the slot timed out (leader inactive)?
            //
            // Adaptive timeout: if NO peer has been active in the last 5s,
            // we're effectively solo-mining — there's nobody to wait for.
            // Drop the timeout to 50ms (just enough to let any in-flight
            // block_announce arrive) so each leader-skip slot doesn't burn
            // 300ms of wall-clock. This was the dominant cost in the 35
            // blocks/min steady state: half the slots had a missing peer
            // leader → 300ms × 0.5 ≈ 150ms wasted per block on average.
            const now_ms: i64 = g_clock.nowMs();
            const now_s: i64 = @divTrunc(now_ms, 1000);
            const tip_age_ms: i64 = now_ms - tip_arrival_ms;
            const peer_active_ts_ms = p2p.lastPeerActivityTs() * 1000;
            const peer_offline = peer_active_ts_ms == 0 or
                (now_ms - peer_active_ts_ms) >= 5_000;
            const base_timeout_ms: i64 = if (peer_offline) 50 else SLOT_TIMEOUT_MS;
            // Apply stabilizer multiplier (clamped to [0.2, 2.0] in updater).
            // Floor at 30ms — anything tighter than that and we hit the OS
            // sleep-quantum noise floor and burn CPU without producing blocks.
            const scaled_ms = @as(f64, @floatFromInt(base_timeout_ms)) *
                              stabilizer_timeout_mult;
            const effective_timeout_ms: i64 = @max(@as(i64, 30),
                @as(i64, @intFromFloat(scaled_ms)));
            const slot_timed_out = tip_age_ms >= effective_timeout_ms;

            const is_my_turn = blk: {
                // Bootstrap free-for-all — when no validator yet has crossed
                // MIN_VALIDATOR_BALANCE, the chain would freeze (no slot
                // leader to pick → mining loop sleeps forever). To break
                // the catch-22 (need to mine to gain balance to be a
                // validator), we let any node with `--miner-address`
                // produce blocks while the validator set is empty.
                //
                // Safety: we only bootstrap when there are NO peers
                // connected. If we have peers, we sync from them instead
                // of producing our own (otherwise two fresh nodes with no
                // common chain history both mine block 1 and fork forever).
                // The yield-to-active-peer check below covers the dual-
                // online case once at least one node has bootstrapped.
                const peers_connected = p2p.peers.items.len;
                if (bc.validator_set.items.len == 0 and my_addr.len > 0) {
                    const PEER_ACTIVE_BOOT_S: i64 = 2;
                    const peer_active_ts = p2p.lastPeerActivityTs();
                    const peer_recently_active =
                        peer_active_ts > 0 and (now_s - peer_active_ts) <= PEER_ACTIVE_BOOT_S;
                    if (peers_connected > 0 and peer_recently_active) {
                        std.debug.print(
                            "[BOOTSTRAP] Validator set empty but peer active {d}s ago — yielding to let them seed\n",
                            .{now_s - peer_active_ts},
                        );
                        break :blk false;
                    }
                    if (block_count % 30 == 0) {
                        std.debug.print(
                            "[BOOTSTRAP] No validators yet ({d} blocks, {d} peers) — producing slot {d}\n",
                            .{ bc.chain.items.len, peers_connected, slot_id },
                        );
                    }
                    break :blk true;
                }

                if (leader) |l| {
                    if (std.mem.eql(u8, l.address, my_addr)) break :blk true;
                }
                // Liveness: leader missed the slot — any validator picks up.
                // Anti-fork via deterministic tiebreak: when both validators
                // see the timeout at the same time, they both want to take
                // the slot. Naive yield-to-active-peer deadlocks (both yield
                // to each other → 6s gap, 17 blocks/min instead of 60).
                //
                // Fix: rank candidate fallback validators by address ascending.
                // Only the lowest-ranked validator (lex-smallest address) takes
                // the orphan slot; everyone else yields. This is symmetric
                // *visible* state (the validator set is identical on every
                // node) so both sides reach the same decision without any
                // extra coordination message.
                if (slot_timed_out and i_am_validator) {
                    var lowest_addr: []const u8 = my_addr;
                    for (bc.validator_set.items) |v| {
                        // Skip the missing leader — they're the one who silenced.
                        if (leader) |l| {
                            if (std.mem.eql(u8, l.address, v.address)) continue;
                        }
                        if (std.mem.lessThan(u8, v.address, lowest_addr)) {
                            lowest_addr = v.address;
                        }
                    }
                    const i_am_fallback = std.mem.eql(u8, lowest_addr, my_addr);
                    if (!i_am_fallback) {
                        if (block_count % 30 == 0) {
                            std.debug.print(
                                "[SLOT-YIELD] Tip aged {d}ms at slot {d} — yielding to {s} (lex-min validator)\n",
                                .{ tip_age_ms, slot_id,
                                   lowest_addr[0..@min(12, lowest_addr.len)] },
                            );
                        }
                        break :blk false;
                    }
                    std.debug.print(
                        "[SLOT-SKIP] Leader {s} silent for {d}ms at slot {d}, taking the slot (I am lex-min fallback)\n",
                        .{ if (leader) |l| l.address[0..@min(12, l.address.len)] else "<none>",
                           tip_age_ms, slot_id },
                    );
                    break :blk true;
                }
                break :blk false;
            };
            if (!is_my_turn) {
                if (block_count % 30 == 0 and leader != null) {
                    std.debug.print(
                        "[SLOT] Not my turn at slot {d} — leader is {s} (I am {s})\n",
                        .{ slot_id, leader.?.address[0..@min(12, leader.?.address.len)], my_addr[0..@min(12, my_addr.len)] },
                    );
                }
                // Tight poll (50ms) so we react within ~half a SLOT_TIMEOUT.
                // The previous 500ms added avoidable latency: at 1s/block we
                // could miss the failover window entirely on one iteration.
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            }

            // Block-rate enforcement: never produce a new block faster
            // than MIN_BLOCK_GAP_MS after the previous one. With the
            // gap set to 1000 ms this locks the chain to exactly the
            // 60 blocks/min target from the whitepaper.
            //
            // Hardware capacity is ~3× this rate (we measured 180-185
            // blocks/min uncapped on the same VPS). The headroom is
            // intentional safety margin — when scheduler pauses or
            // network jitter eat into a slot, the next iteration still
            // produces inside the same wall-clock second; we never fall
            // behind the published schedule.
            //
            // Previously this smoothing was conditional on
            // `stabilizer_timeout_mult >= 1.0`, but that escape hatch
            // existed only because we were chasing 60/min and didn't
            // want to suppress recovery bursts. With the oracle_fetcher
            // unblocked (no more 8-9 s spikes) we have no reason to
            // burst — the unconditional gap keeps tokenomics honest.
            if (last_block_produced_ms != 0) {
                const since_last = now_ms - last_block_produced_ms;
                if (since_last < MIN_BLOCK_GAP_MS) {
                    const wait_ms: u64 = @intCast(MIN_BLOCK_GAP_MS - since_last);
                    std.Thread.sleep(wait_ms * std.time.ns_per_ms);
                }
            }
        }

        // ── Ciclu 10 sub-blocuri × 0.1s → 1 Key-Block ────────────────────────
        const reward_sat = blockchain_mod.blockRewardAt(block_count);

        // Scoate TX-urile minabile din mempool (locktime <= current height)
        // Locked TXs (locktime > block_count) raman in mempool pana cand chain-ul ajunge la acea inaltime
        const pending_txs = mempool.getMineable(1000, block_count, allocator) catch &.{};
        defer if (pending_txs.len > 0) allocator.free(pending_txs);

        var key_block_opt: ?sub_block_mod.KeyBlock = null;

        // Run all 10 sub-block ticks back-to-back, no sleep between them.
        //
        // Previous implementation paced each tick with sleep(40ms) = 400ms
        // of pure idle time per block. Sub-blocks were NEVER broadcast on
        // P2P, NEVER pushed via WebSocket, NEVER exposed via RPC, NEVER
        // surfaced in the frontend — the "soft confirmation at 100ms" idea
        // from the comments was design intent, not actual behavior. The
        // sleep was overhead with zero functional value.
        //
        // Pacing of block production now lives entirely in the slot-leader
        // gate above (SLOT_TIMEOUT_MS / adaptive timeout / lex-min tiebreak).
        // The 10 sub-block ticks become pure TX batching: each tick takes
        // an even share of `pending_txs` and produces a SubBlock that
        // contributes to the KeyBlock's aggregate merkle root.
        //
        // If we ever want real soft confirmation later, sub-blocks need to
        // be broadcast + WS-pushed + indexed by RPC — that's a separate
        // multi-component project, not just a sleep call.
        for (0..sub_block_mod.SUB_BLOCKS_PER_BLOCK) |sub_i| {
            _ = sub_i;
            key_block_opt = try sb_engine.tick(@constCast(pending_txs), reward_sat);
        }

        // Key-Block complet → mineaza blocul principal in blockchain
        // Round-robin: reward-ul merge la fiecare miner pe rand
        if (key_block_opt != null) {
            const miner_addr = g_miner_pool.getMinerForBlock(block_count, effective_miner_addr);
            const mine_start_ns: u64 = @intCast(std.time.nanoTimestamp());
            // Resilient mining: if mineBlockForMiner returns an error (most
            // commonly OOM from balance HashMap growth on long-running nodes,
            // see crash trace 2026-04-26 testnet/regtest at ~16500 blocks),
            // we log + skip THIS block and continue. The node stays up,
            // chain pauses 1s, and the next iteration tries again. Crashing
            // the entire process for a transient OOM is what brought the
            // testnet/regtest nodes down — never again.
            const new_block = bc.mineBlockForMiner(miner_addr) catch |err| {
                std.debug.print(
                    "[MINER] mineBlockForMiner failed: {} — skipping this block, retrying next tick\n",
                    .{err},
                );
                std.Thread.sleep(1 * std.time.ns_per_s);
                continue;
            };
            const mine_end_ns: u64 = @intCast(std.time.nanoTimestamp());
            const mine_time_ns = mine_end_ns - mine_start_ns;

            // ── Snapshot prices from WS feed into the mined block ────────
            // Mapeaza ws_exchange_feed.PriceFetch → blockchain.BlockPriceEntry
            // (fixed-size strings ca sa traiasca in hashmap fara allocator).
            if (g_ws_feed) |*feed| {
                const live = feed.snapshot();
                var entries: [6]blockchain_mod.BlockPriceEntry = undefined;
                for (live, 0..) |p, i| {
                    var e: blockchain_mod.BlockPriceEntry = .{};
                    const elen = @min(p.exchange.len, 16);
                    e.exchange_len = @intCast(elen);
                    @memcpy(e.exchange[0..elen], p.exchange[0..elen]);
                    const plen = @min(p.pair.len, 16);
                    e.pair_len = @intCast(plen);
                    @memcpy(e.pair[0..plen], p.pair[0..plen]);
                    e.bid_micro_usd = p.bid_micro_usd;
                    e.ask_micro_usd = p.ask_micro_usd;
                    e.timestamp_ms  = p.timestamp_ms;
                    e.success       = p.success;
                    entries[i] = e;
                }
                bc.recordBlockPrices(new_block.index, &entries);
            }

            // Update metrics: hashrate from nonces tried
            g_metrics.updateHashrate(new_block.nonce, mine_time_ns);

            if (!consensus.isBlockHashValid(new_block.hash, bc.difficulty)) {
                std.debug.print("[CONSENSUS] Bloc respins: hash invalid\n", .{});
                continue;
            }

            block_count += 1;
            last_block_produced_ms = g_clock.nowMs();

            // Rebuild slot calendar every 10 blocks (≈ every 10 seconds at
            // target rate). 60 leaderForSlot SHA256 calls per rebuild was
            // ~60-200µs of hot-path overhead per block; at 1/10 rate that
            // drops to a 6-20µs amortised cost. Calendar entries don't go
            // stale faster than that — leader assignments are stable as
            // long as validator_set + tip hash haven't changed, and an
            // out-of-date calendar self-corrects via refreshStates() and
            // isStale() checks at consume time.
            if (block_count % 10 == 0) {
                g_slot_calendar.rebuild(
                    validator_mod.Validator,
                    bc.validator_set.items,
                    @intCast(block_count),
                    new_block.hash,
                    last_block_produced_ms,
                    1000, // slot interval ms — matches block time
                    validator_mod.leaderForSlot,
                );
            }

            // ── Stabilizer: record block arrival + adapt timeouts ──────────
            //
            // Block-arrival timestamp + 60s reporting interval both come
            // from the orchestrator's AtomicClock + stabilizer timer.
            // `tick()` returns whether the 60s timer fired this iteration;
            // we still also pass the boolean OR with a manual fallback
            // so that a block arriving slightly after the orchestrator
            // tick still triggers the report on its own arrival path.
            {
                const arrival_ms = g_clock.nowMs();
                rate_ring[rate_ring_head] = arrival_ms;
                rate_ring_head = (rate_ring_head + 1) % RATE_RING_SIZE;
                if (rate_ring_count < RATE_RING_SIZE) rate_ring_count += 1;

                const orch_fired = orch.tick().fired(.stabilizer);
                const manual_due = (arrival_ms - stabilizer_last_report_ms) >= 60_000;
                if (orch_fired or manual_due) {
                    // Count blocks within the last 60s and last 60min windows.
                    var blocks_1m: u32 = 0;
                    var blocks_60m: u32 = 0;
                    const cutoff_1m = arrival_ms - 60_000;
                    const cutoff_60m = arrival_ms - 60 * 60_000;
                    var i: usize = 0;
                    while (i < rate_ring_count) : (i += 1) {
                        const ts = rate_ring[i];
                        if (ts >= cutoff_60m) blocks_60m += 1;
                        if (ts >= cutoff_1m)  blocks_1m  += 1;
                    }
                    const ratio = @as(f64, @floatFromInt(blocks_1m)) /
                                  TARGET_BLOCKS_PER_MIN;
                    // Direct adjust: low rate (ratio < 1) → shrink timeout
                    // (faster failover, more aggressive); high rate (ratio > 1)
                    // → relax timeout (less CPU pressure). Multiplier *is* the
                    // ratio, clamped to [0.2, 2.0]: at ratio=0.6 we set
                    // timeout to 60% of base (300ms × 0.6 = 180ms).
                    var new_mult = ratio;
                    if (new_mult < 0.2) new_mult = 0.2;
                    if (new_mult > 2.0) new_mult = 2.0;
                    stabilizer_timeout_mult = new_mult;

                    // Clock health score: how close was the actual wall-
                    // clock 60s span to the expected 60_000ms? On a
                    // shared VPS the scheduler can pause us for seconds —
                    // that drags the score down and tells the operator
                    // the timing layer is unreliable. On baremetal we
                    // expect 100 always.
                    const score = orchestrator_mod.clockScore60s(
                        stabilizer_last_report_ms, arrival_ms,
                    );

                    // Hardware cycle counter snapshot — direct rdtscp.
                    // The 64-bit spectrum line lets the operator visually
                    // see CPU clock progression. On a stable system the
                    // high 16 bits stay constant minute-to-minute; the
                    // low bits oscillate every cycle. Anomalies (suspended
                    // process, frequency scaling, hypervisor migration)
                    // show up as broken bit patterns.
                    const cycles = orchestrator_mod.nowCycles();
                    var spec_buf: [64]u8 = undefined;
                    orchestrator_mod.formatSpectrum(cycles, &spec_buf);

                    std.debug.print(
                        "[STABILIZER] last 60s = {d} blocks ({d:.1}/min) | " ++
                        "last 60min = {d} blocks | target = {d:.0}/min | " ++
                        "ratio = {d:.2} | timeout_mult = {d:.2} | " ++
                        "clock_score = {d}/100 | rdtsc = {d}\n" ++
                        "[CLOCK-BITS] {s}\n",
                        .{
                            blocks_1m, @as(f64, @floatFromInt(blocks_1m)),
                            blocks_60m, TARGET_BLOCKS_PER_MIN,
                            ratio, stabilizer_timeout_mult, score, cycles,
                            spec_buf,
                        },
                    );

                    // Slot-calendar status snapshot — refresh entry states
                    // and log the next future leader so the operator can
                    // see who'll mine the upcoming slot before it lands.
                    g_slot_calendar.refreshStates(arrival_ms, block_count);
                    if (g_slot_calendar.nextFutureSlot()) |next| {
                        const leader = next.leaderSlice();
                        const leader_short = leader[0..@min(12, leader.len)];
                        const ms_until = next.expected_arrival_ms - arrival_ms;
                        std.debug.print(
                            "[CALENDAR] next slot {d} in {d}ms | leader = {s}\n",
                            .{ next.slot_id, ms_until, leader_short },
                        );
                    }
                    // ── PHASE-B: audit balance consistency ─────────────────────
                    const audit = bc.auditBalanceConsistency();
                    if (audit.divergences > 0) {
                        std.debug.print(
                            "[ALERT] Balance divergence detected: {d}/{d} addresses diverged from UTXO set\n",
                            .{ audit.divergences, audit.addresses_checked },
                        );
                    }
                    // ── PHASE-C.3: stray-write detector ────────────────────────
                    // Every legitimate balance mutation comes through
                    // applyBlock / mineBlockForMiner / recalculateFromHeight
                    // / p2p sync — all of those set bc.in_apply_block=true
                    // for the duration of the work. Anything outside that
                    // window is a phantom write that won't survive replay.
                    // Counter is process-lifetime; non-zero means we have
                    // a regression to find before C.4 deletes bc.balances
                    // entirely.
                    if (bc.stray_balance_writes > 0) {
                        std.debug.print(
                            "[ALERT] Stray balance writes since startup: {d} — phantom credits/debits, find the callsite\n",
                            .{bc.stray_balance_writes},
                        );
                    }
                    // ── PHASE-C.4: chainstate audit + sync ────────────────────
                    if (g_chainstate) |*cs| {
                        // Sync RAM → chainstate. We do this once a minute,
                        // not per block — the WAL fsync per record would
                        // dominate latency at 60 blocks/min. A future
                        // applyBlock-time hook will narrow the window
                        // when we're ready to make chainstate primary.
                        var sync_count: usize = 0;
                        var sync_diff: usize = 0;
                        var bit2 = bc.balances.iterator();
                        while (bit2.next()) |kv| {
                            const ram_bal = kv.value_ptr.*;
                            const cs_bal = cs.getBalance(kv.key_ptr.*);
                            if (ram_bal != cs_bal) {
                                cs.putBalance(kv.key_ptr.*, ram_bal) catch {};
                                sync_diff += 1;
                            }
                            sync_count += 1;
                        }
                        const cs_addrs = cs.balanceCount();
                        const cs_supply = cs.totalSupply();
                        std.debug.print(
                            "[CHAINSTATE] audit: ram_addrs={d} cs_addrs={d} cs_supply={d} sat | synced={d} diff this tick\n",
                            .{ sync_count, cs_addrs, cs_supply, sync_diff },
                        );
                        // Persist the chainstate snapshot. Cheap (data is
                        // small for now) and keeps WAL bounded.
                        cs.checkpoint() catch |err| {
                            std.debug.print("[CHAINSTATE] checkpoint failed: {}\n", .{err});
                        };
                    }

                    stabilizer_last_report_ms = arrival_ms;
                }
            }

            // ── Reputation: credit FOOD pentru miner-ul efectiv al acestui bloc.
            // Pe testnet ne uitam la `miner_addr` (rotat round-robin de pool).
            // VACATION + LOVE se acorda separat (per-day tick mai jos in loop).
            if (g_reputation) |*rep_mgr| {
                rep_mgr.creditMinedBlock(miner_addr, @as(u64, block_count));
            }

            // Auto-save: track blocks and TXs since last save
            bc.blocks_since_save += 1;
            bc.txs_since_save += @intCast(pending_txs.len);
            // Detectam daca checkAutoSave a flush-uit prin reset-ul contorului.
            const before_save = bc.blocks_since_save;
            bc.checkAutoSave();
            var did_save = bc.blocks_since_save < before_save;

            // ── FIX (2026-05-03): per-block chainstate flush ──────────────────
            //
            // Inainte: checkAutoSave era no-op si saveToDisc ruleaza doar din
            // thread-ul de fundal (interval 30s). Orice stake/agent register/
            // op_return memo din ultimele 30s inainte de SEGV / restart binar /
            // systemctl restart era pierdut — restart-ul citea chainstate
            // vechi, iar pubkey_registry/balances populate de TX-urile recente
            // disparuser. Validatorii pierdeau rolul, agentii dispareau, sent
            // values pe pool addresses se reseta la 0.
            //
            // Acum: dupa fiecare bloc reusit forteaza un flush. Wrapped in
            // try/catch — daca disk-ul e plin sau lent, log + continua mining
            // (thread-ul de 30s va reincerca). NU oprim mining-ul pe save fail.
            //
            // TBD (Fix #2): saveBlockchain face full-file rewrite (monolitic).
            // La 50k+ blocuri devine ~hundreds of ms per save. Plan refactor
            // → blocks/blkNNNNN.dat append + chainstate/ KV (Bitcoin-style),
            // tracked in arch/leveldb-storage. Pana atunci, costul e acceptabil
            // pentru garantia ca state survives restart.
            bc.saveToDisc() catch |err| {
                std.debug.print(
                    "[DB] Per-block save failed at #{d}: {} — continuing mining, 30s thread will retry\n",
                    .{ block_count, err },
                );
            };
            std.debug.print("[DB] Saved chainstate after block #{d}\n", .{block_count});
            did_save = true;
            // DNS persist piggybacks on chain auto-save (cadenta identica).
            if (did_save) {
                dns.saveToFile(dns_persist_path) catch |err| {
                    std.debug.print("[DNS] Save to {s} failed: {s}\n",
                        .{ dns_persist_path, @errorName(err) });
                };
            }

            // Record metrics
            g_metrics.recordBlock();
            for (0..pending_txs.len) |_| {
                g_metrics.recordTx();
            }

            // ── PoUW: Track mining work for reward distribution ─────────
            {
                var work = pouw_mod.WorkReport{
                    .miner_address = undefined,
                    .miner_addr_len = 0,
                    .work_type = .matching,
                    .block_height = block_count,
                    .timestamp_ms = @intCast(std.time.milliTimestamp()),
                    .fills_count = 0,
                    .volume_matched_sat = 0,
                    .price_updates = 0,
                    .settlements_count = 0,
                    .work_hash = std.mem.zeroes([32]u8),
                    .signature = std.mem.zeroes([64]u8),
                };
                // Copy miner address
                const addr_bytes = miner_addr;
                const addr_len: u8 = @intCast(@min(addr_bytes.len, 64));
                @memcpy(work.miner_address[0..addr_len], addr_bytes[0..addr_len]);
                work.miner_addr_len = addr_len;
                g_pouw_engine.submitWorkReport(work) catch {};
            }

            // Anunta blocul la peerii P2P (legacy announce + gossip relay)
            p2p.chain_height = block_count;
            p2p.broadcastBlock(block_count, new_block.hash, reward_sat);
            p2p.broadcastBlockGossip(block_count, new_block.hash, reward_sat);

            // Push real-time catre frontend React prin WebSocket
            ws_srv.broadcastBlock(
                block_count,
                new_block.hash,
                reward_sat,
                bc.difficulty,
                mempool.size(),
            );

            // ── PoUW: Calculate and log rewards for this block ──────────
            g_pouw_engine.calculateRewards(block_count);
            g_pouw_engine.resetBlock();

            // ── AI Agents: tick all loaded agents on this block ─────────
            agentTickAll(&bc, block_count);

            // ── Price Oracle: Reset submissions for next round ──────────
            g_price_oracle.resetRound();

            // ── Oracle Fetcher: log latest snapshot every 10 blocks ─────────
            //
            // The actual fetching happens on a dedicated worker thread (see
            // OracleFetcher.startWorker in main()). Here we only read the
            // latest snapshot under the mutex — constant-time, never blocks
            // mining. Previously this branch called fetcher.fetchAll()
            // directly, which did 6 sequential blocking HTTPS calls and
            // could pause the mining thread for 8–9 seconds when any
            // exchange was slow. That was the cause of the periodic
            // 9000ms block-latency spikes the operator observed in
            // testnet logs (1 slow block at every 10th, like clockwork).
            if (block_count % 10 == 0) {
                if (g_oracle_fetcher) |*fetcher| {
                    const snap = fetcher.snapshot();
                    var btc_ok: u8 = 0;
                    var lcx_ok: u8 = 0;
                    for (snap[0..3]) |p| { if (p.success) btc_ok += 1; }
                    for (snap[3..6]) |p| { if (p.success) lcx_ok += 1; }
                    if (fetcher.getMedianPrice()) |median| {
                        std.debug.print("[ORACLE-FETCHER] BTC/USD median: ${d}.{d:0>2} ({d}/3 exchanges)\n",
                            .{ median / 1_000_000, (median % 1_000_000) / 10_000, btc_ok });
                    } else {
                        std.debug.print("[ORACLE-FETCHER] BTC: no prices available\n", .{});
                    }
                    if (fetcher.getMedianLcxPrice()) |median| {
                        std.debug.print("[ORACLE-FETCHER] LCX/USD median: ${d}.{d:0>4} ({d}/3 exchanges)\n",
                            .{ median / 1_000_000, (median % 1_000_000) / 100, lcx_ok });
                    } else {
                        std.debug.print("[ORACLE-FETCHER] LCX: no prices available\n", .{});
                    }
                }
            }

            // ── Metachain: inregistreaza shard header pentru acest bloc ───────
            const shard_id = metachain.coordinator.getShardForAddress(wallet.address);
            const meta_block = try metachain.beginMetaBlock();
            var block_hash_fixed: [32]u8 = std.mem.zeroes([32]u8);
            const hash_copy_len = @min(new_block.hash.len, 32);
            @memcpy(block_hash_fixed[0..hash_copy_len], new_block.hash[0..hash_copy_len]);
            try meta_block.addShardHeader(.{
                .shard_id     = shard_id,
                .block_height = block_count,
                .block_hash   = block_hash_fixed,
                .tx_count     = @intCast(pending_txs.len),
                .timestamp    = std.time.timestamp(),
                .miner        = wallet.address,
                .reward_sat   = reward_sat,
            });
            try metachain.finalizeMetaBlock();

            if (block_count % 10 == 0) {
                std.debug.print("[METACHAIN] height={d} shard={d} active_shards={d}\n", .{
                    metachain.getHeight(),
                    shard_id,
                    metachain.coordinator.num_shards,
                });
            }

            // Notifica SyncManager — bloc aplicat local
            sync_mgr.onBlockApplied(block_count);

            // Sincronizeaza balanta
            wallet.updateBalance(bc.getAddressBalance(wallet.address));

            // Per-block DB persistence DISABLED.
            //
            // Was: pbc.appendBlock(&bc, db_path) → which on v2 DB always
            // fallbacks to a full saveBlockchain rewrite (hundreds of MB at
            // 55k+ blocks, 1-2s per block). Killed throughput.
            //
            // Now: persistence happens only at the every-100-blocks checkpoint
            // below + the every-10-min checkAutoSave + on graceful shutdown.
            // Crash-recovery falls back to peer resync, which testnet-style
            // mesh handles trivially.

            if (block_count % 10 == 0) {
                std.debug.print("[MINING] {d} blocks | difficulty: {d} | reward: {d} SAT | balance: {d} SAT\n",
                    .{ block_count, bc.difficulty, reward_sat, wallet.balance });
                std.debug.print("[MINING] Hashrate: {d} H/s | TPS: {d} | Peak TPS: {d}\n",
                    .{ g_metrics.hashrate, g_metrics.currentTps(), g_metrics.peak_tps });
                mempool.printStats();
            }

            // DB checkpoint disabled in mining loop.
            //
            // The blockchain itself IS the database — balances, nonces,
            // pubkey registry are all reconstructed deterministically by
            // replaying the chain. The .dat file is just a startup cache.
            // On testnet (and frankly anywhere with peer mesh), restart
            // resyncs from peers in seconds. Synchronous full rewrites of
            // a 55k-block chain were the dominant p99 outlier (18s pauses)
            // and bought zero functional value.
            //
            // Save still happens on graceful shutdown (signal handler) and
            // via checkAutoSave's 10-min safety net.

            // ── State Trie: update account state ───────────────────────
            {
                var addr_buf: [20]u8 = std.mem.zeroes([20]u8);
                const alen = @min(wallet.address.len, 20);
                @memcpy(addr_buf[0..alen], wallet.address[0..alen]);
                try state_trie.updateBalance(addr_buf, wallet.balance, block_count);
                state_trie.block_height = block_count;
            }

            // ── Finality: propose checkpoint every 64 blocks ────────────
            if (block_count % finality_mod.CHECKPOINT_INTERVAL == 0 and block_count > 0) {
                _ = finality.proposeCheckpoint(block_count, block_hash_fixed) catch {};
                // Self-attest (solo miner attests own checkpoint)
                finality.attest(.{
                    .validator_id = 0,
                    .target_epoch = block_count / finality_mod.CHECKPOINT_INTERVAL,
                    .source_epoch = finality.last_justified_epoch,
                    .voting_power = 1000,
                    .block_hash = block_hash_fixed,
                    .timestamp = std.time.timestamp(),
                }) catch {};
                std.debug.print("[FINALITY] Checkpoint epoch {d} | justified={d} finalized={d}\n",
                    .{ block_count / finality_mod.CHECKPOINT_INTERVAL,
                       finality.last_justified_epoch, finality.last_finalized_epoch });
            }

            // ── Staking: distribute rewards (every 100 blocks) ──────────
            if (block_count % staking_mod.REWARD_EPOCH_BLOCKS == 0 and staking.activeCount() > 0) {
                staking.distributeRewards(reward_sat);
                std.debug.print("[STAKING] Epoch {d} | validators={d} | total_staked={d}\n",
                    .{ staking.current_epoch, staking.activeCount(), staking.total_staked });
            }

            // ── Peer Scoring: score peers on block relay ─────────────────
            // In solo mode no peers, but ready for multi-node
            _ = &peer_scoring;

            // ── F8: Update miner balance caches ────────────────────────────
            //
            // BUG FIX (2026-04-27): we previously also republished each
            // pool entry's `public_key_hex` into `bc.pubkey_registry`. When
            // the entry was created via `registerWithRandomKey` (the legacy
            // `register(addr)` path), that pubkey was a random key unrelated
            // to the real address — registering it would poison the registry
            // and cause ECDSA verification to fail for any transaction
            // actually signed with the wallet's mnemonic. The `sendtransaction`
            // RPC handler now is the only authoritative writer; it registers
            // the *real* pubkey from `ctx.wallet.addresses[0].public_key_hex`
            // before validation. Pool entries with random keys are still
            // useful for `getMinerForBlock` rotation, just not for signing.
            {
                g_miner_pool.mutex.lock();
                const pool_count = g_miner_pool.count;
                var addrs_buf: [MinerWalletPool.MAX][64]u8 = undefined;
                var lens_buf: [MinerWalletPool.MAX]u8 = undefined;
                for (0..pool_count) |pi| {
                    addrs_buf[pi] = g_miner_pool.wallets[pi].address;
                    lens_buf[pi] = g_miner_pool.wallets[pi].address_len;
                }
                g_miner_pool.mutex.unlock();

                for (0..pool_count) |pi| {
                    const maddr = addrs_buf[pi][0..lens_buf[pi]];
                    const mbal = bc.getAddressBalance(maddr);
                    g_miner_pool.updateBalance(maddr, mbal);
                }
            }

            // ── F8: Auto-TX between miners (every 5 blocks) ─────────────
            if (block_count % 5 == 0 and g_miner_pool.count >= 2) {
                autoTxBetweenMiners(&bc, block_count, allocator);
            }

            // Curata mempool la fiecare 300 blocuri (cu expiry 14 zile)
            if (block_count % 300 == 0) {
                mempool.maintenance();
            }
        }

        maint_count += 1;
        if (maint_count % 30 == 0) {
            launcher.maintenance();

            // ── P2P maintenance: reconnect dead peers + evict expired bans ──
            // Without this, peers that drop mid-broadcast (TCP reset) stay
            // marked dead forever and the node mines on a private fork.
            // Observed live 2026-04-26: PC at 49875, VPS at 49625, 250
            // blocks of divergence because gossip kept failing with
            // ConnectionClosed and nothing reconnected.
            p2p.processReconnects();
            p2p.evictExpiredBans();
            // Fork recovery: if we've been broadcasting blocks that peers
            // keep rejecting (TCP closed mid-send), we're on a fork. Drop
            // the last 1-2 blocks and re-sync. Returns true if recovery
            // was triggered (logs a [FORK-RECOVERY] line).
            _ = p2p.tryForkRecovery();

            // ── Governance: log active proposals ────────────────────────
            if (governance.proposal_count > 0) {
                std.debug.print("[GOVERNANCE] Active proposals: {d}\n", .{governance.proposal_count});
            }

            // ── DNS: log registry stats ─────────────────────────────────
            const dns_active = dns.activeCount(block_count);
            if (dns_active > 0) {
                std.debug.print("[DNS] Registered names: {d}\n", .{dns_active});
            }

            // ── Guardian: log guarded accounts ──────────────────────────
            const guarded = guardian.guardedCount(block_count);
            if (guarded > 0) {
                std.debug.print("[GUARDIAN] Guarded accounts: {d}\n", .{guarded});
            }
            if (launcher.getNetworkStatus()) |s| {
                std.debug.print("[NETWORK] peers: {d}  miners: {d}  synced: {}\n",
                    .{ s.total_peers, s.total_miners, s.is_synced });
            }
            p2p.cleanDeadPeers();
            p2p.gossipMaintenance();

            // Log gossip stats
            {
                const gs2 = p2p.getGossipStats();
                if (gs2.tx_relayed > 0 or gs2.blocks_relayed > 0) {
                    std.debug.print("[GOSSIP] TX relayed: {d} | Blocks relayed: {d} | Seen TX: {d} | Seen blocks: {d}\n",
                        .{ gs2.tx_relayed, gs2.blocks_relayed, gs2.seen_tx, gs2.seen_blocks });
                }
            }

            // Verifica daca sync-ul e blocat
            if (sync_mgr.isStalled()) {
                std.debug.print("[SYNC] STALLED >60s — resetare sync\n", .{});
                sync_mgr = SyncManager.init(@intCast(bc.chain.items.len), allocator);
            }

            // Log status sync periodic
            if (!sync_mgr.isSynced()) {
                sync_mgr.state.print();
            }
        }

        // Notifica SyncManager cand un peer P2P anunta un bloc mai inalt
        if (p2p.chain_height > @as(u32, @intCast(bc.chain.items.len))) {
            if (sync_mgr.onPeerHeight(p2p.chain_height)) |_| {
                // Cere blocuri lipsa de la primul peer care are height mai mare
                p2p.requestSync(@intCast(bc.chain.items.len));
                std.debug.print("[SYNC] requestSync trimis (local={d} peer={d})\n",
                    .{ bc.chain.items.len, p2p.chain_height });
            }
        }
    }

    // ── Graceful shutdown — save state before defers run ────────────────────
    std.debug.print("\n[SHUTDOWN] Saving chain to disc...\n", .{});

    // Stop the background state-save thread first so it doesn't race with
    // the final shutdown save. join() blocks until the worker finishes its
    // current iteration; in the worst case we wait one save-interval.
    stopStateSaveThread();

    pbc.saveBlockchain(&bc, db_path) catch |err| {
        std.debug.print("[SHUTDOWN] Save failed: {} — data may be lost!\n", .{err});
    };
    // PHASE-C.4: final chainstate checkpoint + close. The checkpoint
    // dumps the memtable to .snap and truncates the WAL, so the next
    // startup loads in O(1) instead of replaying every WAL record.
    if (g_chainstate) |*cs| {
        cs.checkpoint() catch |err| {
            std.debug.print("[SHUTDOWN] chainstate checkpoint failed: {}\n", .{err});
        };
        cs.close();
        std.debug.print("[SHUTDOWN] chainstate checkpointed and closed\n", .{});
    }
    // Save DNS registry too — names registered after last auto-save would be lost otherwise.
    dns.saveToFile(dns_persist_path) catch |err| {
        std.debug.print("[SHUTDOWN] DNS save failed: {s}\n", .{@errorName(err)});
    };
    std.debug.print("[SHUTDOWN] Saved {d} blocks, {d} addresses, {d} names\n", .{ bc.chain.items.len, bc.balances.count(), dns.entry_count });
    std.debug.print("[SHUTDOWN] Cleaning up (P2P, WS, wallet via defer)... Goodbye!\n", .{});
    // p2p.deinit(), ws_srv.deinit(), bc.deinit(), pbc.deinit() etc. run via defer
}
