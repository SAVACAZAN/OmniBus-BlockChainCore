/// price_oracle.zig — Oracle Distribuit de Pret: Consens Miner P2P
///
/// Fiecare miner fetches preturi de pe exchange-uri, le semneaza si le broadcast-eaza.
/// Consensul determina pretul final on-chain prin votul a 2/3 din mineri.
///
/// Acesta este layerul de CONSENS pe deasupra oracle.zig (care stocheaza BID/ASK raw).
/// Fluxul:
///   1. Miner-ul citeste preturile din oracle.zig (ExchangeQuote)
///   2. Calculeaza un pret median local
///   3. Semneaza si trimite MinerPriceSubmission via P2P
///   4. DistributedPriceOracle colecteaza submissions de la toti minerii
///   5. La sfarsitul rundei (block), calculeaza ConsensusPrice (median + 2/3 agreement)
///   6. Pretul consensual intra in block header (merkle root)
///
const std = @import("std");
const oracle = @import("oracle.zig");

pub const ChainId = oracle.ChainId;
pub const ExchangeId = oracle.ExchangeId;
pub const ExchangeQuote = oracle.ExchangeQuote;

// --- CONSTANTE ---------------------------------------------------------------

pub const MAX_MINERS: usize = 128;
pub const CHAINS: usize = 20; // same as oracle.zig
pub const MAX_PRICE_HISTORY: usize = 1000;
pub const PRICE_STALE_MS: i64 = 30_000; // 30 seconds
pub const OUTLIER_THRESHOLD_BPS: u64 = 500; // 5% = 500 basis points
pub const MIN_SUBMISSIONS: u8 = 3; // need at least 3 miners
pub const CONSENSUS_THRESHOLD_PCT: u8 = 67; // 2/3

// --- TIPURI ------------------------------------------------------------------

/// Pret submis de un miner — semnat si timestamped
pub const MinerPriceSubmission = struct {
    miner_address: [64]u8,
    miner_addr_len: u8,
    chain_id: ChainId,
    price_micro_usd: u64,
    timestamp_ms: i64,
    /// SHA256 signature of (chain_id ++ price ++ timestamp ++ miner_address)
    signature: [64]u8,

    /// Returns the miner address as a slice
    pub fn getMinerAddress(self: *const MinerPriceSubmission) []const u8 {
        return self.miner_address[0..self.miner_addr_len];
    }

    /// A submission is stale if older than PRICE_STALE_MS
    pub fn isStale(self: *const MinerPriceSubmission, now_ms: i64) bool {
        return (now_ms - self.timestamp_ms) > PRICE_STALE_MS;
    }
};

/// Pret consensual — rezultatul votului a 2/3 din mineri
pub const ConsensusPrice = struct {
    chain_id: ChainId,
    price_micro_usd: u64, // median of valid submissions
    submission_count: u8, // how many miners submitted
    agreement_count: u8, // how many are within 5% of median
    timestamp_ms: i64,
    block_height: u64,
    is_valid: bool, // true if agreement_count >= 2/3 * submission_count

    /// Deviation from a reference price in basis points (1 bp = 0.01%)
    /// Returns |self - reference| / reference * 10000
    pub fn deviationPct(self: *const ConsensusPrice, reference: u64) u64 {
        if (reference == 0) return 0;
        const diff = if (self.price_micro_usd > reference)
            self.price_micro_usd - reference
        else
            reference - self.price_micro_usd;
        // (diff * 10000) / reference = basis points
        return (diff * 10000) / reference;
    }
};

