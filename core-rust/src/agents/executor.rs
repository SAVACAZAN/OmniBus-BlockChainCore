//! executor.rs — per-agent decision engine.
//!
//! Port of `core/agent_executor.zig`. Pure (no IO, no signing): the
//! `tick()` method consumes the latest `AgentState` + `OracleSnapshot`
//! and returns a `Decision` the host translates into either a signed
//! native TX or a queued external-venue request.
//!
//! Algorithm per tick (identical to Zig):
//!   1. Honour halt flag.
//!   2. Check daily-loss limit; halt if breached.
//!   3. Auto-claim faucet if capital == 0.
//!   4. Evaluate user rules in declaration order — first match wins.
//!   5. Fall back to the strategy preset for the current tier.

use serde::{Deserialize, Serialize};

use super::config::{Action, AgentConfig, Metric, Op, Rule, Strategy};
use super::tier::{self, Tier, TierTransition, FAUCET_GRANT_SAT};

/// Agent state snapshot used by tick().
#[derive(Debug, Clone, Default)]
pub struct AgentState {
    pub address: String,
    pub balance_sat: u64,
    pub staked_sat: u64,
    pub lp_locked_sat: u64,
    /// Cumulated session P&L (can be negative).
    pub pnl_session_sat: i64,
    pub tier: Tier,
    pub last_block_height: u64,
    pub halted: bool,
    pub ticks: u64,
}

impl AgentState {
    pub fn capital_sat(&self) -> u64 {
        self.balance_sat + self.staked_sat + self.lp_locked_sat
    }
}

/// Oracle snapshot (BTC/LCX USD prices + spread). Fed by oracle_fetcher.
#[derive(Debug, Clone, Copy, Default)]
pub struct OracleSnapshot {
    pub btc_usd_micro: u64,
    pub lcx_usd_micro: u64,
    pub btc_change_1h_pct: f64,
    pub btc_change_24h_pct: f64,
    pub spread_bps: u32,
    pub block_height: u64,
    pub fresh: bool,
}

/// What the executor decided to do this tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DecisionKind {
    None,
    ClaimFaucet,
    Mine,
    Stake,
    Unstake,
    ProvideLiquidity,
    WithdrawLiquidity,
    Buy,
    Sell,
    Halt,
}

/// Where the decision is executed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Venue {
    None,
    /// Native on-chain (mining / stake / transfer).
    OmnibusNative,
    Lcx,
    Kraken,
    Coinbase,
    /// Native DEX on Liberty Chain.
    OmnibusEx,
    Uniswap,
}

impl Default for Venue {
    fn default() -> Self {
        Venue::None
    }
}

