const std = @import("std");
const bip32_mod = @import("bip32_wallet.zig");
const secp256k1_mod = @import("secp256k1.zig");
const transaction_mod = @import("transaction.zig");
const crypto_mod = @import("crypto.zig");

const BIP32Wallet = bip32_mod.BIP32Wallet;
const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;
const Crypto = crypto_mod.Crypto;
const Transaction = transaction_mod.Transaction;

/// MinerWallet — a lightweight wallet for virtual miners in the pool.
/// Each miner gets a real secp256k1 key pair and can sign transactions.
/// Unlike the full Wallet (which derives 5 PQ domains), MinerWallet only
/// derives the primary OMNI key (coin_type 777) for minimal overhead.
pub const MinerWallet = struct {
    /// Primary address (ob_omni_...)
    address: [64]u8,
    address_len: u8,
    /// secp256k1 private key (32 bytes)
    private_key: [32]u8,
    /// Compressed public key (33 bytes: 0x02/0x03 + X)
    public_key: [33]u8,
    /// Compressed public key as hex (66 chars)
    public_key_hex: [66]u8,
    /// Cached balance (updated from blockchain after each block)
    balance_cache: u64,
    /// Whether this wallet was derived from a mnemonic (true) or random (false)
    has_mnemonic: bool,

    const HEX_CHARS = "0123456789abcdef";

    /// Derive a MinerWallet from a BIP-39 mnemonic.
    /// Uses BIP-32 path m/44'/777'/0'/0/0 (OMNI primary).
    pub fn fromMnemonic(mnemonic: []const u8, address_slice: []const u8, allocator: std.mem.Allocator) !MinerWallet {
        const bip32 = try BIP32Wallet.initFromMnemonic(mnemonic, allocator);
        const privkey = try bip32.deriveChildKeyForPath(44, 777, 0);
        const pubkey = try Secp256k1Crypto.privateKeyToPublicKey(privkey);

        var wallet = MinerWallet{
            .address = undefined,
            .address_len = 0,
            .private_key = privkey,
            .public_key = pubkey,
            .public_key_hex = undefined,
            .balance_cache = 0,
            .has_mnemonic = true,
        };

        // Set address from the provided address string (already derived by caller)
        const alen = @min(address_slice.len, 64);
        @memcpy(wallet.address[0..alen], address_slice[0..alen]);
        wallet.address_len = @intCast(alen);

        // Compute pubkey hex
        for (pubkey, 0..) |byte, j| {
            wallet.public_key_hex[j * 2] = HEX_CHARS[byte >> 4];
            wallet.public_key_hex[j * 2 + 1] = HEX_CHARS[byte & 0x0F];
        }

        return wallet;
    }

    /// Generate a MinerWallet from a random private key (no mnemonic).
    /// Address is derived from the public key using Hash160.
    pub fn fromRandom(address_slice: []const u8) !MinerWallet {
        // Generate random 32-byte private key
        var privkey: [32]u8 = undefined;
        std.crypto.random.bytes(&privkey);

        // Ensure valid private key (non-zero, less than curve order)
        while (!Secp256k1Crypto.isValidPrivateKey(privkey)) {
            std.crypto.random.bytes(&privkey);
        }

        const pubkey = try Secp256k1Crypto.privateKeyToPublicKey(privkey);

        var wallet = MinerWallet{
            .address = undefined,
            .address_len = 0,
            .private_key = privkey,
            .public_key = pubkey,
            .public_key_hex = undefined,
            .balance_cache = 0,
            .has_mnemonic = false,
        };

        // Set address from provided string
        const alen = @min(address_slice.len, 64);
        @memcpy(wallet.address[0..alen], address_slice[0..alen]);
        wallet.address_len = @intCast(alen);

        // Compute pubkey hex
        for (pubkey, 0..) |byte, j| {
            wallet.public_key_hex[j * 2] = HEX_CHARS[byte >> 4];
            wallet.public_key_hex[j * 2 + 1] = HEX_CHARS[byte & 0x0F];
        }

        return wallet;
    }

    /// Get address as a slice.
    pub fn getAddress(self: *const MinerWallet) []const u8 {
        return self.address[0..self.address_len];
    }

    /// Get public key hex as a slice.
    pub fn getPubkeyHex(self: *const MinerWallet) []const u8 {
        return &self.public_key_hex;
    }

    /// Create and sign a transaction from this miner to a recipient.
    /// Returns a fully signed Transaction ready for mempool insertion.
    pub fn createSignedTx(
        self: *const MinerWallet,
        to_address: []const u8,
        amount_sat: u64,
        tx_id: u32,
        nonce: u64,
        fee_sat: u64,
        allocator: std.mem.Allocator,
    ) !Transaction {
        const to_owned = try allocator.dupe(u8, to_address);
        const from_owned = try allocator.dupe(u8, self.getAddress());
        var tx = Transaction{
            .id = tx_id,
            .from_address = from_owned,
            .to_address = to_owned,
            .amount = amount_sat,
            .fee = fee_sat,
            .timestamp = std.time.timestamp(),
            .nonce = nonce,
            .signature = "",
            .hash = "",
        };
        try tx.sign(self.private_key, allocator);
        return tx;
    }

    /// Securely wipe private key from memory.
    pub fn wipeKey(self: *MinerWallet) void {
        @memset(&self.private_key, 0);
    }
};

