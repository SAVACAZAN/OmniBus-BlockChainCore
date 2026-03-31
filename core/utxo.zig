const std = @import("std");

// ─── UTXO Model (Bitcoin-compatible) ────────────────────────────────────────
//
// Hybrid design: OmniBus keeps account balances for fast lookups AND
// maintains a UTXO set for auditability, privacy, and Bitcoin compatibility.
//
// UTXO = Unspent Transaction Output
//   - Created when a TX sends funds to an address
//   - Consumed (spent) when used as input in a new TX
//   - The sum of all UTXOs for an address = account balance
//
// Each UTXO is identified by (tx_hash, output_index)

/// A single unspent transaction output
pub const UTXO = struct {
    /// Transaction hash that created this output (32 bytes hex = 64 chars)
    tx_hash: []const u8,
    /// Output index within the transaction (vout)
    output_index: u32,
    /// Recipient address
    address: []const u8,
    /// Amount in SAT
    amount: u64,
    /// Block height where this UTXO was created
    block_height: u64,
    /// Script pubkey (locking script) — hex encoded
    script_pubkey: []const u8,
    /// Is this a coinbase output? (needs 100 confirmations to spend)
    is_coinbase: bool,

    /// Unique key for this UTXO: "tx_hash:vout"
    pub fn outpoint(self: *const UTXO, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}:{d}", .{ self.tx_hash, self.output_index });
    }

    /// Check if coinbase UTXO is mature enough to spend (100 blocks)
    pub fn isMature(self: *const UTXO, current_height: u64) bool {
        if (!self.is_coinbase) return true;
        return current_height >= self.block_height + 100;
    }
};

