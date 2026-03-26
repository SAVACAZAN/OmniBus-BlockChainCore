/// sub_block.zig — 10 sub-blocuri de 0.1s → 1 KeyBlock de 1s
/// Structura: SubBlock (0.1s) × 10 = KeyBlock (1s) → Blockchain
const std        = @import("std");
const array_list = std.array_list;
const transaction_mod = @import("transaction.zig");
const blockchain_mod  = @import("blockchain.zig");

pub const Transaction = transaction_mod.Transaction;
pub const Block       = blockchain_mod.Block;

/// Numarul de sub-blocuri per bloc principal
pub const SUB_BLOCKS_PER_BLOCK: u8 = 10;

/// Intervalul unui sub-bloc in ms
pub const SUB_BLOCK_INTERVAL_MS: u64 = 100;

/// Sub-block — confirmare soft la 0.1s
pub const SubBlock = struct {
    sub_id:       u8,      // 0-9 (pozitia in secunda curenta)
    block_number: u32,     // Blocul parinte (Key-Block index)
    timestamp_ms: i64,     // Unix milliseconds
    merkle_root:  [32]u8,  // SHA256 al TX-urilor
    shard_id:     u8,      // 0-6 (sharding — care validator proceseaza)
    miner_id:     []const u8,
    nonce:        u64,
    hash:         [32]u8,
    tx_count:     u32,
    transactions: array_list.Managed(Transaction),

    pub fn init(
        allocator:    std.mem.Allocator,
        sub_id:       u8,
        block_number: u32,
        shard_id:     u8,
        miner_id:     []const u8,
    ) SubBlock {
        return .{
            .sub_id       = sub_id,
            .block_number = block_number,
            .timestamp_ms = std.time.milliTimestamp(),
            .merkle_root  = @splat(0),
            .shard_id     = shard_id,
            .miner_id     = miner_id,
            .nonce        = 0,
            .hash         = @splat(0),
            .tx_count     = 0,
            .transactions = array_list.Managed(Transaction).init(allocator),
        };
    }

    pub fn deinit(self: *SubBlock) void {
        self.transactions.deinit();
    }

    pub fn addTransaction(self: *SubBlock, tx: Transaction) !void {
        try self.transactions.append(tx);
        self.tx_count += 1;
    }

    pub fn finalize(self: *SubBlock) void {
        self.merkle_root = self.calcMerkleRoot();
        self.hash        = self.calcHash();
    }

    fn calcMerkleRoot(self: *const SubBlock) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (self.transactions.items) |tx| {
            hasher.update(tx.hash);
        }
        var root: [32]u8 = undefined;
        hasher.final(&root);
        return root;
    }

    fn calcHash(self: *const SubBlock) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "sb:{d}:{d}:{d}:{d}:{d}", .{
            self.sub_id, self.block_number,
            self.timestamp_ms, self.shard_id, self.nonce,
        }) catch "";
        hasher.update(s);
        hasher.update(&self.merkle_root);
        var h: [32]u8 = undefined;
        hasher.final(&h);
        return h;
    }

    pub fn isValid(self: *const SubBlock) bool {
        if (self.sub_id >= SUB_BLOCKS_PER_BLOCK) return false;
        for (self.transactions.items) |tx| {
            if (!tx.isValid()) return false;
        }
        return true;
    }
};

// ─── KeyBlock — agrega 10 SubBlock-uri → 1 bloc valid in chain ───────────────

/// Starea unui KeyBlock in constructie
pub const KeyBlockState = enum {
    collecting,   // Colecteaza sub-blocuri (0-9)
    complete,     // 10/10 sub-blocuri primite
    finalized,    // Hash calculat, gata de adaugat in chain
};

