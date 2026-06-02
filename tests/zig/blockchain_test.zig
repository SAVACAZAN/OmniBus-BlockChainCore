const std = @import("std");
const testing = std.testing;
const blockchain_mod = @import("../core/blockchain.zig");
const block_mod = @import("../core/block.zig");
const transaction_mod = @import("../core/transaction.zig");
const wallet_mod = @import("../core/wallet.zig");

pub const Blockchain = blockchain_mod.Blockchain;
pub const Block = block_mod.Block;
pub const Transaction = transaction_mod.Transaction;
pub const Wallet = wallet_mod.Wallet;

test "blockchain initialization" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try testing.expectEqual(bc.getBlockCount(), 1); // Genesis block
}

test "block mining" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const initial_count = bc.getBlockCount();
    _ = try bc.mineBlock();
    const final_count = bc.getBlockCount();

    try testing.expectEqual(final_count, initial_count + 1);
}

test "wallet initialization" {
    var wallet = try Wallet.init(testing.allocator);
    defer wallet.deinit();

    try testing.expect(wallet.getBalance() > 0);
    try testing.expect(wallet.address.len > 0);
}

test "wallet addresses" {
    var wallet = try Wallet.init(testing.allocator);
    defer wallet.deinit();

    const addresses = wallet.getAllAddresses();
    try testing.expectEqual(addresses.len, 5);

    // Check first address is OMNI
    try testing.expect(std.mem.startsWith(u8, addresses[0].omni_address, "ob_omni_"));

    // Check other addresses have different prefixes
    try testing.expect(std.mem.startsWith(u8, addresses[1].omni_address, "ob_k1_"));
    try testing.expect(std.mem.startsWith(u8, addresses[2].omni_address, "ob_f5_"));
    try testing.expect(std.mem.startsWith(u8, addresses[3].omni_address, "ob_d5_"));
    try testing.expect(std.mem.startsWith(u8, addresses[4].omni_address, "ob_s3_"));
}

test "transaction validation" {
    const tx = Transaction{
        .id = 1,
        .from_address = "ob_omni_sender",
        .to_address = "ob_omni_receiver",
        .amount = 1000,
        .timestamp = std.time.timestamp(),
        .signature = "sig",
        .hash = "hash",
    };

    try testing.expect(tx.isValid());
}

test "invalid transaction (zero amount)" {
    const tx = Transaction{
        .id = 1,
        .from_address = "ob_omni_sender",
        .to_address = "ob_omni_receiver",
        .amount = 0,
        .timestamp = std.time.timestamp(),
        .signature = "sig",
        .hash = "hash",
    };

    try testing.expect(!tx.isValid());
}

test "invalid transaction (invalid address)" {
    const tx = Transaction{
        .id = 1,
        .from_address = "invalid_address",
        .to_address = "ob_omni_receiver",
        .amount = 1000,
        .timestamp = std.time.timestamp(),
        .signature = "sig",
        .hash = "hash",
    };

    try testing.expect(!tx.isValid());
}
