//! Fee estimator dinamic pentru OmniBus.
//!
//! Înlocuiește FeeEstimator-ul minimal din chain_config.zig: in loc de "fee = f(mempool size)",
//! ține o fereastră alunecătoare de eșantioane fee/size din TX-uri confirmate, calculează
//! percentile (P10/P50/P90) pentru cele 3 priority classes:
//!   - SLOW   = P10 — confirmare în ~1h (6 blocks)
//!   - NORMAL = P50 — confirmare în ~10min (1 block)
//!   - FAST   = P90 — confirmare next block
//!
//! Sample submission e responsabilitatea mempool/block confirmation handler-ului:
//! la fiecare TX confirmat, apel `estimator.recordSample(fee_rate, observed_at_height)`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Priority = enum {
    slow,
    normal,
    fast,
};

pub const FeeSample = struct {
    /// Fee rate observat — în sat/vbyte (sau orice unitate consistentă).
    fee_rate: u64,
    /// Înălțimea blocului în care a fost confirmat. Folosit la sliding window cleanup.
    block_height: u64,
};

pub const FeeEstimator = struct {
    allocator: Allocator,
    /// Câte blocuri în trecut păstrăm. Default: 144 (~1 zi pe Bitcoin, ~24h pe OmniBus 10s).
    window_blocks: u64 = 144,
    samples: std.ArrayList(FeeSample) = .empty,
    /// Fee minim absolut returnat (anti-spam, evită fee=0 când mempool e gol).
    min_fee_rate: u64 = 1,

    pub fn init(allocator: Allocator) FeeEstimator {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FeeEstimator) void {
        self.samples.deinit(self.allocator);
    }

    /// Adaugă o observație și curăță samples care au căzut din fereastră.
    pub fn recordSample(self: *FeeEstimator, fee_rate: u64, current_height: u64) !void {
        try self.samples.append(self.allocator, .{
            .fee_rate = fee_rate,
            .block_height = current_height,
        });
        self.evictOld(current_height);
    }

    fn evictOld(self: *FeeEstimator, current_height: u64) void {
        const cutoff = if (current_height > self.window_blocks)
            current_height - self.window_blocks
        else
            0;
        // Filtru in-place: păstrăm doar samples cu height >= cutoff.
        var write_idx: usize = 0;
        for (self.samples.items) |s| {
            if (s.block_height >= cutoff) {
                self.samples.items[write_idx] = s;
                write_idx += 1;
            }
        }
        self.samples.shrinkRetainingCapacity(write_idx);
    }

    /// Estimează fee_rate pentru priority dată. Returnează min_fee_rate dacă nu avem samples.
    pub fn estimate(self: *FeeEstimator, priority: Priority) !u64 {
        if (self.samples.items.len == 0) return self.min_fee_rate;

        // Copie + sort ascending după fee_rate.
        const sorted = try self.allocator.alloc(u64, self.samples.items.len);
        defer self.allocator.free(sorted);
        for (self.samples.items, 0..) |s, i| sorted[i] = s.fee_rate;
        std.mem.sort(u64, sorted, {}, std.sort.asc(u64));

        const percentile: f64 = switch (priority) {
            .slow => 0.10,
            .normal => 0.50,
            .fast => 0.90,
        };

        // Nearest-rank: idx = ceil(p * N) - 1, în [0, N-1].
        const n: f64 = @floatFromInt(sorted.len);
        var idx: usize = @intFromFloat(@ceil(percentile * n));
        if (idx == 0) idx = 1;
        if (idx > sorted.len) idx = sorted.len;
        const rate = sorted[idx - 1];

        return @max(rate, self.min_fee_rate);
    }

    pub fn sampleCount(self: *const FeeEstimator) usize {
        return self.samples.items.len;
    }
};

// ============================================================
// Tests
// ============================================================

test "no samples returns min_fee_rate" {
    var fe = FeeEstimator.init(std.testing.allocator);
    defer fe.deinit();

    try std.testing.expectEqual(@as(u64, 1), try fe.estimate(.slow));
    try std.testing.expectEqual(@as(u64, 1), try fe.estimate(.normal));
    try std.testing.expectEqual(@as(u64, 1), try fe.estimate(.fast));
}

test "percentiles return increasing values" {
    var fe = FeeEstimator.init(std.testing.allocator);
    defer fe.deinit();

    // 100 samples cu fee_rate 1..100
    var i: u64 = 1;
    while (i <= 100) : (i += 1) {
        try fe.recordSample(i, 200);
    }

    const slow = try fe.estimate(.slow);
    const normal = try fe.estimate(.normal);
    const fast = try fe.estimate(.fast);

    try std.testing.expectEqual(@as(u64, 10), slow);
    try std.testing.expectEqual(@as(u64, 50), normal);
    try std.testing.expectEqual(@as(u64, 90), fast);
}

test "old samples evicted outside window" {
    var fe = FeeEstimator.init(std.testing.allocator);
    fe.window_blocks = 10;
    defer fe.deinit();

    // Samples vechi (height 0-5)
    var i: u64 = 0;
    while (i < 5) : (i += 1) {
        try fe.recordSample(1000, i);
    }

    // Samples noi (height 100, mult înainte de fereastra height 100-window=90)
    try fe.recordSample(50, 100);
    try fe.recordSample(60, 100);

    // După push la 100, samples cu height < 90 trebuie să fie eliminate.
    try std.testing.expectEqual(@as(usize, 2), fe.sampleCount());
    try std.testing.expectEqual(@as(u64, 50), try fe.estimate(.slow));
}

test "min_fee_rate floor enforced even with low samples" {
    var fe = FeeEstimator.init(std.testing.allocator);
    fe.min_fee_rate = 5;
    defer fe.deinit();

    try fe.recordSample(1, 100);
    try fe.recordSample(2, 100);
    try fe.recordSample(3, 100);

    try std.testing.expect(try fe.estimate(.slow) >= 5);
    try std.testing.expect(try fe.estimate(.normal) >= 5);
}

test "single sample: all percentiles return that value" {
    var fe = FeeEstimator.init(std.testing.allocator);
    defer fe.deinit();

    try fe.recordSample(42, 1);
    try std.testing.expectEqual(@as(u64, 42), try fe.estimate(.slow));
    try std.testing.expectEqual(@as(u64, 42), try fe.estimate(.normal));
    try std.testing.expectEqual(@as(u64, 42), try fe.estimate(.fast));
}
