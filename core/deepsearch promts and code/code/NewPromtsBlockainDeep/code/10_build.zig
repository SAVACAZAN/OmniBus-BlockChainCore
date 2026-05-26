// ============================================
// 1. core/fee_estimator.zig
// ============================================
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const time = std.time;

pub const FeeSample = struct {
    fee_rate: u64, // sat/vbyte
    timestamp: i64,
    block_height: u64,
};

pub const FeeEstimator = struct {
    allocator: Allocator,
    sample_window_secs: u64,
    samples: ArrayList(FeeSample),
    
    pub fn init(allocator: Allocator, window_secs: u64) FeeEstimator {
        return FeeEstimator{
            .allocator = allocator,
            .sample_window_secs = window_secs,
            .samples = ArrayList(FeeSample).init(allocator),
        };
    }
    
    pub fn deinit(self: *FeeEstimator) void {
        self.samples.deinit();
    }
    
    pub fn addSample(self: *FeeEstimator, fee_rate: u64, timestamp: i64, block_height: u64) !void {
        try self.samples.append(FeeSample{
            .fee_rate = fee_rate,
            .timestamp = timestamp,
            .block_height = block_height,
        });
        self.pruneOldSamples(timestamp);
    }
    
    fn pruneOldSamples(self: *FeeEstimator, current_time: i64) void {
        const cutoff = current_time - @as(i64, @intCast(self.sample_window_secs));
        var i: usize = 0;
        while (i < self.samples.items.len) {
            if (self.samples.items[i].timestamp < cutoff) {
                _ = self.samples.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
    
    pub fn estimatePercentile(self: *const FeeEstimator, percentile: u8) u64 {
        if (self.samples.items.len == 0) return 10;
        
        var sorted = ArrayList(u64).init(self.allocator);
        defer sorted.deinit();
        for (self.samples.items) |sample| {
            sorted.append(sample.fee_rate) catch continue;
        }
        std.sort.sort(u64, sorted.items, {}, std.sort.asc(u64));
        
        const idx = @min(@as(usize, @intCast((percentile * sorted.items.len) / 100)), sorted.items.len - 1);
        return sorted.items[idx];
    }
    
    pub fn estimate(self: *const FeeEstimator, target_blocks: u32) u64 {
        // target_blocks: 1=fast, 2=normal, 6=slow
        const percentile = switch (target_blocks) {
            0...1 => 90,  // fast: P90
            2...3 => 50,  // normal: P50
            else => 10,   // slow: P10
        };
        return self.estimatePercentile(percentile);
    }
    
    pub fn getPriorityFees(self: *const FeeEstimator) struct { slow: u64, normal: u64, fast: u64 } {
        return .{
            .slow = self.estimate(6),
            .normal = self.estimate(2),
            .fast = self.estimate(1),
        };
    }
};

test "FeeEstimator basic" {
    var allocator = std.testing.allocator;
    var estimator = FeeEstimator.init(allocator, 3600);
    defer estimator.deinit();
    
    const now = time.timestamp();
    for (0..100) |i| {
        try estimator.addSample(@intCast(i + 1), now, @intCast(i));
    }
    
    const slow = estimator.estimate(6);
    const normal = estimator.estimate(2);
    const fast = estimator.estimate(1);
    
    try std.testing.expect(slow >= 10);
    try std.testing.expect(normal >= 50);
    try std.testing.expect(fast >= 90);
}