impl Venue {
    pub fn name(self) -> &'static str {
        match self {
            Venue::None => "none",
            Venue::OmnibusNative => "omnibus_native",
            Venue::Lcx => "lcx",
            Venue::Kraken => "kraken",
            Venue::Coinbase => "coinbase",
            Venue::OmnibusEx => "omnibus_ex",
            Venue::Uniswap => "uniswap",
        }
    }
    pub fn is_native(self) -> bool {
        matches!(self, Venue::OmnibusNative)
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Decision {
    pub kind: DecisionKind,
    #[serde(default)]
    pub venue: Venue,
    #[serde(default)]
    pub amount_sat: u64,
    #[serde(default)]
    pub pair: String,
    #[serde(default)]
    pub reason: String,
}

impl Default for DecisionKind {
    fn default() -> Self {
        DecisionKind::None
    }
}

impl Decision {
    pub fn noop() -> Self {
        Self::default()
    }
    pub fn with_reason(mut self, r: impl Into<String>) -> Self {
        self.reason = r.into();
        self
    }
    pub fn with_pair(mut self, p: impl Into<String>) -> Self {
        self.pair = p.into();
        self
    }
}

/// Per-agent decision engine. Holds config + mutable state.
pub struct AgentExecutor {
    pub config: AgentConfig,
    pub state: AgentState,
}

impl AgentExecutor {
    pub fn new(config: AgentConfig, address: impl Into<String>) -> Self {
        let state = AgentState {
            address: address.into(),
            ..Default::default()
        };
        Self { config, state }
    }

    /// Update the financial snapshot (call before each tick).
    pub fn update_balance(&mut self, balance: u64, staked: u64, lp: u64, pnl: i64) {
        self.state.balance_sat = balance;
        self.state.staked_sat = staked;
        self.state.lp_locked_sat = lp;
        self.state.pnl_session_sat = pnl;
    }

    /// Recompute the tier; returns Some(transition) if it changed.
    pub fn recompute_tier(&mut self, block_height: u64) -> Option<TierTransition> {
        let old = self.state.tier;
        let mut new = tier::compute_tier(old, self.state.capital_sat());
        // Apply user-defined cap.
        if let Some(cap) = self.config.tier_cap {
            if new > cap {
                new = cap;
            }
        }
        // If auto_tier off, stay on old (still respecting cap).
        if !self.config.auto_tier {
            new = old;
            if let Some(cap) = self.config.tier_cap {
                if new > cap {
                    new = cap;
                }
            }
        }
        self.state.tier = new;
        if new == old {
            None
        } else {
            Some(TierTransition {
                from: old,
                to: new,
                capital_sat: self.state.capital_sat(),
                block_height,
            })
        }
    }

    /// Main tick — emits a Decision (or NoOp).
    pub fn tick(&mut self, oracle: OracleSnapshot) -> Decision {
        self.state.ticks += 1;

        // 1. Halt has absolute precedence.
        if self.state.halted {
            return Decision::noop();
        }

        // 2. Daily-loss guard.
        let cap = self.state.capital_sat();
        if cap > 0 && self.state.pnl_session_sat < 0 {
            let loss_abs = (-self.state.pnl_session_sat) as u64;
            let max_loss = (cap * self.config.risk.max_daily_loss_pct as u64) / 100;
            if loss_abs >= max_loss {
                self.state.halted = true;
                return Decision {
                    kind: DecisionKind::Halt,
                    venue: Venue::None,
                    amount_sat: 0,
                    pair: String::new(),
                    reason: "daily_loss_limit_breached".to_string(),
                };
            }
        }

        // 3. Bootstrap faucet.
        if cap == 0 && self.config.auto_claim_faucet {
            return Decision {
                kind: DecisionKind::ClaimFaucet,
                amount_sat: FAUCET_GRANT_SAT,
                reason: "bootstrap_faucet".to_string(),
                ..Default::default()
            };
        }

        // 4. User rules — first match wins.
        for rule in self.config.rules.iter().copied() {
            let m = read_metric(rule.metric, &self.state, &oracle);
            if match_op(m, rule.op, rule.threshold) {
                return rule_to_decision(&rule, &self.state, &self.config);
            }
        }

        // 5. Strategy preset for the current tier.
        strategy_decision(self.state.tier, self.config.strategy, &self.state)
    }
}

fn read_metric(metric: Metric, state: &AgentState, oracle: &OracleSnapshot) -> f64 {
    match metric {
        Metric::BtcDrop1hPct => -oracle.btc_change_1h_pct,
        Metric::BtcChange24hPct => oracle.btc_change_24h_pct,
        Metric::CapitalOmni => state.capital_sat() as f64 / 1_000_000_000.0,
        Metric::PnlSessionOmni => state.pnl_session_sat as f64 / 1_000_000_000.0,
        Metric::SpreadBps => oracle.spread_bps as f64,
    }
}

fn match_op(value: f64, op: Op, threshold: f64) -> bool {
    match op {
        Op::Gt => value > threshold,
        Op::Gte => value >= threshold,
        Op::Lt => value < threshold,
        Op::Lte => value <= threshold,
        Op::Eq => value == threshold,
    }
}

fn rule_to_decision(rule: &Rule, state: &AgentState, config: &AgentConfig) -> Decision {
    let cap = state.capital_sat();
    let max_trade = (cap * config.risk.max_trade_pct as u64) / 100;
    let requested = (cap * rule.amount_pct as u64) / 100;
    let amount = requested.min(max_trade);
    let kind = match rule.action {
        Action::Buy => DecisionKind::Buy,
        Action::Sell => DecisionKind::Sell,
        Action::Stake => DecisionKind::Stake,
        Action::ProvideLiquidity => DecisionKind::ProvideLiquidity,
        Action::Halt => DecisionKind::Halt,
    };
    Decision {
        kind,
        amount_sat: amount,
        pair: config.pairs.first().cloned().unwrap_or_default(),
        reason: "user_rule".to_string(),
        ..Default::default()
    }
}

fn strategy_decision(tier: Tier, strat: Strategy, state: &AgentState) -> Decision {
    let cap = state.capital_sat();
    let _ = cap;
    let reserve = 500_000_000u64;
    let idle = if state.balance_sat > reserve {
        state.balance_sat - reserve
    } else {
        0
    };

    let mine = || Decision {
        kind: DecisionKind::Mine,
        reason: "preset_mine".to_string(),
        ..Default::default()
    };
    let stake_idle = |idle: u64| {
        if idle < super::tier::T2_MIN_SAT {
            return mine();
        }
        Decision {
            kind: DecisionKind::Stake,
            amount_sat: idle,
            reason: "preset_stake_idle".to_string(),
            ..Default::default()
        }
    };
    let provide_lp = |idle: u64| {
        if idle < 10_000_000_000 {
            return mine();
        }
        Decision {
            kind: DecisionKind::ProvideLiquidity,
            amount_sat: idle,
            reason: "preset_provide_lp".to_string(),
            ..Default::default()
        }
    };

    match tier {
        Tier::T1Mining => mine(),
        Tier::T2Staking => match strat {
            Strategy::Conservative | Strategy::Balanced | Strategy::MarketMaker => stake_idle(idle),
            Strategy::Aggressive | Strategy::ArbitrageOnly => mine(),
        },
        Tier::T3Liquidity => match strat {
            Strategy::Conservative => stake_idle(idle),
            Strategy::Balanced
            | Strategy::MarketMaker
            | Strategy::Aggressive
            | Strategy::ArbitrageOnly => provide_lp(idle),
        },
        Tier::T4Arbitrage => match strat {
            Strategy::Conservative => stake_idle(idle),
            Strategy::Balanced | Strategy::MarketMaker => provide_lp(idle),
            Strategy::Aggressive | Strategy::ArbitrageOnly => mine(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fresh_agent_claims_faucet() {
        let cfg = AgentConfig::defaults("a", 1);
        let mut ex = AgentExecutor::new(cfg, "ob1q_test");
        let d = ex.tick(OracleSnapshot::default());
        assert_eq!(d.kind, DecisionKind::ClaimFaucet);
        assert_eq!(d.amount_sat, FAUCET_GRANT_SAT);
    }

    #[test]
    fn t1_mines_by_default() {
        let mut cfg = AgentConfig::defaults("a", 1);
        cfg.auto_claim_faucet = false;
        let mut ex = AgentExecutor::new(cfg, "addr");
        ex.update_balance(50_000_000_000, 0, 0, 0);
        ex.recompute_tier(1);
        let d = ex.tick(OracleSnapshot::default());
        assert_eq!(d.kind, DecisionKind::Mine);
        assert_eq!(ex.state.tier, Tier::T1Mining);
    }

    #[test]
    fn user_rule_overrides_preset() {
        let mut cfg = AgentConfig::defaults("a", 1);
        cfg.auto_claim_faucet = false;
        cfg.add_pair("BTC/USD").unwrap();
        cfg.add_rule(Rule {
            metric: Metric::BtcDrop1hPct,
            op: Op::Gte,
            threshold: 5.0,
            action: Action::Buy,
            amount_pct: 10,
        })
        .unwrap();
        let mut ex = AgentExecutor::new(cfg, "addr");
        ex.update_balance(100_000_000_000, 0, 0, 0);
        ex.recompute_tier(1);
        let d = ex.tick(OracleSnapshot {
            btc_change_1h_pct: -6.0,
            fresh: true,
            ..Default::default()
        });
        assert_eq!(d.kind, DecisionKind::Buy);
        assert_eq!(d.pair, "BTC/USD");
        assert_eq!(d.reason, "user_rule");
        // 10% requested, but max_trade_pct = 5 caps it.
        assert_eq!(d.amount_sat, 5_000_000_000);
    }

    #[test]
    fn daily_loss_triggers_halt() {
        let mut cfg = AgentConfig::defaults("a", 1);
        cfg.auto_claim_faucet = false;
        cfg.risk.max_daily_loss_pct = 10;
        let mut ex = AgentExecutor::new(cfg, "addr");
        ex.update_balance(100_000_000_000, 0, 0, -15_000_000_000);
        ex.recompute_tier(1);
        let d = ex.tick(OracleSnapshot::default());
        assert_eq!(d.kind, DecisionKind::Halt);
        assert!(ex.state.halted);
    }

    #[test]
    fn tier_cap_restricts() {
        let mut cfg = AgentConfig::defaults("a", 1);
        cfg.tier_cap = Some(Tier::T2Staking);
        let mut ex = AgentExecutor::new(cfg, "addr");
        ex.update_balance(0, 5_000_000_000_000, 0, 0);
        ex.recompute_tier(1);
        assert_eq!(ex.state.tier, Tier::T2Staking);
    }
}
