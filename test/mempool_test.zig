/// mempool_test.zig - Teste pentru mempool și managementul tranzacțiilor
const std = @import("std");
const testing = std.testing;

const mempool_mod = @import("../core/mempool.zig");
const tx_mod = @import("../core/transaction.zig");

const Mempool = mempool_mod.Mempool;
const MempoolError = mempool_mod.MempoolError;
const Transaction = tx_mod.Transaction;

// Helper: creează o tranzacție validă pentru teste
fn createTestTransaction(allocator: std.mem.Allocator, from: []const u8, to: []const u8, amount: u64) !Transaction {
    var tx = Transaction{
        .from = try allocator.dupe(u8, from),
        .to = try allocator.dupe(u8, to),
        .amount = amount,
        .fee = 1,
        .timestamp = std.time.timestamp(),
        .hash = &[_]u8{}, // va fi calculat
    };
    
    // Calculează hash
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(tx.from);
    hasher.update(tx.to);
    var buf: [32]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], tx.amount, .little);
    hasher.update(&buf);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    
    tx.hash = try allocator.dupe(u8, &hash);
    
    return tx;
}

fn freeTransaction(tx: *Transaction, allocator: std.mem.Allocator) void {
    allocator.free(tx.from);
    allocator.free(tx.to);
    allocator.free(tx.hash);
}

// =============================================================================
// MEMPOOL BASIC TESTS
// =============================================================================

test "Mempool: initialization" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();
    
    try testing.expectEqual(mp.entries.items.len, 0);
    try testing.expectEqual(mp.total_bytes, 0);
    
    std.debug.print("[Mempool] Init OK\n", .{});
}

test "Mempool: add single transaction" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();
    
    var tx = try createTestTransaction(
        testing.allocator,
        "ob_omni_sender123",
        "ob_omni_receiver456",
        1000
    );
    defer freeTransaction(&tx, testing.allocator);
    
    try mp.add(tx);
    
    try testing.expectEqual(mp.entries.items.len, 1);
    try testing.expect(mp.total_bytes > 0);
    
    std.debug.print("[Mempool] Add single TX OK\n", .{});
}

test "Mempool: add multiple transactions" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();
    
    const count = 10;
    
    for (0..count) |i| {
        var sender_buf: [32]u8 = undefined;
        var receiver_buf: [32]u8 = undefined;
        const sender = try std.fmt.bufPrint(&sender_buf, "sender{d}", .{i});
        const receiver = try std.fmt.bufPrint(&receiver_buf, "receiver{d}", .{i});
        
        var tx = try createTestTransaction(
            testing.allocator,
            sender,
            receiver,
            @as(u64, @intCast(100 + i))
        );
        
        // Note: mempool face copie la TX, deci putem elibera după
        try mp.add(tx);
        freeTransaction(&tx, testing.allocator);
    }
    
    try testing.expectEqual(mp.entries.items.len, count);
    
    std.debug.print("[Mempool] Add {d} TXs OK\n", .{count});
}

test "Mempool: duplicate detection" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();
    
    var tx = try createTestTransaction(
        testing.allocator,
        "sender1",
        "receiver1",
        500
    );
    defer freeTransaction(&tx, testing.allocator);
    
    // Prima adăugare reușește
    try mp.add(tx);
    try testing.expectEqual(mp.entries.items.len, 1);
    
    // Adăugare duplicat = eroare
    const result = mp.add(tx);
    try testing.expectError(MempoolError.TxDuplicate, result);
    
    std.debug.print("[Mempool] Duplicate detection OK\n", .{});
}

test "Mempool: transaction validation" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();
    
    // TX invalidă: amount = 0
    var invalid_tx = try createTestTransaction(
        testing.allocator,
        "sender",
        "receiver",
        0 // invalid
    );
    defer freeTransaction(&invalid_tx, testing.allocator);
    
    const result = mp.add(invalid_tx);
    try testing.expectError(MempoolError.TxInvalid, result);
    
    std.debug.print("[Mempool] Validation OK\n", .{});
}

// =============================================================================
// MEMPOOL LIMITS TESTS
// =============================================================================