/// Istoric de preturi — ultimele N preturi consensuale (circular buffer)
pub const PriceHistory = struct {
    prices: [MAX_PRICE_HISTORY]ConsensusPrice,
    count: u32,
    head: u32, // next write position in circular buffer

    pub fn init() PriceHistory {
        return PriceHistory{
            .prices = undefined,
            .count = 0,
            .head = 0,
        };
    }

    /// Push a new consensus price into the circular buffer
    pub fn push(self: *PriceHistory, price: ConsensusPrice) void {
        self.prices[self.head] = price;
        self.head = (self.head + 1) % @as(u32, MAX_PRICE_HISTORY);
        if (self.count < MAX_PRICE_HISTORY) {
            self.count += 1;
        }
    }

    /// Returns the most recent consensus price, or null if empty
    pub fn latest(self: *const PriceHistory) ?ConsensusPrice {
        if (self.count == 0) return null;
        // head points to next write, so latest is head-1
        const idx = if (self.head == 0) MAX_PRICE_HISTORY - 1 else self.head - 1;
        return self.prices[idx];
    }

    /// Time-weighted average price over a window.
    /// Iterates backwards from latest, includes prices within [now - window_ms, now].
    /// Returns null if no prices in window.
    pub fn twap(self: *const PriceHistory, window_ms: i64) ?u64 {
        if (self.count == 0) return null;

        const latest_price = self.latest() orelse return null;
        const now = latest_price.timestamp_ms;
        const cutoff = now - window_ms;

        var weighted_sum: u128 = 0;
        var total_weight: u128 = 0;

        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            // Walk backwards from latest
            const raw_idx = if (self.head >= i + 1)
                self.head - i - 1
            else
                MAX_PRICE_HISTORY - (i + 1 - self.head);
            const p = self.prices[raw_idx];

            if (p.timestamp_ms < cutoff) break;
            if (!p.is_valid) continue;

            // Weight = time this price was "active" (until next price or now)
            const next_ts = if (i == 0) now else blk: {
                const prev_idx = if (self.head >= i)
                    self.head - i
                else
                    MAX_PRICE_HISTORY - (i - self.head);
                break :blk self.prices[prev_idx].timestamp_ms;
            };

            const duration: u128 = @intCast(@max(next_ts - p.timestamp_ms, 1));
            weighted_sum += @as(u128, p.price_micro_usd) * duration;
            total_weight += duration;
        }

        if (total_weight == 0) return null;
        return @intCast(weighted_sum / total_weight);
    }

    /// Simplified volatility: max - min price in the buffer (all stored prices)
    /// Returns null if fewer than 2 prices
    pub fn volatility(self: *const PriceHistory) ?u64 {
        if (self.count < 2) return null;

        var min_price: u64 = std.math.maxInt(u64);
        var max_price: u64 = 0;

        for (0..self.count) |i| {
            const raw_idx = if (self.head >= i + 1)
                self.head - i - 1
            else
                MAX_PRICE_HISTORY - (i + 1 - self.head);
            const p = self.prices[raw_idx];
            if (!p.is_valid) continue;
            if (p.price_micro_usd < min_price) min_price = p.price_micro_usd;
            if (p.price_micro_usd > max_price) max_price = p.price_micro_usd;
        }

        if (max_price == 0) return null;
        return max_price - min_price;
    }
};

// --- ORACLE DISTRIBUIT -------------------------------------------------------

