// core/fee_estimator.zig - P1.1
const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const FeeSample = struct {
    fee_rate: u64, // sat/vbyte
    timestamp: u64, // unix seconds
    block_height: u64,
};

pub const FeeEstimator = struct {
    allocator: Allocator,
    sample_window_secs: u64, // 3600 = 1 hour
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
    
    pub fn addSample(self: *FeeEstimator, fee_rate: u64, timestamp: u64, block_height: u64) !void {
        try self.samples.append(FeeSample{
            .fee_rate = fee_rate,
            .timestamp = timestamp,
            .block_height = block_height,
        });
        self.pruneOldSamples(timestamp);
    }
    
    fn pruneOldSamples(self: *FeeEstimator, current_time: u64) void {
        const cutoff = current_time - self.sample_window_secs;
        var i: usize = 0;
        while (i < self.samples.items.len) {
            if (self.samples.items[i].timestamp < cutoff) {
                _ = self.samples.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
    
    pub fn estimate(self: *const FeeEstimator, target_blocks: u32) u64 {
        if (self.samples.items.len == 0) {
            return 10; // default fallback
        }
        
        // Sort by fee_rate for percentile calculation
        var sorted = ArrayList(u64).init(self.allocator);
        defer sorted.deinit();
        for (self.samples.items) |sample| {
            sorted.append(sample.fee_rate) catch continue;
        }
        std.sort.sort(u64, sorted.items, {}, std.sort.asc(u64));
        
        const idx = @min(@as(usize, @intCast((target_blocks * 10) / 100)), sorted.items.len - 1);
        return sorted.items[idx];
    }
    
    pub fn estimatePriority(self: *const FeeEstimator) struct { slow: u64, normal: u64, fast: u64 } {
        return .{
            .slow = self.estimate(6),   // ~1 hour
            .normal = self.estimate(2), // ~10 minutes
            .fast = self.estimate(1),   // ~5 minutes
        };
    }
};

test "FeeEstimator percentile calculation" {
    var allocator = std.testing.allocator;
    var estimator = FeeEstimator.init(allocator, 3600);
    defer estimator.deinit();
    
    const now = std.time.timestamp();
    // Add 100 samples
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