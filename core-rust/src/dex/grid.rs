//! Grid trading engine.
//!
//! Mirrors `core/grid_engine.zig` semantics:
//!   - User sets `{ pair_id, price_low, price_high, levels, total_base,
//!     total_quote }` → engine generates N buy + N sell virtual orders.
//!   - Orders are placed into the matching engine as "open"; funds are NOT
//!     locked until a fill happens (per CLAUDE.md DEX rules).
//!   - On fill, an opposite order is auto-placed at the adjacent level to
//!     refill the grid (sell filled → buy one step lower; buy filled →
//!     sell one step higher).
//!   - HTLCs are born at fill time, not at grid creation.
//!
//! Prices are micro-USD (6 decimals); amounts are SAT (1 OMNI = 1e9).

use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::matching::MatchingEngine;
use super::order::{Order, Side};

pub const MAX_GRIDS: usize = 256;
pub const MAX_LEVELS: u16 = 100;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GridConfig {
    pub id: u64,
    pub owner: Vec<u8>,
    pub pair_id: u16,
    pub price_low: u64,
    pub price_high: u64,
    pub levels: u16,
    pub total_base: u64,
    pub total_quote: u64,
    pub filled_count: u32,
    pub profit_quote: i64,
    pub active: bool,
    pub created_block: u64,
}

impl GridConfig {
    pub fn price_step(&self) -> u64 {
        if self.levels == 0 {
            return 0;
        }
        (self.price_high - self.price_low) / (self.levels as u64 * 2)
    }

    /// Price of buy level `i` (0 = lowest).
    pub fn buy_price(&self, i: u16) -> u64 {
        self.price_low + (i as u64) * self.price_step()
    }

    /// Price of sell level `i` (0 = first sell, just above mid).
    pub fn sell_price(&self, i: u16) -> u64 {
        let mid = self.price_low + (self.levels as u64) * self.price_step();
        mid + (i as u64) * self.price_step()
    }

    pub fn base_per_level(&self) -> u64 {
        if self.levels == 0 {
            0
        } else {
            self.total_base / self.levels as u64
        }
    }
    pub fn quote_per_level(&self) -> u64 {
        if self.levels == 0 {
            0
        } else {
            self.total_quote / self.levels as u64
        }
    }
}

#[derive(Debug, Error)]
pub enum GridError {
    #[error("price_low must be < price_high")]
    InvalidRange,
    #[error("levels must be 1..=100")]
    TooManyLevels,
    #[error("grid registry full")]
    Full,
    #[error("grid not found")]
    NotFound,
    #[error("not owner")]
    NotOwner,
    #[error("grid already inactive")]
    AlreadyInactive,
}

#[derive(Debug, Default)]
pub struct GridRegistry {
    grids: Vec<GridConfig>,
    next_id: u64,
}

impl GridRegistry {
    pub fn new() -> Self {
        Self {
            grids: Vec::new(),
            next_id: 1,
        }
    }

    /// `grid_create` RPC equivalent.
    pub fn create(
        &mut self,
        owner: Vec<u8>,
        pair_id: u16,
        price_low: u64,
        price_high: u64,
        levels: u16,
        total_base: u64,
        total_quote: u64,
        current_block: u64,
    ) -> Result<u64, GridError> {
        if price_low >= price_high {
            return Err(GridError::InvalidRange);
        }
        if levels == 0 || levels > MAX_LEVELS {
            return Err(GridError::TooManyLevels);
        }
        if self.grids.len() >= MAX_GRIDS {
            return Err(GridError::Full);
        }
        let id = self.next_id;
        self.next_id += 1;
        self.grids.push(GridConfig {
            id,
            owner,
            pair_id,
            price_low,
            price_high,
            levels,
            total_base,
            total_quote,
            filled_count: 0,
            profit_quote: 0,
            active: true,
            created_block: current_block,
        });
        Ok(id)
    }

    pub fn find(&self, grid_id: u64) -> Option<&GridConfig> {
        self.grids.iter().find(|g| g.id == grid_id)
    }

    fn find_mut(&mut self, grid_id: u64) -> Option<&mut GridConfig> {
        self.grids.iter_mut().find(|g| g.id == grid_id)
    }

    /// `grid_list` RPC — all grids (filter by owner at caller side).
    pub fn list(&self) -> &[GridConfig] {
        &self.grids
    }

