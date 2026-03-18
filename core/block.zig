const std = @import("std");
const transaction_mod = @import("transaction.zig");
const array_list = std.array_list;

pub const Transaction = transaction_mod.Transaction;

pub const Block = struct {
    index: u32,
    timestamp: i64,
    transactions: array_list.Managed(Transaction),
    previous_hash: []const u8,
    nonce: u64,
    hash: []const u8,

    pub fn calculateHash(self: *const Block) ![32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        // Hash block header
        var buffer: [512]u8 = undefined;
        const str = try std.fmt.bufPrint(&buffer, "{d}{d}{s}{d}", .{
            self.index,
            self.timestamp,
            self.previous_hash,
            self.nonce,
        });

        hasher.update(str);

        // Hash all transactions in block
        for (self.transactions.items) |tx| {
            hasher.update(tx.hash);
        }

        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        return hash;
    }

    pub fn validateTransactions(self: *const Block) bool {
        for (self.transactions.items) |tx| {
            if (!tx.isValid()) {
                return false;
            }
        }
        return true;
    }

    pub fn getTransactionCount(self: *const Block) u32 {
        return @intCast(self.transactions.items.len);
    }

    pub fn addTransaction(self: *Block, tx: Transaction) !void {
        try self.transactions.append(tx);
    }
};
