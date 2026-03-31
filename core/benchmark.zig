const std = @import("std");
const crypto_mod = @import("crypto.zig");
const secp256k1_mod = @import("secp256k1.zig");
const transaction_mod = @import("transaction.zig");
const block_mod = @import("block.zig");
const mempool_mod = @import("mempool.zig");

const Crypto = crypto_mod.Crypto;
const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;
const Transaction = transaction_mod.Transaction;
const Block = block_mod.Block;
const Mempool = mempool_mod.Mempool;

// ─── BenchResult ────────────────────────────────────────────────────────────

pub const BenchResult = struct {
    name: []const u8,
    iterations: u32,
    total_ns: u64,
    avg_ns: u64,
    ops_per_sec: u64,

    pub fn print(self: *const BenchResult) void {
        std.debug.print("  {s:<30} | {d:>10} iters | {d:>12} ns avg | {d:>12} ops/s\n", .{
            self.name,
            self.iterations,
            self.avg_ns,
            self.ops_per_sec,
        });
    }
};

// ─── Metrics — live performance counters ────────────────────────────────────

/// Ring buffer size for TPS rolling window
const TX_TS_RING_SIZE: usize = 1000;

pub const Metrics = struct {
    start_time: i64,
    blocks_mined: u64,
    txs_processed: u64,
    rpc_requests: u64,
    p2p_messages: u64,
    peak_tps: u64,
    /// Ring buffer of last TX timestamps (nanosecond precision)
    tx_timestamps: [TX_TS_RING_SIZE]i64,
    tx_ts_head: u32,
    tx_ts_count: u32,
    /// Mining hashrate tracking
    last_mining_nonces: u64,
    last_mining_time_ns: u64,
    hashrate: u64, // H/s

    pub fn init() Metrics {
        return .{
            .start_time = 0, // set at runtime via resetStartTime()
            .blocks_mined = 0,
            .txs_processed = 0,
            .rpc_requests = 0,
            .p2p_messages = 0,
            .peak_tps = 0,
            .tx_timestamps = [_]i64{0} ** TX_TS_RING_SIZE,
            .tx_ts_head = 0,
            .tx_ts_count = 0,
            .last_mining_nonces = 0,
            .last_mining_time_ns = 0,
            .hashrate = 0,
        };
    }

    /// Set the start time to now (call at runtime, not comptime)
    pub fn start(self: *Metrics) void {
        self.start_time = std.time.timestamp();
    }

    /// Record a processed transaction
    pub fn recordTx(self: *Metrics) void {
        self.txs_processed += 1;
        const now = std.time.timestamp();
        self.tx_timestamps[self.tx_ts_head] = now;
        self.tx_ts_head = (self.tx_ts_head + 1) % @as(u32, TX_TS_RING_SIZE);
        if (self.tx_ts_count < TX_TS_RING_SIZE) {
            self.tx_ts_count += 1;
        }
        // Update peak TPS
        const current_tps = self.currentTps();
        if (current_tps > self.peak_tps) {
            self.peak_tps = current_tps;
        }
    }

    /// Record a mined block
    pub fn recordBlock(self: *Metrics) void {
        self.blocks_mined += 1;
    }

    /// Record an RPC request
    pub fn recordRpcRequest(self: *Metrics) void {
        self.rpc_requests += 1;
    }

    /// Record a P2P message
    pub fn recordP2pMessage(self: *Metrics) void {
        self.p2p_messages += 1;
    }

    /// Update mining hashrate from nonces tried and time taken
    pub fn updateHashrate(self: *Metrics, nonces: u64, time_ns: u64) void {
        self.last_mining_nonces = nonces;
        self.last_mining_time_ns = time_ns;
        if (time_ns > 0) {
            // H/s = nonces * 1_000_000_000 / time_ns
            self.hashrate = nonces * std.time.ns_per_s / time_ns;
        }
    }

    /// Calculate current TPS from the rolling window (TXs in the last 10 seconds)
    pub fn currentTps(self: *const Metrics) u64 {
        const now = std.time.timestamp();
        const window: i64 = 10; // 10 second window
        var count: u64 = 0;
        const n = self.tx_ts_count;
        for (0..n) |i| {
            const ts = self.tx_timestamps[i];
            if (ts > 0 and (now - ts) <= window) {
                count += 1;
            }
        }
        if (count == 0) return 0;
        return count / @as(u64, @intCast(window));
    }

    /// Uptime in seconds
    pub fn uptimeSeconds(self: *const Metrics) u64 {
        const now = std.time.timestamp();
        const diff = now - self.start_time;
        return if (diff > 0) @intCast(diff) else 0;
    }

    /// Average block time in ms (blocks_mined / uptime)
    pub fn avgBlockTimeMs(self: *const Metrics) u64 {
        const uptime = self.uptimeSeconds();
        if (self.blocks_mined == 0 or uptime == 0) return 0;
        return (uptime * 1000) / self.blocks_mined;
    }

    /// Blocks per minute
    pub fn blocksPerMinute(self: *const Metrics) u64 {
        const uptime = self.uptimeSeconds();
        if (self.blocks_mined == 0 or uptime == 0) return 0;
        return (self.blocks_mined * 60) / uptime;
    }
};

