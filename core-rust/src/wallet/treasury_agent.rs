//! treasury_agent.rs — Autonomous market-making agent for the NS treasury.
//!
//! Ported from `core/wallet/treasury_agent.zig` (355 lines).
//!
//! Architecture goal (memory: project_omnibus_autonomous_treasury_design):
//! The NS treasury (ens.omnibus, registrar slot 5) accumulates payments
//! from name-claim TXs. The agent ONLY places limit orders on the
//! OMNI/USDC orderbook — it never withdraws or transfers. Adaptive
//! spread: levels at mid ± k×σ for k in 1..=5, where σ is a rolling
//! population stddev of the last `VOL_WINDOW` trade prices.
//!
//! Phase 1 constraints (intentional):
//!   - Single pair: OMNI/USDC (pair_id = 0).
//!   - 70% of treasury balance committed to the grid by default.
//!   - Capital weights per level: [40, 25, 15, 12, 8] (sum = 100).
//!   - Re-grid trigger: cooldown + mid drift ≥ 50% of σ OR balance change ≥ 10%.
//!   - Min 10 blocks between re-grids to prevent orderbook thrash.
//!
//! This file intentionally avoids importing chain/engine types directly
//! so it compiles without the full node stack. In production the caller
//! provides balance and mid-price via the `tick_with_state` entry point.

// ─── Constants ───────────────────────────────────────────────────────────────

pub const PAIR_ID: u16 = 0;
pub const DEFAULT_LEVELS_PER_SIDE: usize = 5;
pub const DEFAULT_LEVEL_WEIGHTS: [u8; DEFAULT_LEVELS_PER_SIDE] = [40, 25, 15, 12, 8];
pub const DEFAULT_GRID_ALLOC_PCT: u8 = 70;
pub const VOL_WINDOW: usize = 100;
/// Minimum spread in micro-USD (0.001 USD).
pub const MIN_SPREAD_MICRO_USD: u64 = 1_000;
/// Maximum spread in micro-USD (10 USD).
pub const MAX_SPREAD_MICRO_USD: u64 = 10_000_000;
pub const MIN_REGRID_BLOCKS: u64 = 10;
/// Re-grid when mid drifts by ≥ 50% of σ.
pub const DRIFT_THRESHOLD_PCT: u8 = 50;
/// Re-grid when balance changes by ≥ 10%.
pub const BALANCE_DELTA_PCT: u8 = 10;

// ─── Config ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct Config {
    pub grid_alloc_pct: u8,
    pub levels_per_side: usize,
    pub level_weights: [u8; DEFAULT_LEVELS_PER_SIDE],
    pub min_regrid_blocks: u64,
    pub drift_threshold_pct: u8,
    pub balance_delta_pct: u8,
    pub vol_window: usize,
    pub enabled: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            grid_alloc_pct: DEFAULT_GRID_ALLOC_PCT,
            levels_per_side: DEFAULT_LEVELS_PER_SIDE,
            level_weights: DEFAULT_LEVEL_WEIGHTS,
            min_regrid_blocks: MIN_REGRID_BLOCKS,
            drift_threshold_pct: DRIFT_THRESHOLD_PCT,
            balance_delta_pct: BALANCE_DELTA_PCT,
            vol_window: VOL_WINDOW,
            enabled: true,
        }
    }
}

// ─── VolTracker ──────────────────────────────────────────────────────────────

/// Ring-buffer of trade prices used to compute rolling population stddev.
/// Fixed capacity = `VOL_WINDOW` — no allocation after init.
#[derive(Debug, Clone)]
pub struct VolTracker {
    samples: [u64; VOL_WINDOW],
    head: usize,
    pub count: usize,
}

impl Default for VolTracker {
    fn default() -> Self {
        VolTracker {
            samples: [0u64; VOL_WINDOW],
            head: 0,
            count: 0,
        }
    }
}