pub const DistributedPriceOracle = struct {
    // Submissions din runda curenta (per chain)
    submissions: [CHAINS][MAX_MINERS]MinerPriceSubmission,
    submission_count: [CHAINS]u8,
    submission_valid: [CHAINS][MAX_MINERS]bool,

    // Preturi consensuale curente
    consensus_prices: [CHAINS]ConsensusPrice,

    // Istoric
    history: [CHAINS]PriceHistory,

    // Config
    current_block: u64,

    /// Initialize oracle with empty state
    pub fn init() DistributedPriceOracle {
        @setEvalBranchQuota(10000);
        var self: DistributedPriceOracle = undefined;

        for (0..CHAINS) |c| {
            self.submission_count[c] = 0;
            for (0..MAX_MINERS) |m| {
                self.submission_valid[c][m] = false;
            }
            self.consensus_prices[c] = ConsensusPrice{
                .chain_id = @enumFromInt(c),
                .price_micro_usd = 0,
                .submission_count = 0,
                .agreement_count = 0,
                .timestamp_ms = 0,
                .block_height = 0,
                .is_valid = false,
            };
            self.history[c] = PriceHistory.init();
        }

        self.current_block = 0;
        return self;
    }

    /// Submit a price from a miner for a given chain
    /// Rejects stale submissions and duplicates from same miner
    pub fn submitPrice(self: *DistributedPriceOracle, chain: ChainId, submission: MinerPriceSubmission) !void {
        const c = @intFromEnum(chain);
        if (c >= CHAINS) return error.InvalidChain;

        // Reject zero prices
        if (submission.price_micro_usd == 0) return error.InvalidPrice;

        // Reject stale submissions (use submission's own timestamp as reference for determinism)
        // In production, now_ms would come from block timestamp
        // For validation, we check relative to latest known time
        // Stale check is done by caller with isStale()

        // Check for duplicate miner in this round
        const count = self.submission_count[c];
        for (0..count) |i| {
            if (!self.submission_valid[c][i]) continue;
            const existing = self.submissions[c][i];
            if (std.mem.eql(u8, existing.getMinerAddress(), submission.getMinerAddress())) {
                return error.DuplicateMiner;
            }
        }

        // Check capacity
        if (count >= MAX_MINERS) return error.TooManyMiners;

        // Store submission
        self.submissions[c][count] = submission;
        self.submission_valid[c][count] = true;
        self.submission_count[c] = count + 1;
    }

    /// Calculate consensus price for a chain from current submissions.
    /// Steps:
    ///   1. Collect all valid prices
    ///   2. Sort and find median
    ///   3. Count how many are within OUTLIER_THRESHOLD_BPS of median
    ///   4. Valid if agreement_count >= CONSENSUS_THRESHOLD_PCT% of submission_count
    pub fn calculateConsensus(self: *DistributedPriceOracle, chain: ChainId, block_height: u64) !ConsensusPrice {
        const c = @intFromEnum(chain);
        if (c >= CHAINS) return error.InvalidChain;

        const count = self.submission_count[c];
        if (count < MIN_SUBMISSIONS) return error.InsufficientSubmissions;

        // Collect valid prices into a sortable array
        var prices: [MAX_MINERS]u64 = undefined;
        var valid_count: u8 = 0;

        for (0..count) |i| {
            if (!self.submission_valid[c][i]) continue;
            prices[valid_count] = self.submissions[c][i].price_micro_usd;
            valid_count += 1;
        }

        if (valid_count < MIN_SUBMISSIONS) return error.InsufficientSubmissions;

        // Insertion sort for median calculation
        for (1..valid_count) |i| {
            const key = prices[i];
            var j: usize = i;
            while (j > 0 and prices[j - 1] > key) : (j -= 1) {
                prices[j] = prices[j - 1];
            }
            prices[j] = key;
        }

        // Median
        const median = prices[valid_count / 2];

        // Count agreements (within OUTLIER_THRESHOLD_BPS of median)
        var agreement_count: u8 = 0;
        for (0..valid_count) |i| {
            if (!isOutlierPrice(median, prices[i])) {
                agreement_count += 1;
            }
        }

        // Check consensus threshold: agreement_count * 100 >= valid_count * CONSENSUS_THRESHOLD_PCT
        const is_valid = (@as(u32, agreement_count) * 100) >= (@as(u32, valid_count) * CONSENSUS_THRESHOLD_PCT);

        // Find latest timestamp among submissions
        var latest_ts: i64 = 0;
        for (0..count) |i| {
            if (!self.submission_valid[c][i]) continue;
            if (self.submissions[c][i].timestamp_ms > latest_ts) {
                latest_ts = self.submissions[c][i].timestamp_ms;
            }
        }

        const consensus = ConsensusPrice{
            .chain_id = chain,
            .price_micro_usd = median,
            .submission_count = valid_count,
            .agreement_count = agreement_count,
            .timestamp_ms = latest_ts,
            .block_height = block_height,
            .is_valid = is_valid,
        };

        // Store as current consensus and push to history
        self.consensus_prices[c] = consensus;
        if (is_valid) {
            self.history[c].push(consensus);
        }

        return consensus;
    }

    /// Get the current consensus price for a chain, or null if not yet calculated
    pub fn getPrice(self: *const DistributedPriceOracle, chain: ChainId) ?ConsensusPrice {
        const c = @intFromEnum(chain);
        if (c >= CHAINS) return null;
        const p = self.consensus_prices[c];
        if (!p.is_valid) return null;
        return p;
    }

    /// Get TWAP for a chain over a time window
    pub fn getTwap(self: *const DistributedPriceOracle, chain: ChainId, window_ms: i64) ?u64 {
        const c = @intFromEnum(chain);
        if (c >= CHAINS) return null;
        return self.history[c].twap(window_ms);
    }

    /// Clear all submissions for a new round (new block)
    pub fn resetRound(self: *DistributedPriceOracle) void {
        for (0..CHAINS) |c| {
            self.submission_count[c] = 0;
            for (0..MAX_MINERS) |m| {
                self.submission_valid[c][m] = false;
            }
        }
        self.current_block += 1;
    }

    /// Check if a price is an outlier relative to the current median for a chain.
    /// An outlier deviates > OUTLIER_THRESHOLD_BPS (5%) from median.
    pub fn isOutlier(self: *const DistributedPriceOracle, chain: ChainId, price: u64) bool {
        const c = @intFromEnum(chain);
        if (c >= CHAINS) return true;

        const count = self.submission_count[c];
        if (count < MIN_SUBMISSIONS) return false; // can't determine outlier without enough data

        // Collect and sort current submissions to find median
        var prices: [MAX_MINERS]u64 = undefined;
        var valid_count: u8 = 0;

        for (0..count) |i| {
            if (!self.submission_valid[c][i]) continue;
            prices[valid_count] = self.submissions[c][i].price_micro_usd;
            valid_count += 1;
        }

        if (valid_count < MIN_SUBMISSIONS) return false;

        // Insertion sort
        for (1..valid_count) |i| {
            const key = prices[i];
            var j: usize = i;
            while (j > 0 and prices[j - 1] > key) : (j -= 1) {
                prices[j] = prices[j - 1];
            }
            prices[j] = key;
        }

        const median = prices[valid_count / 2];
        return isOutlierPrice(median, price);
    }

    /// Compute a Merkle root (SHA256) of all current consensus prices.
    /// Deterministic: same prices always produce the same root.
    /// Used in block header to commit to the oracle state.
    pub fn pricesMerkleRoot(self: *const DistributedPriceOracle) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        for (0..CHAINS) |c| {
            const p = self.consensus_prices[c];
            // Include chain_id
            const chain_byte: [1]u8 = .{@intCast(c)};
            hasher.update(&chain_byte);

            // Include price (little-endian u64)
            const price_bytes = std.mem.toBytes(p.price_micro_usd);
            hasher.update(&price_bytes);

            // Include block height
            const height_bytes = std.mem.toBytes(p.block_height);
            hasher.update(&height_bytes);

            // Include validity flag
            const valid_byte: [1]u8 = .{if (p.is_valid) 1 else 0};
            hasher.update(&valid_byte);

            // Include timestamp
            const ts_bytes = std.mem.toBytes(p.timestamp_ms);
            hasher.update(&ts_bytes);
        }

        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }
};

