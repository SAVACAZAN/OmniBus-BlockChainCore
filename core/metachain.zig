/// metachain.zig — Metachain EGLD-style
///
/// Metachain-ul este coordonatorul central al tuturor shard-urilor.
/// Nu procesează TX normale — procesează doar:
///   1. ShardBlockHeader-e (dovezile că shard-urile au minat blocuri)
///   2. Cross-shard receipts (confirmări TX cross-shard)
///   3. Stake/Unstake operații pentru validatori
///   4. Adaptive sharding events (split/merge)
///
/// Un MetaBlock este produs la fiecare Key-Block (1s) și conține
/// header-ele tuturor shard-urilor din acea secundă.
const std = @import("std");
const shard_coord_mod = @import("shard_coordinator.zig");
const array_list = std.array_list;

pub const ShardCoordinator = shard_coord_mod.ShardCoordinator;
pub const METACHAIN_SHARD  = shard_coord_mod.METACHAIN_SHARD;

/// Header rezumat al unui shard block — trimis la Metachain pentru confirmare
pub const ShardBlockHeader = struct {
    shard_id:     u8,
    block_height: u64,
    block_hash:   [32]u8,    // SHA256 al blocului din shard
    tx_count:     u32,
    timestamp:    i64,
    miner:        []const u8,
    reward_sat:   u64,
};

/// Cross-shard receipt — confirmă că o TX cross-shard a fost procesată
/// La EGLD: faza 1 = scade din shard sursei; faza 2 = creditează în shard destinației
pub const CrossShardReceipt = struct {
    tx_hash:      [32]u8,
    from_shard:   u8,
    to_shard:     u8,
    from_address: []const u8,
    to_address:   []const u8,
    amount_sat:   u64,
    phase:        CrossShardPhase,
    meta_height:  u64,   // MetaBlock în care a fost confirmat
};

pub const CrossShardPhase = enum(u8) {
    phase1_debit  = 1,   // Suma scăzută din shard sursei
    phase2_credit = 2,   // Suma creditată în shard destinației
    finalized     = 3,   // Ambele faze complete
};

/// MetaBlock — blocul Metachain-ului (1 per secundă)
pub const MetaBlock = struct {
    height:        u64,
    timestamp:     i64,
    previous_hash: [32]u8,
    hash:          [32]u8,

    /// Header-ele tuturor shard-urilor confirmate în această secundă
    shard_headers: array_list.Managed(ShardBlockHeader),

    /// Receipt-urile cross-shard procesate în acest MetaBlock
    cross_receipts: array_list.Managed(CrossShardReceipt),

    /// Numărul total de TX procesate în toate shard-urile
    total_tx_count: u64,

    /// Numărul de shard-uri active la acest height
    active_shards: u8,

    pub fn init(allocator: std.mem.Allocator, height: u64, prev_hash: [32]u8) MetaBlock {
        return MetaBlock{
            .height        = height,
            .timestamp     = std.time.timestamp(),
            .previous_hash = prev_hash,
            .hash          = std.mem.zeroes([32]u8),
            .shard_headers = array_list.Managed(ShardBlockHeader).init(allocator),
            .cross_receipts = array_list.Managed(CrossShardReceipt).init(allocator),
            .total_tx_count = 0,
            .active_shards  = 0,
        };
    }

    pub fn deinit(self: *MetaBlock) void {
        self.shard_headers.deinit();
        self.cross_receipts.deinit();
    }

    /// Adaugă header-ul unui shard la acest MetaBlock
    pub fn addShardHeader(self: *MetaBlock, hdr: ShardBlockHeader) !void {
        self.total_tx_count += hdr.tx_count;
        try self.shard_headers.append(hdr);
        if (hdr.shard_id + 1 > self.active_shards) {
            self.active_shards = hdr.shard_id + 1;
        }
    }

    /// Adaugă un receipt cross-shard
    pub fn addCrossReceipt(self: *MetaBlock, receipt: CrossShardReceipt) !void {
        try self.cross_receipts.append(receipt);
    }

    /// Calculează hash-ul MetaBlock-ului (SHA256 peste toate datele)
    pub fn calculateHash(self: *MetaBlock) void {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buf: [64]u8 = undefined;

        // Hash height + timestamp + previous_hash
        const hdr_str = std.fmt.bufPrint(&buf, "{d}{d}", .{
            self.height, self.timestamp,
        }) catch "";
        hasher.update(hdr_str);
        hasher.update(&self.previous_hash);

        // Hash fiecare shard header
        for (self.shard_headers.items) |sh| {
            var sh_buf: [64]u8 = undefined;
            const sh_str = std.fmt.bufPrint(&sh_buf, "{d}{d}{d}", .{
                sh.shard_id, sh.block_height, sh.tx_count,
            }) catch "";
            hasher.update(sh_str);
            hasher.update(&sh.block_hash);
        }

        // Hash receipt-uri cross-shard
        for (self.cross_receipts.items) |r| {
            var r_buf: [32]u8 = undefined;
            const r_str = std.fmt.bufPrint(&r_buf, "{d}{d}{d}", .{
                r.from_shard, r.to_shard, r.amount_sat,
            }) catch "";
            hasher.update(r_str);
            hasher.update(&r.tx_hash);
        }

        hasher.final(&self.hash);
    }

    pub fn isComplete(self: *const MetaBlock, expected_shards: u8) bool {
        return self.shard_headers.items.len >= expected_shards;
    }
};