    /// `grid_status` RPC.
    pub fn status(&self, grid_id: u64) -> Option<&GridConfig> {
        self.find(grid_id)
    }

    /// `grid_cancel` RPC.
    pub fn cancel(&mut self, grid_id: u64, owner: &[u8]) -> Result<(), GridError> {
        let g = self.find_mut(grid_id).ok_or(GridError::NotFound)?;
        if g.owner != owner {
            return Err(GridError::NotOwner);
        }
        if !g.active {
            return Err(GridError::AlreadyInactive);
        }
        g.active = false;
        Ok(())
    }

    /// Place N buy + N sell virtual orders into a matching engine for a
    /// freshly created grid. Funds are NOT locked — these are bookkeeping
    /// orders only.
    pub fn place_level_orders(
        &mut self,
        grid_id: u64,
        engine: &mut MatchingEngine,
        now_ms: i64,
    ) {
        let Some(g) = self.find(grid_id) else { return };
        if !g.active || g.levels == 0 {
            return;
        }
        let base_per = g.base_per_level();
        let quote_per = g.quote_per_level();
        let owner = g.owner.clone();
        let pair_id = g.pair_id;
        let levels = g.levels;

        // BUYs: price_low .. mid (ascending).
        for i in 0..levels {
            let price = g.buy_price(i);
            if price == 0 {
                continue;
            }
            // amount_sat = quote_per * 1e6 / price (so base*price=quote per level).
            let amount_sat = quote_per.saturating_mul(1_000_000) / price;
            if amount_sat == 0 {
                continue;
            }
            let order = Order::new(owner.clone(), pair_id, Side::Buy, price, amount_sat, now_ms);
            let _ = engine.place_order(order);
        }
        // SELLs: mid .. price_high (ascending).
        for i in 0..levels {
            if base_per == 0 {
                continue;
            }
            let price = g.sell_price(i);
            let order = Order::new(owner.clone(), pair_id, Side::Sell, price, base_per, now_ms);
            let _ = engine.place_order(order);
        }
    }
}

// ─── Tick — called each block ─────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct GridFill {
    pub grid_id: u64,
    pub level_idx: u16,
    pub side: Side,
    pub price: u64,
    pub amount_base: u64,
    pub amount_quote: u64,
    pub block_height: u64,
}

#[derive(Debug, Clone)]
pub struct FollowOrder {
    pub grid_id: u64,
    pub pair_id: u16,
    pub side: Side,
    pub price: u64,
    pub amount_base: u64,
    pub amount_quote: u64,
}

#[derive(Debug, Default)]
pub struct TickResult {
    pub fills: Vec<GridFill>,
    pub follow_orders: Vec<FollowOrder>,
}

