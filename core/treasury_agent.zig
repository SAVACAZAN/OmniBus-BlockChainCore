//! treasury_agent.zig — autonomous market-making agent for the NS treasury.
//!
//! Architecture goal (memory: project_omnibus_autonomous_treasury_design):
//! the NS treasury (ens.omnibus, registrar slot 5) accumulates payments
//! from name-claim TXs. Instead of those funds sitting idle (or worse,
//! being withdrawn externally), an agent thread *cannot* withdraw them
//! either — it only places limit orders on the OMNI/USDC orderbook. This
//! gives the chain permanent on-book liquidity AND makes the treasury
//! impossible to drain (the only way out is for some user to actually
//! buy or sell against the agent's orders, on-chain).
//!
//! Design choices (set in stone unless config_user explicitly overrides):
//!   - Single pair: OMNI/USDC (the most liquid; USDC is stablecoin).
//!   - Adaptive spread: levels at mid ± k×σ for k in 1..5, where σ is the
//!     rolling stddev of the last `VOL_WINDOW` trade prices. Spread auto-
//!     widens in volatile markets, tightens when calm.
//!   - 70% of treasury balance committed to grid by default (configurable).
//!     Remaining 30% acts as renewal/premium-fee reserve.
//!   - Capital allocation per side: weighted toward k=1 (most fills happen
//!     near mid). Weights: [40, 25, 15, 12, 8] across k=1..5 (sum=100).
//!   - Re-grid trigger: cancel + re-place when mid drifts by >5% of σ from
//!     the last grid centre, OR when treasury balance changes by >10%.
//!   - Cooldown: minimum BLOCK_INTERVAL blocks between full re-grids, so a
//!     volatile market doesn't thrash the orderbook.
//!
//! Single-point-of-failure note: the agent uses the registrar slot 5
//! private key, which lives in the founder's mnemonic. Phase 2 plan is
//! to migrate this to a consensus-controlled treasury (the chain itself
//! enforces the orders, no key needed). For Phase 1 (MVP) the agent
//! signs from the slot-5 wallet derivation. Single key = single risk;
//! mitigated by the agent ONLY emitting place_order / cancel_order calls
//! — never withdraw or transfer.

const std = @import("std");
const matching_mod = @import("matching_engine.zig");
const wallet_mod = @import("wallet.zig");
const transaction_mod = @import("transaction.zig");
const blockchain_mod = @import("blockchain.zig");
const registrar_mod = @import("registrar_addresses.zig");

const Order = matching_mod.Order;
const Fill = matching_mod.Fill;

// ─── Tunable constants (defaults; override via TreasuryAgent.config) ────

/// Active pair the agent makes a market on. Hardcoded to OMNI/USDC for
/// Phase 1 — only OMNI/USDC has guaranteed liquidity from claim-TX flow.
pub const PAIR_ID: u16 = 0;

/// How many levels per side. 5 = ten orders total per re-grid.
pub const DEFAULT_LEVELS_PER_SIDE: u8 = 5;

/// Capital weights per level — the closer to mid, the more SAT we commit.
/// Index = level k-1 (0 = closest to mid). Sum is 100 (percent).
pub const DEFAULT_LEVEL_WEIGHTS = [DEFAULT_LEVELS_PER_SIDE]u8{ 40, 25, 15, 12, 8 };

/// Default fraction of treasury balance pushed into grid. The rest is
/// held back as a buffer for NS renewals / premium-fee accounting.
pub const DEFAULT_GRID_ALLOC_PCT: u8 = 70;

/// Volatility window — rolling stddev of the last N trade prices on the
/// active pair. Smaller = more reactive, larger = more stable spread.
pub const VOL_WINDOW: usize = 100;

/// Minimum and maximum k×σ spread, in micro-USD, to clamp the band when
/// stddev is near-zero (cold orderbook) or absurdly large (early outliers).
pub const MIN_SPREAD_MICRO_USD: u64 = 1_000;       // 0.001 USD
pub const MAX_SPREAD_MICRO_USD: u64 = 10_000_000;  // 10 USD

/// Re-grid every N blocks at minimum. Caps thrash on volatile markets.
pub const MIN_REGRID_BLOCKS: u64 = 10;

/// Re-grid early if mid drifts by ≥ DRIFT_THRESHOLD * sigma from the last
/// grid centre. 0.5 = re-grid as soon as mid moves by half a stddev.
pub const DRIFT_THRESHOLD_PCT: u8 = 50;

/// Re-grid early if treasury balance changes by ≥ this % from the last grid.
pub const BALANCE_DELTA_PCT: u8 = 10;