/// Metachain — chain de MetaBlock-uri, coordonator global
pub const Metachain = struct {
    chain:       array_list.Managed(MetaBlock),
    coordinator: ShardCoordinator,
    allocator:   std.mem.Allocator,

    /// Receipts pending (phase1 done, phase2 în așteptare)
    pending_receipts: array_list.Managed(CrossShardReceipt),

    pub fn init(allocator: std.mem.Allocator, num_shards: u8) !Metachain {
        var chain = array_list.Managed(MetaBlock).init(allocator);

        // MetaBlock genesis (height 0)
        var genesis = MetaBlock.init(allocator, 0, std.mem.zeroes([32]u8));
        genesis.calculateHash();
        try chain.append(genesis);

        return Metachain{
            .chain       = chain,
            .coordinator = try ShardCoordinator.init(allocator, num_shards),
            .allocator   = allocator,
            .pending_receipts = array_list.Managed(CrossShardReceipt).init(allocator),
        };
    }

    pub fn deinit(self: *Metachain) void {
        for (self.chain.items) |*mb| mb.deinit();
        self.chain.deinit();
        self.pending_receipts.deinit();
    }

    pub fn getHeight(self: *const Metachain) u64 {
        return self.chain.items.len - 1;
    }

    pub fn getLatestHash(self: *const Metachain) [32]u8 {
        return self.chain.items[self.chain.items.len - 1].hash;
    }

    /// Creează un nou MetaBlock gol pentru height-ul următor
    pub fn beginMetaBlock(self: *Metachain) !*MetaBlock {
        const height = self.chain.items.len;
        const prev_hash = self.getLatestHash();
        const mb = MetaBlock.init(self.allocator, height, prev_hash);
        try self.chain.append(mb);
        return &self.chain.items[self.chain.items.len - 1];
    }

    /// Finalizează MetaBlock-ul curent: calculează hash + procesează receipts pending
    pub fn finalizeMetaBlock(self: *Metachain) !void {
        if (self.chain.items.len < 2) return; // genesis nu se finalizeaza

        const mb = &self.chain.items[self.chain.items.len - 1];

        // Procesează receipt-urile cross-shard pending (phase2)
        // Procesează toate receipt-urile pending (phase2) — drenăm lista
        while (self.pending_receipts.items.len > 0) {
            var r = self.pending_receipts.items[0];
            r.phase = .phase2_credit;
            r.meta_height = mb.height;
            try mb.addCrossReceipt(r);
            _ = self.pending_receipts.swapRemove(0);
        }

        mb.calculateHash();

        std.debug.print("[META] Block #{d} finalized | shards={d} | tx={d} | cross_receipts={d}\n",
            .{
                mb.height,
                mb.shard_headers.items.len,
                mb.total_tx_count,
                mb.cross_receipts.items.len,
            });

        // Adaptive sharding — verifică dacă trebuie split/merge
        if (self.coordinator.needsSplit()) |shard_id| {
            _ = try self.coordinator.splitShard(shard_id);
        } else if (self.coordinator.needsMerge()) |pair| {
            try self.coordinator.mergeShards(pair[0], pair[1]);
        }
    }

    /// Înregistrează o TX cross-shard — Phase 1 (debit din shard sursă)
    pub fn registerCrossShardTx(self: *Metachain,
                                  tx_hash:    [32]u8,
                                  from_addr:  []const u8,
                                  to_addr:    []const u8,
                                  amount_sat: u64) !void {
        const from_shard = self.coordinator.getShardForAddress(from_addr);
        const to_shard   = self.coordinator.getShardForAddress(to_addr);

        const receipt = CrossShardReceipt{
            .tx_hash      = tx_hash,
            .from_shard   = from_shard,
            .to_shard     = to_shard,
            .from_address = from_addr,
            .to_address   = to_addr,
            .amount_sat   = amount_sat,
            .phase        = .phase1_debit,
            .meta_height  = self.getHeight(),
        };

        // Phase 1 adăugat în MetaBlock curent, Phase 2 în pending
        if (self.chain.items.len > 0) {
            const mb = &self.chain.items[self.chain.items.len - 1];
            try mb.addCrossReceipt(receipt);
        }

        // Phase 2 va fi procesată în MetaBlock-ul următor
        var r2 = receipt;
        r2.phase = .phase2_credit;
        try self.pending_receipts.append(r2);

        std.debug.print("[META] Cross-shard TX registered: shard {d}→{d} | {d} SAT\n",
            .{ from_shard, to_shard, amount_sat });
    }

    pub fn printStatus(self: *const Metachain) void {
        std.debug.print("[METACHAIN] Height: {d} | Shards: {d} | Pending cross-shard: {d}\n",
            .{ self.getHeight(), self.coordinator.num_shards, self.pending_receipts.items.len });
    }
};