pub const KeyBlock = struct {
    block_number:  u32,
    sub_blocks:    [SUB_BLOCKS_PER_BLOCK]?SubBlock,
    received:      u8,          // cate sub-blocuri am primit (0-10)
    state:         KeyBlockState,
    started_at_ms: i64,
    finalized_at_ms: i64,
    /// Merkle root al celor 10 sub-block hash-uri
    sub_merkle_root: [32]u8,
    /// Hash-ul final al Key-Block-ului
    key_hash:      [32]u8,
    /// Reward total (suma reward-urilor din toate sub-blocurile)
    total_reward_sat: u64,

    pub fn init(block_number: u32) KeyBlock {
        return .{
            .block_number    = block_number,
            .sub_blocks      = @splat(null),
            .received        = 0,
            .state           = .collecting,
            .started_at_ms   = std.time.milliTimestamp(),
            .finalized_at_ms = 0,
            .sub_merkle_root = @splat(0),
            .key_hash        = @splat(0),
            .total_reward_sat = 0,
        };
    }

    /// Adauga un sub-bloc (trebuie sa aiba sub_id unic 0-9)
    /// Returneaza true daca Key-Block-ul e complet (10/10)
    pub fn addSubBlock(self: *KeyBlock, sb: SubBlock) !bool {
        if (self.state != .collecting) return error.KeyBlockClosed;
        if (sb.sub_id >= SUB_BLOCKS_PER_BLOCK) return error.InvalidSubId;
        if (self.sub_blocks[sb.sub_id] != null) return error.DuplicateSubBlock;
        if (!sb.isValid()) return error.InvalidSubBlock;

        self.sub_blocks[sb.sub_id] = sb;
        self.received += 1;

        if (self.received == SUB_BLOCKS_PER_BLOCK) {
            self.state = .complete;
            return true;
        }
        return false;
    }

    /// Finalizeaza Key-Block-ul — calculeaza hash-ul agregat
    pub fn finalize(self: *KeyBlock, reward_sat: u64) void {
        self.total_reward_sat = reward_sat;
        self.sub_merkle_root  = self.calcSubMerkleRoot();
        self.key_hash         = self.calcKeyHash();
        self.finalized_at_ms  = std.time.milliTimestamp();
        self.state            = .finalized;
    }

    /// Total TX-uri din toate sub-blocurile
    pub fn totalTxCount(self: *const KeyBlock) u32 {
        var total: u32 = 0;
        for (self.sub_blocks) |maybe_sb| {
            if (maybe_sb) |sb| total += sb.tx_count;
        }
        return total;
    }

    /// Latenta totala de la primul sub-bloc la finalizare (ms)
    pub fn latencyMs(self: *const KeyBlock) i64 {
        if (self.finalized_at_ms == 0) return 0;
        return self.finalized_at_ms - self.started_at_ms;
    }

    /// Cate sub-blocuri lipsesc
    pub fn missing(self: *const KeyBlock) u8 {
        return SUB_BLOCKS_PER_BLOCK - self.received;
    }

    fn calcSubMerkleRoot(self: *const KeyBlock) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (self.sub_blocks) |maybe_sb| {
            if (maybe_sb) |sb| {
                hasher.update(&sb.hash);
            } else {
                hasher.update(&([_]u8{0} ** 32)); // sub-bloc lipsa → zero hash
            }
        }
        var root: [32]u8 = undefined;
        hasher.final(&root);
        return root;
    }

    fn calcKeyHash(self: *const KeyBlock) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "kb:{d}:{d}", .{
            self.block_number, self.total_reward_sat,
        }) catch "";
        hasher.update(s);
        hasher.update(&self.sub_merkle_root);
        var h: [32]u8 = undefined;
        hasher.final(&h);
        return h;
    }

    pub fn printStatus(self: *const KeyBlock) void {
        std.debug.print(
            "[KEY-BLOCK #{d}] {d}/10 sub-blocks | TX: {d} | State: {s} | Latency: {d}ms\n",
            .{
                self.block_number, self.received,
                self.totalTxCount(), @tagName(self.state),
                self.latencyMs(),
            },
        );
    }
};

// ─── SubBlockEngine — orchestreaza ciclul 0.1s × 10 → 1s ────────────────────

pub const SubBlockEngine = struct {
    current_key_block: KeyBlock,
    block_number:      u32,
    sub_counter:       u8,       // 0-9, resetat la fiecare Key-Block
    miner_id:          []const u8,
    shard_id:          u8,
    allocator:         std.mem.Allocator,

    pub fn init(
        miner_id:  []const u8,
        shard_id:  u8,
        allocator: std.mem.Allocator,
    ) SubBlockEngine {
        return .{
            .current_key_block = KeyBlock.init(0),
            .block_number      = 0,
            .sub_counter       = 0,
            .miner_id          = miner_id,
            .shard_id          = shard_id,
            .allocator         = allocator,
        };
    }

    /// Creeaza si finalizeaza urmatorul sub-bloc (apelat la fiecare 0.1s)
    /// Returneaza Key-Block-ul complet daca cele 10 sub-blocuri sunt gata
    pub fn tick(
        self:        *SubBlockEngine,
        txs:         []Transaction,
        reward_sat:  u64,
    ) !?KeyBlock {
        var sb = SubBlock.init(
            self.allocator,
            self.sub_counter,
            self.block_number,
            self.shard_id,
            self.miner_id,
        );

        // Adauga TX-urile disponibile in sub-bloc
        for (txs) |tx| {
            sb.addTransaction(tx) catch break;
        }

        sb.finalize();

        const complete = try self.current_key_block.addSubBlock(sb);

        std.debug.print(
            "  [SUB #{d}/10] block={d} shard={d} txs={d} hash={x:0>4}\n",
            .{
                self.sub_counter + 1, self.block_number,
                self.shard_id, sb.tx_count,
                std.mem.readInt(u16, self.current_key_block.sub_blocks[self.sub_counter].?.hash[0..2], .big),
            },
        );

        self.sub_counter += 1;

        if (complete) {
            // Finalizeaza Key-Block
            self.current_key_block.finalize(reward_sat);
            self.current_key_block.printStatus();

            // Pregateste urmatorul ciclu
            const finished = self.current_key_block;
            self.block_number += 1;
            self.sub_counter = 0;
            self.current_key_block = KeyBlock.init(self.block_number);

            return finished;
        }

        return null;
    }
};