impl VolTracker {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, price_micro_usd: u64) {
        self.samples[self.head] = price_micro_usd;
        self.head = (self.head + 1) % VOL_WINDOW;
        if self.count < VOL_WINDOW {
            self.count += 1;
        }
    }

    pub fn mean(&self) -> u64 {
        if self.count == 0 {
            return 0;
        }
        let sum: u128 = self.samples[..self.count].iter().map(|&s| s as u128).sum();
        (sum / self.count as u128) as u64
    }

    /// Population standard deviation (integer sqrt).
    pub fn sigma(&self) -> u64 {
        if self.count < 2 {
            return 0;
        }
        let m = self.mean() as i128;
        let sum_sq: u128 = self.samples[..self.count]
            .iter()
            .map(|&s| {
                let diff = s as i128 - m;
                (diff * diff) as u128
            })
            .sum();
        let variance = sum_sq / self.count as u128;
        isqrt_u128(variance) as u64
    }
}

fn isqrt_u128(n: u128) -> u128 {
    if n == 0 {
        return 0;
    }
    let mut x = n;
    let mut y = (x + 1) / 2;
    while y < x {
        x = y;
        y = (x + n / x) / 2;
    }
    x
}

// ─── Side ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    Buy,
    Sell,
}

// ─── ManagedOrder ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, Default)]
pub struct ManagedOrder {
    pub order_id: u64,
    pub side: Option<Side>,
    pub level: u8,
    pub price_micro_usd: u64,
    pub amount_sat: u64,
}

// ─── GridResult ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct PlacedOrder {
    pub order_id: u64,
    pub side: Side,
    pub level: u8,
    pub price_micro_usd: u64,
    pub amount_sat: u64,
}

#[derive(Debug, Default)]
pub struct RegridResult {
    pub orders: Vec<PlacedOrder>,
    pub cancelled_count: usize,
    pub mid: u64,
    pub sigma: u64,
}

// ─── TreasuryAgent ───────────────────────────────────────────────────────────

/// Autonomous treasury market-maker.
///
/// Usage pattern (decoupled from chain types for testability):
/// 1. Call `on_fill(price_micro_usd)` whenever a fill occurs on pair 0.
/// 2. Call `tick(current_block, balance_sat, mid_price_micro_usd)` after every
///    mined block. Returns `Some(RegridResult)` when a re-grid was performed.
pub struct TreasuryAgent {
    pub config: Config,
    pub treasury_address: String,
    pub vol: VolTracker,

    /// Currently live orders (slots 0..2*levels_per_side).
    live_orders: Vec<ManagedOrder>,

    last_grid_mid_micro_usd: u64,
    last_grid_balance_sat: u64,
    last_regrid_block: u64,

    /// Monotonic counter for locally-generated order IDs.
    next_order_id: u64,
}

impl TreasuryAgent {
    pub fn new(treasury_address: impl Into<String>, config: Config) -> Self {
        let capacity = 2 * config.levels_per_side;
        TreasuryAgent {
            treasury_address: treasury_address.into(),
            vol: VolTracker::new(),
            live_orders: vec![ManagedOrder::default(); capacity],
            config,
            last_grid_mid_micro_usd: 0,
            last_grid_balance_sat: 0,
            last_regrid_block: 0,
            next_order_id: 1,
        }
    }

    /// Feed a fill event into the volatility tracker.
    pub fn on_fill(&mut self, price_micro_usd: u64) {
        self.vol.push(price_micro_usd);
    }

