const std     = @import("std");
const builtin = @import("builtin");

// Re-export the EVM build flag at root scope so that sub-modules
// (evm_executor.zig) can probe it via `@hasDecl(@import("root"), …)`.
// build.zig wires `build_options` into this exe via `addOptions()`.
pub const build_options_evm_enabled: bool = @import("build_options").evm_enabled;

// Single-instance lock — un singur miner per masina.
// Vezi core/node/platform_lock.zig pentru implementare (Windows + POSIX).
const platform_lock = @import("node/platform_lock.zig");
const acquireSingleInstanceLock = platform_lock.acquireSingleInstanceLock;
const wallet_setup = @import("node/wallet_setup.zig");
const mempool_init = @import("node/mempool_init.zig");
const db_setup     = @import("node/db_setup.zig");
const subsystems_init = @import("node/subsystems_init.zig");
const p2p_init     = @import("node/p2p_init.zig");
const config_setup = @import("node/config_setup.zig");
const matching_engine_init = @import("node/matching_engine_init.zig");

const pq_crypto_mod   = @import("pq_crypto.zig");
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
const faucet_mod       = @import("faucet.zig");

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
const secp256k1_mod    = @import("secp256k1.zig");
const governance_mod   = @import("governance.zig");
const staking_mod      = @import("staking.zig");
const chain_config_mod = @import("chain_config.zig");
const validator_mod    = @import("validator_registry.zig");
const state_trie_mod   = @import("state_trie.zig");
const tx_receipt_mod   = @import("tx_receipt.zig");
const guardian_mod     = @import("guardian.zig");
const dns_mod          = @import("dns_registry.zig");
const registrar_mod    = @import("registrar_addresses.zig");
const dex_settler_mod  = @import("dex_settler.zig");
const evm_signer_mod   = @import("evm_signer.zig");
const evm_escrow_mod   = @import("evm_escrow_watcher.zig");
const fills_log_mod    = @import("fills_log.zig");
const peer_scoring_mod = @import("peer_scoring.zig");
const peer_persist_mod = @import("peer_persist.zig");
const compact_mod      = @import("compact_blocks.zig");
const kademlia_mod     = @import("kademlia_dht.zig");
const key_enc_mod      = @import("key_encryption.zig");
const light_client_mod = @import("light_client.zig");
const light_miner_mod  = @import("light_miner.zig");
const payment_mod      = @import("payment_channel.zig");
const bread_mod        = @import("bread_ledger.zig");
const schnorr_mod      = @import("schnorr.zig");
const multisig_mod     = @import("multisig.zig");
const transaction_mod  = @import("transaction.zig");
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
const bridge_mod         = @import("bridge_native.zig");
const grid_mod           = @import("grid_engine.zig");

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

// ── Mempool TX verifier (HIGH-05) ──────────────────────────────────────────
// Closes the RBF-without-sig-check hole: every TX entering the mempool
// (initial submit OR replace-by-fee replacement) is signature-checked here
// before acceptance. Mirrors the dispatch in blockchain.validateTransaction:
//   ECDSA  → look up pubkey in bc.pubkey_registry (or use embedded pubkey
//             field if the sender hasn't registered yet — backward compat
//             with the same first-tx behavior the chain validator uses).
//   PQ     → pubkey is embedded in the TX itself (PQ keys aren't in the
//             registry; each PQ scheme carries its own pk).
// Returns false on any decode/lookup error so the mempool rejects the TX.
// Extracted to core/node/mempool_verifier.zig (2026-05-29). Body delegates
// to keep main.zig lean; the wrapper preserves the original symbol so any
// in-file reference (mempool init, tests) continues to resolve.
const mempool_verifier_mod = @import("node/mempool_verifier.zig");
fn mempoolVerifierFn(ctx_opt: ?*anyopaque, tx: *const transaction_mod.Transaction) bool {
    return mempool_verifier_mod.mempoolVerifierFn(ctx_opt, tx);
}

// ── Graceful Shutdown — Ctrl+C / SIGINT handler ─────────────────────────────
// Extracted to core/node/shutdown.zig (2026-05-29). The `g_shutdown` re-export
// preserves the legacy name so any cross-module reference via `main_mod.g_shutdown`
// continues to resolve (callers can use the pointer with .load/.store on `.*`).
const shutdown_mod = @import("node/shutdown.zig");
pub const g_shutdown = &shutdown_mod.g_shutdown;