test "Mempool: size limit" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();
    
    // Adaugă multe TX-uri
    var i: usize = 0;
    while (i < mempool_mod.MEMPOOL_MAX_TX + 5) : (i += 1) {
        var sender_buf: [32]u8 = undefined;
        var receiver_buf: [32]u8 = undefined;
        const sender = try std.fmt.bufPrint(&sender_buf, "s{d}", .{i});
        const receiver = try std.fmt.bufPrint(&receiver_buf, "r{d}", .{i});
        
        var tx = try createTestTransaction(
            testing.allocator,
            sender,
            receiver,
            100
        );
        
        const result = mp.add(tx);
        freeTransaction(&tx, testing.allocator);
        
        if (result == MempoolError.Full) {
            break;
        }
    }
    
    try testing.expect(mp.entries.items.len <= mempool_mod.MEMPOOL_MAX_TX);
    
    std.debug.print("[Mempool] Size limit OK (max={d}, actual={d})\n", .{
        mempool_mod.MEMPOOL_MAX_TX, mp.entries.items.len,
    });
}

test "Mempool: byte limit" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();
    
    // Verifică că total_bytes crește
    const initial_bytes = mp.total_bytes;
    
    var tx = try createTestTransaction(
        testing.allocator,
        "sender_with_long_name",
        "receiver_with_long_name",
        999999
    );
    defer freeTransaction(&tx, testing.allocator);
    
    try mp.add(tx);
    
    try testing.expect(mp.total_bytes > initial_bytes);
    
    std.debug.print("[Mempool] Byte tracking OK (added {d} bytes)\n", .{mp.total_bytes});
}

// =============================================================================
// MEMPOOL QUERY TESTS
// =============================================================================

test "Mempool: get transactions for block" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();
    
    // Adaugă câteva TX-uri
    for (0..5) |i| {
        var sender_buf: [32]u8 = undefined;
        var receiver_buf: [32]u8 = undefined;
        const sender = try std.fmt.bufPrint(&sender_buf, "s{d}", .{i});
        const receiver = try std.fmt.bufPrint(&receiver_buf, "r{d}", .{i});
        
        var tx = try createTestTransaction(
            testing.allocator,
            sender,
            receiver,
            100
        );
        
        try mp.add(tx);
        freeTransaction(&tx, testing.allocator);
    }
    
    // Obține TX-uri pentru bloc
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    
    const txs = mp.getTransactionsForBlock(arena.allocator(), 3);
    try testing.expectEqual(txs.len, 3);
    
    std.debug.print("[Mempool] Get for block OK ({d} TXs)\n", .{txs.len});
}

test "Mempool: remove transactions" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();
    
    // Adaugă TX-uri
    var hashes: [3][]const u8 = undefined;
    for (0..3) |i| {
        var sender_buf: [32]u8 = undefined;
        var receiver_buf: [32]u8 = undefined;
        const sender = try std.fmt.bufPrint(&sender_buf, "s{d}", .{i});
        const receiver = try std.fmt.bufPrint(&receiver_buf, "r{d}", .{i});
        
        var tx = try createTestTransaction(
            testing.allocator,
            sender,
            receiver,
            100
        );
        
        hashes[i] = try testing.allocator.dupe(u8, tx.hash);
        try mp.add(tx);
        freeTransaction(&tx, testing.allocator);
    }
    defer {
        for (hashes) |h| testing.allocator.free(h);
    }
    
    try testing.expectEqual(mp.entries.items.len, 3);
    
    // Elimină 2 TX-uri
    mp.removeTransactions(hashes[0..2]);
    
    try testing.expectEqual(mp.entries.items.len, 1);
    
    std.debug.print("[Mempool] Remove TXs OK\n", .{});
}

test "Mempool: get transaction count" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();
    
    try testing.expectEqual(mp.getTransactionCount(), 0);
    
    for (0..5) |i| {
        var sender_buf: [32]u8 = undefined;
        var receiver_buf: [32]u8 = undefined;
        const sender = try std.fmt.bufPrint(&sender_buf, "s{d}", .{i});
        const receiver = try std.fmt.bufPrint(&receiver_buf, "r{d}", .{i});
        
        var tx = try createTestTransaction(
            testing.allocator,
            sender,
            receiver,
            100
        );
        
        try mp.add(tx);
        freeTransaction(&tx, testing.allocator);
    }
    
    try testing.expectEqual(mp.getTransactionCount(), 5);
    
    std.debug.print("[Mempool] Count OK (5 TXs)\n", .{});
}

// =============================================================================
// MEMPOOL EXPIRY TESTS
// =============================================================================

test "Mempool: expiry tracking" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();
    
    var tx = try createTestTransaction(
        testing.allocator,
        "sender",
        "receiver",
        100
    );
    defer freeTransaction(&tx, testing.allocator);
    
    try mp.add(tx);
    
    const count = mp.getTransactionCount();
    try testing.expectEqual(count, 1);
    
    // Verifică că TX are timestamp
    const entry = mp.entries.items[0];
    try testing.expect(entry.received_at > 0);
    
    std.debug.print("[Mempool] Expiry tracking OK (timestamp={d})\n", .{entry.received_at});
}

