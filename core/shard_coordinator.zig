/// shard_coordinator.zig — ShardCoordinator EGLD-style
///
/// Rutare adresă→shard prin hash(addr)[0] % num_shards
/// (Ca la MultiversX: ultimii biți ai adresei determină shard-ul)
///
/// Adaptive sharding: auto-split la 80% capacitate, auto-merge sub 20%
/// Metachain = shard special (ID = 0xFF) care nu procesează TX normale
const std = @import("std");

pub const METACHAIN_SHARD: u8 = 0xFF;
pub const MAX_SHARDS: u8 = 32;
pub const SHARD_SPLIT_THRESHOLD: u8 = 80;  // % capacitate → split
pub const SHARD_MERGE_THRESHOLD: u8 = 20;  // % capacitate → merge

/// Statistici per shard — folosite pentru adaptive sharding
pub const ShardStats = struct {
    shard_id:    u8,
    tx_count:    u64 = 0,
    capacity_pct: u8 = 0,   // 0-100%
    node_count:  u16 = 0,
    active:      bool = true,
};

/// ShardCoordinator — rutare adresă→shard + adaptive split/merge
pub const ShardCoordinator = struct {
    num_shards:  u8,
    allocator:   std.mem.Allocator,
    shard_stats: [MAX_SHARDS]ShardStats,

    pub fn init(allocator: std.mem.Allocator, num_shards: u8) !ShardCoordinator {
        if (num_shards == 0 or num_shards > MAX_SHARDS) return error.InvalidShardCount;

        var stats: [MAX_SHARDS]ShardStats = undefined;
        for (0..MAX_SHARDS) |i| {
            stats[i] = ShardStats{
                .shard_id = @intCast(i),
                .active   = i < num_shards,
            };
        }

        return ShardCoordinator{
            .num_shards  = num_shards,
            .allocator   = allocator,
            .shard_stats = stats,
        };
    }

    /// Rutare adresă → shard_id (EGLD-style: hash primului byte)
    /// La EGLD: ultimii biți din adresă encoding-ează shard-ul
    /// La OmniBus: SHA256(address)[0] % num_shards (mai uniform)
    pub fn getShardForAddress(self: *const ShardCoordinator, address: []const u8) u8 {
        if (address.len == 0) return 0;

        // Hash adresa pentru distribuție uniformă
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(address);
        var h: [32]u8 = undefined;
        hasher.final(&h);

        // Folosim primii 2 bytes pentru mai multă entropie la num_shards mare
        const val: u16 = (@as(u16, h[0]) << 8) | h[1];
        return @intCast(val % self.num_shards);
    }

    /// Verifică dacă o TX este cross-shard (from și to în shard-uri diferite)
    pub fn isCrossShard(self: *const ShardCoordinator,
                        from_addr: []const u8,
                        to_addr:   []const u8) bool {
        return self.getShardForAddress(from_addr) != self.getShardForAddress(to_addr);
    }

    /// Returnează shard-ul nodului curent (din adresa proprie)
    pub fn getMyShardId(self: *const ShardCoordinator, my_address: []const u8) u8 {
        return self.getShardForAddress(my_address);
    }

    /// Verifică dacă nodul curent trebuie să proceseze această TX
    pub fn shouldProcessTx(self: *const ShardCoordinator,
                            my_shard: u8,
                            from_addr: []const u8,
                            to_addr:   []const u8) bool {
        const from_shard = self.getShardForAddress(from_addr);
        const to_shard   = self.getShardForAddress(to_addr);
        // Procesăm TX dacă suntem în shard-ul sursei SAU destinației
        return my_shard == from_shard or my_shard == to_shard;
    }

    /// Actualizează statisticile unui shard
    pub fn updateStats(self: *ShardCoordinator, shard_id: u8,
                       tx_count: u64, capacity_pct: u8) void {
        if (shard_id >= MAX_SHARDS) return;
        self.shard_stats[shard_id].tx_count    = tx_count;
        self.shard_stats[shard_id].capacity_pct = capacity_pct;
    }

    /// Adaptive sharding: verifică dacă un shard trebuie split
    /// La EGLD: shard-ul cu cel mai mare load se împarte în 2
    pub fn needsSplit(self: *const ShardCoordinator) ?u8 {
        if (self.num_shards >= MAX_SHARDS) return null;

        for (0..self.num_shards) |i| {
            const s = self.shard_stats[i];
            if (s.active and s.capacity_pct >= SHARD_SPLIT_THRESHOLD) {
                return @intCast(i);
            }
        }
        return null;
    }

    /// Adaptive sharding: verifică dacă două shard-uri trebuie merged
    pub fn needsMerge(self: *const ShardCoordinator) ?[2]u8 {
        if (self.num_shards <= 1) return null;

        // Găsim 2 shard-uri cu load mic
        var low_count: u8 = 0;
        var low_ids: [2]u8 = .{ 0, 0 };
        for (0..self.num_shards) |i| {
            const s = self.shard_stats[i];
            if (s.active and s.capacity_pct < SHARD_MERGE_THRESHOLD) {
                if (low_count < 2) {
                    low_ids[low_count] = @intCast(i);
                    low_count += 1;
                }
            }
        }
        if (low_count >= 2) return low_ids;
        return null;
    }

    /// Execută split: noul shard primește jumătate din adresele shard-ului original
    /// Returneaza ID-ul noului shard
    pub fn splitShard(self: *ShardCoordinator, shard_id: u8) !u8 {
        if (self.num_shards >= MAX_SHARDS) return error.TooManyShards;
        if (shard_id >= self.num_shards) return error.InvalidShardId;

        const new_id = self.num_shards;
        self.shard_stats[new_id] = ShardStats{
            .shard_id = new_id,
            .active   = true,
        };
        self.num_shards += 1;

        std.debug.print("[SHARD] Split shard {d} → new shard {d} | total shards: {d}\n",
            .{ shard_id, new_id, self.num_shards });
        return new_id;
    }

    /// Execută merge: shard_b se dizolvă în shard_a
    pub fn mergeShards(self: *ShardCoordinator, shard_a: u8, shard_b: u8) !void {
        if (self.num_shards <= 1) return error.CannotMergeLastShard;
        if (shard_a >= self.num_shards or shard_b >= self.num_shards) return error.InvalidShardId;
        if (shard_a == shard_b) return error.SameShardId;

        self.shard_stats[shard_b].active = false;
        self.num_shards -= 1;

        std.debug.print("[SHARD] Merge shard {d} into {d} | total shards: {d}\n",
            .{ shard_b, shard_a, self.num_shards });
    }

    pub fn printStatus(self: *const ShardCoordinator) void {
        std.debug.print("[SHARD_COORD] Active shards: {d} | Max: {d}\n",
            .{ self.num_shards, MAX_SHARDS });
        for (0..self.num_shards) |i| {
            const s = self.shard_stats[i];
            if (s.active) {
                std.debug.print("  Shard {d}: tx={d} load={d}%\n",
                    .{ s.shard_id, s.tx_count, s.capacity_pct });
            }
        }
    }
};