// ─── Teste ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "SubBlock — init si isValid" {
    var sb = SubBlock.init(testing.allocator, 3, 100, 2, "miner-1");
    defer sb.deinit();

    try testing.expectEqual(@as(u8, 3),   sb.sub_id);
    try testing.expectEqual(@as(u32, 100), sb.block_number);
    try testing.expectEqual(@as(u8, 2),   sb.shard_id);
    try testing.expect(sb.isValid());
}

test "SubBlock — sub_id invalid" {
    var sb = SubBlock.init(testing.allocator, 10, 0, 0, "miner-1"); // 10 e invalid
    defer sb.deinit();
    try testing.expect(!sb.isValid());
}

test "SubBlock — finalize calculeaza hash nenul" {
    var sb = SubBlock.init(testing.allocator, 0, 1, 0, "miner-1");
    defer sb.deinit();
    sb.finalize();
    // hash nu trebuie sa fie all-zero dupa finalize
    var all_zero = true;
    for (sb.hash) |b| { if (b != 0) { all_zero = false; break; } }
    try testing.expect(!all_zero);
}

test "KeyBlock — 10 sub-blocuri → complete" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var kb = KeyBlock.init(1);
    try testing.expectEqual(KeyBlockState.collecting, kb.state);

    for (0..10) |i| {
        var sb = SubBlock.init(arena.allocator(), @intCast(i), 1, 0, "miner-1");
        sb.finalize();
        const done = try kb.addSubBlock(sb);
        if (i < 9) {
            try testing.expect(!done);
        } else {
            try testing.expect(done); // al 10-lea → complet
        }
    }

    try testing.expectEqual(KeyBlockState.complete, kb.state);
    try testing.expectEqual(@as(u8, 0), kb.missing());
}

test "KeyBlock — finalize produce hash nenul" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var kb = KeyBlock.init(5);
    for (0..10) |i| {
        var sb = SubBlock.init(arena.allocator(), @intCast(i), 5, 0, "miner-1");
        sb.finalize();
        _ = try kb.addSubBlock(sb);
    }
    kb.finalize(8_333_333);

    try testing.expectEqual(KeyBlockState.finalized, kb.state);
    try testing.expectEqual(@as(u64, 8_333_333), kb.total_reward_sat);

    var all_zero = true;
    for (kb.key_hash) |b| { if (b != 0) { all_zero = false; break; } }
    try testing.expect(!all_zero);
}

test "KeyBlock — sub-bloc duplicat respins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var kb = KeyBlock.init(0);
    var sb0 = SubBlock.init(arena.allocator(), 0, 0, 0, "miner-1");
    sb0.finalize();
    _ = try kb.addSubBlock(sb0);

    var sb0_dup = SubBlock.init(arena.allocator(), 0, 0, 0, "miner-2"); // sub_id=0 din nou
    sb0_dup.finalize();
    const result = kb.addSubBlock(sb0_dup);
    try testing.expectError(error.DuplicateSubBlock, result);
}

test "SubBlockEngine — tick × 10 → KeyBlock returnat" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var engine = SubBlockEngine.init("miner-test", 0, arena.allocator());

    var kb_result: ?KeyBlock = null;
    for (0..10) |_| {
        kb_result = try engine.tick(&.{}, 8_333_333);
    }

    // Dupa 10 tick-uri trebuie sa avem un KeyBlock finalizat
    try testing.expect(kb_result != null);
    try testing.expectEqual(KeyBlockState.finalized, kb_result.?.state);
    try testing.expectEqual(@as(u32, 0), kb_result.?.block_number); // primul bloc
    try testing.expectEqual(@as(u32, 1), engine.block_number);      // urmatorul e pregatit
}