// ── MinerWalletPool — thread-safe pool of MinerWallet entries ─────────────────

/// Global miner wallet pool — stores real key pairs for each virtual miner.
/// Thread-safe: accessed from RPC thread (registration) and mining loop (auto-TX).
pub const MinerWalletPool = struct {
    pub const MAX: usize = 256;

    wallets: [MAX]MinerWallet = undefined,
    count: usize = 0,
    mutex: std.Thread.Mutex = .{},
    /// Round-robin index for auto-TX sender selection
    auto_tx_index: u32 = 0,

    /// Register a miner with a mnemonic-derived wallet.
    /// Returns true if registered, false if duplicate or pool full.
    pub fn registerWithMnemonic(
        self: *MinerWalletPool,
        address: []const u8,
        mnemonic: []const u8,
        allocator: std.mem.Allocator,
    ) !bool {
        if (address.len < 8) return false;
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check duplicate
        for (self.wallets[0..self.count]) |*w| {
            if (w.address_len == address.len and
                std.mem.eql(u8, w.address[0..w.address_len], address))
                return false;
        }
        if (self.count >= MAX) return false;

        self.wallets[self.count] = try MinerWallet.fromMnemonic(mnemonic, address, allocator);
        self.count += 1;
        return true;
    }

    /// Register a miner with a random key pair (no mnemonic provided).
    pub fn registerWithRandomKey(self: *MinerWalletPool, address: []const u8) !bool {
        if (address.len < 8) return false;
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check duplicate
        for (self.wallets[0..self.count]) |*w| {
            if (w.address_len == address.len and
                std.mem.eql(u8, w.address[0..w.address_len], address))
                return false;
        }
        if (self.count >= MAX) return false;

        self.wallets[self.count] = try MinerWallet.fromRandom(address);
        self.count += 1;
        return true;
    }

    /// Look up a miner wallet by address. Returns null if not found.
    pub fn findByAddress(self: *MinerWalletPool, address: []const u8) ?*const MinerWallet {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.wallets[0..self.count]) |*w| {
            if (w.address_len == address.len and
                std.mem.eql(u8, w.address[0..w.address_len], address))
                return w;
        }
        return null;
    }

    /// Get miner address for a given block (round-robin, same as old MinerPool).
    pub fn getMinerForBlock(self: *MinerWalletPool, block_num: u32, fallback: []const u8) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.count == 0) return fallback;
        const idx = block_num % @as(u32, @intCast(self.count));
        return self.wallets[idx].getAddress();
    }

    /// Register a miner in the pool (address only — for backward compat).
    /// Also used when the old MinerPool.register() path is called.
    /// Uses random key derivation since no mnemonic is available.
    pub fn register(self: *MinerWalletPool, addr: []const u8) void {
        _ = self.registerWithRandomKey(addr) catch {};
    }

    /// Update cached balance for a miner wallet.
    pub fn updateBalance(self: *MinerWalletPool, address: []const u8, balance: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.wallets[0..self.count]) |*w| {
            if (w.address_len == address.len and
                std.mem.eql(u8, w.address[0..w.address_len], address)) {
                w.balance_cache = balance;
                return;
            }
        }
    }

    /// Pick two miners with balance > threshold for auto-TX.
    /// Returns (sender_index, receiver_index) or null if not enough funded miners.
    pub fn pickAutoTxPair(self: *MinerWalletPool, min_balance: u64) ?struct { sender: usize, receiver: usize } {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count < 2) return null;

        // Find miners with sufficient balance
        var funded: [MAX]usize = undefined;
        var funded_count: usize = 0;
        for (self.wallets[0..self.count], 0..) |w, i| {
            if (w.balance_cache >= min_balance) {
                funded[funded_count] = i;
                funded_count += 1;
            }
        }
        if (funded_count < 2) return null;

        // Round-robin sender, next as receiver
        const sender_pick = self.auto_tx_index % @as(u32, @intCast(funded_count));
        const receiver_pick = (sender_pick + 1) % @as(u32, @intCast(funded_count));
        self.auto_tx_index +%= 1;

        return .{
            .sender = funded[sender_pick],
            .receiver = funded[receiver_pick],
        };
    }

    /// Get wallet at index (for auto-TX). Caller must hold no lock.
    pub fn getWalletAt(self: *MinerWalletPool, index: usize) ?MinerWallet {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.count) return null;
        return self.wallets[index];
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "MinerWallet.fromMnemonic — derives valid key pair" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const addr = "ob_omni_test_miner_1";

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const mw = try MinerWallet.fromMnemonic(mnemonic, addr, arena.allocator());

    // Address is set correctly
    try testing.expectEqualStrings(addr, mw.getAddress());

    // Public key is compressed secp256k1 (starts with 0x02 or 0x03)
    try testing.expect(mw.public_key[0] == 0x02 or mw.public_key[0] == 0x03);

    // Private key is non-zero
    var all_zero = true;
    for (mw.private_key) |b| {
        if (b != 0) { all_zero = false; break; }
    }
    try testing.expect(!all_zero);

    // Pubkey hex is 66 chars
    try testing.expectEqual(@as(usize, 66), mw.public_key_hex.len);

    // Has mnemonic flag
    try testing.expect(mw.has_mnemonic);
}