/// UTXO Set — tracks all unspent outputs in the blockchain
pub const UTXOSet = struct {
    /// Map: "tx_hash:vout" -> UTXO
    utxos: std.StringHashMap(UTXO),
    /// Index: address -> list of outpoints (for fast balance lookup)
    address_index: std.StringHashMap(std.ArrayList([]const u8)),
    allocator: std.mem.Allocator,
    /// Total number of UTXOs
    count: u64,
    /// Total value locked in all UTXOs
    total_value: u64,

    pub fn init(allocator: std.mem.Allocator) UTXOSet {
        return UTXOSet{
            .utxos = std.StringHashMap(UTXO).init(allocator),
            .address_index = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .allocator = allocator,
            .count = 0,
            .total_value = 0,
        };
    }

    pub fn deinit(self: *UTXOSet) void {
        // Free address index lists
        var addr_it = self.address_index.iterator();
        while (addr_it.next()) |entry| {
            for (entry.value_ptr.items) |key| {
                self.allocator.free(key);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.address_index.deinit();

        // Free UTXO outpoint keys
        var utxo_it = self.utxos.iterator();
        while (utxo_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.utxos.deinit();
    }

    /// Add a new UTXO (when a transaction output is created)
    pub fn addUTXO(
        self: *UTXOSet,
        tx_hash: []const u8,
        output_index: u32,
        address: []const u8,
        amount: u64,
        block_height: u64,
        script_pubkey: []const u8,
        is_coinbase: bool,
    ) !void {
        const utxo = UTXO{
            .tx_hash = tx_hash,
            .output_index = output_index,
            .address = address,
            .amount = amount,
            .block_height = block_height,
            .script_pubkey = script_pubkey,
            .is_coinbase = is_coinbase,
        };

        // Create outpoint key
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ tx_hash, output_index });

        try self.utxos.put(key, utxo);
        self.count += 1;
        self.total_value += amount;

        // Update address index
        const result = try self.address_index.getOrPut(address);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList([]const u8).empty;
        }
        const key_copy = try self.allocator.dupe(u8, key);
        try result.value_ptr.append(self.allocator, key_copy);
    }

    /// Spend (remove) a UTXO by outpoint
    pub fn spendUTXO(self: *UTXOSet, tx_hash: []const u8, output_index: u32) !UTXO {
        var key_buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{d}", .{ tx_hash, output_index }) catch return error.OutpointTooLong;

        const kv = self.utxos.fetchRemove(key) orelse return error.UTXONotFound;
        const utxo = kv.value;

        self.count -= 1;
        self.total_value -= utxo.amount;

        // Remove from address index
        if (self.address_index.getPtr(utxo.address)) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (std.mem.eql(u8, list.items[i], key)) {
                    self.allocator.free(list.items[i]);
                    _ = list.swapRemove(i);
                    break;
                }
                i += 1;
            }
        }

        // Free the outpoint key
        self.allocator.free(kv.key);

        return utxo;
    }

    /// Get all UTXOs for an address
    pub fn getUTXOsForAddress(self: *const UTXOSet, address: []const u8) []const []const u8 {
        if (self.address_index.get(address)) |list| {
            return list.items;
        }
        return &.{};
    }

    /// Get balance for an address (sum of all UTXOs)
    pub fn getBalance(self: *const UTXOSet, address: []const u8) u64 {
        const outpoints = self.getUTXOsForAddress(address);
        var total: u64 = 0;
        for (outpoints) |outpoint| {
            if (self.utxos.get(outpoint)) |utxo| {
                total += utxo.amount;
            }
        }
        return total;
    }

    /// Get a UTXO by outpoint
    pub fn getUTXO(self: *const UTXOSet, tx_hash: []const u8, output_index: u32) ?UTXO {
        var key_buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{d}", .{ tx_hash, output_index }) catch return null;
        return self.utxos.get(key);
    }

    /// Check if a UTXO exists (not spent)
    pub fn hasUTXO(self: *const UTXOSet, tx_hash: []const u8, output_index: u32) bool {
        return self.getUTXO(tx_hash, output_index) != null;
    }

    /// Select UTXOs to cover a target amount (simple greedy algorithm)
    /// Returns selected UTXOs and total selected amount
    pub fn selectUTXOs(
        self: *const UTXOSet,
        address: []const u8,
        target_amount: u64,
        current_height: u64,
        allocator: std.mem.Allocator,
    ) !struct { utxos: std.ArrayList(UTXO), total: u64 } {
        var selected: std.ArrayList(UTXO) = .empty;
        var total: u64 = 0;

        const outpoints = self.getUTXOsForAddress(address);
        for (outpoints) |outpoint| {
            if (self.utxos.get(outpoint)) |utxo| {
                // Skip immature coinbase
                if (!utxo.isMature(current_height)) continue;

                try selected.append(allocator, utxo);
                total += utxo.amount;

                if (total >= target_amount) break;
            }
        }

        if (total < target_amount) {
            selected.deinit(allocator);
            return error.InsufficientFunds;
        }

        return .{ .utxos = selected, .total = total };
    }

    /// Get UTXO count for an address
    pub fn getUTXOCount(self: *const UTXOSet, address: []const u8) usize {
        if (self.address_index.get(address)) |list| {
            return list.items.len;
        }
        return 0;
    }

    /// Get statistics
    pub fn getStats(self: *const UTXOSet) struct { count: u64, total_value: u64, addresses: u32 } {
        return .{
            .count = self.count,
            .total_value = self.total_value,
            .addresses = self.address_index.count(),
        };
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "UTXO — add and get balance" {
    var set = UTXOSet.init(testing.allocator);
    defer set.deinit();

    try set.addUTXO("aabb00", 0, "ob1qtest1", 5000, 100, "0014abcd", false);
    try set.addUTXO("aabb00", 1, "ob1qtest1", 3000, 100, "0014abcd", false);
    try set.addUTXO("ccdd00", 0, "ob1qtest2", 7000, 101, "0014ef01", false);

    try testing.expectEqual(@as(u64, 8000), set.getBalance("ob1qtest1"));
    try testing.expectEqual(@as(u64, 7000), set.getBalance("ob1qtest2"));
    try testing.expectEqual(@as(u64, 0), set.getBalance("ob1qnobody"));
    try testing.expectEqual(@as(u64, 3), set.count);
    try testing.expectEqual(@as(u64, 15000), set.total_value);
}

test "UTXO — spend removes from set" {
    var set = UTXOSet.init(testing.allocator);
    defer set.deinit();

    try set.addUTXO("tx01", 0, "ob1qalice", 10000, 50, "0014aaaa", false);
    try set.addUTXO("tx01", 1, "ob1qbob", 5000, 50, "0014bbbb", false);

    try testing.expectEqual(@as(u64, 10000), set.getBalance("ob1qalice"));
    try testing.expect(set.hasUTXO("tx01", 0));

    // Spend Alice's UTXO
    const spent = try set.spendUTXO("tx01", 0);
    try testing.expectEqual(@as(u64, 10000), spent.amount);

    // Now Alice has 0 balance, UTXO gone
    try testing.expectEqual(@as(u64, 0), set.getBalance("ob1qalice"));
    try testing.expect(!set.hasUTXO("tx01", 0));

    // Bob still has his
    try testing.expectEqual(@as(u64, 5000), set.getBalance("ob1qbob"));
    try testing.expectEqual(@as(u64, 1), set.count);
}

test "UTXO — spend nonexistent returns error" {
    var set = UTXOSet.init(testing.allocator);
    defer set.deinit();

    try testing.expectError(error.UTXONotFound, set.spendUTXO("nonexistent", 0));
}

test "UTXO — coinbase maturity" {
    var set = UTXOSet.init(testing.allocator);
    defer set.deinit();

    try set.addUTXO("coinbase01", 0, "ob1qminer", 50_000_000_000, 100, "0014miner", true);

    const utxo = set.getUTXO("coinbase01", 0).?;
    // Not mature at height 150 (needs 100+100=200)
    try testing.expect(!utxo.isMature(150));
    // Mature at height 200
    try testing.expect(utxo.isMature(200));
    // Mature at height 300
    try testing.expect(utxo.isMature(300));
}

test "UTXO — selectUTXOs greedy" {
    var set = UTXOSet.init(testing.allocator);
    defer set.deinit();

    try set.addUTXO("tx1", 0, "ob1qsender", 3000, 10, "0014aa", false);
    try set.addUTXO("tx2", 0, "ob1qsender", 5000, 11, "0014aa", false);
    try set.addUTXO("tx3", 0, "ob1qsender", 2000, 12, "0014aa", false);

    // Select enough for 7000 SAT
    var result = try set.selectUTXOs("ob1qsender", 7000, 100, testing.allocator);
    defer result.utxos.deinit(testing.allocator);
    try testing.expect(result.total >= 7000);

    // Insufficient funds for 20000
    try testing.expectError(error.InsufficientFunds, set.selectUTXOs("ob1qsender", 20000, 100, testing.allocator));
}

test "UTXO — getStats" {
    var set = UTXOSet.init(testing.allocator);
    defer set.deinit();

    try set.addUTXO("a", 0, "addr1", 100, 1, "", false);
    try set.addUTXO("b", 0, "addr2", 200, 2, "", false);
    try set.addUTXO("c", 0, "addr1", 300, 3, "", false);

    const stats = set.getStats();
    try testing.expectEqual(@as(u64, 3), stats.count);
    try testing.expectEqual(@as(u64, 600), stats.total_value);
    try testing.expectEqual(@as(u32, 2), stats.addresses);
}

test "UTXO — multiple outputs same TX" {
    var set = UTXOSet.init(testing.allocator);
    defer set.deinit();

    // TX with 3 outputs (like BTC: recipient + change + OP_RETURN)
    try set.addUTXO("multitx", 0, "ob1qrecipient", 7500, 50, "0014aaaa", false);
    try set.addUTXO("multitx", 1, "ob1qchange", 2400, 50, "0014bbbb", false);
    try set.addUTXO("multitx", 2, "ob1qfee", 100, 50, "0014cccc", false);

    try testing.expectEqual(@as(u64, 7500), set.getBalance("ob1qrecipient"));
    try testing.expectEqual(@as(u64, 2400), set.getBalance("ob1qchange"));
    try testing.expectEqual(@as(u64, 3), set.count);

    // Spend output 0
    _ = try set.spendUTXO("multitx", 0);
    try testing.expectEqual(@as(u64, 0), set.getBalance("ob1qrecipient"));
    // Others remain
    try testing.expect(set.hasUTXO("multitx", 1));
    try testing.expect(set.hasUTXO("multitx", 2));
}