// ─── Benchmark ──────────────────────────────────────────────────────────────

pub const Benchmark = struct {
    /// Benchmark SHA256d hashing
    pub fn benchHashing(iterations: u32) BenchResult {
        const data = "OmniBus benchmark payload: the quick brown fox jumps over the lazy dog 0123456789";
        const start = std.time.nanoTimestamp();

        for (0..iterations) |_| {
            const h = Crypto.sha256d(data);
            std.mem.doNotOptimizeAway(&h);
        }

        const end = std.time.nanoTimestamp();
        const total_ns: u64 = @intCast(end - start);
        const avg_ns = if (iterations > 0) total_ns / iterations else 0;
        const ops = if (avg_ns > 0) std.time.ns_per_s / avg_ns else 0;

        return .{
            .name = "SHA256d hashing",
            .iterations = iterations,
            .total_ns = total_ns,
            .avg_ns = avg_ns,
            .ops_per_sec = ops,
        };
    }

    /// Benchmark secp256k1 key generation
    pub fn benchKeyGen(iterations: u32) BenchResult {
        const start = std.time.nanoTimestamp();

        for (0..iterations) |_| {
            const kp = Secp256k1Crypto.generateKeyPair() catch continue;
            std.mem.doNotOptimizeAway(&kp);
        }

        const end = std.time.nanoTimestamp();
        const total_ns: u64 = @intCast(end - start);
        const avg_ns = if (iterations > 0) total_ns / iterations else 0;
        const ops = if (avg_ns > 0) std.time.ns_per_s / avg_ns else 0;

        return .{
            .name = "secp256k1 keygen",
            .iterations = iterations,
            .total_ns = total_ns,
            .avg_ns = avg_ns,
            .ops_per_sec = ops,
        };
    }

    /// Benchmark TX hash calculation (the core of TX validation)
    pub fn benchTxValidation(iterations: u32) BenchResult {
        const tx = Transaction{
            .id = 1,
            .from_address = "ob1q8lel793v9h6r49ec2zwc2sxykmw430wy6fmpsy",
            .to_address = "ob1qgwet8xlkj6es5v4hnrl92av9z0jylx3fpjk556",
            .amount = 50_000_000_000,
            .fee = 1,
            .nonce = 42,
            .timestamp = 1_700_000_000,
            .signature = "0000000000000000000000000000000000000000000000000000000000000000" ++
                "0000000000000000000000000000000000000000000000000000000000000000",
            .hash = "0000000000000000000000000000000000000000000000000000000000000000",
        };

        const start = std.time.nanoTimestamp();

        for (0..iterations) |_| {
            const h = tx.calculateHash();
            std.mem.doNotOptimizeAway(&h);
        }

        const end = std.time.nanoTimestamp();
        const total_ns: u64 = @intCast(end - start);
        const avg_ns = if (iterations > 0) total_ns / iterations else 0;
        const ops = if (avg_ns > 0) std.time.ns_per_s / avg_ns else 0;

        return .{
            .name = "TX hash (validation)",
            .iterations = iterations,
            .total_ns = total_ns,
            .avg_ns = avg_ns,
            .ops_per_sec = ops,
        };
    }

    /// Benchmark TX creation + signing speed (secp256k1 ECDSA sign)
    pub fn benchTxSigning(iterations: u32) BenchResult {
        const start = std.time.nanoTimestamp();

        for (0..iterations) |i| {
            // Generate key pair and sign a message (simulates TX signing)
            const kp = Secp256k1Crypto.generateKeyPair() catch continue;
            _ = kp;

            // Hash the TX data (the sign digest)
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "tx-signing-bench-{d}", .{i}) catch continue;
            const digest = Crypto.sha256d(msg);
            std.mem.doNotOptimizeAway(&digest);
        }

        const end = std.time.nanoTimestamp();
        const total_ns: u64 = @intCast(end - start);
        const avg_ns = if (iterations > 0) total_ns / iterations else 0;
        const ops = if (avg_ns > 0) std.time.ns_per_s / avg_ns else 0;

        return .{
            .name = "TX signing (keygen+hash)",
            .iterations = iterations,
            .total_ns = total_ns,
            .avg_ns = avg_ns,
            .ops_per_sec = ops,
        };
    }

    /// Benchmark block mining (PoW) — hashes with leading zeros check
    pub fn benchMining(difficulty: u32, max_nonces: u64) BenchResult {
        const start = std.time.nanoTimestamp();
        var nonce: u64 = 0;

        while (nonce < max_nonces) : (nonce += 1) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "block-bench-{d}-{d}", .{ difficulty, nonce }) catch break;
            const hash = Crypto.sha256d(msg);

            // Check leading zero bytes (simplified difficulty check)
            var leading_zeros: u32 = 0;
            for (hash) |b| {
                if (b == 0) {
                    leading_zeros += 2; // each zero byte = 2 hex zeros
                } else if (b < 0x10) {
                    leading_zeros += 1;
                    break;
                } else break;
            }
            if (leading_zeros >= difficulty) {
                break;
            }
        }

        const end = std.time.nanoTimestamp();
        const total_ns: u64 = @intCast(end - start);
        const iterations: u32 = @intCast(@min(nonce + 1, std.math.maxInt(u32)));
        const avg_ns = if (iterations > 0) total_ns / iterations else 0;
        const ops = if (avg_ns > 0) std.time.ns_per_s / avg_ns else 0;

        return .{
            .name = "PoW mining (SHA256d)",
            .iterations = iterations,
            .total_ns = total_ns,
            .avg_ns = avg_ns,
            .ops_per_sec = ops,
        };
    }

    /// Benchmark merkle root calculation
    pub fn benchMerkleRoot(tx_count: u32) BenchResult {
        const effective_count = @min(tx_count, 512); // keep stack reasonable
        const iterations: u32 = 100; // repeat for timing stability

        // Create a block with N dummy transactions
        const allocator = std.heap.page_allocator;
        var block = Block{
            .index = 0,
            .timestamp = 1_700_000_000,
            .transactions = std.array_list.Managed(Transaction).init(allocator),
            .previous_hash = "0000000000000000000000000000000000000000000000000000000000000000",
            .nonce = 0,
            .hash = "0000000000000000000000000000000000000000000000000000000000000000",
        };
        defer block.transactions.deinit();

        // Add dummy TXs
        for (0..effective_count) |i| {
            block.transactions.append(.{
                .id = @intCast(i),
                .from_address = "ob1qr067dh7p0m6ceuq3atc7ge6wkjxavdugzducq3",
                .to_address = "ob1qp0z2dlp5mnzrzcld3gnsa3tkkqtv0au5hgrwt4",
                .amount = 1000 + @as(u64, @intCast(i)),
                .fee = 1,
                .timestamp = 1_700_000_000,
                .signature = "0000000000000000000000000000000000000000000000000000000000000000" ++
                    "0000000000000000000000000000000000000000000000000000000000000000",
                .hash = "0000000000000000000000000000000000000000000000000000000000000000",
            }) catch break;
        }

        const start = std.time.nanoTimestamp();

        for (0..iterations) |_| {
            const root = block.calculateMerkleRoot();
            std.mem.doNotOptimizeAway(&root);
        }

        const end = std.time.nanoTimestamp();
        const total_ns: u64 = @intCast(end - start);
        const avg_ns = if (iterations > 0) total_ns / iterations else 0;
        const ops = if (avg_ns > 0) std.time.ns_per_s / avg_ns else 0;

        return .{
            .name = "Merkle root (N TXs)",
            .iterations = iterations,
            .total_ns = total_ns,
            .avg_ns = avg_ns,
            .ops_per_sec = ops,
        };
    }

    /// Benchmark mempool add/remove throughput
    pub fn benchMempool(iterations: u32) BenchResult {
        const allocator = std.heap.page_allocator;
        var mempool = Mempool.init(allocator);
        defer mempool.deinit();

        const effective = @min(iterations, mempool_mod.MEMPOOL_MAX_TX - 1);

        const start = std.time.nanoTimestamp();

        // Add TXs — each TX uses a unique dummy signature as hash (hash field
        // is a slice pointing into the TX's own signature, which is stable).
        // We skip hash dedup by using empty hash to avoid StringHashMap issues
        // with stack-allocated slices.
        for (0..effective) |i| {
            mempool.add(.{
                .id = @intCast(i + 1),
                .from_address = "ob1qmvzw5wfurey42l64gg5afnrffna9w380f0d6fq",
                .to_address = "ob1qqhagg05ycvhyydflkgsuuvtg4wtx2tjd4euag8",
                .amount = 1000,
                .fee = 1,
                .nonce = @intCast(i),
                .timestamp = 1_700_000_000,
                .signature = "0000000000000000000000000000000000000000000000000000000000000000" ++
                    "0000000000000000000000000000000000000000000000000000000000000000",
                .hash = "", // empty hash skips dedup in mempool
            }) catch break;
        }

        const end = std.time.nanoTimestamp();
        const total_ns: u64 = @intCast(end - start);
        const avg_ns = if (effective > 0) total_ns / @as(u64, effective) else 0;
        const ops = if (avg_ns > 0) std.time.ns_per_s / avg_ns else 0;

        return .{
            .name = "Mempool add",
            .iterations = @intCast(effective),
            .total_ns = total_ns,
            .avg_ns = avg_ns,
            .ops_per_sec = ops,
        };
    }

    /// Benchmark HMAC-SHA512 (BIP32 key derivation core)
    pub fn benchHmacSha512(iterations: u32) BenchResult {
        const key = "Bitcoin seed";
        const msg = "OmniBus benchmark seed phrase for BIP32 key derivation testing purpose";

        const start = std.time.nanoTimestamp();

        for (0..iterations) |_| {
            const h = Crypto.hmacSha512(key, msg);
            std.mem.doNotOptimizeAway(&h);
        }

        const end = std.time.nanoTimestamp();
        const total_ns: u64 = @intCast(end - start);
        const avg_ns = if (iterations > 0) total_ns / iterations else 0;
        const ops = if (avg_ns > 0) std.time.ns_per_s / avg_ns else 0;

        return .{
            .name = "HMAC-SHA512 (BIP32)",
            .iterations = iterations,
            .total_ns = total_ns,
            .avg_ns = avg_ns,
            .ops_per_sec = ops,
        };
    }

    /// Run all benchmarks and print results
    pub fn runAll() void {
        std.debug.print("\n", .{});
        std.debug.print("==========================================================================\n", .{});
        std.debug.print("  OmniBus-BlockChainCore Performance Benchmarks\n", .{});
        std.debug.print("==========================================================================\n", .{});
        std.debug.print("  {s:<30} | {s:>10} | {s:>15} | {s:>12}\n", .{
            "Benchmark", "Iterations", "Avg latency (ns)", "Ops/sec",
        });
        std.debug.print("--------------------------------------------------------------------------\n", .{});

        const r1 = benchHashing(100_000);
        r1.print();

        const r2 = benchKeyGen(1_000);
        r2.print();

        const r3 = benchTxValidation(100_000);
        r3.print();

        const r4 = benchTxSigning(1_000);
        r4.print();

        const r5 = benchMining(2, 1_000_000);
        r5.print();

        const r6 = benchMerkleRoot(256);
        r6.print();

        const r7 = benchMempool(5_000);
        r7.print();

        const r8 = benchHmacSha512(100_000);
        r8.print();

        std.debug.print("==========================================================================\n\n", .{});
    }
};