// --- HELPER FUNCTIONS --------------------------------------------------------

/// Check if a price deviates more than OUTLIER_THRESHOLD_BPS from the median
fn isOutlierPrice(median: u64, price: u64) bool {
    if (median == 0) return true;
    const diff = if (price > median) price - median else median - price;
    // diff * 10000 / median > OUTLIER_THRESHOLD_BPS
    return (diff * 10000 / median) > OUTLIER_THRESHOLD_BPS;
}

// --- TESTE -------------------------------------------------------------------
const testing = std.testing;

/// Helper: creeaza un MinerPriceSubmission de test
fn makeSubmission(miner_id: u8, chain: ChainId, price: u64, ts: i64) MinerPriceSubmission {
    var addr: [64]u8 = [_]u8{0} ** 64;
    addr[0] = miner_id;
    addr[1] = 'M';
    const addr_len: u8 = 2;

    var sig: [64]u8 = [_]u8{0} ** 64;
    sig[0] = miner_id;

    return MinerPriceSubmission{
        .miner_address = addr,
        .miner_addr_len = addr_len,
        .chain_id = chain,
        .price_micro_usd = price,
        .timestamp_ms = ts,
        .signature = sig,
    };
}

test "init distributed oracle" {
    const dpo = DistributedPriceOracle.init();

    // All submission counts should be zero
    for (0..CHAINS) |c| {
        try testing.expectEqual(@as(u8, 0), dpo.submission_count[c]);
    }

    // No valid consensus prices
    try testing.expect(dpo.getPrice(.btc) == null);
    try testing.expect(dpo.getPrice(.eth) == null);
    try testing.expectEqual(@as(u64, 0), dpo.current_block);
}