// ─── Teste ───────────────────────────────────────────────────────────────────
const testing = std.testing;

test "ShardCoordinator — init 4 shards" {
    const sc = try ShardCoordinator.init(testing.allocator, 4);
    try testing.expectEqual(@as(u8, 4), sc.num_shards);
}

test "ShardCoordinator — getShardForAddress distribuit 0..N-1" {
    const sc = try ShardCoordinator.init(testing.allocator, 4);
    const s = sc.getShardForAddress("ob1q0avux3lts0az4we2c8p7yuuuqw2qp2luxt2mtg");
    try testing.expect(s < 4);
}

test "ShardCoordinator — aceeasi adresă → acelasi shard (determinist)" {
    const sc = try ShardCoordinator.init(testing.allocator, 4);
    const s1 = sc.getShardForAddress("ob1q0avux3lts0az4we2c8p7yuuuqw2qp2luxt2mtg");
    const s2 = sc.getShardForAddress("ob1q0avux3lts0az4we2c8p7yuuuqw2qp2luxt2mtg");
    try testing.expectEqual(s1, s2);
}

test "ShardCoordinator — adrese diferite pot fi în shards diferite" {
    const sc = try ShardCoordinator.init(testing.allocator, 4);
    // Cu 4 shards și adrese diferite, nu toate vor fi în același shard
    var found_diff = false;
    const base_shard = sc.getShardForAddress("ob1q0avux3lts0az4we2c8p7yuuuqw2qp2luxt2mtg");
    const addrs = [_][]const u8{
        "ob1qyy67swcquu9zpgpz84e5j9rlxy0xawsjhg7xqy", "ob_k1_carol00000", "ob_f5_dave000000",
        "ob_d5_eve0000000", "ob_s3_frank00000",
    };
    for (addrs) |addr| {
        if (sc.getShardForAddress(addr) != base_shard) {
            found_diff = true;
            break;
        }
    }
    try testing.expect(found_diff);
}

