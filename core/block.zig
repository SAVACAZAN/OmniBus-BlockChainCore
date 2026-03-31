const std = @import("std");
const transaction_mod = @import("transaction.zig");
const light_client_mod = @import("light_client.zig");
const array_list = std.array_list;

pub const Transaction = transaction_mod.Transaction;
pub const MerkleProof = light_client_mod.MerkleProof;

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
