const std = @import("std");
const blockchain_mod = @import("blockchain.zig");
const rpc_mod = @import("rpc_server.zig");
const wallet_mod = @import("wallet.zig");

const Blockchain = blockchain_mod.Blockchain;
const RPCServer = rpc_mod.RPCServer;
const Wallet = wallet_mod.Wallet;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout = std.io.getStdOut().writer();

    try stdout.print("=== OmniBus Blockchain Node ===\n", .{});
    try stdout.print("Version: 1.0.0-dev\n", .{});
    try stdout.print("Language: Zig 0.15.2\n", .{});
    try stdout.print("Platform: Cross-Platform (Windows + Linux)\n\n", .{});

    // Initialize blockchain
    var bc = try Blockchain.init(allocator);
    defer bc.deinit();

    try stdout.print("[INIT] Blockchain initialized\n", .{});
    try stdout.print("  - Genesis block created\n", .{});
    try stdout.print("  - Difficulty: {d}\n", .{bc.difficulty});
    try stdout.print("  - Chain length: {d}\n\n", .{bc.chain.items.len});

    // Initialize wallet
    var wallet = try Wallet.init(allocator);
    defer wallet.deinit();

    try stdout.print("[WALLET] Wallet initialized\n", .{});
    try stdout.print("  - Address: {s}\n", .{wallet.address});
    try stdout.print("  - Balance: {d} SAT\n\n", .{wallet.balance});

    // Initialize RPC server
    var rpc = try RPCServer.init(allocator, &bc, &wallet);
    defer rpc.deinit();

    try stdout.print("[RPC] JSON-RPC 2.0 Server\n", .{});
    try stdout.print("  - Listening on: http://localhost:8332\n", .{});
    try stdout.print("  - WebSocket: ws://localhost:8333\n\n", .{});

    try stdout.print("[STATUS] OmniBus Blockchain running\n", .{});
    try stdout.print("  - Blocks: {d}\n", .{bc.chain.items.len});
    try stdout.print("  - Transactions: {d}\n", .{bc.mempool.items.len});
    try stdout.print("  - Wallet balance: {d} SAT\n\n", .{wallet.balance});

    // Main event loop
    try stdout.print("[LOOP] Starting mining loop...\n", .{});

    var block_counter: u32 = 0;
    while (true) {
        // Mine a new block
        _ = try bc.mineBlock();
        block_counter += 1;

        if (block_counter % 10 == 0) {
            try stdout.print("[MINING] Mined {d} blocks | Difficulty: {d}\n", .{ block_counter, bc.difficulty });
        }

        // Sleep for block time (10 seconds)
        std.time.sleep(10 * std.time.ns_per_s);
    }
}