fn installShutdownHandler() void {
    shutdown_mod.installShutdownHandlers();
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
// Extracted to core/node/state_save.zig. Re-exports kept here so callers
// using `main_mod.startStateSaveThread` / `main_mod.stopStateSaveThread`
// and `main_mod.g_state_save_*` (see persistence.zig comment) keep working.
const state_save_mod = @import("node/state_save.zig");
pub const STATE_SAVE_INTERVAL_SEC = state_save_mod.STATE_SAVE_INTERVAL_SEC;
pub const startStateSaveThread = state_save_mod.startStateSaveThread;
pub const stopStateSaveThread = state_save_mod.stopStateSaveThread;

// Graceful shutdown sequence — extracted to core/node/graceful_shutdown.zig
// (2026-05-31). Keeps the entry point readable; the call site below is a
// single `node_shutdown.runGracefulShutdown(.{ ... })` invocation.
const node_shutdown = @import("node/graceful_shutdown.zig");

// ── Global Slot Calendar — pre-computed next 60 slots (PoH-style) ─────────
// Rebuilt after each block from the validator set + tip hash. Read-only
// from frontend (RPC endpoint `getslotcalendar`) and from the mining
// loop (which uses `nextFutureSlot()` for "what's next" hints).
pub var g_slot_calendar: orchestrator_mod.SlotCalendar =
    orchestrator_mod.SlotCalendar.empty();

// ── Global WS Exchange Feed — live BTC + LCX bid/ask via WebSocket ──────────
// Initialized in main() after all other inits, before mining loop
pub var g_ws_feed: ?ws_exchange_feed_mod.ExchangeFeed = null;

// ── Global StakingEngine pointer — set in main() after init ────────────────
// Allows rpc_server handlers (handleStake / handleGetStakers / handleGetValidatorsV2)
// and the per-block reputation reward loop to read validator state without
// passing the engine through every call site.
pub var g_staking_engine: ?*staking_mod.StakingEngine = null;

// ── Oracle Bridge — pulls prices from standalone omnibus-oracle on :28100 ──
// When OMNIBUS_EXTERNAL_ORACLE=1, the chain process does NOT run the 3 WS
// workers (Coinbase/Kraken/LCX). Instead this bridge thread polls the
// standalone oracle every 10s via JSON-RPC and feeds g_ws_feed using
// upsertPriceExternal(). Downstream RPCs (omnibus_getallprices etc.) and
// ArbitrageEngine read g_ws_feed identically — they don't know the source.
pub var g_oracle_bridge_run: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var g_oracle_bridge_thread: ?std.Thread = null;

// ── Process-wide context for hooks that fire from background threads ──────
// Set once in main() after wallet derivation; read by oracle bridge tick
// for FOOD reputation credit. Null on RPC-only / non-mining nodes.
pub var g_local_miner_address: ?[]const u8 = null;
// Atomic block height for thread-safe reads from oracle bridge / agents.
// Updated each iteration of the mining loop.
pub var g_current_block_height: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

// ── Global WS Server pointer — set after WsServer.start() in main() ──────────
// Used by chain hot paths (blockchain.addTransaction, dns_registry handlers,
// p2p connect/disconnect) to push real-time events to frontend without needing
// a direct dependency on ws_server.zig from those modules. Safe to read from
// any thread because ws_srv internally locks. Null until server starts; null
// after server stops — every emit must check for null.
pub var g_ws_srv: ?*WsServer = null;
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

// Thread RPC — pornit din main, detach.
// Extracted 2026-05-29 to core/node/rpc_thread.zig; re-exported here so
// existing call sites (`std.Thread.spawn(.{}, rpcThread, .{RPCThreadArgs{…}})`)
// keep working unchanged.
const rpc_thread_mod = @import("node/rpc_thread.zig");
const RPCThreadArgs = rpc_thread_mod.RPCThreadArgs;
const rpcThread     = rpc_thread_mod.rpcThread;

// Faucet auto-refill + auto-TX-between-miners.
// Extracted 2026-05-29 to core/node/faucet_thread.zig; re-exported here.
// faucet_thread.zig accesses `g_miner_pool` via @import("root").
const faucet_thread_mod = @import("node/faucet_thread.zig");
const runtime_init      = @import("node/runtime_init.zig");
const autoTxBetweenMiners       = faucet_thread_mod.autoTxBetweenMiners;
const FaucetRefillArgs          = faucet_thread_mod.FaucetRefillArgs;
const faucetRefillLoop          = faucet_thread_mod.faucetRefillLoop;
const FAUCET_REFILL_THRESHOLD_SAT = faucet_thread_mod.FAUCET_REFILL_THRESHOLD_SAT;
const FAUCET_REFILL_AMOUNT_SAT    = faucet_thread_mod.FAUCET_REFILL_AMOUNT_SAT;
const FAUCET_REFILL_TICK_S        = faucet_thread_mod.FAUCET_REFILL_TICK_S;

// ── AI Agent System: load config + tick on every block ─────────────────────
//
// Extracted to core/node/agents.zig (2026-05-29). The re-exports below
// preserve the legacy symbol names so existing call sites in this file
// (loadAgentConfig from CLI parse, agentTickAll from mining loop,
// backfillReputationFromChain from startup) keep resolving unchanged.
const agents_mod = @import("node/agents.zig");
const loadAgentConfig             = agents_mod.loadAgentConfig;
const buildOracleSnapshot         = agents_mod.buildOracleSnapshot;
const submitNativeTx              = agents_mod.submitNativeTx;
const agentTickAll                = agents_mod.agentTickAll;
const backfillReputationFromChain = agents_mod.backfillReputationFromChain;

// Oracle bridge moved to core/node/oracle_bridge.zig
const oracle_bridge_mod = @import("node/oracle_bridge.zig");
const mining_periodic = @import("node/mining_periodic.zig");
const loadOracleQuorumPubkeys = oracle_bridge_mod.loadOracleQuorumPubkeys;
const startOracleBridge = oracle_bridge_mod.startOracleBridge;
const stopOracleBridge = oracle_bridge_mod.stopOracleBridge;


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

    // Initialize liboqs (CPU feature detection, PQ crypto runtime).
    // MUST run before any pq_crypto.* call (wallet derivation, TX verify).
    pq_crypto_mod.init();
    std.debug.print("[PQ] liboqs initialized — ML-DSA-87 + Falcon-512 + SLH-DSA + ML-KEM-768 ready\n", .{});

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

    // ── Chain config + Oracle policy ─ moved to node/config_setup.zig ───────
    const net_cfg: ChainConfig = config_setup.resolveChainConfig(parsed.chain_mode).net_cfg;
    g_oracle_policy = config_setup.buildOraclePolicy(
        net_cfg.chain_id,
        parsed.price_warn_pct,
        parsed.price_reject_pct,
        parsed.price_fillgap_pct,
        parsed.price_validation_disabled,
    );

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

    // ── Mnemonic ─ moved to node/config_setup.zig ───────────────────────────
    const mnemonic = try config_setup.resolveMnemonic(config.mnemonic, allocator);

    // ── DB path selection + Init database ─ moved to node/db_setup.zig ──────
    const chain_name = net_cfg.name; // e.g. "omnibus-mainnet" / "omnibus-testnet"
    const short_name = db_setup.shortChainName(chain_name);

    const db_path_res = try db_setup.resolveDbPath(allocator, short_name);
    defer allocator.free(db_path_res.db_path);
    defer if (db_path_res.env_data_dir) |d| allocator.free(d);
    const db_path: []u8 = db_path_res.db_path;

    var pbc = try db_setup.loadPersistentDb(allocator, db_path);
    defer pbc.deinit();

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
    // Faucet starts at 0 — funded organically by mining donations, community top-ups,
    // and miner auto-refill (see FAUCET_REFILL_THRESHOLD_SAT in faucetRefillLoop).
    // No genesis-allocated supply: every OMNI in the faucet was mined by someone first.

    // ── pq_identity_map persistence + chainstate KV ─ moved to node/db_setup.zig ──
    db_setup.loadPqIdentities(&bc, short_name, allocator);
    g_chainstate = db_setup.openChainstateKV(&bc, short_name, allocator);

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
    var wallet = try wallet_setup.initLocalWallet(mnemonic, config.wallet_index, allocator);
    defer wallet.deinit();

    // ── Faucet wallet (optional) ────────────────────────────────────────
    // SECURITY: faucet wallet is loaded from a RAW PRIVATE KEY (env var
    // OMNIBUS_FAUCET_PRIVKEY, 64 hex chars), NOT from the miner mnemonic.
    // Why: a faucet runs 24/7 on a public server. Using the miner mnemonic
    // would expose ALL derived wallets (savacazan, sava.omnibus, etc.) if
    // the server is compromised. With a single-purpose private key, an
    // attacker who steals the file gets only the faucet's small balance
    // (≤ a few OMNI) and cannot touch the rest of the user's wallet
    // family. Same model Bitcoin uses for hot wallets (HSM-style isolation).
    var faucet_wallet_opt: ?Wallet = if (config.faucet_mode)
        wallet_setup.loadFaucetWallet(allocator, config.faucet_grant_sat)
    else
        null;
    defer if (faucet_wallet_opt) |*fw| fw.deinit();
    _ = config.faucet_wallet_index; // retained on NodeConfig for future BIP-32 path; not used by privkey loader

    if (faucet_wallet_opt != null) {
        wallet_setup.setupFaucetLedger(allocator, config.testnet, config.regtest);
    }

    // ── Effective miner address ─────────────────────────────────────────
    const effective_miner_addr = wallet_setup.pickEffectiveMinerAddress(config.miner_address, wallet.address);
    // Expose miner address to background threads (oracle bridge → FOOD credit).
    g_local_miner_address = effective_miner_addr;

    // Inregistreaza adresa minerului efectiv ca primul miner in pool.
    // See wallet_setup.registerSeedMiner for the bug-fix history (2026-04-27).
    wallet_setup.registerSeedMiner(&g_miner_pool, effective_miner_addr, wallet.address, mnemonic, allocator);

    // ── AI Agents: load --agent-config <file> if provided ─────────────────────
    if (agents_mod.checkAgentsActive(allocator)) {
        if (parsed.agent_config_path) |agent_path| {
            loadAgentConfig(agent_path, mnemonic, effective_miner_addr, allocator);
        }
    }

    // ── Init Mempool FIFO ─────────────────────────────────────────────────────
    var mempool = try mempool_init.initMempool(allocator, &bc, mempoolVerifierFn);
    defer mempool.deinit();

    // ── Init 6 core subsystems (Consensus / Metachain / StateTrie / Finality /
    //    Staking / Governance) — see core/node/subsystems_init.zig for prints.
    var subs = try subsystems_init.initSubsystems(allocator, NUM_SHARDS, wallet.private_key_bytes);
    defer subs.metachain.deinit();
    defer subs.state_trie.deinit();
    g_staking_engine = &subs.staking;
    const consensus = subs.consensus;
    const governance = subs.governance;

    // ── Init Peer Scoring ────────────────────────────────────────────────────
    var peer_scoring = peer_scoring_mod.PeerScoringEngine.init();
    const peer_persistence = @import("node/peer_persistence.zig");
    var peer_bans_path_buf: [256]u8 = undefined;
    const peer_bans_path = peer_persistence.loadPeerBans(&peer_scoring, @tagName(parsed.chain_mode), &peer_bans_path_buf);
    // Periodic save cadence (mining loop checks elapsed time).
    var peer_bans_last_save: i64 = std.time.timestamp();
    const PEER_BANS_SAVE_INTERVAL_S: i64 = 60;

    // ── Init DNS Registry + persist file (per-chain) ────────────────────────
    var dns = dns_mod.DnsRegistry.init();
    var dns_persist_path_buf: [256]u8 = undefined;
    const dns_persist_path = peer_persistence.loadDnsRegistry(&dns, @tagName(parsed.chain_mode), &dns_persist_path_buf);
    // DNS finalize: Phase 2 migration + prune + treasury wiring + fee/sign
    // enforcement config. See core/node/peer_persistence.zig.
    try peer_persistence.finalizeDns(&dns, @intCast(bc.chain.items.len), parsed.chain_mode);

    // Attach the registry to the blockchain so applyBlock can run pay-to-claim:
    // every TX with op_return `ns_claim:<name>.<tld>` paying ens.omnibus the
    // right fee gets the name auto-registered to its sender. See
    // dns_registry.claimByPayment + blockchain.applyBlock for the full flow.
    bc.dns_registry = &dns;

    // ── Init swap-stack persistence (HTLC + Payment Channels + Intents) ────
    // All three follow the same data/<chain>/<file> layout; helpers in
    // node/swap_persistence.zig handle bufPrint + load + log lines and
    // return the resolved path so periodic-save / shutdown call sites
    // below can reuse it without re-formatting.
    const swap_persistence = @import("node/swap_persistence.zig");
    var htlc_persist_path_buf: [256]u8 = undefined;
    const htlc_persist_path = swap_persistence.loadHtlcRegistry(&bc.htlc_registry, @tagName(parsed.chain_mode), &htlc_persist_path_buf);
    var channels_path_buf: [256]u8 = undefined;
    const channels_path = swap_persistence.loadPaymentChannels(&g_channel_mgr, @tagName(parsed.chain_mode), &channels_path_buf);
    var intent_persist_path_buf: [256]u8 = undefined;
    const intent_persist_path = swap_persistence.loadIntentRegistry(&bc.intent_registry, @tagName(parsed.chain_mode), &intent_persist_path_buf);

    // ── Init cross-chain oracle quorum pubkey set ───────────────────────────
    // `oracle_recordHeader` requires ≥ ORACLE_QUORUM_MIN distinct valid
    // signatures from this set; without it, the handler falls through to
    // the legacy dev-mode `quorum_ok=true` flag that any caller can spoof.
    // Operators install the set by writing data/<chain>/oracle_quorum.json
    // (committed for testnet; mainnet pulls from a hardened genesis ceremony).
    var quorum_path_buf: [256]u8 = undefined;
    const quorum_path = std.fmt.bufPrint(
        &quorum_path_buf,
        "data/{s}/oracle_quorum.json",
        .{@tagName(parsed.chain_mode)},
    ) catch "data/oracle_quorum.json";
    _ = wallet_setup.loadOracleQuorum(quorum_path);

    // ── Init Guardian System ─────────────────────────────────────────────────
    var guardian = swap_persistence.initGuardian();

    std.debug.print("[SUBSYSTEMS] StateTrie + Finality + Staking + Governance + PeerScoring + DNS + Guardian\n\n", .{});

    // ── Init P2P stack (P2P node + listener + heartbeat + sub-block engine +
    //    sync manager + light client). See core/node/p2p_init.zig.
    var p2p_stack = try p2p_init.initP2PStack(
        allocator,
        config.node_id,
        config.host,
        config.port,
        net_cfg.chain_id,
        config.seed_host,
        config.seed_port,
        @intCast(bc.chain.items.len),
    );
    defer {
        p2p_stack.p2p_heap.deinit();
        allocator.destroy(p2p_stack.p2p_heap);
    }
    defer p2p_stack.light_client.deinit();
    const p2p = p2p_stack.p2p_heap;

    // ── Knock Knock — anunta reteaua + verifica duplicat pe acelasi IP ────────
    wallet_setup.logKnockResult(p2p.knockKnock());

    // Ataseaza blockchain + sync_mgr la nodul P2P — necesar pentru sync real
    p2p.attachBlockchain(&bc, &p2p_stack.sync_mgr);

    const is_light = (config.mode == node_launcher.NodeMode.light);
    if (is_light) {
        p2p.attachLightClient(&p2p_stack.light_client);
        std.debug.print("[LIGHT] SPV light client mode — headers only, no full blocks\n\n", .{});
    }

    // ── EVM Engine (revm) — initialize before RPC so eth_* methods work ──────
    subsystems_init.initEvm();
    defer subsystems_init.shutdownEvm();

    // ── WebSocket + RPC — pornite pe TOATE nodurile ─────────────────────────────
    // Minerii AU NEVOIE de RPC/WS pentru ca UI (Liberty Suite) sa poata afisa
    // IBD progress, balance, mining stats pt nodul LOCAL — fara aceasta UI
    // arata doar starea seed-ului, nu a minerului propriu. Pentru a evita
    // conflict de port cand rulezi seed + miner pe aceeasi masina, miner-ul
    // foloseste rpc_port+1 / ws_port+1.
    const is_seed = (config.mode == node_launcher.NodeMode.seed);
    const ws_port  = if (is_seed) net_cfg.ws_port  else net_cfg.ws_port  + 1;
    const rpc_port = if (is_seed) net_cfg.rpc_port else net_cfg.rpc_port + 1;

    // ── WebSocket + RPC config + DEX journal paths ─ moved to node/ws_rpc_init.zig ─
    const ws_rpc_init = @import("node/ws_rpc_init.zig");
    const ws_rpc_chain_subdir: []const u8 = if (config.testnet) "testnet"
        else if (config.regtest) "regtest" else "mainnet";
    var ws_cfg = try ws_rpc_init.initWsAndRpcConfig(allocator, &bc, ws_port, ws_rpc_chain_subdir);
    defer ws_cfg.ws_srv.deinit();
    defer allocator.free(ws_cfg.rpc_bind);
    defer if (ws_cfg.rpc_token) |t| allocator.free(t);
    defer if (ws_cfg.users_path) |p| allocator.free(p);
    defer if (ws_cfg.identities_path) |p| allocator.free(p);
    defer if (ws_cfg.kyc_path) |p| allocator.free(p);
    defer if (ws_cfg.profiles_path) |p| allocator.free(p);

    p2p.attachWsServer(&ws_cfg.ws_srv);
    // Publish to global so non-main modules (blockchain, dns_registry hooks)
    // can emit events without holding a direct WsServer pointer.
    g_ws_srv = &ws_cfg.ws_srv;
    // Tell P2P which wallet address mines on this node, so block
    // announcements carry the WALLET address as `miner_id` (which is
    // what peers validate against the slot leader). Without this, peers
    // saw `local_id` ("vps-testnet" etc.) and rejected every block.
    p2p.attachMinerAddress(effective_miner_addr);

    const rpc_bind = ws_cfg.rpc_bind;
    const rpc_token = ws_cfg.rpc_token;

    // ── Native DEX matching engine ─ moved to node/matching_engine_init.zig ─
    const exchange_disabled = std.process.hasEnvVar(allocator, "OMNIBUS_EXCHANGE_OFF") catch false;
    const paper_disabled = std.process.hasEnvVar(allocator, "OMNIBUS_PAPER_OFF") catch false;
    const me_chain_subdir: []const u8 = if (config.testnet) "testnet"
        else if (config.regtest) "regtest" else "mainnet";
    const real_engine_res = matching_engine_init.initRealEngine(allocator, me_chain_subdir, exchange_disabled);
    const exchange_engine: ?*matching_mod.MatchingEngine = real_engine_res.engine;
    const orders_path_owned: ?[]u8 = real_engine_res.orders_path;
    // PHASE 2B: attach engine to blockchain for consensus matching.
    // applyBlock will route TxType.order_place / .order_cancel into this engine
    // deterministically after sorting by (pair, price, hash).
    if (exchange_engine) |e| bc.exchange_engine = e;
    const exchange_paper_engine: ?*matching_mod.MatchingEngine =
        matching_engine_init.initPaperEngine(exchange_disabled, paper_disabled);

    // Registrar slots are hardcoded in registrar_addresses.zig — no run-time
    // loop here (Linux + Zig 0.15 segfault on the const-array iteration; see
    // chain wipe history 2026-04-29). Operator can `cat core/registrar_addresses.zig`
    // for the canonical map. Each slot is a native smart contract: on-chain
    // address, no private key, chain enforces the rules.

    // Exchange-users / identities / KYC / profiles journal paths moved into
    // node/ws_rpc_init.zig (see ws_cfg above). Aliased here so RPCThreadArgs
    // construction below stays unchanged.
    const users_path_owned = ws_cfg.users_path;
    const identities_path_owned = ws_cfg.identities_path;
    const kyc_path_owned = ws_cfg.kyc_path;
    const profiles_path_owned = ws_cfg.profiles_path;

    // Trade fills log, KYC issuer, bridge state, grid registry —
    // all four heap-init blocks were extracted into core/node/exchange_engines.zig.
    const exchange_engines = @import("node/exchange_engines.zig");
    const ee_chain_subdir = exchange_engines.chainSubdir(config.testnet, config.regtest);
    const fills_log_handle = exchange_engines.initFillsLog(allocator, ee_chain_subdir);
    const kyc_issuer_owned = exchange_engines.deriveKycIssuer(mnemonic, allocator);
    const bridge_state_ptr = exchange_engines.initBridgeState(allocator);
    const grid_init = exchange_engines.initGridRegistry(allocator, ee_chain_subdir);
    const grid_registry_ptr = grid_init.registry;
    const grid_path_owned = grid_init.path;

    // EVM escrow watcher + DEX settler — extracted helpers in node/exchange_init.zig.
    // Behavior unchanged (same chain IDs, RPC URLs, poll intervals, log lines).
    const exchange_init = @import("node/exchange_init.zig");
    const evm_watcher_handle = exchange_init.initEvmEscrowWatcher(allocator);
    // dex_settler handle intentionally kept alive for the lifetime of the
    // process; shutdown signal handling is best-effort in mainnet, so we
    // simply discard the pointer once the thread has been started.
    if (bc.exchange_engine) |engine| {
        _ = exchange_init.initDexSettler(allocator, mnemonic, engine, fills_log_handle, evm_watcher_handle);
    } else {
        std.debug.print("[DEX_SETTLER] exchange_engine not enabled — settler skipped\n", .{});
    }

    const t = try std.Thread.spawn(.{}, rpcThread, .{RPCThreadArgs{
        .bc       = &bc,
        .wallet   = &wallet,
        .alloc    = allocator,
        .mempool  = &mempool,
        .p2p      = p2p,
        .sync_mgr = &p2p_stack.sync_mgr,
        .metrics  = &g_metrics,
        .channel_mgr = &g_channel_mgr,
        .staking  = &subs.staking,
        .chain_id = @intFromEnum(net_cfg.chain_id),
        .rpc_port = rpc_port,
        .rpc_bind = rpc_bind,
        .rpc_token = rpc_token,
        .faucet_wallet = if (faucet_wallet_opt) |*fw| fw else null,
        .faucet_grant_sat = if (config.faucet_mode) config.faucet_grant_sat else 0,
        .dns = &dns,
        .exchange = exchange_engine,
        .exchange_paper = exchange_paper_engine,
        .evm_escrow_watcher = evm_watcher_handle,
        .orders_path = orders_path_owned,
        .users_path = users_path_owned,
        .identities_path = identities_path_owned,
        .kyc_path = kyc_path_owned,
        .kyc_issuer_address = kyc_issuer_owned,
        .bridge = bridge_state_ptr,
        .grid_registry = grid_registry_ptr,
        .grid_path = grid_path_owned,
        .profiles_path = profiles_path_owned,
        .fills_log = fills_log_handle,
    }});
    t.detach();
    std.debug.print("[RPC] Server pornit pe port {d} ({s}) bind={s} auth={s}\n\n", .{
        rpc_port,
        if (is_seed) "seed" else "miner",
        rpc_bind,
        if (rpc_token != null) "ON" else "off (loopback only safe)",
    });

    // ── Faucet auto-refill thread (Faza 5) ─────────────────────────────────
    _ = runtime_init.spawnFaucetRefillThread(
        allocator,
        config.faucet_mode,
        config.faucet_grant_sat,
        &bc,
        &wallet,
        if (faucet_wallet_opt) |*fw| fw else null,
    );

    // ── Node launcher ─────────────────────────────────────────────────────────
    var launcher = try runtime_init.buildAndStartNodeLauncher(config, p2p);
    defer launcher.deinit();

    std.debug.print("[STATUS] Node running | Blocks: {d} | Mempool: {d}\n\n",
        .{ bc.chain.items.len, mempool.size() });

    // ── Light client SPV sync loop ─────────────────────────────────────────
    if (is_light) {
        @import("node/light_loop.zig").runLightLoop(p2p, &p2p_stack.light_client);
        return;
    }

    // ── Mining loop (1s per bloc, conform net_cfg) ────────────────────────────
    std.debug.print("[LOOP] Starting mining loop ({d}ms blocks)...\n\n",
        .{net_cfg.block_time_ms});
    std.debug.print("[POUW] Proof-of-Useful-Work engine initialized\n", .{});
    std.debug.print("[ORACLE] Distributed price oracle initialized\n", .{});

    // ── Oracle Fetcher: real prices from LCX, Kraken, Coinbase ────────────────
    g_oracle_fetcher = runtime_init.initOracleFetcher(allocator);

    // ── Performance Metrics init ───────────────────────────────────────────────
    g_metrics = runtime_init.initMetrics();

    // ── Pair registry (optional — extends WS subscriptions to all common pairs) ──
    g_pair_registry = runtime_init.loadPairRegistry(allocator, parsed.pair_registry_path);

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
            "— in-process WS feed disabled. Bridging from omnibus-oracle on :28100\n", .{});
        // Initialize an EMPTY feed (no WS workers) — the poll thread fills it
        // via upsertPriceExternal from the standalone oracle's snapshot. All
        // downstream RPCs (omnibus_getallprices / getexchangefeed / getarbitrage)
        // and ArbitrageEngine read from g_ws_feed exactly as if WS were live.
        g_ws_feed = ws_exchange_feed_mod.ExchangeFeed.init(allocator);
        if (g_pair_registry) |*reg| g_ws_feed.?.setPairRegistry(reg);
        g_ws_feed.?.setClock(&g_clock);
        // Spawn the bridge poll thread. Idempotent — joins on shutdown via
        // g_oracle_bridge_run atomic flag.
        startOracleBridge(allocator) catch |err| {
            std.debug.print("[ORACLE-BRIDGE] spawn failed: {} — feed will stay empty\n", .{err});
        };
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
            // Guard: chain should always contain genesis, but if another thread
            // is mid-reset (DB reload, fork resolution), len can transiently be 0.
            // Skip this slot rather than panic on out-of-bounds index.
            if (bc.chain.items.len == 0) {
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            }
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
                // Treat the validator_set as "effectively empty" when it
                // contains ONLY the genesis placeholder ("…replaceformainnet")
                // and no real wallet has been promoted yet. Without this gate,
                // the slot-leader check below ALWAYS rejects me (placeholder
                // address never matches a real wallet) → mining spins forever
                // without producing blocks. See validator_registry.zig:63-69
                // for the placeholder seed.
                var has_real_validator = false;
                for (bc.validator_set.items) |v| {
                    if (std.mem.indexOf(u8, v.address, "replaceformainnet") == null and
                        std.mem.indexOf(u8, v.address, "bootstrapvalidator") == null) {
                        has_real_validator = true;
                        break;
                    }
                }
                if (!has_real_validator and my_addr.len > 0) {
                    const PEER_ACTIVE_BOOT_S: i64 = 2;
                    const peer_active_ts = p2p.lastPeerActivityTs();
                    const peer_recently_active =
                        peer_active_ts > 0 and (now_s - peer_active_ts) <= PEER_ACTIVE_BOOT_S;
                    if (peers_connected > 0 and peer_recently_active) {
                        std.debug.print(
                            "[BOOTSTRAP] Validator set placeholder-only but peer active {d}s ago — yielding to let them seed\n",
                            .{now_s - peer_active_ts},
                        );
                        break :blk false;
                    }
                    if (block_count % 30 == 0) {
                        std.debug.print(
                            "[BOOTSTRAP] No real validators yet ({d} blocks, {d} peers, set_size={d}) — producing slot {d}\n",
                            .{ bc.chain.items.len, peers_connected, bc.validator_set.items.len, slot_id },
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
            key_block_opt = try p2p_stack.sb_engine.tick(@constCast(pending_txs), reward_sat);
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
            // Publish height for background threads (oracle bridge etc.)
            g_current_block_height.store(@as(u64, block_count), .release);
            last_block_produced_ms = g_clock.nowMs();

            // Rebuild slot calendar every 10 blocks (≈ every 10 seconds at
            // target rate). 60 leaderForSlot SHA256 calls per rebuild was
            // ~60-200µs of hot-path overhead per block; at 1/10 rate that
            // drops to a 6-20µs amortised cost. Calendar entries don't go
            // stale faster than that — leader assignments are stable as
            // long as validator_set + tip hash haven't changed, and an
            // out-of-date calendar self-corrects via refreshStates() and
            // isStale() checks at consume time.
            // Steady-state DNS prune: every 1000 blocks (~16 min at 1s/block)
            // drop names whose grace period elapsed. Cheap — linear scan of
            // registry, swap-remove. Skip on testnet where blocks tick fast
            // and we may not want lifecycle churn during stress tests.
            if (block_count % 1000 == 0 and parsed.chain_mode == .mainnet) {
                const pruned = dns.pruneExpiredNames(@intCast(block_count));
                if (pruned > 0) {
                    std.debug.print("[DNS] Pruned {d} expired names at block {d}\n",
                        .{ pruned, block_count });
                }
            }

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

            // ── Reputation: credit pentru toate cele 4 domenii ─────────────────
            //
            // FOOD = work (mining + oracle push + agent decisions)
            // RENT = capital (stake + hold per-block)
            // VACATION = longevity (per-day tick at 8640 blocks)
            // LOVE = uptime (per-block heartbeat for active miners)
            //
            // Hooks for oracle push + agent decisions are wired separately at
            // their call sites (oracle bridge tick, submitNativeTx success).
            if (g_reputation) |*rep_mgr| {
                // FOOD — block mined credit
                rep_mgr.creditMinedBlock(miner_addr, @as(u64, block_count));

                // LOVE — uptime credit pentru miner activ. La 1s/block, 60 blocs
                // = 1 minut online. Acordat la fiecare 60 blocuri (creditUptimeMinutes
                // trateaza 1 minut = LOVE_PER_MINUTE_ONLINE points).
                if (block_count > 0 and block_count % 60 == 0) {
                    rep_mgr.creditUptimeMinutes(miner_addr, 1, @as(u64, block_count));
                }
                // LOVE bonus — daily streak (la fiecare 8640 blocuri = 1 zi).
                if (block_count > 0 and block_count % 8640 == 0) {
                    rep_mgr.creditDailyStreak(miner_addr, @as(u64, block_count));
                }

                // RENT — credit per-block pentru stakeri activi.
                // Iteram primii `validator_count` din slot-ul fix de 128.
                // Stake e in SAT (1e9 SAT = 1 OMNI), creditStakePerBlock asteapta OMNI.
                if (g_staking_engine) |se| {
                    var vi: usize = 0;
                    while (vi < se.validator_count) : (vi += 1) {
                        const val = &se.validators[vi];
                        if (val.status != .active) continue;
                        const omni_staked = val.total_stake / 1_000_000_000;
                        if (omni_staked == 0) continue;
                        rep_mgr.creditStakePerBlock(
                            val.address[0..val.addr_len],
                            omni_staked,
                            @as(u64, block_count),
                        );
                    }
                }

                // VACATION — daily tick. 1 day = 8640 blocks @ 10s.
                // Fix B1 deadlock: previously took rep_mgr.lock() then called
                // creditVacationDay which re-locks the same mutex (non-reentrant
                // std.Thread.Mutex panics → mainnet wedge for ~12 min until
                // systemd respawn). Solution: collect the addresses first under
                // a brief lock, then iterate the OWNED list calling
                // creditVacationDay (which will lock once, briefly, per addr).
                if (block_count > 0 and block_count % 8640 == 0) {
                    const total_days: u64 = @as(u64, block_count) / 8640;
                    // Snapshot keys under lock to avoid concurrent-modify panic.
                    var addr_list = std.array_list.Managed([]const u8).init(allocator);
                    defer {
                        for (addr_list.items) |a| allocator.free(a);
                        addr_list.deinit();
                    }
                    {
                        rep_mgr.lock();
                        defer rep_mgr.unlock();
                        var iter = rep_mgr.iterate();
                        while (iter.next()) |entry| {
                            const owned = allocator.dupe(u8, entry.key_ptr.*) catch continue;
                            addr_list.append(owned) catch {
                                allocator.free(owned);
                                break;
                            };
                        }
                    }
                    // Now lock-free — each call takes the mutex briefly.
                    for (addr_list.items) |addr| {
                        rep_mgr.creditVacationDay(
                            addr,
                            total_days,
                            @as(u64, block_count),
                        );
                    }
                }
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
                // HTLC registry persists on the same cadence as DNS.
                @import("htlc_persist.zig").saveToFile(&bc.htlc_registry, htlc_persist_path) catch |err| {
                    std.debug.print("[HTLC] Save to {s} failed: {s}\n",
                        .{ htlc_persist_path, @errorName(err) });
                };
                // Payment channels persist on the same cadence.
                @import("channel_persist.zig").saveToFile(&g_channel_mgr, channels_path) catch |err| {
                    std.debug.print("[CHANNELS] Save to {s} failed: {s}\n",
                        .{ channels_path, @errorName(err) });
                };
                // Intent registry persists on the same cadence as HTLC.
                bc.intent_registry.saveToFile(intent_persist_path) catch |err| {
                    std.debug.print("[INTENT] Save to {s} failed: {s}\n",
                        .{ intent_persist_path, @errorName(err) });
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
            ws_cfg.ws_srv.broadcastBlock(
                block_count,
                new_block.hash,
                reward_sat,
                bc.difficulty,
                mempool.size(),
            );

            // Emit tx_confirmed for every TX bundled in this block. UI uses this
            // to flip mempool entries from "pending" → "confirmed" without
            // re-querying. Skip the coinbase (idx=0) which has no real sender.
            for (new_block.transactions.items, 0..) |tx, idx| {
                if (idx == 0) continue;
                if (tx.hash.len == 0) continue;
                ws_cfg.ws_srv.broadcastTxConfirmed(tx.hash, block_count, new_block.hash);
            }

            // ── WS: broadcast fills (trades) + orderbook snapshots ──────
            {
                // Canonical pair labels — mirrors exchange_listPairs RPC order
                const PAIR_LABELS = [7][]const u8{
                    "OMNI/USDC", "BTC/USDC", "LCX/USDC",
                    "ETH/USDC",  "OMNI/BTC", "OMNI/LCX", "OMNI/ETH",
                };

                if (bc.fills_history.get(@intCast(new_block.index))) |fills| {
                    for (fills) |fill| {
                        const label = if (fill.pair_id < PAIR_LABELS.len)
                            PAIR_LABELS[fill.pair_id] else "OMNI/USDC";
                        ws_cfg.ws_srv.broadcastTrade(
                            fill.pair_id, label,
                            fill.price_micro_usd, fill.amount_sat,
                            "buy", block_count,
                        );
                    }
                }

                if (bc.exchange_engine) |eng| {
                    for (PAIR_LABELS, 0..) |label, pid| {
                        const pair_id: u16 = @intCast(pid);
                        const bb = eng.bestBid(pair_id) orelse 0;
                        const ba = eng.bestAsk(pair_id) orelse 0;
                        const oc = eng.orderCountForPair(pair_id);
                        if (bb > 0 or ba > 0 or oc > 0) {
                            const sp = if (ba > bb) ba - bb else 0;
                            ws_cfg.ws_srv.broadcastOrderbook(pair_id, label, bb, ba, sp, oc, block_count);
                        }
                    }
                }
            }

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
                        ws_cfg.ws_srv.broadcastOraclePrice("BTC/USD", median, btc_ok);
                    } else {
                        std.debug.print("[ORACLE-FETCHER] BTC: no prices available\n", .{});
                    }
                    if (fetcher.getMedianLcxPrice()) |median| {
                        std.debug.print("[ORACLE-FETCHER] LCX/USD median: ${d}.{d:0>4} ({d}/3 exchanges)\n",
                            .{ median / 1_000_000, (median % 1_000_000) / 100, lcx_ok });
                        ws_cfg.ws_srv.broadcastOraclePrice("LCX/USD", median, lcx_ok);
                    } else {
                        std.debug.print("[ORACLE-FETCHER] LCX: no prices available\n", .{});
                    }
                }
            }

            // ── Metachain: inregistreaza shard header pentru acest bloc ───────
            const shard_id = subs.metachain.coordinator.getShardForAddress(wallet.address);
            const meta_block = try subs.metachain.beginMetaBlock();
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
            try subs.metachain.finalizeMetaBlock();

            if (block_count % 10 == 0) {
                std.debug.print("[METACHAIN] height={d} shard={d} active_shards={d}\n", .{
                    subs.metachain.getHeight(),
                    shard_id,
                    subs.metachain.coordinator.num_shards,
                });
            }

            // Notifica SyncManager — bloc aplicat local
            p2p_stack.sync_mgr.onBlockApplied(block_count);

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

            // ── Peer ban list periodic flush ──────────────────────────────
            // Saves every PEER_BANS_SAVE_INTERVAL_S so a crash doesn't
            // forget bans accumulated since the last graceful shutdown.
            // File is small (≤28 KiB) so the rewrite is cheap.
            {
                const now_ts = std.time.timestamp();
                if (now_ts - peer_bans_last_save >= PEER_BANS_SAVE_INTERVAL_S) {
                    peer_persist_mod.saveToFile(&peer_scoring, peer_bans_path) catch |err| {
                        std.debug.print("[PEER-BANS] Periodic save failed: {s}\n", .{@errorName(err)});
                    };
                    peer_bans_last_save = now_ts;
                }
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
            try mining_periodic.updateStateTrie(&subs.state_trie, wallet.address, wallet.balance, block_count);

            // ── Finality: propose checkpoint every 64 blocks ────────────
            mining_periodic.maybeProposeCheckpoint(&subs.finality, block_count, block_hash_fixed, wallet.private_key_bytes);

            // ── Staking: distribute rewards (every 100 blocks) ──────────
            mining_periodic.maybeDistributeStakingRewards(&subs.staking, block_count, reward_sat);

            // ── Peer Scoring: score peers on block relay ─────────────────
            // In solo mode no peers, but ready for multi-node
            _ = &peer_scoring;

            // ── F8: Update miner balance caches ────────────────────────────
            mining_periodic.updateMinerPoolBalances(&bc, &g_miner_pool);

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
            if (p2p_stack.sync_mgr.isStalled()) {
                std.debug.print("[SYNC] STALLED >60s — resetare sync\n", .{});
                p2p_stack.sync_mgr = SyncManager.init(@intCast(bc.chain.items.len), allocator);
            }

            // Log status sync periodic
            if (!p2p_stack.sync_mgr.isSynced()) {
                p2p_stack.sync_mgr.state.print();
            }
        }

        // Notifica SyncManager cand un peer P2P anunta un bloc mai inalt
        if (p2p.chain_height > @as(u32, @intCast(bc.chain.items.len))) {
            if (p2p_stack.sync_mgr.onPeerHeight(p2p.chain_height)) |_| {
                // Cere blocuri lipsa de la primul peer care are height mai mare
                p2p.requestSync(@intCast(bc.chain.items.len));
                std.debug.print("[SYNC] requestSync trimis (local={d} peer={d})\n",
                    .{ bc.chain.items.len, p2p.chain_height });
            }
        }
    }

    // ── Graceful shutdown — save state before defers run ────────────────────
    node_shutdown.runGracefulShutdown(.{
        .pbc = &pbc,
        .bc = &bc,
        .db_path = db_path,
        .chainstate = &g_chainstate,
        .dns = &dns,
        .dns_persist_path = dns_persist_path,
        .htlc_persist_path = htlc_persist_path,
        .channel_mgr = &g_channel_mgr,
        .channels_path = channels_path,
        .intent_persist_path = intent_persist_path,
        .peer_scoring = &peer_scoring,
        .peer_bans_path = peer_bans_path,
    });
    // p2p.deinit(), ws_srv.deinit(), bc.deinit(), pbc.deinit() etc. run via defer
}