// ─── Main (standalone executable) ───────────────────────────────────────────

pub fn main() void {
    Benchmark.runAll();
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "BenchResult struct creation" {
    const result = BenchResult{
        .name = "test-bench",
        .iterations = 100,
        .total_ns = 1_000_000,
        .avg_ns = 10_000,
        .ops_per_sec = 100_000,
    };
    try testing.expectEqual(@as(u32, 100), result.iterations);
    try testing.expectEqual(@as(u64, 1_000_000), result.total_ns);
    try testing.expectEqual(@as(u64, 10_000), result.avg_ns);
    try testing.expectEqual(@as(u64, 100_000), result.ops_per_sec);
    try testing.expectEqualSlices(u8, "test-bench", result.name);
}

test "Metrics init" {
    const m = Metrics.init();
    try testing.expectEqual(@as(u64, 0), m.blocks_mined);
    try testing.expectEqual(@as(u64, 0), m.txs_processed);
    try testing.expectEqual(@as(u64, 0), m.rpc_requests);
    try testing.expectEqual(@as(u64, 0), m.p2p_messages);
    try testing.expectEqual(@as(u64, 0), m.peak_tps);
    try testing.expectEqual(@as(u32, 0), m.tx_ts_head);
    try testing.expectEqual(@as(u32, 0), m.tx_ts_count);
    try testing.expectEqual(@as(u64, 0), m.hashrate);
}

test "Metrics counter increment" {
    var m = Metrics.init();
    try testing.expectEqual(@as(u64, 0), m.blocks_mined);

    m.recordBlock();
    try testing.expectEqual(@as(u64, 1), m.blocks_mined);

    m.recordBlock();
    m.recordBlock();
    try testing.expectEqual(@as(u64, 3), m.blocks_mined);

    m.recordRpcRequest();
    m.recordRpcRequest();
    try testing.expectEqual(@as(u64, 2), m.rpc_requests);

    m.recordP2pMessage();
    try testing.expectEqual(@as(u64, 1), m.p2p_messages);
}

test "Metrics TX recording and ring buffer" {
    var m = Metrics.init();
    try testing.expectEqual(@as(u64, 0), m.txs_processed);
    try testing.expectEqual(@as(u32, 0), m.tx_ts_head);

    m.recordTx();
    try testing.expectEqual(@as(u64, 1), m.txs_processed);
    try testing.expectEqual(@as(u32, 1), m.tx_ts_head);
    try testing.expectEqual(@as(u32, 1), m.tx_ts_count);

    m.recordTx();
    m.recordTx();
    try testing.expectEqual(@as(u64, 3), m.txs_processed);
    try testing.expectEqual(@as(u32, 3), m.tx_ts_head);
    try testing.expectEqual(@as(u32, 3), m.tx_ts_count);
}

test "Metrics TPS calculation from ring buffer" {
    var m = Metrics.init();
    // No TXs = 0 TPS
    try testing.expectEqual(@as(u64, 0), m.currentTps());

    // Add some TXs with current timestamp
    for (0..50) |_| {
        m.recordTx();
    }
    // All TXs are within 10s window, so TPS = 50/10 = 5
    const tps = m.currentTps();
    try testing.expect(tps >= 4 and tps <= 50); // allow range due to timing
}

test "Metrics hashrate update" {
    var m = Metrics.init();
    try testing.expectEqual(@as(u64, 0), m.hashrate);

    // 1000 nonces in 1 second = 1000 H/s
    m.updateHashrate(1000, std.time.ns_per_s);
    try testing.expectEqual(@as(u64, 1000), m.hashrate);

    // 500_000 nonces in 500ms = 1_000_000 H/s
    m.updateHashrate(500_000, 500 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u64, 1_000_000), m.hashrate);
}