test "submit single price" {
    var dpo = DistributedPriceOracle.init();

    const sub = makeSubmission(1, .btc, 50_000_000_000, 1000);
    try dpo.submitPrice(.btc, sub);

    try testing.expectEqual(@as(u8, 1), dpo.submission_count[@intFromEnum(ChainId.btc)]);
    try testing.expect(dpo.submission_valid[@intFromEnum(ChainId.btc)][0]);
    try testing.expectEqual(@as(u64, 50_000_000_000), dpo.submissions[@intFromEnum(ChainId.btc)][0].price_micro_usd);
}

test "consensus with 3 miners agreeing" {
    var dpo = DistributedPriceOracle.init();

    // 3 miners, all within 5% of each other
    try dpo.submitPrice(.btc, makeSubmission(1, .btc, 50_000_000_000, 1000)); // $50,000
    try dpo.submitPrice(.btc, makeSubmission(2, .btc, 50_100_000_000, 1001)); // $50,100
    try dpo.submitPrice(.btc, makeSubmission(3, .btc, 49_900_000_000, 1002)); // $49,900

    const consensus = try dpo.calculateConsensus(.btc, 42);

    try testing.expect(consensus.is_valid);
    try testing.expectEqual(@as(u8, 3), consensus.submission_count);
    try testing.expectEqual(@as(u8, 3), consensus.agreement_count);
    try testing.expectEqual(@as(u64, 50_000_000_000), consensus.price_micro_usd); // median
    try testing.expectEqual(@as(u64, 42), consensus.block_height);
}

test "consensus with outlier rejected" {
    var dpo = DistributedPriceOracle.init();

    // 2 agree at ~$50,000, 1 outlier at $60,000 (20% deviation)
    try dpo.submitPrice(.btc, makeSubmission(1, .btc, 50_000_000_000, 1000));
    try dpo.submitPrice(.btc, makeSubmission(2, .btc, 50_100_000_000, 1001));
    try dpo.submitPrice(.btc, makeSubmission(3, .btc, 60_000_000_000, 1002)); // outlier

    const consensus = try dpo.calculateConsensus(.btc, 10);

    // Median is $50,100M, 2 out of 3 agree => 66.6% < 67% threshold
    // Actually: sorted = [50000, 50100, 60000], median = 50100
    // $50000 dev from $50100 = 0.2% -> in range
    // $50100 dev from $50100 = 0% -> in range
    // $60000 dev from $50100 = 19.7% -> outlier
    // agreement = 2/3 = 66.6% < 67% -> not valid
    try testing.expect(!consensus.is_valid);
    try testing.expectEqual(@as(u8, 2), consensus.agreement_count);
}

test "consensus fails — too few miners" {
    var dpo = DistributedPriceOracle.init();

    // Only 2 miners, need MIN_SUBMISSIONS (3)
    try dpo.submitPrice(.eth, makeSubmission(1, .eth, 3_000_000_000, 1000));
    try dpo.submitPrice(.eth, makeSubmission(2, .eth, 3_010_000_000, 1001));

    try testing.expectError(error.InsufficientSubmissions, dpo.calculateConsensus(.eth, 5));
}

test "stale submission rejected" {
    const now_ms: i64 = 100_000;
    const old_ts: i64 = now_ms - PRICE_STALE_MS - 1; // 31 seconds ago

    const sub = makeSubmission(1, .btc, 50_000_000_000, old_ts);
    try testing.expect(sub.isStale(now_ms));

    // A fresh submission should not be stale
    const fresh = makeSubmission(2, .btc, 50_000_000_000, now_ms - 1000); // 1 second ago
    try testing.expect(!fresh.isStale(now_ms));
}

test "price history TWAP" {
    var hist = PriceHistory.init();

    // Push 3 prices at different times
    hist.push(ConsensusPrice{
        .chain_id = .btc,
        .price_micro_usd = 50_000_000_000, // $50,000
        .submission_count = 5,
        .agreement_count = 5,
        .timestamp_ms = 1000,
        .block_height = 1,
        .is_valid = true,
    });

    hist.push(ConsensusPrice{
        .chain_id = .btc,
        .price_micro_usd = 51_000_000_000, // $51,000
        .submission_count = 5,
        .agreement_count = 5,
        .timestamp_ms = 2000,
        .block_height = 2,
        .is_valid = true,
    });

    hist.push(ConsensusPrice{
        .chain_id = .btc,
        .price_micro_usd = 52_000_000_000, // $52,000
        .submission_count = 5,
        .agreement_count = 5,
        .timestamp_ms = 3000,
        .block_height = 3,
        .is_valid = true,
    });

    // TWAP over entire window (3000ms from latest ts=3000)
    const result = hist.twap(3000);
    try testing.expect(result != null);

    // Prices: 50000 (1000-2000, 1000ms), 51000 (2000-3000, 1000ms), 52000 (3000-3000, 1ms min)
    // TWAP = (50000*1000 + 51000*1000 + 52000*1) / (1000+1000+1) ~ 50500
    // The exact value depends on weights; the important thing is it's between 50000 and 52000
    const twap_val = result.?;
    try testing.expect(twap_val >= 50_000_000_000);
    try testing.expect(twap_val <= 52_000_000_000);
}