/// Process all active grids against the current oracle price for a pair.
/// Generates at most one fill per grid per tick (matches Zig semantics).
pub fn tick(
    registry: &mut GridRegistry,
    pair_id: u16,
    oracle_price: u64,
    block_height: u64,
) -> TickResult {
    let mut result = TickResult::default();

    for g in &mut registry.grids {
        if !g.active || g.pair_id != pair_id {
            continue;
        }
        let step = g.price_step();
        if step == 0 {
            continue;
        }
        let amount_base = g.base_per_level();

        // Check sell levels (oracle climbed up → fill a sell).
        let mut handled = false;
        for lvl in 0..g.levels {
            let sell_p = g.sell_price(lvl);
            if oracle_price >= sell_p {
                let amount_quote = sell_p.saturating_mul(amount_base) / 1_000_000;
                result.fills.push(GridFill {
                    grid_id: g.id,
                    level_idx: g.levels + lvl,
                    side: Side::Sell,
                    price: sell_p,
                    amount_base,
                    amount_quote,
                    block_height,
                });
                let buy_p = sell_p.saturating_sub(step);
                result.follow_orders.push(FollowOrder {
                    grid_id: g.id,
                    pair_id,
                    side: Side::Buy,
                    price: buy_p,
                    amount_base,
                    amount_quote: buy_p.saturating_mul(amount_base) / 1_000_000,
                });
                g.filled_count += 1;
                g.profit_quote = g
                    .profit_quote
                    .saturating_add((step.saturating_mul(amount_base) / 1_000_000) as i64);
                handled = true;
                break;
            }
        }
        if handled {
            continue;
        }
        // Check buy levels (oracle dropped down → fill a buy).
        for lvl in 0..g.levels {
            let buy_idx = g.levels - 1 - lvl;
            let buy_p = g.buy_price(buy_idx);
            if oracle_price <= buy_p {
                let amount_quote = buy_p.saturating_mul(amount_base) / 1_000_000;
                result.fills.push(GridFill {
                    grid_id: g.id,
                    level_idx: buy_idx,
                    side: Side::Buy,
                    price: buy_p,
                    amount_base,
                    amount_quote,
                    block_height,
                });
                let sell_p = buy_p + step;
                result.follow_orders.push(FollowOrder {
                    grid_id: g.id,
                    pair_id,
                    side: Side::Sell,
                    price: sell_p,
                    amount_base,
                    amount_quote: sell_p.saturating_mul(amount_base) / 1_000_000,
                });
                g.filled_count += 1;
                g.profit_quote = g
                    .profit_quote
                    .saturating_sub((step.saturating_mul(amount_base) / 1_000_000) as i64);
                break;
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn price_step_and_levels() {
        let g = GridConfig {
            id: 1,
            owner: vec![],
            pair_id: 0,
            price_low: 100_000,
            price_high: 200_000,
            levels: 10,
            total_base: 1_000_000_000,
            total_quote: 1_000_000,
            filled_count: 0,
            profit_quote: 0,
            active: true,
            created_block: 0,
        };
        assert_eq!(g.price_step(), 5_000);
        assert_eq!(g.buy_price(0), 100_000);
        assert_eq!(g.sell_price(0), 150_000);
    }

    #[test]
    fn create_find_cancel() {
        let mut r = GridRegistry::new();
        let id = r
            .create(b"alex".to_vec(), 0, 100_000, 200_000, 10, 1_000_000_000, 1_000_000, 1)
            .unwrap();
        assert!(r.find(id).unwrap().active);
        r.cancel(id, b"alex").unwrap();
        assert!(!r.find(id).unwrap().active);
        assert!(matches!(r.cancel(id, b"alex"), Err(GridError::AlreadyInactive)));
        assert!(matches!(r.cancel(id, b"other"), Err(GridError::NotFound) | Err(GridError::NotOwner)));
    }

    #[test]
    fn invalid_range_and_levels() {
        let mut r = GridRegistry::new();
        assert!(matches!(
            r.create(vec![], 0, 200_000, 100_000, 10, 1, 1, 1),
            Err(GridError::InvalidRange)
        ));
        assert!(matches!(
            r.create(vec![], 0, 100_000, 200_000, 0, 1, 1, 1),
            Err(GridError::TooManyLevels)
        ));
        assert!(matches!(
            r.create(vec![], 0, 100_000, 200_000, 101, 1, 1, 1),
            Err(GridError::TooManyLevels)
        ));
    }

    #[test]
    fn tick_fills_sell_when_oracle_rises() {
        let mut r = GridRegistry::new();
        r.create(b"a".to_vec(), 0, 100_000, 200_000, 10, 1_000_000_000, 1_000_000, 1)
            .unwrap();
        let res = tick(&mut r, 0, 160_000, 2);
        assert!(!res.fills.is_empty());
        assert_eq!(res.fills[0].side, Side::Sell);
        assert_eq!(res.fills[0].price, 150_000); // first sell level == mid
        assert_eq!(res.follow_orders[0].side, Side::Buy);
        assert_eq!(res.follow_orders[0].price, 145_000);
    }

    #[test]
    fn tick_fills_buy_when_oracle_falls() {
        let mut r = GridRegistry::new();
        r.create(b"a".to_vec(), 0, 100_000, 200_000, 10, 1_000_000_000, 1_000_000, 1)
            .unwrap();
        let res = tick(&mut r, 0, 120_000, 3);
        assert!(!res.fills.is_empty());
        assert_eq!(res.fills[0].side, Side::Buy);
        assert_eq!(res.follow_orders[0].side, Side::Sell);
    }

    #[test]
    fn tick_ignores_other_pairs() {
        let mut r = GridRegistry::new();
        r.create(b"a".to_vec(), 0, 100_000, 200_000, 10, 1_000_000_000, 1_000_000, 1)
            .unwrap();
        let res = tick(&mut r, 3, 160_000, 2);
        assert!(res.fills.is_empty());
    }
}
