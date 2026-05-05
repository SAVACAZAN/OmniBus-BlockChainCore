const std = @import("std");
const transaction_mod = @import("transaction.zig");
const light_client_mod = @import("light_client.zig");
const oracle_types = @import("oracle_types.zig");
const matching_mod = @import("matching_engine.zig");
const array_list = std.array_list;

pub const Transaction = transaction_mod.Transaction;
pub const MerkleProof = light_client_mod.MerkleProof;
pub const BlockPriceEntry = oracle_types.BlockPriceEntry;
pub const BLOCK_PRICE_SLOTS = oracle_types.BLOCK_PRICE_SLOTS;
pub const Fill = matching_mod.Fill;

/// Maximum block size in bytes (1 MB, like Dogecoin/Bitcoin legacy)
pub const MAX_BLOCK_SIZE: usize = 1_048_576;
/// Maximum transactions per block
/// Reduced from 10,000 to 4,096 to keep Merkle root stack allocation under 128KB
/// (4096 * 32 = 131,072 bytes vs 10,000 * 32 = 320,000 bytes)
pub const MAX_BLOCK_TX: usize = 4_096;

pub const Block = struct {
    index: u32,
    timestamp: i64,
    transactions: array_list.Managed(Transaction),
    previous_hash: []const u8,
    nonce: u64,
    hash: []const u8,
    /// Merkle root of all transaction hashes (32 bytes, like Bitcoin)
    /// Commits to all TX content without including full TX data in header
    merkle_root: [32]u8 = [_]u8{0} ** 32,
    /// Adresa minerului care a validat blocul (goala pentru genesis)
    miner_address: []const u8 = "",
    /// Reward acordat minerului in SAT (0 pentru genesis)
    reward_sat: u64 = 0,
    /// true daca miner_address e alocat pe heap (restaurat din disc) si trebuie eliberat
    miner_heap: bool = false,
    /// Oracle price snapshot captured at mining time (21 entries: 7 pairs × 3 venues).
    /// EMPTY ([21]BlockPriceEntry{}) for the genesis block and for blocks mined
    /// before the WS feed populated.
    /// TODO(db-v2): Agent 5 must extend the binary codec / database serialization
    /// to persist `prices` and `prices_root` so they survive restarts.
    prices: [BLOCK_PRICE_SLOTS]BlockPriceEntry = [_]BlockPriceEntry{.{}} ** BLOCK_PRICE_SLOTS,
    /// SHA-256 of the canonical prices encoding (see computePricesRoot below).
    /// Mixed into calculateHash so the block hash commits to the prices —
    /// any tampering invalidates PoW. Zero-hash means "no prices recorded".
    prices_root: [32]u8 = [_]u8{0} ** 32,

    /// PHASE 2D — Match fills produced when applyBlock matches order TXs
    /// from this block. Fills are appended to history so RPC endpoints
    /// (Ledgers, TradesHistory, OHLC, Spread) can derive answers from
    /// chain state without an in-memory log. Empty for genesis and any
    /// block that touched no orders.
    fills: []const Fill = &.{},
    /// SHA-256 of the canonical fills encoding (see computeFillsRoot).
    /// Mixed into calculateHash so the block hash commits to the fills —
    /// every node MUST reach the same set of fills for the same orders.
    /// Zero-hash means "no fills produced".
    fills_root: [32]u8 = [_]u8{0} ** 32,
    /// True if `fills` slice owns heap memory (allocated by applyBlock,
    /// freed in deinit). False when fills came from a static slice
    /// (e.g. genesis, light-node restore from disk).
    fills_heap: bool = false,

    /// Canonical on-wire size for a single Fill record (180 bytes).
    /// Layout (little-endian, packed):
    ///   [0..8]    fill_id          u64
    ///   [8..16]   buy_order_id     u64
    ///   [16..24]  sell_order_id    u64
    ///   [24..32]  price_micro_usd  u64
    ///   [32..40]  amount_sat       u64
    ///   [40..48]  timestamp_ms     i64
    ///   [48..50]  pair_id          u16
    ///   [50..114] buyer_address    [64]u8
    ///   [114]     buyer_addr_len   u8
    ///   [115..179] seller_address  [64]u8
    ///   [179]     seller_addr_len  u8
    pub const FILL_WIRE_SIZE: usize = 180;

    /// Encode a single Fill to its canonical 180-byte representation.
    pub fn encodeFill(f: *const Fill, out: []u8) void {
        std.debug.assert(out.len >= FILL_WIRE_SIZE);
        @memset(out[0..FILL_WIRE_SIZE], 0);
        std.mem.writeInt(u64, out[0..8], f.fill_id, .little);
        std.mem.writeInt(u64, out[8..16], f.buy_order_id, .little);
        std.mem.writeInt(u64, out[16..24], f.sell_order_id, .little);
        std.mem.writeInt(u64, out[24..32], f.price_micro_usd, .little);
        std.mem.writeInt(u64, out[32..40], f.amount_sat, .little);
        std.mem.writeInt(i64, out[40..48], f.timestamp_ms, .little);
        std.mem.writeInt(u16, out[48..50], f.pair_id, .little);
        @memcpy(out[50..114], &f.buyer_address);
        out[114] = f.buyer_addr_len;
        @memcpy(out[115..179], &f.seller_address);
        out[179] = f.seller_addr_len;
    }

    /// Decode 180 bytes back into a Fill. No allocation needed.
    pub fn decodeFill(buf: []const u8) Fill {
        std.debug.assert(buf.len >= FILL_WIRE_SIZE);
        var f = Fill.empty();
        f.fill_id = std.mem.readInt(u64, buf[0..8], .little);
        f.buy_order_id = std.mem.readInt(u64, buf[8..16], .little);
        f.sell_order_id = std.mem.readInt(u64, buf[16..24], .little);
        f.price_micro_usd = std.mem.readInt(u64, buf[24..32], .little);
        f.amount_sat = std.mem.readInt(u64, buf[32..40], .little);
        f.timestamp_ms = std.mem.readInt(i64, buf[40..48], .little);
        f.pair_id = std.mem.readInt(u16, buf[48..50], .little);
        @memcpy(&f.buyer_address, buf[50..114]);
        f.buyer_addr_len = buf[114];
        @memcpy(&f.seller_address, buf[115..179]);
        f.seller_addr_len = buf[179];
        return f;
    }

    /// Computes the fills_root: SHA-256 over canonical fill encoding.
    /// Fills hashed in input order (matching engine's fill_id order).
    /// Empty fills array → zero hash.
    pub fn computeFillsRoot(fills: []const Fill) [32]u8 {
        if (fills.len == 0) return [_]u8{0} ** 32;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (fills) |f| {
            var rec: [FILL_WIRE_SIZE]u8 = undefined;
            encodeFill(&f, &rec);
            hasher.update(&rec);
        }
        var out: [32]u8 = undefined;
        hasher.final(&out);
        return out;
    }

    /// Calculeaza Merkle Root din toate TX hashes (binary Merkle tree, ca Bitcoin)
    pub fn calculateMerkleRoot(self: *const Block) [32]u8 {
        const tx_count = self.transactions.items.len;
        if (tx_count == 0) return [_]u8{0} ** 32;

        // Collect TX hashes
        var hashes: [MAX_BLOCK_TX][32]u8 = undefined;
        var count: usize = @min(tx_count, MAX_BLOCK_TX);
        for (0..count) |i| {
            hashes[i] = self.transactions.items[i].calculateHash();
        }

        // Build binary Merkle tree (bottom-up, like Bitcoin)
        while (count > 1) {
            const next_count = (count + 1) / 2;
            for (0..next_count) |i| {
                const left = i * 2;
                const right = if (i * 2 + 1 < count) i * 2 + 1 else left; // duplicate last if odd
                var hasher = std.crypto.hash.sha2.Sha256.init(.{});
                hasher.update(&hashes[left]);
                hasher.update(&hashes[right]);
                hasher.final(&hashes[i]);
            }
            count = next_count;
        }

        return hashes[0];
    }

    pub fn calculateHash(self: *const Block) ![32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        // Hash block header (includes merkle_root for TX commitment)
        var buffer: [512]u8 = undefined;
        const str = try std.fmt.bufPrint(&buffer, "{d}{d}{s}{d}", .{
            self.index,
            self.timestamp,
            self.previous_hash,
            self.nonce,
        });

        hasher.update(str);
        hasher.update(&self.merkle_root);
        // Commit to oracle prices — any tampering with self.prices flips the
        // block hash and therefore invalidates PoW.
        hasher.update(&self.prices_root);

        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        return hash;
    }

    /// Canonical encoding of the 21-slot oracle price snapshot, hashed with
    /// SHA-256. Layout per entry (little-endian for integers):
    ///   exchange_len: u8
    ///   exchange:     exchange_len bytes (≤ 16)
    ///   pair_len:     u8
    ///   pair:         pair_len bytes (≤ 16)
    ///   bid_micro_usd: u64 LE
    ///   ask_micro_usd: u64 LE
    ///   timestamp_ms:  i64 LE
    ///   success:       u8 (0 | 1)
    ///
    /// If every slot has success=false AND timestamp_ms=0 the entries carry no
    /// information and we return the all-zero hash (which `validatePrices` and
    /// downstream tools treat as "no prices recorded for this block").
    pub fn computePricesRoot(self: *const Block) [32]u8 {
        // Detect "no data" case: all slots empty.
        var any_data = false;
        for (self.prices) |e| {
            if (e.success or e.timestamp_ms != 0) {
                any_data = true;
                break;
            }
        }
        if (!any_data) return [_]u8{0} ** 32;

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        // Per-entry max size: 1 + 16 + 1 + 16 + 8 + 8 + 8 + 1 = 59 bytes.
        // We hash entry-by-entry rather than via a single big buffer so the
        // numeric fields keep their little-endian layout regardless of host.
        var num_buf: [8]u8 = undefined;

        for (self.prices) |entry| {
            const elen = @min(entry.exchange_len, @as(u8, 16));
            const plen = @min(entry.pair_len, @as(u8, 16));

            hasher.update(&[_]u8{elen});
            hasher.update(entry.exchange[0..elen]);
            hasher.update(&[_]u8{plen});
            hasher.update(entry.pair[0..plen]);

            std.mem.writeInt(u64, &num_buf, entry.bid_micro_usd, .little);
            hasher.update(&num_buf);
            std.mem.writeInt(u64, &num_buf, entry.ask_micro_usd, .little);
            hasher.update(&num_buf);
            std.mem.writeInt(i64, &num_buf, entry.timestamp_ms, .little);
            hasher.update(&num_buf);

            hasher.update(&[_]u8{if (entry.success) @as(u8, 1) else @as(u8, 0)});
        }

        var out: [32]u8 = undefined;
        hasher.final(&out);
        return out;
    }

    /// Copies the supplied 21-slot snapshot into the block and recomputes
    /// `prices_root`. Call this BEFORE `calculateHash`/PoW mining so the
    /// final hash commits to the snapshot.
    pub fn setPrices(self: *Block, entries: [BLOCK_PRICE_SLOTS]BlockPriceEntry) void {
        self.prices = entries;
        self.prices_root = self.computePricesRoot();
    }

    /// Recomputes the canonical prices root from `self.prices` and compares
    /// it against the stored `self.prices_root`. Returns true on match. Used
    /// by the P2P validate path (peer sends a block; we re-hash its prices
    /// and reject if the commitment doesn't line up).
    pub fn validatePrices(self: *const Block) bool {
        const recomputed = self.computePricesRoot();
        return std.mem.eql(u8, &recomputed, &self.prices_root);
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

    /// Generate a Merkle inclusion proof for a transaction at the given index.
    /// Returns null if tx_index is out of range or there are no transactions.
    /// The proof allows a light client to verify the TX is in this block
    /// using only the block header's merkle_root (SPV verification).
    pub fn generateMerkleProof(self: *const Block, tx_index: usize) ?MerkleProof {
        const tx_count = self.transactions.items.len;
        if (tx_count == 0 or tx_index >= tx_count) return null;

        // Collect all TX hashes
        var hashes: [MAX_BLOCK_TX][32]u8 = undefined;
        const count: usize = @min(tx_count, MAX_BLOCK_TX);
        for (0..count) |i| {
            hashes[i] = self.transactions.items[i].calculateHash();
        }

        const tx_hash = hashes[tx_index];
        var proof = MerkleProof.init(tx_hash, self.merkle_root, 0, @intCast(tx_index));

        // Walk up the Merkle tree, recording sibling at each level
        var pos = tx_index;
        var level_count = count;

        while (level_count > 1) {
            const is_left = (pos % 2 == 0);
            const sibling_pos = if (is_left)
                (if (pos + 1 < level_count) pos + 1 else pos) // duplicate last if odd
            else
                pos - 1;

            if (is_left) {
                // We are left child, sibling is on right
                proof.addStep(hashes[sibling_pos], true);
            } else {
                // We are right child, sibling is on left
                proof.addStep(hashes[sibling_pos], false);
            }

            // Compute next level in-place
            const next_count = (level_count + 1) / 2;
            for (0..next_count) |i| {
                const left = i * 2;
                const right = if (i * 2 + 1 < level_count) i * 2 + 1 else left;
                var hasher = std.crypto.hash.sha2.Sha256.init(.{});
                hasher.update(&hashes[left]);
                hasher.update(&hashes[right]);
                hasher.final(&hashes[i]);
            }

            pos = pos / 2;
            level_count = next_count;
        }

        return proof;
    }
};

// ─── Teste ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Construieste o tranzactie minima pentru teste (fara semnatura reala)
fn makeTx(id: u32, from: []const u8, to: []const u8, amount: u64) Transaction {
    return Transaction{
        .id        = id,
        .from_address = from,
        .to_address   = to,
        .amount    = amount,
        .timestamp = 1_700_000_000,
        .signature = "0000000000000000000000000000000000000000000000000000000000000000" ++
                     "0000000000000000000000000000000000000000000000000000000000000000",
        .hash      = "0000000000000000000000000000000000000000000000000000000000000000",
    };
}

test "block - hash nu e zero pentru bloc gol" {
    const allocator = testing.allocator;
    var block = Block{
        .index         = 0,
        .timestamp     = 1_700_000_000,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "0000000000000000000000000000000000000000000000000000000000000000",
        .nonce         = 0,
        .hash          = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer block.transactions.deinit();

    const h = try block.calculateHash();
    var all_zero = true;
    for (h) |b| if (b != 0) { all_zero = false; break; };
    try testing.expect(!all_zero);
}

test "block - hash diferit pentru nonce diferit" {
    const allocator = testing.allocator;
    var b1 = Block{
        .index = 1, .timestamp = 1_700_000_000,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "aaaa",
        .nonce = 42,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer b1.transactions.deinit();
    var b2 = Block{
        .index = 1, .timestamp = 1_700_000_000,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "aaaa",
        .nonce = 43,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer b2.transactions.deinit();

    const h1 = try b1.calculateHash();
    const h2 = try b2.calculateHash();
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "block - hash diferit pentru previous_hash diferit" {
    const allocator = testing.allocator;
    var b1 = Block{
        .index = 2, .timestamp = 1_700_000_000,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "aabb",
        .nonce = 0,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer b1.transactions.deinit();
    var b2 = Block{
        .index = 2, .timestamp = 1_700_000_000,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "ccdd",
        .nonce = 0,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer b2.transactions.deinit();

    const h1 = try b1.calculateHash();
    const h2 = try b2.calculateHash();
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "block - hash determinist (acelasi input => acelasi hash)" {
    const allocator = testing.allocator;
    var b1 = Block{
        .index = 5, .timestamp = 1_700_000_000,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "deadbeef",
        .nonce = 999,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer b1.transactions.deinit();
    var b2 = Block{
        .index = 5, .timestamp = 1_700_000_000,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "deadbeef",
        .nonce = 999,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer b2.transactions.deinit();

    const h1 = try b1.calculateHash();
    const h2 = try b2.calculateHash();
    try testing.expectEqualSlices(u8, &h1, &h2);
}

test "block - addTransaction creste numarul de TX" {
    const allocator = testing.allocator;
    var block = Block{
        .index = 0, .timestamp = 1_700_000_000,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "genesis",
        .nonce = 0,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer block.transactions.deinit();

    try testing.expectEqual(@as(u32, 0), block.getTransactionCount());
    try block.addTransaction(makeTx(1, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas", 1000));
    try testing.expectEqual(@as(u32, 1), block.getTransactionCount());
    try block.addTransaction(makeTx(2, "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas", "ob1q8yy5x2xqfdv0gt53wwfy66cqmkrafgx88kda02", 500));
    try testing.expectEqual(@as(u32, 2), block.getTransactionCount());
}

test "block - hash include tranzactiile via merkle root (hash diferit cu/fara TX)" {
    const allocator = testing.allocator;
    var empty_block = Block{
        .index = 1, .timestamp = 1_700_000_000,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "prev",
        .nonce = 0,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer empty_block.transactions.deinit();
    // Set merkle root for empty block
    empty_block.merkle_root = empty_block.calculateMerkleRoot();

    var block_with_tx = Block{
        .index = 1, .timestamp = 1_700_000_000,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "prev",
        .nonce = 0,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer block_with_tx.transactions.deinit();
    try block_with_tx.addTransaction(makeTx(1, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas", 1_000_000_000));
    // Set merkle root AFTER adding TX (commits to TX content)
    block_with_tx.merkle_root = block_with_tx.calculateMerkleRoot();

    const h_empty = try empty_block.calculateHash();
    const h_tx    = try block_with_tx.calculateHash();
    try testing.expect(!std.mem.eql(u8, &h_empty, &h_tx));
}

test "block - merkle root changes with different transactions" {
    const allocator = testing.allocator;
    var b1 = Block{
        .index = 1, .timestamp = 1_700_000_000,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "prev", .nonce = 0,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer b1.transactions.deinit();
    try b1.addTransaction(makeTx(1, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas", 100));

    var b2 = Block{
        .index = 1, .timestamp = 1_700_000_000,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "prev", .nonce = 0,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer b2.transactions.deinit();
    try b2.addTransaction(makeTx(2, "ob1q8yy5x2xqfdv0gt53wwfy66cqmkrafgx88kda02", "ob1q4xrmwk7c8e263jt3f2wlc0jxyu9merufdwcezs", 200));

    const mr1 = b1.calculateMerkleRoot();
    const mr2 = b2.calculateMerkleRoot();
    try testing.expect(!std.mem.eql(u8, &mr1, &mr2));
}

test "block - empty block merkle root is all zeros" {
    const allocator = testing.allocator;
    var block = Block{
        .index = 0, .timestamp = 0,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "", .nonce = 0,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer block.transactions.deinit();
    const mr = block.calculateMerkleRoot();
    const zeros = [_]u8{0} ** 32;
    try testing.expectEqualSlices(u8, &zeros, &mr);
}

test "block - validateTransactions bloc gol" {
    const allocator = testing.allocator;
    var block = Block{
        .index = 0, .timestamp = 1_700_000_000,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "genesis",
        .nonce = 0,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer block.transactions.deinit();
    // Bloc fara tranzactii e valid (coinbase-only)
    try testing.expect(block.validateTransactions());
}

test "block - getTransactionCount zero initial" {
    const allocator = testing.allocator;
    var block = Block{
        .index = 0, .timestamp = 0,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "",
        .nonce = 0,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer block.transactions.deinit();
    try testing.expectEqual(@as(u32, 0), block.getTransactionCount());
}

test "block - generateMerkleProof empty block returns null" {
    const allocator = testing.allocator;
    var block = Block{
        .index = 0, .timestamp = 0,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "", .nonce = 0,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer block.transactions.deinit();
    try testing.expect(block.generateMerkleProof(0) == null);
}

test "block - generateMerkleProof out of range returns null" {
    const allocator = testing.allocator;
    var block = Block{
        .index = 0, .timestamp = 0,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "", .nonce = 0,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer block.transactions.deinit();
    try block.addTransaction(makeTx(1, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas", 100));
    block.merkle_root = block.calculateMerkleRoot();
    try testing.expect(block.generateMerkleProof(5) == null);
}

test "block - generateMerkleProof single TX verifies" {
    const allocator = testing.allocator;
    var block = Block{
        .index = 0, .timestamp = 0,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "", .nonce = 0,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer block.transactions.deinit();
    try block.addTransaction(makeTx(1, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas", 100));
    block.merkle_root = block.calculateMerkleRoot();

    // Single TX: tree is just the TX hash duplicated as sibling
    const proof_opt = block.generateMerkleProof(0);
    try testing.expect(proof_opt != null);
    const proof = proof_opt.?;
    try testing.expect(light_client_mod.verifyMerkleProof(&proof));
}

test "block - generateMerkleProof 2 TXs verifies both" {
    const allocator = testing.allocator;
    var block = Block{
        .index = 0, .timestamp = 0,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "", .nonce = 0,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer block.transactions.deinit();
    try block.addTransaction(makeTx(1, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas", 100));
    try block.addTransaction(makeTx(2, "ob1q8yy5x2xqfdv0gt53wwfy66cqmkrafgx88kda02", "ob1q4xrmwk7c8e263jt3f2wlc0jxyu9merufdwcezs", 200));
    block.merkle_root = block.calculateMerkleRoot();

    // Verify proof for TX 0
    const p0 = block.generateMerkleProof(0).?;
    try testing.expect(light_client_mod.verifyMerkleProof(&p0));

    // Verify proof for TX 1
    const p1 = block.generateMerkleProof(1).?;
    try testing.expect(light_client_mod.verifyMerkleProof(&p1));
}

test "block - generateMerkleProof 4 TXs verifies all" {
    const allocator = testing.allocator;
    var block = Block{
        .index = 0, .timestamp = 0,
        .transactions  = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "", .nonce = 0,
        .hash  = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    defer block.transactions.deinit();
    try block.addTransaction(makeTx(1, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas", 100));
    try block.addTransaction(makeTx(2, "ob1q8yy5x2xqfdv0gt53wwfy66cqmkrafgx88kda02", "ob1q4xrmwk7c8e263jt3f2wlc0jxyu9merufdwcezs", 200));
    try block.addTransaction(makeTx(3, "ob1qdz28c9t6r9qy33pu2agsnmms9nje88ejxrltgt", "ob1q8lrgnmdspgyj3lwt5d8zehlarzqrdxffsgx5u0", 300));
    try block.addTransaction(makeTx(4, "ob1qg5udjz6lmvvhayca0d7x3xy3e2sl9favpv0a7e", "ob1q2hy0ea4swquau990w9w0vcrdzyfu54qyye4f2k", 400));
    block.merkle_root = block.calculateMerkleRoot();

    for (0..4) |i| {
        const p = block.generateMerkleProof(i).?;
        try testing.expect(light_client_mod.verifyMerkleProof(&p));
    }
}

// ─── Oracle price snapshot tests ─────────────────────────────────────────────

/// Build an empty Block (no transactions) for price-test scenarios.
fn makePriceTestBlock(allocator: std.mem.Allocator) Block {
    return Block{
        .index = 7,
        .timestamp = 1_700_000_000,
        .transactions = array_list.Managed(Transaction).init(allocator),
        .previous_hash = "deadbeef",
        .nonce = 0,
        .hash = "0000000000000000000000000000000000000000000000000000000000000000",
    };
}

/// Build one populated BlockPriceEntry for tests.
fn makePriceEntry(exchange: []const u8, pair: []const u8, bid: u64, ask: u64, ts: i64) BlockPriceEntry {
    var e: BlockPriceEntry = .{};
    const elen = @min(exchange.len, 16);
    e.exchange_len = @intCast(elen);
    @memcpy(e.exchange[0..elen], exchange[0..elen]);
    const plen = @min(pair.len, 16);
    e.pair_len = @intCast(plen);
    @memcpy(e.pair[0..plen], pair[0..plen]);
    e.bid_micro_usd = bid;
    e.ask_micro_usd = ask;
    e.timestamp_ms = ts;
    e.success = true;
    return e;
}

test "block.prices - empty snapshot yields zero prices_root" {
    const allocator = testing.allocator;
    var block = makePriceTestBlock(allocator);
    defer block.transactions.deinit();

    const root = block.computePricesRoot();
    const zeros = [_]u8{0} ** 32;
    try testing.expectEqualSlices(u8, &zeros, &root);

    // setPrices with default-init entries also yields zero root.
    const empty = [_]BlockPriceEntry{.{}} ** BLOCK_PRICE_SLOTS;
    block.setPrices(empty);
    try testing.expectEqualSlices(u8, &zeros, &block.prices_root);
}

test "block.prices - one populated entry produces non-zero deterministic root" {
    const allocator = testing.allocator;
    var b1 = makePriceTestBlock(allocator);
    defer b1.transactions.deinit();
    var b2 = makePriceTestBlock(allocator);
    defer b2.transactions.deinit();

    var entries = [_]BlockPriceEntry{.{}} ** BLOCK_PRICE_SLOTS;
    entries[0] = makePriceEntry("Coinbase", "BTC/USD", 65_000_000_000, 65_001_000_000, 1_700_000_123);

    b1.setPrices(entries);
    b2.setPrices(entries);

    // Non-zero
    const zeros = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(u8, &zeros, &b1.prices_root));
    // Deterministic across two re-inits with identical input
    try testing.expectEqualSlices(u8, &b1.prices_root, &b2.prices_root);
}

test "block.prices - tampering with bid changes prices_root" {
    const allocator = testing.allocator;
    var block = makePriceTestBlock(allocator);
    defer block.transactions.deinit();

    var entries = [_]BlockPriceEntry{.{}} ** BLOCK_PRICE_SLOTS;
    entries[0] = makePriceEntry("Kraken", "ETH/USD", 3_500_000_000, 3_501_000_000, 1_700_000_456);
    block.setPrices(entries);
    const original_root = block.prices_root;

    // Mutate bid in place; recompute root and confirm it differs.
    block.prices[0].bid_micro_usd = 3_500_000_001;
    const tampered_root = block.computePricesRoot();
    try testing.expect(!std.mem.eql(u8, &original_root, &tampered_root));

    // validatePrices() now disagrees because stored root reflects the OLD bid.
    try testing.expect(!block.validatePrices());
}

test "block.prices - validatePrices true after setPrices" {
    const allocator = testing.allocator;
    var block = makePriceTestBlock(allocator);
    defer block.transactions.deinit();

    var entries = [_]BlockPriceEntry{.{}} ** BLOCK_PRICE_SLOTS;
    entries[0] = makePriceEntry("LCX", "LCX/USD", 200_000, 201_000, 1_700_000_789);
    entries[5] = makePriceEntry("Coinbase", "ETH/USD", 3_500_000_000, 3_501_000_000, 1_700_000_790);
    block.setPrices(entries);

    try testing.expect(block.validatePrices());

    // Empty snapshot also validates (zero-hash vs zero-hash).
    var empty_block = makePriceTestBlock(allocator);
    defer empty_block.transactions.deinit();
    try testing.expect(empty_block.validatePrices());
}

test "block.prices - calculateHash matches across two identical price sets" {
    const allocator = testing.allocator;
    var b1 = makePriceTestBlock(allocator);
    defer b1.transactions.deinit();
    var b2 = makePriceTestBlock(allocator);
    defer b2.transactions.deinit();

    var entries = [_]BlockPriceEntry{.{}} ** BLOCK_PRICE_SLOTS;
    entries[0] = makePriceEntry("Coinbase", "BTC/USD", 65_000_000_000, 65_001_000_000, 1_700_111_111);
    entries[1] = makePriceEntry("Kraken",   "BTC/USD", 64_999_500_000, 65_000_500_000, 1_700_111_112);
    entries[2] = makePriceEntry("LCX",      "BTC/USD", 65_000_250_000, 65_001_250_000, 1_700_111_113);

    b1.setPrices(entries);
    b2.setPrices(entries);

    const h1 = try b1.calculateHash();
    const h2 = try b2.calculateHash();
    try testing.expectEqualSlices(u8, &h1, &h2);
}

test "block.prices - calculateHash differs when prices differ" {
    const allocator = testing.allocator;
    var b1 = makePriceTestBlock(allocator);
    defer b1.transactions.deinit();
    var b2 = makePriceTestBlock(allocator);
    defer b2.transactions.deinit();

    var entries_a = [_]BlockPriceEntry{.{}} ** BLOCK_PRICE_SLOTS;
    entries_a[0] = makePriceEntry("Coinbase", "BTC/USD", 65_000_000_000, 65_001_000_000, 1_700_000_000);
    var entries_b = entries_a;
    entries_b[0].bid_micro_usd = 65_000_000_001; // 1 micro-USD difference

    b1.setPrices(entries_a);
    b2.setPrices(entries_b);

    const h1 = try b1.calculateHash();
    const h2 = try b2.calculateHash();
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}