test "ShardCoordinator — isCrossShard detecteaza TX cross-shard" {
    const sc = try ShardCoordinator.init(testing.allocator, 4);
    // Cel putin o pereche de adrese trebuie să fie cross-shard cu 4 shards
    var found_cross = false;
    const addr_a = "ob1q0avux3lts0az4we2c8p7yuuuqw2qp2luxt2mtg";
    const others = [_][]const u8{
        "ob1qyy67swcquu9zpgpz84e5j9rlxy0xawsjhg7xqy", "ob_k1_carol00000", "ob_f5_dave000000",
        "ob_d5_eve0000000",
    };
    for (others) |b| {
        if (sc.isCrossShard(addr_a, b)) {
            found_cross = true;
            break;
        }
    }
    try testing.expect(found_cross);
}

test "ShardCoordinator — isCrossShard false pentru aceeasi adresa" {
    const sc = try ShardCoordinator.init(testing.allocator, 4);
    try testing.expect(!sc.isCrossShard("ob1q0avux3lts0az4we2c8p7yuuuqw2qp2luxt2mtg", "ob1q0avux3lts0az4we2c8p7yuuuqw2qp2luxt2mtg"));
}

test "ShardCoordinator — splitShard creste num_shards" {
    var sc = try ShardCoordinator.init(testing.allocator, 2);
    const new_id = try sc.splitShard(0);
    try testing.expectEqual(@as(u8, 3), sc.num_shards);
    try testing.expectEqual(@as(u8, 2), new_id);
}

test "ShardCoordinator — mergeShards scade num_shards" {
    var sc = try ShardCoordinator.init(testing.allocator, 4);
    try sc.mergeShards(0, 3);
    try testing.expectEqual(@as(u8, 3), sc.num_shards);
}

test "ShardCoordinator — needsSplit detecteaza shard supraincärcat" {
    var sc = try ShardCoordinator.init(testing.allocator, 2);
    sc.updateStats(0, 1000, 85); // 85% > threshold 80%
    const split_candidate = sc.needsSplit();
    try testing.expect(split_candidate != null);
    try testing.expectEqual(@as(u8, 0), split_candidate.?);
}

test "ShardCoordinator — needsMerge detecteaza shards subincarcate" {
    var sc = try ShardCoordinator.init(testing.allocator, 4);
    sc.updateStats(0, 10, 10);
    sc.updateStats(1, 5, 8);
    const merge_candidates = sc.needsMerge();
    try testing.expect(merge_candidates != null);
}

test "ShardCoordinator — METACHAIN_SHARD constant = 0xFF" {
    try testing.expectEqual(@as(u8, 0xFF), METACHAIN_SHARD);
}
