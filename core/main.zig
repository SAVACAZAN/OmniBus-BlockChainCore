const std     = @import("std");
const builtin = @import("builtin");

// ── Single-instance lock — un singur miner per masina ────────────────────────
// Windows: lock file exclusiv  omnibus-miner.lock (in directorul curent)
// Linux/macOS: flock()         /tmp/omnibus-miner.lock
fn acquireSingleInstanceLock() void {
    if (comptime builtin.os.tag == .windows) {
        // Pe Windows: CreateFileW cu FILE_FLAG_DELETE_ON_CLOSE + exclusive
        // Daca fisierul e deja deschis exclusiv de alt proces → eroare → EXIT
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
const NetworkConfig        = genesis_mod.NetworkConfig;
const GenesisState         = genesis_mod.GenesisState;
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
const state_trie_mod   = @import("state_trie.zig");
const tx_receipt_mod   = @import("tx_receipt.zig");
const guardian_mod     = @import("guardian.zig");
const dns_mod          = @import("dns_registry.zig");
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

// Force compilation of all subsystems (ensures tests are included in full build)
comptime {
    _ = finality_mod; _ = governance_mod; _ = staking_mod;
    _ = chain_config_mod; _ = state_trie_mod; _ = tx_receipt_mod;
    _ = guardian_mod; _ = dns_mod; _ = peer_scoring_mod;
    _ = compact_mod; _ = kademlia_mod; _ = key_enc_mod;
    _ = light_client_mod; _ = light_miner_mod; _ = payment_mod;
    _ = bread_mod; _ = schnorr_mod; _ = multisig_mod; _ = bls_mod;
    _ = miner_wallet_mod; _ = benchmark_mod;
    _ = @import("witness_data.zig"); _ = @import("compact_transaction.zig");
    _ = @import("os_mode.zig"); _ = @import("synapse_priority.zig");
    _ = @import("omni_brain.zig"); _ = @import("oracle.zig");
    _ = @import("bridge_relay.zig"); _ = @import("domain_minter.zig");
    _ = @import("ubi_distributor.zig");
}

const DB_PATH = "omnibus-chain.dat";

// ── Graceful Shutdown — Ctrl+C / SIGINT handler ─────────────────────────────
// Atomic flag checked by the mining loop; set by OS signal handler.
var g_shutdown = std.atomic.Value(bool).init(false);

fn installShutdownHandler() void {
    if (comptime builtin.os.tag == .windows) {
        // Windows: use std.os.windows.SetConsoleCtrlHandler wrapper
        std.os.windows.SetConsoleCtrlHandler(&windowsCtrlHandler, true) catch {
            std.debug.print("[SHUTDOWN] Failed to install Ctrl+C handler\n", .{});
        };
    } else {
        // POSIX: catch SIGINT + SIGTERM
        const act = std.posix.Sigaction{
            .handler = .{ .handler = posixSignalHandler },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null) catch {};
        std.posix.sigaction(std.posix.SIG.TERM, &act, null) catch {};
    }
}

fn windowsCtrlHandler(dwCtrlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    _ = dwCtrlType;
    g_shutdown.store(true, .monotonic);
    return std.os.windows.TRUE; // handled, don't terminate immediately
}

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

// Thread RPC — pornit din main, detach
const RPCThreadArgs = struct {
    bc:       *Blockchain,
    wallet:   *Wallet,
    alloc:    std.mem.Allocator,
    mempool:  *mempool_mod.Mempool,
    p2p:      *p2p_mod.P2PNode,
    sync_mgr: *sync_mod.SyncManager,
    metrics:  *benchmark_mod.Metrics,
    channel_mgr: *payment_mod.ChannelManager,
    staking:  *staking_mod.StakingEngine,
};

fn rpcThread(args: RPCThreadArgs) void {
    rpc_mod.startHTTPEx(args.bc, args.wallet, args.alloc, .{
        .mempool  = args.mempool,
        .p2p      = args.p2p,
        .sync_mgr = args.sync_mgr,
        .metrics  = args.metrics,
        .channel_mgr = args.channel_mgr,
        .staking  = args.staking,
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

pub fn main() !void {
    // Single-instance lock dezactivat — permite multiple instante pe acelasi PC
    // pentru testare retea cu N mineri. In productie, reactivati acquireSingleInstanceLock().
    // acquireSingleInstanceLock();

    // Install Ctrl+C / SIGINT handler for graceful shutdown
    installShutdownHandler();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ── Network config — mainnet sau testnet ──────────────────────────────────
    // Schimba in .testnet() pentru development fara sa afectezi trecutul
    const net_cfg = NetworkConfig.mainnet();
    net_cfg.print();

    // ── CLI args ──────────────────────────────────────────────────────────────
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cli = CLI.init(allocator);
    const config = cli.parseArgs(args) catch |err| {
        switch (err) {
            error.HelpRequested => return,
            else => {
                std.debug.print("[ERROR] {}\n", .{err});
                return err;
            }
        }
    };

    std.debug.print("[NETWORK] Mode: {}  ID: {s}  Host: {s}:{d}\n\n",
        .{ config.mode, config.node_id, config.host, config.port });

    // ── Mnemonic — SuperVault Named Pipe → env var → dev default ─────────────
    const mnemonic = try vault_reader.readMnemonic(allocator);

    // ── Init database (persistent storage) ───────────────────────────────────
    var pbc = try PersistentBlockchain.loadFromDisk(allocator, DB_PATH);
    defer pbc.deinit();
    const loaded_stats = pbc.getStats();
    std.debug.print("[DB] Loaded: {d} blocks, {d} addresses from {s}\n",
        .{ loaded_stats.total_blocks, loaded_stats.total_addresses, DB_PATH });

    // ── Init blockchain cu Genesis oficial ───────────────────────────────────
    const gs = GenesisState.init(net_cfg, allocator);
    var bc = try gs.buildBlockchain();
    defer bc.deinit();

    // Valideaza genesis — daca e gresit, oprim nodul
    if (!gs.validateGenesisBlock(&bc)) {
        std.debug.print("[FATAL] Genesis block invalid! Oprire nod.\n", .{});
        return error.InvalidGenesis;
    }

    // Reincarca blocurile si balantele salvate anterior (continua lantul)
    pbc.restoreInto(&bc, DB_PATH) catch |err| {
        std.debug.print("[DB] Restore failed ({}) — pornire de la genesis\n", .{err});
    };

    // Attach persistent database to blockchain for auto-save support
    bc.persistent_db = &pbc;
    bc.db_path = DB_PATH;
    bc.last_save_time = std.time.timestamp();

    std.debug.print("[INIT] Blockchain initialized\n", .{});
    std.debug.print("  Genesis: {s}\n", .{net_cfg.genesis_hash[0..16]});
    std.debug.print("  Difficulty: {d}  Chain: {d} block(s) (height {d})\n\n",
        .{ bc.difficulty, bc.chain.items.len, bc.chain.items.len - 1 });

    // ── Init wallet ───────────────────────────────────────────────────────────
    var wallet = try Wallet.fromMnemonic(mnemonic, "", allocator);
    defer wallet.deinit();

    std.debug.print("[WALLET] Address: {s}\n", .{wallet.address});
    std.debug.print("[WALLET] Balance: {d} SAT ({d:.4} OMNI)\n\n",
        .{ wallet.balance, @as(f64, @floatFromInt(wallet.balance)) / 1e9 });

    // Inregistreaza seed-ul ca primul miner in pool
    g_miner_pool.register(wallet.address);

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

    // ── Init DNS Registry ────────────────────────────────────────────────────
    var dns = dns_mod.DnsRegistry.init();

    // ── Init Guardian System ─────────────────────────────────────────────────
    var guardian = guardian_mod.GuardianEngine.init();

    std.debug.print("[SUBSYSTEMS] StateTrie + Finality + Staking + Governance + PeerScoring + DNS + Guardian\n\n", .{});

    // ── Init P2P Node ─────────────────────────────────────────────────────────
    var p2p = P2PNode.init(config.node_id, config.host, config.port, allocator);
    defer p2p.deinit();
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

    // ── WebSocket + RPC — doar pe seed node (minerii nu pornesc servere) ──────
    var ws_srv = WsServer.init(ws_mod.WS_PORT, allocator);
    defer ws_srv.deinit();

    const is_seed = (config.mode == node_launcher.NodeMode.seed);
    if (is_seed) {
        ws_srv.attachBlockchain(&bc);
        ws_srv.start() catch |err| {
            std.debug.print("[WS] Server start failed: {} — continuam fara WS\n", .{err});
        };

        const t = try std.Thread.spawn(.{}, rpcThread, .{RPCThreadArgs{
            .bc       = &bc,
            .wallet   = &wallet,
            .alloc    = allocator,
            .mempool  = &mempool,
            .p2p      = &p2p,
            .sync_mgr = &sync_mgr,
            .metrics  = &g_metrics,
            .channel_mgr = &g_channel_mgr,
            .staking  = &staking,
        }});
        t.detach();
        std.debug.print("[RPC] Server pornit pe port {d}\n\n", .{net_cfg.rpc_port});
    } else {
        std.debug.print("[MINER] RPC/WS disabled — only seed runs servers\n\n", .{});
    }

    // ── Node launcher ─────────────────────────────────────────────────────────
    var launcher = node_launcher.NodeLauncher.init(config);
    defer launcher.deinit();

    // Ataseaza P2PNode real la launcher — broadcast() va folosi TCP in loc de print-only
    launcher.attachP2PNode(&p2p);

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

    // ── Performance Metrics init ───────────────────────────────────────────────
    g_metrics = benchmark_mod.Metrics.init();
    g_metrics.start(); // set start_time at runtime (can't call timestamp() at comptime)
    std.debug.print("[METRICS] Performance tracking initialized\n\n", .{});

    // Porneste block_count de la inaltimea curenta a lantului (continua, nu de la 0)
    var block_count: u32 = @intCast(bc.chain.items.len - 1);
    var maint_count: u32 = 0;
    var mining_started: bool = false;

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

        // ── Ciclu 10 sub-blocuri × 0.1s → 1 Key-Block ────────────────────────
        const reward_sat = blockchain_mod.blockRewardAt(block_count);

        // Scoate TX-urile minabile din mempool (locktime <= current height)
        // Locked TXs (locktime > block_count) raman in mempool pana cand chain-ul ajunge la acea inaltime
        const pending_txs = mempool.getMineable(1000, block_count, allocator) catch &.{};
        defer if (pending_txs.len > 0) allocator.free(pending_txs);

        var key_block_opt: ?sub_block_mod.KeyBlock = null;

        for (0..sub_block_mod.SUB_BLOCKS_PER_BLOCK) |sub_i| {
            _ = sub_i;
            // Distribuie TX-urile uniform intre sub-blocuri
            key_block_opt = try sb_engine.tick(@constCast(pending_txs), reward_sat);
            // Sleep 0.1s intre sub-blocuri
            std.Thread.sleep(sub_block_mod.SUB_BLOCK_INTERVAL_MS * std.time.ns_per_ms);
        }

        // Key-Block complet → mineaza blocul principal in blockchain
        // Round-robin: reward-ul merge la fiecare miner pe rand
        if (key_block_opt != null) {
            const miner_addr = g_miner_pool.getMinerForBlock(block_count, wallet.address);
            const mine_start_ns: u64 = @intCast(std.time.nanoTimestamp());
            const new_block = try bc.mineBlockForMiner(miner_addr);
            const mine_end_ns: u64 = @intCast(std.time.nanoTimestamp());
            const mine_time_ns = mine_end_ns - mine_start_ns;

            // Update metrics: hashrate from nonces tried
            g_metrics.updateHashrate(new_block.nonce, mine_time_ns);

            if (!consensus.isBlockHashValid(new_block.hash, bc.difficulty)) {
                std.debug.print("[CONSENSUS] Bloc respins: hash invalid\n", .{});
                continue;
            }

            block_count += 1;

            // Auto-save: track blocks and TXs since last save
            bc.blocks_since_save += 1;
            bc.txs_since_save += @intCast(pending_txs.len);
            bc.checkAutoSave();

            // Record metrics
            g_metrics.recordBlock();
            for (0..pending_txs.len) |_| {
                g_metrics.recordTx();
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

            // Append O(1) la fiecare bloc minat — sync continuu chain→db
            pbc.appendBlock(&bc, DB_PATH) catch |err| {
                std.debug.print("[DB] appendBlock failed: {} — fallback saveBlockchain\n", .{err});
                pbc.saveBlockchain(&bc, DB_PATH) catch {};
            };

            if (block_count % 10 == 0) {
                std.debug.print("[MINING] {d} blocks | difficulty: {d} | reward: {d} SAT | balance: {d} SAT\n",
                    .{ block_count, bc.difficulty, reward_sat, wallet.balance });
                std.debug.print("[MINING] Hashrate: {d} H/s | TPS: {d} | Peak TPS: {d}\n",
                    .{ g_metrics.hashrate, g_metrics.currentTps(), g_metrics.peak_tps });
                mempool.printStats();
            }

            // Full checkpoint la fiecare 100 blocuri (siguranta maxima)
            if (block_count % 100 == 0) {
                pbc.saveBlockchain(&bc, DB_PATH) catch |err| {
                    std.debug.print("[DB] Checkpoint save failed: {}\n", .{err});
                };
            }

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

            // ── F8: Update miner balance caches + register pubkeys ─────────
            {
                g_miner_pool.mutex.lock();
                const pool_count = g_miner_pool.count;
                // Copy addresses out to avoid holding lock during blockchain access
                var addrs_buf: [MinerWalletPool.MAX][64]u8 = undefined;
                var lens_buf: [MinerWalletPool.MAX]u8 = undefined;
                var pkhex_buf: [MinerWalletPool.MAX][66]u8 = undefined;
                for (0..pool_count) |pi| {
                    addrs_buf[pi] = g_miner_pool.wallets[pi].address;
                    lens_buf[pi] = g_miner_pool.wallets[pi].address_len;
                    pkhex_buf[pi] = g_miner_pool.wallets[pi].public_key_hex;
                }
                g_miner_pool.mutex.unlock();

                for (0..pool_count) |pi| {
                    const maddr = addrs_buf[pi][0..lens_buf[pi]];
                    const mbal = bc.getAddressBalance(maddr);
                    g_miner_pool.updateBalance(maddr, mbal);
                    // Register pubkey so their signed TXs can be verified
                    bc.registerPubkey(maddr, &pkhex_buf[pi]) catch {};
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
    pbc.saveBlockchain(&bc, DB_PATH) catch |err| {
        std.debug.print("[SHUTDOWN] Save failed: {} — data may be lost!\n", .{err});
    };
    std.debug.print("[SHUTDOWN] Saved {d} blocks, {d} addresses\n", .{ bc.chain.items.len, bc.balances.count() });
    std.debug.print("[SHUTDOWN] Cleaning up (P2P, WS, wallet via defer)... Goodbye!\n", .{});
    // p2p.deinit(), ws_srv.deinit(), bc.deinit(), pbc.deinit() etc. run via defer
}
