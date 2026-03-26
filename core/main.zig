const std = @import("std");
const blockchain_mod  = @import("blockchain.zig");
const rpc_mod         = @import("rpc_server.zig");
const wallet_mod      = @import("wallet.zig");
const cli_mod         = @import("cli.zig");
const node_launcher   = @import("node_launcher.zig");
const vault_reader    = @import("vault_reader.zig");
const database_mod    = @import("database.zig");

const Blockchain          = blockchain_mod.Blockchain;
const Wallet              = wallet_mod.Wallet;
const CLI                 = cli_mod.CLI;
const PersistentBlockchain = database_mod.PersistentBlockchain;

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

    std.debug.print("=== OmniBus Blockchain Node ===\n", .{});
    std.debug.print("Version: 1.0.0-dev\n", .{});
    std.debug.print("Language: Zig 0.15.2\n", .{});
    std.debug.print("Platform: Windows + Linux\n\n", .{});

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

    // ── Init blockchain ───────────────────────────────────────────────────────
    var bc = try Blockchain.init(allocator);
    defer bc.deinit();

    std.debug.print("[INIT] Blockchain initialized\n", .{});
    std.debug.print("  Difficulty: {d}  Chain: {d} block(s)\n\n", .{ bc.difficulty, bc.chain.items.len });

    // ── Init wallet ───────────────────────────────────────────────────────────
    var wallet = try Wallet.fromMnemonic(mnemonic, "", allocator);
    defer wallet.deinit();

    std.debug.print("[WALLET] Address: {s}\n", .{wallet.address});
    std.debug.print("[WALLET] Balance: {d} SAT\n\n", .{wallet.balance});

    // ── RPC HTTP server pe thread separat ─────────────────────────────────────
    const t = try std.Thread.spawn(.{}, rpcThread, .{RPCThreadArgs{ .bc = &bc, .wallet = &wallet, .alloc = allocator }});
    t.detach();

    // ── Node launcher ─────────────────────────────────────────────────────────
    var launcher = node_launcher.NodeLauncher.init(config);
    defer launcher.deinit();

    if (config.mode == node_launcher.NodeMode.seed) {
        try launcher.startSeedNode();
    } else {
        try launcher.startMinerNode();
    }

    std.debug.print("[STATUS] Node running | Blocks: {d} | Mempool: {d}\n\n",
        .{ bc.chain.items.len, bc.mempool.items.len });

    // ── Mining loop ───────────────────────────────────────────────────────────
    std.debug.print("[LOOP] Starting mining loop (10s blocks)...\n\n", .{});

    var block_count:  u32 = 0;
    var maint_count:  u32 = 0;

    while (launcher.is_running) {
        if (!launcher.readyForMining() and block_count == 0) {
            maint_count += 1;
            if (maint_count % 6 == 0) {
                std.debug.print("[NETWORK] Waiting for peers...\n", .{});
                if (launcher.getBootstrapStatus()) |stats| {
                    std.debug.print("  peers: {d}  status: {}\n", .{ stats.peer_count, stats.status });
                }
            }
            std.Thread.sleep(10 * std.time.ns_per_s);
            continue;
        }

        if (block_count == 0 and launcher.readyForMining()) {
            try launcher.startMining();
            std.debug.print("[MINING] Network ready — mining started\n\n", .{});
        }

        _ = try bc.mineBlockForMiner(wallet.address);
        block_count += 1;
        // Sincronizeaza balanta wallet-ului din blockchain
        wallet.updateBalance(bc.getAddressBalance(wallet.address));

        if (block_count % 10 == 0) {
            std.debug.print("[MINING] {d} blocks | difficulty: {d}\n", .{ block_count, bc.difficulty });
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

        std.Thread.sleep(10 * std.time.ns_per_s);
    }
}

