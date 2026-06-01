//! config.rs — agent configuration (JSON-serialisable).
//!
//! Port of `core/agent_config.zig`. Same JSON schema:
//!
//! ```json
//! { "agents": [
//!   { "name": "alpha", "wallet_index": 1, "strategy": "balanced",
//!     "auto_tier": true, "tick_ms": 5000,
//!     "pairs": ["BTC/USD","ETH/USD"],
//!     "risk": { "max_trade_pct": 5, "max_daily_loss_pct": 10 },
//!     "rules": [ { "metric":"btc_drop_1h_pct","op":"gte",
//!                  "threshold":5.0,"action":"buy","amount_pct":10 } ] }
//! ] }
//! ```

use serde::{Deserialize, Serialize};

use super::tier::Tier;

pub const MAX_AGENTS_PER_NODE: usize = 16;
pub const MAX_RULES_PER_AGENT: usize = 16;
pub const MAX_PAIRS_PER_AGENT: usize = 8;

/// Pre-built strategy presets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Strategy {
    /// Mining + passive staking only. Zero trading risk.
    Conservative,
    /// Mining + staking + LP with wide spread (low risk).
    Balanced,
    /// LP with tight spread + aggressive arbitrage.
    Aggressive,
    /// Cross-exchange arbitrage only (requires T4).
    ArbitrageOnly,
    /// Market making focus — high-volume LP.
    MarketMaker,
}

impl Default for Strategy {
    fn default() -> Self {
        Strategy::Conservative
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Op {
    Gt,
    Gte,
    Lt,
    Lte,
    Eq,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    Buy,
    Sell,
    Stake,
    ProvideLiquidity,
    Halt,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Metric {
    BtcDrop1hPct,
    BtcChange24hPct,
    CapitalOmni,
    PnlSessionOmni,
    SpreadBps,
}

/// User-written rule, evaluated every tick.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Rule {
    pub metric: Metric,
    pub op: Op,
    pub threshold: f64,
    pub action: Action,
    /// Percent of capital to commit (1..100).
    pub amount_pct: u8,
}

/// Hard risk limits — never violated, no matter the strategy / rules.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct RiskLimits {
    /// Max % of capital per single trade.
    pub max_trade_pct: u8,
    /// Max daily loss % before auto-halt.
    pub max_daily_loss_pct: u8,
    /// Reserve to keep for fees, in SAT.
    pub min_reserve_sat: u64,
    /// Max accepted slippage in bps.
    pub max_slippage_bps: u32,
}

impl Default for RiskLimits {
    fn default() -> Self {
        Self {
            max_trade_pct: 5,
            max_daily_loss_pct: 10,
            min_reserve_sat: 500_000_000,
            max_slippage_bps: 50,
        }
    }
}

/// Configuration of one agent.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentConfig {
    pub name: String,
    /// BIP-44 derivation index (1..N; index 0 is the node's wallet).
    pub wallet_index: u32,
    #[serde(default)]
    pub strategy: Strategy,
    /// Auto-progress through tiers as capital grows.
    #[serde(default = "default_true")]
    pub auto_tier: bool,
    /// Optional ceiling tier.
    #[serde(default)]
    pub tier_cap: Option<Tier>,
    /// User rules, evaluated in declaration order.
    #[serde(default)]
    pub rules: Vec<Rule>,
    /// Preferred trading pairs.
    #[serde(default)]
    pub pairs: Vec<String>,
    #[serde(default)]
    pub risk: RiskLimits,
    /// Tick interval in milliseconds.
    #[serde(default = "default_tick_ms")]
    pub tick_ms: u32,
    /// Auto-claim the faucet on first start.
    #[serde(default = "default_true")]
    pub auto_claim_faucet: bool,
}

fn default_true() -> bool {
    true
}
fn default_tick_ms() -> u32 {
    5_000
}

impl Default for AgentConfig {
    fn default() -> Self {
        Self {
            name: String::new(),
            wallet_index: 1,
            strategy: Strategy::Conservative,
            auto_tier: true,
            tier_cap: None,
            rules: Vec::new(),
            pairs: Vec::new(),
            risk: RiskLimits::default(),
            tick_ms: 5_000,
            auto_claim_faucet: true,
        }
    }
}

impl AgentConfig {
    pub fn defaults(name: impl Into<String>, wallet_index: u32) -> Self {
        Self {
            name: name.into(),
            wallet_index,
            ..Default::default()
        }
    }

