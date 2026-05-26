//! Solana Commitment Levels and Confirmation Strategies

const std = @import("std");
const time = std.time;

// ============================================================
// Commitment Levels
// ============================================================

pub const Commitment = enum {
    /// Processed: After basic validation (fastest, least reliable)
    processed,
    
    /// Confirmed: After 1 confirmation (good balance of speed/reliability)
    confirmed,
    
    /// Finalized: After 32 confirmations (slowest, most reliable)
    finalized,
    
    /// Max: Same as finalized (alias)
    max,
    
    pub fn toString(self: Commitment) []const u8 {
        return switch (self) {
            .processed => "processed",
            .confirmed => "confirmed",
            .finalized => "finalized",
            .max => "finalized",
        };
    }
    
    /// Minimum confirmations needed
    pub fn minConfirmations(self: Commitment) u32 {
        return switch (self) {
            .processed => 0,
            .confirmed => 1,
            .finalized => 32,
            .max => 32,
        };
    }
    
    /// Estimated time in seconds
    pub fn estimatedTime(self: Commitment) u64 {
        // Average Solana block time ~0.4 seconds
        return @as(u64, @intCast(@as(f64, @floatFromInt(self.minConfirmations())) * 0.4));
    }
};

// ============================================================
// Confirmation Strategy
// ============================================================

pub const ConfirmationStrategy = struct {
    commitment: Commitment,
    timeout_ms: u64,
    poll_interval_ms: u64,
    
    pub fn standard(commitment: Commitment) ConfirmationStrategy {
        return .{
            .commitment = commitment,
            .timeout_ms = 30000, // 30 seconds
            .poll_interval_ms = 500, // 0.5 seconds
        };
    }
    
    pub fn fast() ConfirmationStrategy {
        return .{
            .commitment = .processed,
            .timeout_ms = 5000,
            .poll_interval_ms = 200,
        };
    }
    
    pub fn safe() ConfirmationStrategy {
        return .{
            .commitment = .finalized,
            .timeout_ms = 60000,
            .poll_interval_ms = 1000,
        };
    }
    
    pub fn custom(commitment: Commitment, timeout_ms: u64, poll_interval_ms: u64) ConfirmationStrategy {
        return .{
            .commitment = commitment,
            .timeout_ms = timeout_ms,
            .poll_interval_ms = poll_interval_ms,
        };
    }
};

// ============================================================
// Transaction Confirmation Tracker
// ============================================================

pub const ConfirmationTracker = struct {
    allocator: std.mem.Allocator,
    strategy: ConfirmationStrategy,
    signature: []u8,
    status: Status,
    confirmations: u32,
    slot: u64,
    
    pub const Status = enum {
        pending,
        confirmed,
        finalized,
        failed,
        timeout,
    };
    
    pub fn init(allocator: std.mem.Allocator, strategy: ConfirmationStrategy, signature: []const u8) ConfirmationTracker {
        return .{
            .allocator = allocator,
            .strategy = strategy,
            .signature = allocator.dupe(u8, signature) catch unreachable,
            .status = .pending,
            .confirmations = 0,
            .slot = 0,
        };
    }
    
    pub fn deinit(self: *ConfirmationTracker) void {
        self.allocator.free(self.signature);
    }
    
    /// Update status based on RPC response
    pub fn update(self: *ConfirmationTracker, confirmations: u64, err: ?[]const u8, slot: u64) void {
        if (err != null) {
            self.status = .failed;
            return;
        }
        
        self.confirmations = @as(u32, @intCast(confirmations));
        self.slot = slot;
        
        if (confirmations >= self.strategy.commitment.minConfirmations()) {
            if (self.strategy.commitment == .finalized or self.strategy.commitment == .max) {
                if (confirmations >= 32) {
                    self.status = .finalized;
                } else {
                    self.status = .confirmed;
                }
            } else if (self.strategy.commitment == .confirmed) {
                if (confirmations >= 1) {
                    self.status = .confirmed;
                }
            } else {
                self.status = .confirmed;
            }
        }
    }
    
    /// Check if confirmation is complete
    pub fn isComplete(self: *ConfirmationTracker) bool {
        return switch (self.status) {
            .confirmed, .finalized, .failed, .timeout => true,
            .pending => false,
        };
    }
    
    /// Get confirmation progress (0-1)
    pub fn progress(self: *ConfirmationTracker) f64 {
        const target = self.strategy.commitment.minConfirmations();
        if (target == 0) return 1.0;
        return @as(f64, @floatFromInt(self.confirmations)) / @as(f64, @floatFromInt(target));
    }
};

// ============================================================
// Fee Priority Levels (Compute Units)
// ============================================================

pub const FeePriority = enum {
    /// Minimum fee (slowest)
    min,
    
    /// Standard fee (normal)
    standard,
    
    /// High fee (fast)
    high,
    
    /// Maximum fee (fastest)
    max,
    
    /// Custom fee in micro-lamports per CU
    custom: u64,
    
    pub fn getMicroLamportsPerCu(self: FeePriority) u64 {
        const base: u64 = 5000; // ~0.000005 SOL per CU
        return switch (self) {
            .min => base,
            .standard => base * 2,
            .high => base * 5,
            .max => base * 10,
            .custom => |value| value,
        };
    }
    
    /// Get compute unit price for transaction
    pub fn getComputeUnitPrice(self: FeePriority) u64 {
        return self.getMicroLamportsPerCu();
    }
    
    /// Get recommended compute unit limit for common operations
    pub fn getRecommendedComputeUnits(self: FeePriority, operation: OperationType) u32 {
        _ = self;
        return switch (operation) {
            .transfer => 150_000,
            .token_transfer => 200_000,
            .create_account => 300_000,
            .create_token_account => 400_000,
            .mint_tokens => 250_000,
            .complex => 1_000_000,
            .custom => |units| units,
        };
    }
};

pub const OperationType = union(enum) {
    transfer,
    token_transfer,
    create_account,
    create_token_account,
    mint_tokens,
    complex,
    custom: u32,
};

// ============================================================
// Tests
// ============================================================

test "Commitment levels" {
    try std.testing.expectEqualStrings(Commitment.processed.toString(), "processed");
    try std.testing.expectEqual(Commitment.confirmed.minConfirmations(), 1);
    try std.testing.expectEqual(Commitment.finalized.minConfirmations(), 32);
}

test "Confirmation strategy" {
    const strategy = ConfirmationStrategy.fast();
    try std.testing.expect(strategy.commitment == .processed);
    try std.testing.expect(strategy.timeout_ms == 5000);
    
    const safe = ConfirmationStrategy.safe();
    try std.testing.expect(safe.commitment == .finalized);
}

test "Fee priority" {
    const standard = FeePriority.standard;
    try std.testing.expect(standard.getMicroLamportsPerCu() == 10000);
    
    const custom = FeePriority.custom(12345);
    try std.testing.expect(custom.getMicroLamportsPerCu() == 12345);
}