test "MinerWallet.fromMnemonic — deterministic" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const addr = "ob_omni_test_det";

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const mw1 = try MinerWallet.fromMnemonic(mnemonic, addr, arena.allocator());
    const mw2 = try MinerWallet.fromMnemonic(mnemonic, addr, arena.allocator());

    try testing.expectEqualSlices(u8, &mw1.private_key, &mw2.private_key);
    try testing.expectEqualSlices(u8, &mw1.public_key, &mw2.public_key);
}

test "MinerWallet.fromRandom — generates valid key pair" {
    const addr = "ob_omni_random_miner";
    const mw = try MinerWallet.fromRandom(addr);

    try testing.expectEqualStrings(addr, mw.getAddress());
    try testing.expect(mw.public_key[0] == 0x02 or mw.public_key[0] == 0x03);
    try testing.expect(!mw.has_mnemonic);
}

test "MinerWallet.createSignedTx — produces signed TX in mempool format" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const addr = "ob_omni_sender_test";

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const mw = try MinerWallet.fromMnemonic(mnemonic, addr, arena.allocator());
    const tx = try mw.createSignedTx("ob_omni_receiver_test", 5000, 1, 0, 1, arena.allocator());

    // TX is valid
    try testing.expect(tx.isValid());

    // TX has signature (128 hex chars = 64 bytes)
    try testing.expectEqual(@as(usize, 128), tx.signature.len);

    // TX has hash (64 hex chars = 32 bytes)
    try testing.expectEqual(@as(usize, 64), tx.hash.len);

    // TX addresses match
    try testing.expectEqualStrings(addr, tx.from_address);
    try testing.expectEqualStrings("ob_omni_receiver_test", tx.to_address);

    // TX amount and fee match
    try testing.expectEqual(@as(u64, 5000), tx.amount);
    try testing.expectEqual(@as(u64, 1), tx.fee);

    // Verify signature with pubkey
    try testing.expect(tx.verify(mw.public_key));
}