// ─── Config ────────────────────────────────────────────────────────────

pub const Config = struct {
    grid_alloc_pct: u8 = DEFAULT_GRID_ALLOC_PCT,
    levels_per_side: u8 = DEFAULT_LEVELS_PER_SIDE,
    level_weights: [DEFAULT_LEVELS_PER_SIDE]u8 = DEFAULT_LEVEL_WEIGHTS,
    min_regrid_blocks: u64 = MIN_REGRID_BLOCKS,
    drift_threshold_pct: u8 = DRIFT_THRESHOLD_PCT,
    balance_delta_pct: u8 = BALANCE_DELTA_PCT,
    vol_window: usize = VOL_WINDOW,
    enabled: bool = true,
};

// ─── Volatility tracker (rolling stddev) ────────────────────────────────

/// Ring-buffer of trade prices used to compute σ. Fixed size (VOL_WINDOW)
/// so no allocator needed after init.
pub const VolTracker = struct {
    samples: [VOL_WINDOW]u64 = [_]u64{0} ** VOL_WINDOW,
    head: usize = 0,
    count: usize = 0,

    pub fn push(self: *VolTracker, price_micro_usd: u64) void {
        self.samples[self.head] = price_micro_usd;
        self.head = (self.head + 1) % VOL_WINDOW;
        if (self.count < VOL_WINDOW) self.count += 1;
    }

    pub fn mean(self: *const VolTracker) u64 {
        if (self.count == 0) return 0;
        var sum: u128 = 0;
        for (self.samples[0..self.count]) |s| sum += s;
        return @intCast(sum / self.count);
    }

    /// Population stddev. u64 in micro-USD.
    pub fn sigma(self: *const VolTracker) u64 {
        if (self.count < 2) return 0;
        const m: i128 = @intCast(self.mean());
        var sum_sq: u128 = 0;
        for (self.samples[0..self.count]) |s| {
            const diff: i128 = @as(i128, @intCast(s)) - m;
            sum_sq += @intCast(diff * diff);
        }
        const variance = sum_sq / self.count;
        return @intCast(std.math.sqrt(@as(u128, variance)));
    }
};

// ─── Treasury agent state ───────────────────────────────────────────────

/// Tracks one of the agent's live orders so we can cancel cleanly.
const ManagedOrder = struct {
    order_id: u64,
    side: matching_mod.Side,
    level: u8,           // 1..levels_per_side
    price_micro_usd: u64,
    amount_sat: u64,
};