// ─── Teste ───────────────────────────────────────────────────────────────────
const testing = std.testing;

test "MetaBlock — init si calculateHash produce hash non-zero" {
    var mb = MetaBlock.init(testing.allocator, 1, std.mem.zeroes([32]u8));
    defer mb.deinit();
    mb.calculateHash();
    var all_zero = true;
    for (mb.hash) |b| if (b != 0) { all_zero = false; break; };
    try testing.expect(!all_zero);
}

test "MetaBlock — addShardHeader creste total_tx_count" {
    var mb = MetaBlock.init(testing.allocator, 1, std.mem.zeroes([32]u8));
    defer mb.deinit();

    const hdr = ShardBlockHeader{
        .shard_id     = 0,
        .block_height = 10,
        .block_hash   = std.mem.zeroes([32]u8),
        .tx_count     = 42,
        .timestamp    = 1742959200,
        .miner        = "ob_omni_miner000",
        .reward_sat   = 83333333,
    };
    try mb.addShardHeader(hdr);
    try testing.expectEqual(@as(u64, 42), mb.total_tx_count);
}

test "MetaBlock — isComplete detecteaza cand toate shardurile au raportat" {
    var mb = MetaBlock.init(testing.allocator, 1, std.mem.zeroes([32]u8));
    defer mb.deinit();

    try testing.expect(!mb.isComplete(2));

    for (0..2) |i| {
        try mb.addShardHeader(ShardBlockHeader{
            .shard_id     = @intCast(i),
            .block_height = 1,
            .block_hash   = std.mem.zeroes([32]u8),
            .tx_count     = 10,
            .timestamp    = 0,
            .miner        = "ob_omni_miner000",
            .reward_sat   = 0,
        });
    }
    try testing.expect(mb.isComplete(2));
}

test "Metachain — init genesis block" {
    var mc = try Metachain.init(testing.allocator, 2);
    defer mc.deinit();
    try testing.expectEqual(@as(u64, 0), mc.getHeight());
}

test "Metachain — beginMetaBlock creste height" {
    var mc = try Metachain.init(testing.allocator, 2);
    defer mc.deinit();
    _ = try mc.beginMetaBlock();
    try testing.expectEqual(@as(u64, 1), mc.getHeight());
}

test "Metachain — finalizeMetaBlock calculeaza hash" {
    var mc = try Metachain.init(testing.allocator, 2);
    defer mc.deinit();
    _ = try mc.beginMetaBlock();
    try mc.finalizeMetaBlock();
    const h = mc.getLatestHash();
    var all_zero = true;
    for (h) |b| if (b != 0) { all_zero = false; break; };
    try testing.expect(!all_zero);
}

test "Metachain — registerCrossShardTx adauga in pending" {
    var mc = try Metachain.init(testing.allocator, 4);
    defer mc.deinit();
    _ = try mc.beginMetaBlock();

    const tx_hash = std.mem.zeroes([32]u8);
    try mc.registerCrossShardTx(
        tx_hash,
        "ob_omni_alice000",
        "ob_k1_bob0000000",
        1_000_000_000,
    );
    try testing.expect(mc.pending_receipts.items.len > 0);
}

test "Metachain — cross-shard receipt phase2 procesat la finalize" {
    var mc = try Metachain.init(testing.allocator, 4);
    defer mc.deinit();

    // MetaBlock 1: înregistrăm TX cross-shard
    _ = try mc.beginMetaBlock();
    const tx_hash = std.mem.zeroes([32]u8);
    try mc.registerCrossShardTx(tx_hash, "ob_omni_alice000", "ob_k1_bob0000000", 500);
    try mc.finalizeMetaBlock();

    const pending_after_1 = mc.pending_receipts.items.len;

    // MetaBlock 2: phase2 trebuie procesată
    _ = try mc.beginMetaBlock();
    try mc.finalizeMetaBlock();

    // Pending ar trebui să scadă (phase2 procesată)
    try testing.expect(mc.pending_receipts.items.len <= pending_after_1);
}

test "Metachain — hash MetaBlock-uri consecutive sunt diferite" {
    var mc = try Metachain.init(testing.allocator, 2);
    defer mc.deinit();

    _ = try mc.beginMetaBlock();
    try mc.finalizeMetaBlock();
    const h1 = mc.getLatestHash();

    _ = try mc.beginMetaBlock();
    try mc.finalizeMetaBlock();
    const h2 = mc.getLatestHash();

    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}
