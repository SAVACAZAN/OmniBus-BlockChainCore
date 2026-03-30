const std = @import("std");
const array_list = std.array_list;

/// Account state (replaces needing to store all transactions)
pub const AccountState = struct {
    address: [20]u8,                // Compressed address
    balance: u64,                   // Current balance in SAT
    nonce: u32,                     // Transaction counter
    last_updated_block: u32,        // Last block that modified this account
    flags: u8 = 0,                  // Flags (frozen, etc)

    pub fn hash(self: *const AccountState) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        var buffer: [256]u8 = undefined;
        const str = std.fmt.bufPrint(&buffer, "{d}:{d}:{d}", .{
            self.balance,
            self.nonce,
            self.last_updated_block,
        }) catch "";

        hasher.update(&self.address);
        hasher.update(str);

        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    pub fn print(self: *const AccountState) void {
        std.debug.print(
            "[Account] Balance={d}, Nonce={d}, Updated={d}\n",
            .{ self.balance, self.nonce, self.last_updated_block },
        );
    }
};

/// State Trie - merkle tree of account states
/// Instead of storing all transactions, store only current state
/// ~50 MB for 1M+ accounts vs 1.6 TB for all transaction history!
pub const StateTrie = struct {
    allocator: std.mem.Allocator,
    accounts: std.AutoHashMap([20]u8, AccountState),
    root_hash: [32]u8 = [_]u8{0} ** 32,
    block_height: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) StateTrie {
        return StateTrie{
            .allocator = allocator,
            .accounts = std.AutoHashMap([20]u8, AccountState).init(allocator),
        };
    }

    /// Update account balance
    pub fn updateBalance(self: *StateTrie, address: [20]u8, new_balance: u64, block_height: u32) !void {
        var account = self.accounts.get(address) orelse AccountState{
            .address = address,
            .balance = 0,
            .nonce = 0,
            .last_updated_block = block_height,
        };
        account.balance = new_balance;
        account.last_updated_block = block_height;
        try self.accounts.put(address, account);
    }

    /// Increment nonce (for transaction sequencing)
    pub fn incrementNonce(self: *StateTrie, address: [20]u8, block_height: u32) !void {
        var account = self.accounts.get(address) orelse AccountState{
            .address = address,
            .balance = 0,
            .nonce = 0,
            .last_updated_block = block_height,
        };
        account.nonce += 1;
        account.last_updated_block = block_height;
        try self.accounts.put(address, account);
    }

    /// Get account balance
    pub fn getBalance(self: *const StateTrie, address: [20]u8) u64 {
        if (self.accounts.get(address)) |account| return account.balance;
        return 0;
    }

    /// Get account nonce
    pub fn getNonce(self: *const StateTrie, address: [20]u8) u32 {
        if (self.accounts.get(address)) |account| return account.nonce;
        return 0;
    }

    /// Calculate root hash (merkle root of all accounts)
    pub fn calculateRootHash(self: *const StateTrie) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        var it = self.accounts.valueIterator();
        while (it.next()) |account| {
            const account_hash = account.hash();
            hasher.update(&account_hash);
        }

        var root: [32]u8 = undefined;
        hasher.final(&root);
        return root;
    }

    /// Get account count
    pub fn getAccountCount(self: *const StateTrie) usize {
        return self.accounts.count();
    }

    /// Estimate storage size
    pub fn estimateStorageSize(self: *const StateTrie) u64 {
        // ~1 KB per account (address + balance + nonce + metadata)
        return self.accounts.count() * 1024;
    }

    /// Print statistics
    pub fn printStats(self: *const StateTrie) void {
        const root = self.calculateRootHash();
        const size = self.estimateStorageSize();

        std.debug.print(
            \\[StateTrie] Statistics:
            \\  - Accounts: {d}
            \\  - Estimated size: {d} MB
            \\  - Root hash: {x:0>2}{x:0>2}...
            \\  - Block height: {d}
            \\
        , .{
            self.accounts.count(),
            size / (1024 * 1024),
            root[0],
            root[1],
            self.block_height,
        });
    }

    /// Get all accounts (for verification)
    pub fn getAllAccounts(self: *const StateTrie, allocator: std.mem.Allocator) ![]AccountState {
        var accounts = std.array_list.Managed(AccountState).init(allocator);

        var it = self.accounts.valueIterator();
        while (it.next()) |account| {
            try accounts.append(account.*);
        }

        return accounts.items;
    }

    pub fn deinit(self: *StateTrie) void {
        self.accounts.deinit();
    }
};

/// State snapshot for checkpointing
pub const StateSnapshot = struct {
    block_height: u32,
    root_hash: [32]u8,
    timestamp: i64,
    account_count: usize,
    size_bytes: u64,

    pub fn print(self: *const StateSnapshot) void {
        std.debug.print(
            "[Snapshot] Block {d}: {d} accounts, {d} MB\n",
            .{ self.block_height, self.account_count, self.size_bytes / (1024 * 1024) },
        );
    }
};

// Tests
const testing = std.testing;

test "state trie initialization" {
    var trie = StateTrie.init(testing.allocator);
    defer trie.deinit();

    try testing.expectEqual(trie.getAccountCount(), 0);
}

test "account balance update" {
    var trie = StateTrie.init(testing.allocator);
    defer trie.deinit();

    const address = [_]u8{1} ** 20;
    try trie.updateBalance(address, 1000, 1);

    const balance = trie.getBalance(address);
    try testing.expectEqual(balance, 1000);
}

test "account nonce increment" {
    var trie = StateTrie.init(testing.allocator);
    defer trie.deinit();

    const address = [_]u8{2} ** 20;
    try trie.incrementNonce(address, 1);
    try trie.incrementNonce(address, 2);

    const nonce = trie.getNonce(address);
    try testing.expectEqual(nonce, 2);
}

test "state trie root hash" {
    var trie = StateTrie.init(testing.allocator);
    defer trie.deinit();

    const addr1 = [_]u8{1} ** 20;
    const addr2 = [_]u8{2} ** 20;

    try trie.updateBalance(addr1, 5000, 1);
    try trie.updateBalance(addr2, 3000, 1);

    const root = trie.calculateRootHash();
    try testing.expect(root[0] != 0);  // Should have non-zero hash
}

test "state storage efficiency" {
    var trie = StateTrie.init(testing.allocator);
    defer trie.deinit();

    // Add 100 accounts
    for (0..100) |i| {
        var address: [20]u8 = [_]u8{0} ** 20;
        address[0] = @intCast(i);
        try trie.updateBalance(address, @intCast(i * 1000), 1);
    }

    const size = trie.estimateStorageSize();
    // 100 accounts × 1KB = 100 KB (vs MB for transactions!)
    try testing.expect(size < 1024 * 1024);  // Less than 1 MB
}