pub const TreasuryAgent = struct {
    /// Mostly constants set at init.
    config: Config,
    /// Treasury wallet — derived from founder mnemonic at slot 5 (.ens).
    /// Holds the secp256k1 key the agent signs every order with.
    wallet: wallet_mod.Wallet,
    /// Treasury bech32 address, cached (slice into the wallet's addr buf).
    treasury_address: []const u8,

    /// References to the systems the agent reads / writes.
    bc: *blockchain_mod.Blockchain,
    engine: *matching_mod.MatchingEngine,

    /// Volatility tracker — fed by `onFill` from rpc_server.
    vol: VolTracker = .{},

    /// Live orders we placed, indexed by slot. Capacity = 2 * levels_per_side
    /// (buys + sells). Unused slots have order_id == 0.
    live_orders: [2 * DEFAULT_LEVELS_PER_SIDE]ManagedOrder =
        [_]ManagedOrder{.{
            .order_id = 0,
            .side = .buy,
            .level = 0,
            .price_micro_usd = 0,
            .amount_sat = 0,
        }} ** (2 * DEFAULT_LEVELS_PER_SIDE),

    /// Grid centre of the last successful re-grid; used for drift check.
    last_grid_mid_micro_usd: u64 = 0,
    /// Treasury balance at the last re-grid; used for balance-delta check.
    last_grid_balance_sat: u64 = 0,
    /// Block height of the last re-grid; cooldown gate.
    last_regrid_block: u64 = 0,

    pub fn init(
        bc: *blockchain_mod.Blockchain,
        engine: *matching_mod.MatchingEngine,
        wallet: wallet_mod.Wallet,
        config: Config,
    ) TreasuryAgent {
        return .{
            .config = config,
            .wallet = wallet,
            .treasury_address = wallet.address,
            .bc = bc,
            .engine = engine,
        };
    }

    /// Called from rpc_server.exchange dispatch whenever a real-mode fill
    /// lands on the active pair. We feed the price into the volatility
    /// tracker so the next re-grid widens/tightens accordingly.
    pub fn onFill(self: *TreasuryAgent, fill: Fill) void {
        if (fill.pair_id != PAIR_ID) return;
        self.vol.push(fill.price_micro_usd);
    }

    /// Called from the mining loop after every block. Decides whether to
    /// re-grid based on cooldown + drift + balance-delta. Cheap when
    /// nothing has changed.
    pub fn tick(self: *TreasuryAgent, current_block: u64) void {
        if (!self.config.enabled) return;
        if (current_block < self.last_regrid_block + self.config.min_regrid_blocks) return;

        const balance = self.bc.getAddressBalance(self.treasury_address);
        if (balance == 0) return; // nothing to grid

        const mid = self.computeMid() orelse return; // need an orderbook ref price

        const drifted = self.midDrifted(mid);
        const balance_changed = self.balanceChanged(balance);
        const first_run = self.last_regrid_block == 0;
        if (!first_run and !drifted and !balance_changed) return;

        self.regrid(current_block, mid, balance) catch |err| {
            std.debug.print("[TREASURY-AGENT] regrid failed: {}\n", .{err});
        };
    }

    /// Compute the reference mid price. If both sides of the orderbook are
    /// populated we use (best_bid + best_ask) / 2. Otherwise we fall back
    /// to the mean of the volatility tracker (last 100 fills) so a cold
    /// book bootstraps from recent trade history. Returns null only if
    /// neither source has data yet — agent waits.
    fn computeMid(self: *const TreasuryAgent) ?u64 {
        const best_bid = self.engine.bestBid(PAIR_ID) orelse 0;
        const best_ask = self.engine.bestAsk(PAIR_ID) orelse 0;
        if (best_bid > 0 and best_ask > 0) {
            return (best_bid + best_ask) / 2;
        }
        const m = self.vol.mean();
        if (m > 0) return m;
        return null;
    }

    fn midDrifted(self: *const TreasuryAgent, current_mid: u64) bool {
        if (self.last_grid_mid_micro_usd == 0) return true;
        const sigma = @max(self.vol.sigma(), MIN_SPREAD_MICRO_USD);
        const threshold = sigma * self.config.drift_threshold_pct / 100;
        const diff = if (current_mid > self.last_grid_mid_micro_usd)
            current_mid - self.last_grid_mid_micro_usd
        else
            self.last_grid_mid_micro_usd - current_mid;
        return diff >= threshold;
    }

    fn balanceChanged(self: *const TreasuryAgent, current_balance: u64) bool {
        if (self.last_grid_balance_sat == 0) return true;
        const diff = if (current_balance > self.last_grid_balance_sat)
            current_balance - self.last_grid_balance_sat
        else
            self.last_grid_balance_sat - current_balance;
        const threshold = self.last_grid_balance_sat * self.config.balance_delta_pct / 100;
        return diff >= threshold;
    }

    /// Cancel every previously-placed live order, then place a fresh
    /// adaptive grid centred on `mid`. Capital = balance × grid_alloc_pct.
    fn regrid(self: *TreasuryAgent, current_block: u64, mid: u64, balance: u64) !void {
        // 1. Cancel everything we still own on the engine.
        for (&self.live_orders) |*mo| {
            if (mo.order_id == 0) continue;
            self.engine.cancelOrder(mo.order_id) catch {};
            mo.order_id = 0;
        }

        const sigma_clamped = std.math.clamp(self.vol.sigma(), MIN_SPREAD_MICRO_USD, MAX_SPREAD_MICRO_USD);
        const grid_capital = balance * self.config.grid_alloc_pct / 100;
        // Half the capital each side — buys consume QUOTE balance,
        // sells consume BASE. We model both as same SAT pool for now;
        // when balances diverge the engine simply rejects the side that
        // can't be funded and we re-grid on next balance change.
        const per_side_capital = grid_capital / 2;

        var placed: usize = 0;

        // 2. Place buy levels: mid - k×σ (k = 1..levels)
        var k: u8 = 1;
        while (k <= self.config.levels_per_side) : (k += 1) {
            const offset = sigma_clamped * k;
            if (offset >= mid) break; // would cross zero, skip
            const price = mid - offset;
            const weight = self.config.level_weights[k - 1];
            const level_capital_quote = per_side_capital * weight / 100;
            // amount_sat = capital_quote × 1e9 / price_micro_usd (u128 to avoid overflow)
            const amt: u64 = @intCast((@as(u128, level_capital_quote) * 1_000_000_000) / @max(price, 1));
            if (amt == 0) continue;

            const oid = self.placeOrder(.buy, price, amt) catch continue;
            self.recordLiveOrder(.buy, k, price, amt, oid, &placed);
        }

        // 3. Place sell levels: mid + k×σ
        k = 1;
        while (k <= self.config.levels_per_side) : (k += 1) {
            const offset = sigma_clamped * k;
            const price = mid + offset;
            const weight = self.config.level_weights[k - 1];
            const level_capital_base = per_side_capital * weight / 100;
            // For sells, level_capital is in BASE (OMNI SAT) directly.
            const amt = level_capital_base;
            if (amt == 0) continue;

            const oid = self.placeOrder(.sell, price, amt) catch continue;
            self.recordLiveOrder(.sell, k, price, amt, oid, &placed);
        }

        self.last_grid_mid_micro_usd = mid;
        self.last_grid_balance_sat = balance;
        self.last_regrid_block = current_block;

        std.debug.print(
            "[TREASURY-AGENT] regrid block={d} mid={d} sigma={d} placed={d}\n",
            .{ current_block, mid, sigma_clamped, placed },
        );
    }

    fn recordLiveOrder(
        self: *TreasuryAgent,
        side: matching_mod.Side,
        level: u8,
        price: u64,
        amount: u64,
        oid: u64,
        placed: *usize,
    ) void {
        for (&self.live_orders) |*mo| {
            if (mo.order_id == 0) {
                mo.* = .{
                    .order_id = oid,
                    .side = side,
                    .level = level,
                    .price_micro_usd = price,
                    .amount_sat = amount,
                };
                placed.* += 1;
                return;
            }
        }
    }

    /// Wrap matching_engine.placeOrder with the treasury wallet identity
    /// and a fresh sequential order_id. The engine accepts the order
    /// without re-verifying signature when called via this internal path
    /// (treasury owns the engine; the chain validators check the engine's
    /// trade log against the chain's UTXO set on settlement).
    fn placeOrder(
        self: *TreasuryAgent,
        side: matching_mod.Side,
        price_micro_usd: u64,
        amount_sat: u64,
    ) !u64 {
        const oid = std.time.nanoTimestamp() & 0x7FFF_FFFF_FFFF_FFFF;
        var ord = Order.empty();
        ord.order_id = @intCast(oid);
        ord.pair_id = PAIR_ID;
        ord.side = side;
        ord.price_micro_usd = price_micro_usd;
        ord.amount_sat = amount_sat;
        ord.timestamp_ms = std.time.milliTimestamp();
        ord.status = .active;

        const addr_bytes = self.treasury_address;
        const addr_len: u8 = @intCast(@min(addr_bytes.len, 64));
        @memcpy(ord.trader_address[0..addr_len], addr_bytes[0..addr_len]);
        ord.trader_addr_len = addr_len;

        try self.engine.placeOrder(ord);
        return ord.order_id;
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "VolTracker — empty has zero mean and sigma" {
    var v = VolTracker{};
    try testing.expectEqual(@as(u64, 0), v.mean());
    try testing.expectEqual(@as(u64, 0), v.sigma());
}

test "VolTracker — single sample stddev is zero" {
    var v = VolTracker{};
    v.push(1_000_000);
    try testing.expectEqual(@as(u64, 1_000_000), v.mean());
    try testing.expectEqual(@as(u64, 0), v.sigma());
}

test "VolTracker — known-population stddev matches" {
    // 1, 2, 3, 4, 5 — pop mean=3, pop variance=2, pop stddev=√2 ≈ 1
    var v = VolTracker{};
    for ([_]u64{ 1, 2, 3, 4, 5 }) |s| v.push(s);
    try testing.expectEqual(@as(u64, 3), v.mean());
    // sqrt(2) integer-truncated = 1. Fine for our adaptive-spread purpose.
    try testing.expectEqual(@as(u64, 1), v.sigma());
}

test "VolTracker — ring buffer saturates at VOL_WINDOW samples" {
    var v = VolTracker{};
    var i: u64 = 0;
    while (i < VOL_WINDOW + 10) : (i += 1) v.push(i * 1000);
    // count saturates at VOL_WINDOW
    try testing.expectEqual(@as(usize, VOL_WINDOW), v.count);
    // Mean is over the LAST VOL_WINDOW pushes (i = 10 .. 10+VOL_WINDOW-1)
    // Sum of arithmetic seq: n×(first+last)/2, integer-divided by count.
    const first: u64 = 10 * 1000;
    const last: u64 = (10 + VOL_WINDOW - 1) * 1000;
    const expected_mean = (first + last) / 2;
    try testing.expectEqual(@as(u64, expected_mean), v.mean());
}