    /// Per-block tick. Returns `Some(RegridResult)` when a re-grid happened,
    /// `None` when the cooldown / drift / balance guards prevented re-gridding.
    ///
    /// `mid_price` is `None` when the caller cannot determine the orderbook mid
    /// (e.g. cold start). In that case the vol tracker mean is used as fallback.
    pub fn tick(
        &mut self,
        current_block: u64,
        balance_sat: u64,
        mid_price: Option<u64>,
    ) -> Option<RegridResult> {
        if !self.config.enabled {
            return None;
        }
        let first_run = self.last_regrid_block == 0;
        if !first_run && current_block < self.last_regrid_block + self.config.min_regrid_blocks {
            return None;
        }
        if balance_sat == 0 {
            return None;
        }

        let mid = mid_price.or_else(|| {
            let m = self.vol.mean();
            if m > 0 { Some(m) } else { None }
        })?;

        let first_run = self.last_regrid_block == 0;
        let drifted = self.mid_drifted(mid);
        let balance_changed = self.balance_changed(balance_sat);

        if !first_run && !drifted && !balance_changed {
            return None;
        }

        Some(self.regrid(current_block, mid, balance_sat))
    }

    fn mid_drifted(&self, current_mid: u64) -> bool {
        if self.last_grid_mid_micro_usd == 0 {
            return true;
        }
        let sigma = self.vol.sigma().max(MIN_SPREAD_MICRO_USD);
        let threshold = sigma * self.config.drift_threshold_pct as u64 / 100;
        let diff = if current_mid > self.last_grid_mid_micro_usd {
            current_mid - self.last_grid_mid_micro_usd
        } else {
            self.last_grid_mid_micro_usd - current_mid
        };
        diff >= threshold
    }

    fn balance_changed(&self, current_balance: u64) -> bool {
        if self.last_grid_balance_sat == 0 {
            return true;
        }
        let diff = if current_balance > self.last_grid_balance_sat {
            current_balance - self.last_grid_balance_sat
        } else {
            self.last_grid_balance_sat - current_balance
        };
        let threshold = self.last_grid_balance_sat * self.config.balance_delta_pct as u64 / 100;
        diff >= threshold
    }

    /// Cancel live orders and place a fresh adaptive grid.
    fn regrid(&mut self, current_block: u64, mid: u64, balance: u64) -> RegridResult {
        // Cancel all live orders.
        let mut cancelled_count = 0;
        for mo in &mut self.live_orders {
            if mo.order_id != 0 {
                cancelled_count += 1;
                *mo = ManagedOrder::default();
            }
        }

        let sigma_clamped = self
            .vol
            .sigma()
            .max(MIN_SPREAD_MICRO_USD)
            .min(MAX_SPREAD_MICRO_USD);

        let grid_capital = balance * self.config.grid_alloc_pct as u64 / 100;
        let per_side_capital = grid_capital / 2;

        let mut result = RegridResult {
            orders: Vec::new(),
            cancelled_count,
            mid,
            sigma: sigma_clamped,
        };

        // Buy levels: mid - k×σ
        for k in 1..=self.config.levels_per_side {
            let offset = sigma_clamped * k as u64;
            if offset >= mid {
                break;
            }
            let price = mid - offset;
            let weight = self.config.level_weights[k - 1] as u64;
            let capital_quote = per_side_capital * weight / 100;
            let amt = (capital_quote as u128 * 1_000_000_000 / price.max(1) as u128) as u64;
            if amt == 0 {
                continue;
            }
            let oid = self.alloc_order_id();
            self.record_live_order(Side::Buy, k as u8, price, amt, oid);
            result.orders.push(PlacedOrder {
                order_id: oid,
                side: Side::Buy,
                level: k as u8,
                price_micro_usd: price,
                amount_sat: amt,
            });
        }

        // Sell levels: mid + k×σ
        for k in 1..=self.config.levels_per_side {
            let offset = sigma_clamped * k as u64;
            let price = mid + offset;
            let weight = self.config.level_weights[k - 1] as u64;
            let amt = per_side_capital * weight / 100;
            if amt == 0 {
                continue;
            }
            let oid = self.alloc_order_id();
            self.record_live_order(Side::Sell, k as u8, price, amt, oid);
            result.orders.push(PlacedOrder {
                order_id: oid,
                side: Side::Sell,
                level: k as u8,
                price_micro_usd: price,
                amount_sat: amt,
            });
        }

        self.last_grid_mid_micro_usd = mid;
        self.last_grid_balance_sat = balance;
        self.last_regrid_block = current_block;

        eprintln!(
            "[TREASURY-AGENT] regrid block={} mid={} sigma={} placed={}",
            current_block,
            mid,
            sigma_clamped,
            result.orders.len()
        );

        result
    }