test "Metrics uptime" {
    var m = Metrics.init();
    m.start(); // set start_time at runtime
    const uptime = m.uptimeSeconds();
    // Just initialized, uptime should be 0 or 1
    try testing.expect(uptime <= 1);
}

test "Metrics avg block time" {
    var m = Metrics.init();
    // No blocks = 0
    try testing.expectEqual(@as(u64, 0), m.avgBlockTimeMs());
    // With blocks but no uptime yet, also 0
    m.blocks_mined = 10;
    // Can't easily test non-zero without waiting, so just verify no crash
    _ = m.avgBlockTimeMs();
}

test "benchHashing produces valid result" {
    const r = Benchmark.benchHashing(100);
    try testing.expectEqual(@as(u32, 100), r.iterations);
    try testing.expect(r.total_ns > 0);
    try testing.expect(r.avg_ns > 0);
    try testing.expect(r.ops_per_sec > 0);
}

test "benchKeyGen produces valid result" {
    const r = Benchmark.benchKeyGen(10);
    try testing.expectEqual(@as(u32, 10), r.iterations);
    try testing.expect(r.total_ns > 0);
}

test "benchTxValidation produces valid result" {
    const r = Benchmark.benchTxValidation(100);
    try testing.expectEqual(@as(u32, 100), r.iterations);
    try testing.expect(r.total_ns > 0);
    try testing.expect(r.ops_per_sec > 0);
}

test "benchMining produces valid result" {
    const r = Benchmark.benchMining(1, 10_000);
    try testing.expect(r.iterations > 0);
    try testing.expect(r.total_ns > 0);
}

test "benchMerkleRoot produces valid result" {
    const r = Benchmark.benchMerkleRoot(16);
    try testing.expectEqual(@as(u32, 100), r.iterations);
    try testing.expect(r.total_ns > 0);
}

test "benchMempool produces valid result" {
    const r = Benchmark.benchMempool(100);
    try testing.expect(r.iterations > 0);
    try testing.expect(r.total_ns > 0);
}