test "MinerWalletPool — register and find" {
    var pool = MinerWalletPool{};
    const addr = "ob_omni_pool_test";

    // Register with random key
    const ok = try pool.registerWithRandomKey(addr);
    try testing.expect(ok);
    try testing.expectEqual(@as(usize, 1), pool.count);

    // Duplicate returns false
    const dup = try pool.registerWithRandomKey(addr);
    try testing.expect(!dup);
    try testing.expectEqual(@as(usize, 1), pool.count);

    // Find by address
    const found = pool.findByAddress(addr);
    try testing.expect(found != null);
    try testing.expectEqualStrings(addr, found.?.getAddress());

    // Not found
    const nope = pool.findByAddress("ob_omni_nonexistent");
    try testing.expect(nope == null);
}

test "MinerWalletPool — getMinerForBlock round-robin" {
    var pool = MinerWalletPool{};

    _ = try pool.registerWithRandomKey("ob_omni_miner_a");
    _ = try pool.registerWithRandomKey("ob_omni_miner_b");
    _ = try pool.registerWithRandomKey("ob_omni_miner_c");

    const m0 = pool.getMinerForBlock(0, "fallback");
    const m1 = pool.getMinerForBlock(1, "fallback");
    const m2 = pool.getMinerForBlock(2, "fallback");
    const m3 = pool.getMinerForBlock(3, "fallback");

    // Block 0 and 3 should map to same miner (3 % 3 == 0)
    try testing.expectEqualStrings(m0, m3);
    // Block 0, 1, 2 should be different miners
    try testing.expect(!std.mem.eql(u8, m0, m1));
    try testing.expect(!std.mem.eql(u8, m1, m2));
}

test "MinerWalletPool — pickAutoTxPair" {
    var pool = MinerWalletPool{};

    _ = try pool.registerWithRandomKey("ob_omni_auto_a");
    _ = try pool.registerWithRandomKey("ob_omni_auto_b");
    _ = try pool.registerWithRandomKey("ob_omni_auto_c");

    // No funded miners yet
    const none = pool.pickAutoTxPair(1000);
    try testing.expect(none == null);

    // Fund two miners
    pool.updateBalance("ob_omni_auto_a", 50000);
    pool.updateBalance("ob_omni_auto_c", 30000);

    const pair = pool.pickAutoTxPair(1000);
    try testing.expect(pair != null);
    try testing.expect(pair.?.sender != pair.?.receiver);
}

test "MinerWalletPool — registerWithMnemonic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var pool = MinerWalletPool{};
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const addr = "ob_omni_mnem_test";

    const ok = try pool.registerWithMnemonic(addr, mnemonic, arena.allocator());
    try testing.expect(ok);

    const found = pool.findByAddress(addr);
    try testing.expect(found != null);
    try testing.expect(found.?.has_mnemonic);
    try testing.expect(found.?.public_key[0] == 0x02 or found.?.public_key[0] == 0x03);
}