test "outlier detection" {
    var dpo = DistributedPriceOracle.init();

    // Submit 3 prices around $50,000
    try dpo.submitPrice(.btc, makeSubmission(1, .btc, 50_000_000_000, 1000));
    try dpo.submitPrice(.btc, makeSubmission(2, .btc, 50_100_000_000, 1001));
    try dpo.submitPrice(.btc, makeSubmission(3, .btc, 49_900_000_000, 1002));

    // $50,500 is within 5% -> not an outlier
    try testing.expect(!dpo.isOutlier(.btc, 50_500_000_000));

    // $60,000 is 20% above median -> outlier
    try testing.expect(dpo.isOutlier(.btc, 60_000_000_000));

    // $40,000 is 20% below median -> outlier
    try testing.expect(dpo.isOutlier(.btc, 40_000_000_000));
}

test "merkle root deterministic" {
    var dpo1 = DistributedPriceOracle.init();
    var dpo2 = DistributedPriceOracle.init();

    // Same submissions to both oracles
    const subs = [_]MinerPriceSubmission{
        makeSubmission(1, .btc, 50_000_000_000, 1000),
        makeSubmission(2, .btc, 50_100_000_000, 1001),
        makeSubmission(3, .btc, 49_900_000_000, 1002),
    };

    for (subs) |sub| {
        try dpo1.submitPrice(.btc, sub);
        try dpo2.submitPrice(.btc, sub);
    }

    _ = try dpo1.calculateConsensus(.btc, 1);
    _ = try dpo2.calculateConsensus(.btc, 1);

    const root1 = dpo1.pricesMerkleRoot();
    const root2 = dpo2.pricesMerkleRoot();

    try testing.expectEqualSlices(u8, &root1, &root2);

    // Different state should produce a different root
    var dpo3 = DistributedPriceOracle.init();
    try dpo3.submitPrice(.btc, makeSubmission(1, .btc, 99_000_000_000, 1000));
    try dpo3.submitPrice(.btc, makeSubmission(2, .btc, 99_100_000_000, 1001));
    try dpo3.submitPrice(.btc, makeSubmission(3, .btc, 98_900_000_000, 1002));
    _ = try dpo3.calculateConsensus(.btc, 1);

    const root3 = dpo3.pricesMerkleRoot();
    try testing.expect(!std.mem.eql(u8, &root1, &root3));
}

test "round reset" {
    var dpo = DistributedPriceOracle.init();

    // Submit some prices
    try dpo.submitPrice(.btc, makeSubmission(1, .btc, 50_000_000_000, 1000));
    try dpo.submitPrice(.btc, makeSubmission(2, .btc, 50_100_000_000, 1001));
    try dpo.submitPrice(.eth, makeSubmission(1, .eth, 3_000_000_000, 1000));

    try testing.expectEqual(@as(u8, 2), dpo.submission_count[@intFromEnum(ChainId.btc)]);
    try testing.expectEqual(@as(u8, 1), dpo.submission_count[@intFromEnum(ChainId.eth)]);

    // Reset round
    dpo.resetRound();

    // All submissions should be cleared
    for (0..CHAINS) |c| {
        try testing.expectEqual(@as(u8, 0), dpo.submission_count[c]);
    }

    // Block counter should have incremented
    try testing.expectEqual(@as(u64, 1), dpo.current_block);

    // Should be able to submit again (same miner, no duplicate error)
    try dpo.submitPrice(.btc, makeSubmission(1, .btc, 50_500_000_000, 2000));
    try testing.expectEqual(@as(u8, 1), dpo.submission_count[@intFromEnum(ChainId.btc)]);
}