    pub fn add_pair(&mut self, pair: impl Into<String>) -> Result<(), ConfigError> {
        if self.pairs.len() >= MAX_PAIRS_PER_AGENT {
            return Err(ConfigError::TooManyPairs);
        }
        self.pairs.push(pair.into());
        Ok(())
    }

    pub fn add_rule(&mut self, rule: Rule) -> Result<(), ConfigError> {
        if self.rules.len() >= MAX_RULES_PER_AGENT {
            return Err(ConfigError::TooManyRules);
        }
        if rule.amount_pct == 0 || rule.amount_pct > 100 {
            return Err(ConfigError::InvalidAmountPct);
        }
        self.rules.push(rule);
        Ok(())
    }
}

/// Bundle of agents loaded from a single `agent.json` file.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AgentBundle {
    #[serde(default)]
    pub agents: Vec<AgentConfig>,
}

impl AgentBundle {
    pub fn parse_json(s: &str) -> Result<Self, ConfigError> {
        let bundle: Self = serde_json::from_str(s).map_err(|_| ConfigError::InvalidJson)?;
        if bundle.agents.len() > MAX_AGENTS_PER_NODE {
            return Err(ConfigError::TooManyAgents);
        }
        for a in &bundle.agents {
            if a.pairs.len() > MAX_PAIRS_PER_AGENT {
                return Err(ConfigError::TooManyPairs);
            }
            if a.rules.len() > MAX_RULES_PER_AGENT {
                return Err(ConfigError::TooManyRules);
            }
            for r in &a.rules {
                if r.amount_pct == 0 || r.amount_pct > 100 {
                    return Err(ConfigError::InvalidAmountPct);
                }
            }
        }
        Ok(bundle)
    }

    pub fn load_file(path: &str) -> Result<Self, ConfigError> {
        let text = std::fs::read_to_string(path).map_err(|_| ConfigError::InvalidJson)?;
        Self::parse_json(&text)
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("invalid JSON")]
    InvalidJson,
    #[error("too many agents")]
    TooManyAgents,
    #[error("too many rules")]
    TooManyRules,
    #[error("too many pairs")]
    TooManyPairs,
    #[error("invalid amount_pct")]
    InvalidAmountPct,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_sane() {
        let c = AgentConfig::defaults("alpha", 1);
        assert_eq!(c.name, "alpha");
        assert_eq!(c.wallet_index, 1);
        assert_eq!(c.strategy, Strategy::Conservative);
        assert!(c.auto_tier);
        assert!(c.auto_claim_faucet);
    }

    #[test]
    fn parse_basic_bundle() {
        let json = r#"{
          "agents": [
            { "name":"alpha","wallet_index":1,"strategy":"balanced",
              "auto_tier":true,"tick_ms":3000,
              "pairs":["BTC/USD","ETH/USD"],
              "risk":{"max_trade_pct":3,"max_daily_loss_pct":8,
                      "min_reserve_sat":500000000,"max_slippage_bps":50} }
          ]
        }"#;
        let b = AgentBundle::parse_json(json).unwrap();
        assert_eq!(b.agents.len(), 1);
        let a = &b.agents[0];
        assert_eq!(a.name, "alpha");
        assert_eq!(a.strategy, Strategy::Balanced);
        assert_eq!(a.tick_ms, 3000);
        assert_eq!(a.pairs.len(), 2);
        assert_eq!(a.risk.max_trade_pct, 3);
    }

    #[test]
    fn parse_rule() {
        let json = r#"{
          "agents":[
            {"name":"r","wallet_index":2,"strategy":"aggressive",
             "rules":[
               {"metric":"btc_drop_1h_pct","op":"gte","threshold":5.0,
                "action":"buy","amount_pct":10},
               {"metric":"pnl_session_omni","op":"lte","threshold":-50.0,
                "action":"halt","amount_pct":100}
             ]}
          ]
        }"#;
        let b = AgentBundle::parse_json(json).unwrap();
        let a = &b.agents[0];
        assert_eq!(a.rules.len(), 2);
        assert_eq!(a.rules[0].action, Action::Buy);
        assert_eq!(a.rules[1].action, Action::Halt);
    }

    #[test]
    fn reject_bad_amount_pct() {
        let json = r#"{
          "agents":[
            {"name":"x","wallet_index":1,
             "rules":[ {"metric":"capital_omni","op":"gte","threshold":1.0,
                        "action":"buy","amount_pct":0} ]}
          ]
        }"#;
        assert!(matches!(
            AgentBundle::parse_json(json),
            Err(ConfigError::InvalidAmountPct)
        ));
    }
}