test "Mempool: clear all" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();
    
    // Adaugă TX-uri
    for (0..3) |i| {
        var sender_buf: [32]u8 = undefined;
        var receiver_buf: [32]u8 = undefined;
        const sender = try std.fmt.bufPrint(&sender_buf, "s{d}", .{i});
        const receiver = try std.fmt.bufPrint(&receiver_buf, "r{d}", .{i});
        
        var tx = try createTestTransaction(
            testing.allocator,
            sender,
            receiver,
            100
        );
        
        try mp.add(tx);
        freeTransaction(&tx, testing.allocator);
    }
    
    try testing.expectEqual(mp.getTransactionCount(), 3);
    
    mp.clear();
    
    try testing.expectEqual(mp.getTransactionCount(), 0);
    try testing.expectEqual(mp.total_bytes, 0);
    
    std.debug.print("[Mempool] Clear OK\n", .{});
}

// =============================================================================
// TRANSACTION TESTS
// =============================================================================

test "Transaction: creation and validation" {
    var tx = Transaction{
        .from = try testing.allocator.dupe(u8, "ob_omni_sender"),
        .to = try testing.allocator.dupe(u8, "ob_omni_receiver"),
        .amount = 1000,
        .fee = 10,
        .timestamp = std.time.timestamp(),
        .hash = try testing.allocator.dupe(u8, "fakehash123"),
    };
    defer freeTransaction(&tx, testing.allocator);
    
    try testing.expect(tx.isValid());
    try testing.expectEqual(tx.amount, 1000);
    
    std.debug.print("[TX] Creation OK\n", .{});
}

test "Transaction: invalid cases" {
    // Amount = 0
    var tx1 = Transaction{
        .from = try testing.allocator.dupe(u8, "sender"),
        .to = try testing.allocator.dupe(u8, "receiver"),
        .amount = 0,
        .fee = 1,
        .timestamp = 0,
        .hash = try testing.allocator.dupe(u8, "hash"),
    };
    defer freeTransaction(&tx1, testing.allocator);
    try testing.expect(!tx1.isValid());
    
    // Empty from
    var tx2 = Transaction{
        .from = try testing.allocator.dupe(u8, ""),
        .to = try testing.allocator.dupe(u8, "receiver"),
        .amount = 100,
        .fee = 1,
        .timestamp = 0,
        .hash = try testing.allocator.dupe(u8, "hash"),
    };
    defer freeTransaction(&tx2, testing.allocator);
    try testing.expect(!tx2.isValid());
    
    std.debug.print("[TX] Invalid cases OK\n", .{});
}

test "Transaction: serialization estimate" {
    var tx = Transaction{
        .from = try testing.allocator.dupe(u8, "long_sender_address_here"),
        .to = try testing.allocator.dupe(u8, "long_receiver_address_here"),
        .amount = 999999999,
        .fee = 100,
        .timestamp = 1234567890,
        .hash = try testing.allocator.dupe(u8, "32bytehashstringhere32bytehash"),
    };
    defer freeTransaction(&tx, testing.allocator);
    
    const size = mempool_mod.estimateTxSize(&tx);
    try testing.expect(size > 0);
    try testing.expect(size <= mempool_mod.TX_MAX_BYTES);
    
    std.debug.print("[TX] Size estimate OK ({d} bytes)\n", .{size});
}

// =============================================================================
// EDGE CASES
// =============================================================================

test "Edge: empty mempool operations" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();
    
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    
    const txs = mp.getTransactionsForBlock(arena.allocator(), 10);
    try testing.expectEqual(txs.len, 0);
    
    mp.clear(); // shouldn't crash
    
    try testing.expectEqual(mp.getTransactionCount(), 0);
    
    std.debug.print("[Edge] Empty mempool OK\n", .{});
}

test "Edge: large transaction amount" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();
    
    var tx = try createTestTransaction(
        testing.allocator,
        "sender",
        "receiver",
        std.math.maxInt(u64) // max amount
    );
    defer freeTransaction(&tx, testing.allocator);
    
    try mp.add(tx);
    try testing.expectEqual(mp.getTransactionCount(), 1);
    
    std.debug.print("[Edge] Large amount OK\n", .{});
}

pub fn main() void {
    std.debug.print("\n=== Mempool & Transaction Tests ===\n\n", .{});
}
