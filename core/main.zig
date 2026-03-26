const std = @import("std");
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

const Blockchain           = blockchain_mod.Blockchain;
const Wallet               = wallet_mod.Wallet;
const CLI                  = cli_mod.CLI;
const PersistentBlockchain = database_mod.PersistentBlockchain;
const NetworkConfig        = genesis_mod.NetworkConfig;
const GenesisState         = genesis_mod.GenesisState;
const Mempool              = mempool_mod.Mempool;
const ConsensusConfig      = consensus_mod.ConsensusConfig;
const ConsensusEngine      = consensus_mod.ConsensusEngine;

const DB_PATH = "omnibus-chain.dat";

// Thread RPC — pornit din main, detach
const RPCThreadArgs = struct { bc: *Blockchain, wallet: *Wallet, alloc: std.mem.Allocator };

fn rpcThread(args: RPCThreadArgs) void {
    rpc_mod.startHTTP(args.bc, args.wallet, args.alloc) catch |err| {
        std.debug.print("[RPC] startHTTP error: {}\n", .{err});
    };
}

pub fn main() !void {
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

    std.debug.print("[INIT] Blockchain initialized cu genesis oficial\n", .{});
    std.debug.print("  Genesis: {s}\n", .{net_cfg.genesis_hash[0..16]});
    std.debug.print("  Difficulty: {d}  Chain: {d} block(s)\n\n",
        .{ bc.difficulty, bc.chain.items.len });

    // ── Init wallet ───────────────────────────────────────────────────────────
    var wallet = try Wallet.fromMnemonic(mnemonic, "", allocator);
    defer wallet.deinit();

    std.debug.print("[WALLET] Address: {s}\n", .{wallet.address});
    std.debug.print("[WALLET] Balance: {d} SAT ({d:.4} OMNI)\n\n",
        .{ wallet.balance, @as(f64, @floatFromInt(wallet.balance)) / 1e9 });

    // ── Init Mempool FIFO ─────────────────────────────────────────────────────
    var mempool = Mempool.init(allocator);
    defer mempool.deinit();
    std.debug.print("[MEMPOOL] FIFO init | Max: {d} TX / {d} KB\n\n",
        .{ mempool_mod.MEMPOOL_MAX_TX, mempool_mod.MEMPOOL_MAX_BYTES / 1024 });

    // ── Init Consensus Engine ─────────────────────────────────────────────────
    // Faza 1: ProofOfWork (compatibil cu codul existent)
    // Upgrade la MajorityVote sau PBFT fara sa schimbi nimic altceva
    const consensus_cfg = ConsensusConfig.init(.ProofOfWork, 1);
    const consensus = ConsensusEngine.init(consensus_cfg, allocator);
    consensus_cfg.print();

    // ── RPC HTTP server pe thread separat ─────────────────────────────────────
    const t = try std.Thread.spawn(.{}, rpcThread, .{RPCThreadArgs{
        .bc    = &bc,
        .wallet = &wallet,
        .alloc  = allocator,
    }});
    t.detach();
    std.debug.print("[RPC] Server pornit pe port {d}\n\n", .{net_cfg.rpc_port});

    // ── Node launcher ─────────────────────────────────────────────────────────
    var launcher = node_launcher.NodeLauncher.init(config);
    defer launcher.deinit();

    if (config.mode == node_launcher.NodeMode.seed) {
        try launcher.startSeedNode();
    } else {
        try launcher.startMinerNode();
    }

    std.debug.print("[STATUS] Node running | Blocks: {d} | Mempool: {d}\n\n",
        .{ bc.chain.items.len, mempool.size() });

    // ── Mining loop (1s per bloc, conform net_cfg) ────────────────────────────
    std.debug.print("[LOOP] Starting mining loop ({d}ms blocks)...\n\n",
        .{net_cfg.block_time_ms});

    var block_count: u32 = 0;
    var maint_count: u32 = 0;

    while (launcher.is_running) {
        if (!launcher.readyForMining() and block_count == 0) {
            maint_count += 1;
            if (maint_count % 6 == 0) {
                std.debug.print("[NETWORK] Waiting for peers...\n", .{});
                if (launcher.getBootstrapStatus()) |stats| {
                    std.debug.print("  peers: {d}  status: {}\n",
                        .{ stats.peer_count, stats.status });
                }
            }
            std.Thread.sleep(10 * std.time.ns_per_s);
            continue;
        }

        if (block_count == 0 and launcher.readyForMining()) {
            try launcher.startMining();
            std.debug.print("[MINING] Network ready — mining started\n\n", .{});
        }

        // Verifica hash-ul blocului cu consensus engine inainte de adaugare
        const new_block = try bc.mineBlockForMiner(wallet.address);
        if (!consensus.isBlockHashValid(new_block.hash, bc.difficulty)) {
            std.debug.print("[CONSENSUS] Bloc respins: hash invalid\n", .{});
            continue;
        }

        block_count += 1;

        // Curata mempool-ul de TX-urile confirmate in bloc
        mempool.removeConfirmed(new_block.transactions.items);

        // Curata TX-urile expirate (>5 minute) din mempool
        if (block_count % 300 == 0) {
            mempool.evictOld(300);
        }

        // Sincronizeaza balanta wallet-ului din blockchain
        wallet.updateBalance(bc.getAddressBalance(wallet.address));

        if (block_count % 10 == 0) {
            std.debug.print("[MINING] {d} blocks | difficulty: {d} | reward: {d} SAT\n",
                .{ block_count, bc.difficulty, blockchain_mod.blockRewardAt(block_count) });
            mempool.printStats();
            // Auto-save state to disk every 10 blocks
            pbc.saveToDisk(DB_PATH) catch |err| {
                std.debug.print("[DB] Save failed: {}\n", .{err});
            };
        }

        maint_count += 1;
        if (maint_count % 30 == 0) {
            launcher.maintenance();
            if (launcher.getNetworkStatus()) |s| {
                std.debug.print("[NETWORK] peers: {d}  miners: {d}  synced: {}\n",
                    .{ s.total_peers, s.total_miners, s.is_synced });
            }
        }

        // Sleep conform block_time din config (1s mainnet)
        std.Thread.sleep(@as(u64, net_cfg.block_time_ms) * std.time.ns_per_ms);
    }
}