    fn alloc_order_id(&mut self) -> u64 {
        let id = self.next_order_id;
        self.next_order_id += 1;
        id
    }

    fn record_live_order(&mut self, side: Side, level: u8, price: u64, amount: u64, oid: u64) {
        for slot in &mut self.live_orders {
            if slot.order_id == 0 {
                *slot = ManagedOrder {
                    order_id: oid,
                    side: Some(side),
                    level,
                    price_micro_usd: price,
                    amount_sat: amount,
                };
                return;
            }
        }
        // All slots occupied — shouldn't happen if capacity = 2 * levels_per_side.
    }

    pub fn live_order_count(&self) -> usize {
        self.live_orders.iter().filter(|mo| mo.order_id != 0).count()
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vol_tracker_empty() {
        let v = VolTracker::new();
        assert_eq!(v.mean(), 0);
        assert_eq!(v.sigma(), 0);
    }

    #[test]
    fn vol_tracker_single_sample() {
        let mut v = VolTracker::new();
        v.push(1_000_000);
        assert_eq!(v.mean(), 1_000_000);
        assert_eq!(v.sigma(), 0);
    }

    #[test]
    fn vol_tracker_known_stddev() {
        // 1,2,3,4,5 → pop mean=3, pop variance=2, pop stddev=√2≈1 (truncated)
        let mut v = VolTracker::new();
        for s in [1u64, 2, 3, 4, 5] {
            v.push(s);
        }
        assert_eq!(v.mean(), 3);
        assert_eq!(v.sigma(), 1);
    }

    #[test]
    fn vol_tracker_ring_buffer_saturates() {
        let mut v = VolTracker::new();
        for i in 0u64..(VOL_WINDOW as u64 + 10) {
            v.push(i * 1000);
        }
        assert_eq!(v.count, VOL_WINDOW);
        // Mean over last VOL_WINDOW pushes (i = 10 .. 10+VOL_WINDOW-1)
        let first = 10u64 * 1000;
        let last = (10 + VOL_WINDOW as u64 - 1) * 1000;
        let expected_mean = (first + last) / 2;
        assert_eq!(v.mean(), expected_mean);
    }

    #[test]
    fn agent_no_regrid_when_disabled() {
        let mut cfg = Config::default();
        cfg.enabled = false;
        let mut agent = TreasuryAgent::new("ob1q_treasury", cfg);
        let result = agent.tick(1, 1_000_000_000, Some(50_000_000));
        assert!(result.is_none());
    }

    #[test]
    fn agent_no_regrid_zero_balance() {
        let mut agent = TreasuryAgent::new("ob1q_treasury", Config::default());
        let result = agent.tick(1, 0, Some(50_000_000));
        assert!(result.is_none());
    }

    #[test]
    fn agent_regrid_on_first_run() {
        let mut agent = TreasuryAgent::new("ob1q_treasury", Config::default());
        // Warm up vol tracker so sigma > 0
        for i in 0..20u64 {
            agent.on_fill(50_000_000 + i * 100_000);
        }
        let result = agent.tick(1, 100_000_000_000, Some(50_000_000));
        assert!(result.is_some());
        let r = result.unwrap();
        assert!(r.orders.len() > 0);
    }

    #[test]
    fn agent_cooldown_prevents_immediate_regrid() {
        let mut agent = TreasuryAgent::new("ob1q_treasury", Config::default());
        for i in 0..20u64 {
            agent.on_fill(50_000_000 + i * 100_000);
        }
        // First regrid
        agent.tick(1, 100_000_000_000, Some(50_000_000));
        // Same block — should be blocked by cooldown (min 10 blocks)
        let result = agent.tick(2, 100_000_000_000, Some(50_000_000));
        assert!(result.is_none());
    }
}
