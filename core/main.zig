const std     = @import("std");
const builtin = @import("builtin");

// Re-export the EVM build flag at root scope so that sub-modules
// (evm_executor.zig) can probe it via `@hasDecl(@import("root"), …)`.
// build.zig wires `build_options` into this exe via `addOptions()`.
pub const build_options_evm_enabled: bool = @import("build_options").evm_enabled;

// Single-instance lock — un singur miner per masina.
// Vezi core/node/platform_lock.zig pentru implementare (Windows + POSIX).
const platform_lock = @import("node/platform_lock.zig");
const mining_telemetry = @import("node/mining_telemetry.zig");
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

// ── Global Slot Calendar v2 — self-contained [20]u8 address-byte calendar ──
// Parallel calendar using the new slot_calendar.zig module. Exposed via
// RPC endpoints `slot_calendar` and `slot_get`. Rebuilt every block
// alongside g_slot_calendar. Lives in main.zig so rpc/slot_calendar.zig
// can import it via `@import("../main.zig").g_slot_calendar_v2`.
const slot_calendar_mod = @import("slot_calendar.zig");
pub var g_slot_calendar_v2: slot_calendar_mod.SlotCalendar =
    slot_calendar_mod.SlotCalendar.init();

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
const slot_leader_mod = @import("node/slot_leader.zig");
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
    g_ws_feed = runtime_init.initWsExchangeFeed(
        allocator,
        if (g_pair_registry) |*reg| reg else null,
        &g_clock,
        startOracleBridge,
    );

    // ── Reputation Manager + retro backfill din chain history ──
    g_reputation = runtime_init.initReputationManager(allocator, bc.chain.items.len - 1);
    backfillReputationFromChain(&bc, &g_reputation.?);

    // Porneste block_count de la inaltimea curenta a lantului (continua, nu de la 0)
    var block_count: u32 = @intCast(bc.chain.items.len - 1);
    var maint_count: u32 = 0;
    var mining_started: bool = false;

    // ── Single source of time + tip-arrival tracker ────────────────────
    const time_state = runtime_init.initTimeState(&g_clock, bc.chain.items.len);
    var orch = time_state.orch;
    var last_tip_height: usize = time_state.last_tip_height;
    var tip_arrival_ms: i64 = time_state.tip_arrival_ms;

    // ── Burst smoothing ──────────────────────────────────────────────────
    const MIN_BLOCK_GAP_MS: i64 = runtime_init.BurstSmoothing.MIN_BLOCK_GAP_MS;
    const burst = runtime_init.BurstSmoothing.init();
    var last_block_produced_ms: i64 = burst.last_block_produced_ms;

    // ── Block-rate stabilizer ────────────────────────────────────────────
    const RATE_RING_SIZE: usize = runtime_init.StabilizerState.RATE_RING_SIZE;
    const TARGET_BLOCKS_PER_MIN: f64 = runtime_init.StabilizerState.TARGET_BLOCKS_PER_MIN;
    const stab = runtime_init.StabilizerState.init(&g_clock);
    var rate_ring: [RATE_RING_SIZE]i64 = stab.rate_ring;
    var rate_ring_head: usize = stab.rate_ring_head;
    var rate_ring_count: usize = stab.rate_ring_count;
    var stabilizer_last_report_ms: i64 = stab.stabilizer_last_report_ms;
    var stabilizer_timeout_mult: f64 = stab.stabilizer_timeout_mult;

    while (launcher.is_running and !g_shutdown.load(.monotonic)) {
        if (try mining_periodic.handleWaitForPeers(&launcher, p2p, &mining_started, &maint_count, block_count)) continue;

        // ── IDLE check — duplicat detectat pe acelasi IP, nu minaza ─────────
        if (p2p.is_idle) {
            // Nodul e IDLE: primeste blocuri, sincronizeaza, dar NU minaza
            mining_periodic.maybeRetryKnockKnock(&p2p, maint_count);
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
        // Logic moved to core/node/slot_leader.zig (2026-06-01 refactor).
        // See that file for the full rationale of the 3 paths (normal /
        // liveness fallback / bootstrap free-for-all) and the adaptive
        // timeout. Same behavior, same print lines, same pacing.
        const SLOT_TIMEOUT_MS: i64 = 300;
        {
            const decision = slot_leader_mod.shouldMineThisSlot(.{
                .bc = &bc,
                .p2p = p2p,
                .clock = &g_clock,
                .effective_miner_addr = effective_miner_addr,
                .stabilizer_timeout_mult = stabilizer_timeout_mult,
                .MIN_BLOCK_GAP_MS = MIN_BLOCK_GAP_MS,
                .SLOT_TIMEOUT_MS = SLOT_TIMEOUT_MS,
                .last_tip_height_ptr = &last_tip_height,
                .tip_arrival_ms_ptr = &tip_arrival_ms,
                .last_block_produced_ms = last_block_produced_ms,
                .block_count = block_count,
            });
            if (decision == .skip) continue;
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
            mining_periodic.snapshotPricesIntoBlock(&g_ws_feed, &bc, new_block.index);

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

                // ── SlotCalendar v2 recompute ─────────────────────────────────
                // Build [20]u8 address array from the string-based validator set
                // and decode the block hash hex into 32 raw bytes for the v2
                // calendar's SHA256-based leader election.
                {
                    const MAX_VALIDATORS_V2 = 256;
                    var v2_addrs: [MAX_VALIDATORS_V2][20]u8 = undefined;
                    const n_validators = @min(bc.validator_set.items.len, MAX_VALIDATORS_V2);
                    var vi: usize = 0;
                    while (vi < n_validators) : (vi += 1) {
                        const addr_str = bc.validator_set.items[vi].address;
                        var addr_bytes = std.mem.zeroes([20]u8);
                        // Encode the string address into the first N bytes (truncate/zero-pad).
                        const copy_len = @min(addr_str.len, 20);
                        @memcpy(addr_bytes[0..copy_len], addr_str[0..copy_len]);
                        v2_addrs[vi] = addr_bytes;
                    }
                    // Convert hex tip hash to [32]u8 bytes.
                    var tip_hash_bytes = std.mem.zeroes([32]u8);
                    const hash_hex = new_block.hash;
                    if (hash_hex.len >= 64) {
                        var bi: usize = 0;
                        while (bi < 32) : (bi += 1) {
                            const hi = bi * 2;
                            const lo = hi + 1;
                            const hi_nibble: u8 = if (hash_hex[hi] >= 'a') hash_hex[hi] - 'a' + 10
                                else if (hash_hex[hi] >= 'A') hash_hex[hi] - 'A' + 10
                                else hash_hex[hi] - '0';
                            const lo_nibble: u8 = if (hash_hex[lo] >= 'a') hash_hex[lo] - 'a' + 10
                                else if (hash_hex[lo] >= 'A') hash_hex[lo] - 'A' + 10
                                else hash_hex[lo] - '0';
                            tip_hash_bytes[bi] = (hi_nibble << 4) | lo_nibble;
                        }
                    }
                    g_slot_calendar_v2.recompute(
                        @intCast(block_count),
                        tip_hash_bytes,
                        last_block_produced_ms,
                        v2_addrs[0..n_validators],
                    );
                }
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
                const orch_fired = orch.tick().fired(.stabilizer);
                mining_telemetry.maybeReportStabilizer(
                    RATE_RING_SIZE,
                    TARGET_BLOCKS_PER_MIN,
                    &rate_ring,
                    &rate_ring_head,
                    &rate_ring_count,
                    &stabilizer_last_report_ms,
                    &stabilizer_timeout_mult,
                    arrival_ms,
                    orch_fired,
                    &bc,
                    &g_chainstate,
                    &g_slot_calendar,
                    block_count,
                );
            }

            // ── Reputation: credit pentru toate cele 4 domenii ─────────────────
            mining_periodic.creditReputationForBlock(
                &g_reputation, g_staking_engine, miner_addr,
                @as(u64, block_count), allocator,
            );

            // Auto-save: track blocks and TXs since last save
            bc.blocks_since_save += 1;
            bc.txs_since_save += @intCast(pending_txs.len);
            bc.checkAutoSave();

            // ── FIX (2026-05-03): per-block chainstate flush + companion persists ──
            mining_periodic.flushChainstatePerBlock(
                &bc, &dns, dns_persist_path,
                htlc_persist_path, &g_channel_mgr, channels_path,
                intent_persist_path, block_count,
            );

            // Record metrics
            g_metrics.recordBlock();
            for (0..pending_txs.len) |_| {
                g_metrics.recordTx();
            }

            // ── PoUW: Track mining work for reward distribution ─────────
            mining_periodic.submitMiningWorkReport(&g_pouw_engine, miner_addr, block_count);

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
            mining_periodic.broadcastFillsAndOrderbook(&bc, &ws_cfg.ws_srv, new_block, block_count);

            // ── PoUW + AI Agents + Price Oracle + Oracle Fetcher logs ───
            mining_periodic.tickRoundEngines(&g_pouw_engine, &bc, &g_price_oracle, &g_oracle_fetcher, &ws_cfg.ws_srv, block_count);

            // ── Metachain: inregistreaza shard header pentru acest bloc ───────
            const block_hash_fixed = try mining_periodic.registerMetaShard(
                &subs.metachain,
                wallet.address,
                block_count,
                new_block.hash,
                @intCast(pending_txs.len),
                reward_sat,
            );

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
            mining_periodic.periodicMaintenance30(&launcher, p2p, block_count, &governance, &dns, &guardian, &p2p_stack.sync_mgr, @intCast(bc.chain.items.len), allocator);
        }

        // Notifica SyncManager cand un peer P2P anunta un bloc mai inalt
        mining_periodic.maybeRequestPeerSync(p2p, &p2p_stack.sync_mgr, @intCast(bc.chain.items.len));
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
