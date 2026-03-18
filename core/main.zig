const std = @import("std");
const blockchain_mod = @import("blockchain.zig");
const rpc_mod = @import("rpc_server.zig");
const wallet_mod = @import("wallet.zig");
const cli_mod = @import("cli.zig");
const node_launcher = @import("node_launcher.zig");

const Blockchain = blockchain_mod.Blockchain;
const RPCServer = rpc_mod.RPCServer;
const Wallet = wallet_mod.Wallet;
const CLI = cli_mod.CLI;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== OmniBus Blockchain Node ===\n", .{});
    std.debug.print("Version: 1.0.0-dev\n", .{});
    std.debug.print("Language: Zig 0.15.2\n", .{});
    std.debug.print("Platform: Cross-Platform (Windows + Linux)\n\n", .{});

    // Get command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse CLI arguments
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

    std.debug.print("[NETWORK] Node Mode: {}\n", .{config.mode});
    std.debug.print("[NETWORK] Node ID: {s}\n", .{config.node_id});
    std.debug.print("[NETWORK] Host: {s}:{d}\n\n", .{ config.host, config.port });

    // Initialize node launcher
    var launcher = node_launcher.NodeLauncher.init(config);
    defer launcher.deinit();

    // Initialize blockchain
    var bc = try Blockchain.init(allocator);
    defer bc.deinit();

    std.debug.print("[INIT] Blockchain initialized\n", .{});
    std.debug.print("  - Genesis block created\n", .{});
    std.debug.print("  - Difficulty: {d}\n", .{bc.difficulty});
    std.debug.print("  - Chain length: {d}\n\n", .{bc.chain.items.len});

    // Initialize wallet
    var wallet = try Wallet.init(allocator);
    defer wallet.deinit();

    std.debug.print("[WALLET] Wallet initialized\n", .{});
    std.debug.print("  - Address: {s}\n", .{wallet.address});
    std.debug.print("  - Balance: {d} SAT\n\n", .{wallet.balance});

    // Initialize RPC server
    var rpc = try RPCServer.init(allocator, &bc, &wallet);
    defer rpc.deinit();

    std.debug.print("[RPC] JSON-RPC 2.0 Server\n", .{});
    std.debug.print("  - Listening on: http://localhost:8332\n", .{});
    std.debug.print("  - WebSocket: ws://localhost:8333\n\n", .{});

    // Start node based on mode
    if (config.mode == node_launcher.NodeMode.seed) {
        try launcher.startSeedNode();
    } else {
        try launcher.startMinerNode();
    }

    std.debug.print("[STATUS] OmniBus Network Node Running\n", .{});
    std.debug.print("  - Mode: {}\n", .{config.mode});
    std.debug.print("  - Blocks: {d}\n", .{bc.chain.items.len});
    std.debug.print("  - Transactions: {d}\n", .{bc.mempool.items.len});
    std.debug.print("  - Wallet balance: {d} SAT\n\n", .{wallet.balance});

    // Main event loop
    std.debug.print("[LOOP] Starting mining loop...\n", .{});
    std.debug.print("[LOOP] Waiting for network readiness...\n\n", .{});

    var block_counter: u32 = 0;
    var maintenance_counter: u32 = 0;

    while (launcher.is_running) {
        // Check if ready for mining
        if (!launcher.readyForMining() and block_counter == 0) {
            // Waiting for network
            maintenance_counter += 1;
            if (maintenance_counter % 6 == 0) {
                std.debug.print("[NETWORK] Waiting for peers to synchronize...\n", .{});
                if (launcher.getBootstrapStatus()) |stats| {
                    std.debug.print("  - Connected peers: {d}\n", .{stats.peer_count});
                    std.debug.print("  - Status: {}\n", .{stats.status});
                }
            }
            std.time.sleep(10 * std.time.ns_per_s);
            continue;
        }

        // Start mining when ready
        if (block_counter == 0 and launcher.readyForMining()) {
            try launcher.startMining();
            std.debug.print("[MINING] Network ready! Starting mining...\n\n", .{});
        }

        // Mine a new block
        _ = try bc.mineBlock();
        block_counter += 1;

        if (block_counter % 10 == 0) {
            std.debug.print("[MINING] Mined {d} blocks | Difficulty: {d}\n", .{ block_counter, bc.difficulty });
        }

        // Periodic maintenance
        maintenance_counter += 1;
        if (maintenance_counter % 30 == 0) {
            launcher.maintenance();
            if (launcher.getNetworkStatus()) |status| {
                std.debug.print("[NETWORK] Peers: {d}, Miners: {d}, Synced: {}\n", .{ status.total_peers, status.total_miners, status.is_synced });
            }
        }

        // Sleep for block time (10 seconds)
        std.time.sleep(10 * std.time.ns_per_s);
    }
}
