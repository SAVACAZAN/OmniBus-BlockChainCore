const std = @import("std");
const blockchain_mod = @import("blockchain.zig");
const wallet_mod = @import("wallet.zig");

pub const Blockchain = blockchain_mod.Blockchain;
pub const Wallet = wallet_mod.Wallet;

pub const RPCServer = struct {
    blockchain: *Blockchain,
    wallet: *Wallet,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, blockchain: *Blockchain, wallet: *Wallet) !RPCServer {
        return RPCServer{
            .blockchain = blockchain,
            .wallet = wallet,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RPCServer) void {
        _ = self;
    }

    // JSON-RPC 2.0 Methods
    pub fn getBlockCount(self: *RPCServer) u32 {
        return self.blockchain.getBlockCount();
    }

    pub fn getBlock(self: *RPCServer, index: u32) ?blockchain_mod.Block {
        return self.blockchain.getBlock(index);
    }

    pub fn getLatestBlock(self: *RPCServer) blockchain_mod.Block {
        return self.blockchain.getLatestBlock();
    }

    pub fn getBalance(self: *RPCServer) u64 {
        return self.wallet.getBalance();
    }

    pub fn sendTransaction(self: *RPCServer, to_address: []const u8, amount: u64) !void {
        try self.wallet.send(to_address, amount);
    }

    pub fn getMempoolSize(self: *RPCServer) u32 {
        return @intCast(self.blockchain.mempool.items.len);
    }

    pub fn getMempoolTransactions(self: *RPCServer) []const blockchain_mod.Transaction {
        return self.blockchain.mempool.items;
    }

    /// Genesis Status for GenesisCountdown page
    pub fn getGenesisStatus(self: *RPCServer) ![]const u8 {
        var response = std.ArrayList(u8).init(self.allocator);

        const genesis_status = try std.fmt.allocPrint(
            self.allocator,
            \\{{"status":"mining","blockCount":{d},"currentDifficulty":4,"timestamp":{d},"connectedMiners":0,"totalMiners":0,"totalHashrate":0,"genesisReady":false,"genesisStarted":false,"minersRequired":3}}
            ,
            .{ self.blockchain.getBlockCount(), std.time.timestamp() }
        );

        try response.appendSlice(genesis_status);
        return response.items;
    }

    /// Get miners list (stub for now)
    pub fn getMiners(self: *RPCServer) ![]const u8 {
        var response = std.ArrayList(u8).init(self.allocator);

        // Return empty miners array initially
        const miners_data = "[]";
        try response.appendSlice(miners_data);
        return response.items;
    }

    /// Start Genesis mining
    pub fn startGenesis(self: *RPCServer) !bool {
        _ = self;
        return true;
    }

    // JSON-RPC response formatter (simplified)
    pub fn formatResponse(self: *RPCServer, method: []const u8, result: []const u8) ![]u8 {
        const buffer = try self.allocator.alloc(u8, 1024);

        const response = try std.fmt.bufPrint(buffer,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"result\":\"{s}\",\"id\":1}}",
            .{ method, result });

        return response;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    _ = gpa.allocator();

    var stdout = std.io.getStdOut().writer();

    try stdout.print("=== OmniBus RPC Server ===\n", .{});
    try stdout.print("Listening on: http://localhost:8332\n", .{});
    try stdout.print("WebSocket: ws://localhost:8333\n\n", .{});

    try stdout.print("Available RPC Methods:\n", .{});
    try stdout.print("  - getblockcount\n", .{});
    try stdout.print("  - getblock <index>\n", .{});
    try stdout.print("  - getlatestblock\n", .{});
    try stdout.print("  - getbalance\n", .{});
    try stdout.print("  - sendtransaction <to> <amount>\n", .{});
    try stdout.print("  - getmempoolsize\n\n", .{});

    try stdout.print("Example requests:\n", .{});
    try stdout.print("  curl -X POST http://localhost:8332 -d '{\"jsonrpc\":\"2.0\",\"method\":\"getblockcount\",\"params\":[],\"id\":1}'\n", .{});
}
