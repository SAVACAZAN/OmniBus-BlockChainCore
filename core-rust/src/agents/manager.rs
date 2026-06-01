//! manager.rs — agent lifecycle + pending-decision queue.
//!
//! Port of `core/agent_manager.zig`. Tracks active agents (loaded from
//! `agent.json` or registered at runtime), tick all of them on demand,
//! queue non-native decisions for the external client to pick up via
//! `agent_pending_decisions` RPC, and apply receipts from
//! `agent_report_execution`.
//!
//! Differences from the Zig original (idiomatic Rust):
//!   - `HashMap<u32, AgentSlot>` instead of fixed-size array (still
//!     capped by `MAX_AGENTS`).
//!   - `VecDeque<PendingDecision>` instead of a hand-rolled ring buffer.
//!   - Errors are `thiserror`-typed.

use std::collections::{HashMap, VecDeque};

use serde::{Deserialize, Serialize};

use super::config::{AgentBundle, AgentConfig};
use super::executor::{AgentExecutor, Decision, DecisionKind, OracleSnapshot, Venue};
use super::tier::{Tier, TierTransition};
use super::wallet::AgentWallet;

pub const MAX_AGENTS: usize = super::config::MAX_AGENTS_PER_NODE;
/// Non-native decisions waiting on the external client.
pub const MAX_PENDING_DECISIONS: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecStatus {
    Success,
    Rejected,
    NetworkError,
    Timeout,
    Cancelled,
}

/// Receipt the external client returns after attempting an external trade.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecReceipt {
    pub decision_id: u64,
    pub status: ExecStatus,
    #[serde(default)]
    pub external_id: String,
    #[serde(default)]
    pub filled_amount_sat: u64,
    #[serde(default)]
    pub fill_price_micro_usd: u64,
    #[serde(default)]
    pub error_msg: String,
    #[serde(default)]
    pub reported_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PendingDecision {
    pub id: u64,
    pub wallet_index: u32,
    pub block_height: u64,
    pub emitted_ms: i64,
    pub decision: Decision,
    pub settled: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AgentStats {
    pub ticks: u64,
    pub decisions_emitted: u64,
    pub txs_submitted: u64,
    pub tier_transitions: u32,
    pub total_mined_sat: u64,
    pub decisions_queued: u64,
    pub exec_success: u64,
    pub exec_failed: u64,
}

pub struct AgentSlot {
    pub config: AgentConfig,
    pub address: String,
    pub wallet: Option<AgentWallet>,
    pub executor: AgentExecutor,
    pub stats: AgentStats,
    pub last_decision: Decision,
    pub last_transition: Option<TierTransition>,
}

impl AgentSlot {
    pub fn can_sign(&self) -> bool {
        self.wallet.as_ref().map_or(false, |w| w.can_sign())
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ManagerError {
    #[error("no slot available")]
    NoSlotAvailable,
    #[error("duplicate wallet_index {0}")]
    DuplicateWalletIndex(u32),
    #[error("agent not found: wallet_index {0}")]
    AgentNotFound(u32),
    #[error("wallet derive: {0}")]
    Wallet(String),
}

pub struct AgentManager {
    /// Keyed by `wallet_index`.
    slots: HashMap<u32, AgentSlot>,
    pending: VecDeque<PendingDecision>,
    next_decision_id: u64,
}

impl Default for AgentManager {
    fn default() -> Self {
        Self::new()
    }
}

impl AgentManager {
    pub fn new() -> Self {
        Self {
            slots: HashMap::new(),
            pending: VecDeque::with_capacity(MAX_PENDING_DECISIONS),
            next_decision_id: 1,
        }
    }

    /// Register an agent whose wallet is derived from the node mnemonic.
    /// Such an agent CAN sign native TX.
    pub fn add_from_mnemonic(
        &mut self,
        config: AgentConfig,
        mnemonic: &str,
    ) -> Result<u32, ManagerError> {
        if self.slots.contains_key(&config.wallet_index) {
            return Err(ManagerError::DuplicateWalletIndex(config.wallet_index));
        }
        if self.slots.len() >= MAX_AGENTS {
            return Err(ManagerError::NoSlotAvailable);
        }
        let wallet = AgentWallet::derive(mnemonic, config.wallet_index)
            .map_err(|e| ManagerError::Wallet(e.to_string()))?;
        let address = wallet.address.clone();
        let idx = config.wallet_index;
        let executor = AgentExecutor::new(config.clone(), address.clone());
        self.slots.insert(
            idx,
            AgentSlot {
                config,
                address,
                wallet: Some(wallet),
                executor,
                stats: AgentStats::default(),
                last_decision: Decision::noop(),
                last_transition: None,
            },
        );
        Ok(idx)
    }

    /// Register a read-only agent (no mnemonic). Cannot sign TX.
    pub fn add(&mut self, config: AgentConfig, address: impl Into<String>) -> Result<u32, ManagerError> {
        if self.slots.contains_key(&config.wallet_index) {
            return Err(ManagerError::DuplicateWalletIndex(config.wallet_index));
        }
        if self.slots.len() >= MAX_AGENTS {
            return Err(ManagerError::NoSlotAvailable);
        }
        let address = address.into();
        let idx = config.wallet_index;
        let executor = AgentExecutor::new(config.clone(), address.clone());
        self.slots.insert(
            idx,
            AgentSlot {
                config,
                address,
                wallet: None,
                executor,
                stats: AgentStats::default(),
                last_decision: Decision::noop(),
                last_transition: None,
            },
        );
        Ok(idx)
    }

    pub fn add_bundle(
        &mut self,
        bundle: AgentBundle,
        mnemonic: &str,
    ) -> Vec<Result<u32, ManagerError>> {
        bundle
            .agents
            .into_iter()
            .map(|c| self.add_from_mnemonic(c, mnemonic))
            .collect()
    }

    pub fn count(&self) -> usize {
        self.slots.len()
    }

    pub fn get(&self, wallet_index: u32) -> Option<&AgentSlot> {
        self.slots.get(&wallet_index)
    }
    pub fn get_mut(&mut self, wallet_index: u32) -> Option<&mut AgentSlot> {
        self.slots.get_mut(&wallet_index)
    }
    pub fn find_by_name(&self, name: &str) -> Option<&AgentSlot> {
        self.slots.values().find(|s| s.config.name == name)
    }

    pub fn remove(&mut self, wallet_index: u32) -> Result<(), ManagerError> {
        self.slots
            .remove(&wallet_index)
            .map(|_| ())
            .ok_or(ManagerError::AgentNotFound(wallet_index))
    }

    /// Pause the agent — its tick() will return NoOp.
    pub fn pause(&mut self, wallet_index: u32) -> Result<(), ManagerError> {
        let s = self
            .get_mut(wallet_index)
            .ok_or(ManagerError::AgentNotFound(wallet_index))?;
        s.executor.state.halted = true;
        Ok(())
    }

    /// Resume a paused agent.
    pub fn resume(&mut self, wallet_index: u32) -> Result<(), ManagerError> {
        let s = self
            .get_mut(wallet_index)
            .ok_or(ManagerError::AgentNotFound(wallet_index))?;
        s.executor.state.halted = false;
        Ok(())
    }

    /// Terminate an agent (alias for remove — kept for API parity).
    pub fn terminate(&mut self, wallet_index: u32) -> Result<(), ManagerError> {
        self.remove(wallet_index)
    }

    /// Tick a single agent.
    pub fn tick_one(
        &mut self,
        wallet_index: u32,
        oracle: OracleSnapshot,
        block_height: u64,
    ) -> Option<Decision> {
        let slot = self.slots.get_mut(&wallet_index)?;
        if let Some(t) = slot.executor.recompute_tier(block_height) {
            slot.last_transition = Some(t);
            slot.stats.tier_transitions += 1;
        }
        let d = slot.executor.tick(oracle);
        slot.last_decision = d.clone();
        slot.stats.ticks += 1;
        if d.kind != DecisionKind::None {
            slot.stats.decisions_emitted += 1;
        }
        slot.executor.state.last_block_height = block_height;
        Some(d)
    }

    /// Tick all agents; returns Vec<(wallet_index, Decision)>.
    pub fn tick_all(
        &mut self,
        oracle: OracleSnapshot,
        block_height: u64,
    ) -> Vec<(u32, Decision)> {
        let keys: Vec<u32> = self.slots.keys().copied().collect();
        keys.into_iter()
            .filter_map(|k| self.tick_one(k, oracle, block_height).map(|d| (k, d)))
            .collect()
    }

    /// Queue a non-native decision for external execution. Returns the id.
    pub fn queue_decision(
        &mut self,
        wallet_index: u32,
        block_height: u64,
        decision: Decision,
    ) -> u64 {
        // Drop oldest settled (or oldest unsettled if full) — matches Zig.
        if self.pending.len() >= MAX_PENDING_DECISIONS {
            if let Some(pos) = self.pending.iter().position(|p| p.settled) {
                self.pending.remove(pos);
            } else {
                self.pending.pop_front();
            }
        }
        let id = self.next_decision_id;
        self.next_decision_id += 1;
        let emitted_ms = now_ms();
        self.pending.push_back(PendingDecision {
            id,
            wallet_index,
            block_height,
            emitted_ms,
            decision,
            settled: false,
        });
        if let Some(s) = self.slots.get_mut(&wallet_index) {
            s.stats.decisions_queued += 1;
        }
        // WS event — surface agent decisions to the frontend agent panel.
        let last = self.pending.back().unwrap();
        crate::ws::try_broadcast(crate::ws::Event::AgentDecision {
            wallet_index,
            decision_id: id,
            kind: format!("{:?}", last.decision.kind),
            venue: format!("{:?}", last.decision.venue),
            amount_sat: last.decision.amount_sat,
            pair: last.decision.pair.clone(),
            reason: last.decision.reason.clone(),
            block_height,
        });
        id
    }

    /// Convenience: tick + auto-queue any non-native decision.
    pub fn tick_and_route(
        &mut self,
        oracle: OracleSnapshot,
        block_height: u64,
    ) -> Vec<(u32, Decision, Option<u64>)> {
        let ticked = self.tick_all(oracle, block_height);
        ticked
            .into_iter()
            .map(|(wi, d)| {
                let id = match d.venue {
                    Venue::None | Venue::OmnibusNative => None,
                    _ if d.kind == DecisionKind::None => None,
                    _ => Some(self.queue_decision(wi, block_height, d.clone())),
                };
                (wi, d, id)
            })
            .collect()
    }

    /// How many non-settled decisions are currently pending?
    pub fn pending_count(&self) -> usize {
        self.pending.iter().filter(|p| !p.settled).count()
    }

    /// Snapshot non-settled decisions, optionally filtered by wallet_index.
    pub fn snapshot_pending(&self, filter_wallet: Option<u32>) -> Vec<PendingDecision> {
        self.pending
            .iter()
            .filter(|p| !p.settled)
            .filter(|p| filter_wallet.map_or(true, |w| p.wallet_index == w))
            .cloned()
            .collect()
    }

    /// Apply an external receipt. Returns true if a pending decision was settled.
    pub fn apply_receipt(&mut self, receipt: ExecReceipt) -> bool {
        let mut wi: Option<u32> = None;
        let mut status: Option<ExecStatus> = None;
        for p in self.pending.iter_mut() {
            if p.id != receipt.decision_id {
                continue;
            }
            if p.settled {
                return false;
            }
            p.settled = true;
            wi = Some(p.wallet_index);
            status = Some(receipt.status);
            break;
        }
        match (wi, status) {
            (Some(w), Some(st)) => {
                if let Some(s) = self.slots.get_mut(&w) {
                    match st {
                        ExecStatus::Success => s.stats.exec_success += 1,
                        _ => s.stats.exec_failed += 1,
                    }
                }
                true
            }
            _ => false,
        }
    }

    /// Record a submitted native TX (caller increments after sendrawtransaction).
    pub fn record_submitted_tx(&mut self, wallet_index: u32) {
        if let Some(s) = self.slots.get_mut(&wallet_index) {
            s.stats.txs_submitted += 1;
        }
    }

    /// Record a mining reward received by an agent.
    pub fn record_reward(&mut self, wallet_index: u32, amount_sat: u64) {
        if let Some(s) = self.slots.get_mut(&wallet_index) {
            s.stats.total_mined_sat += amount_sat;
        }
    }

    /// Snapshot suitable for the `agent_list` RPC.
    pub fn snapshot(&self) -> Vec<AgentSnapshotItem> {
        self.slots
            .values()
            .map(|s| AgentSnapshotItem {
                name: s.config.name.clone(),
                wallet_index: s.config.wallet_index,
                address: s.address.clone(),
                strategy: s.config.strategy,
                tier: s.executor.state.tier,
                balance_sat: s.executor.state.balance_sat,
                staked_sat: s.executor.state.staked_sat,
                lp_locked_sat: s.executor.state.lp_locked_sat,
                pnl_session_sat: s.executor.state.pnl_session_sat,
                halted: s.executor.state.halted,
                stats: s.stats.clone(),
            })
            .collect()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentSnapshotItem {
    pub name: String,
    pub wallet_index: u32,
    pub address: String,
    pub strategy: super::config::Strategy,
    pub tier: Tier,
    pub balance_sat: u64,
    pub staked_sat: u64,
    pub lp_locked_sat: u64,
    pub pnl_session_sat: i64,
    pub halted: bool,
    pub stats: AgentStats,
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::super::config::Strategy;
    use super::*;

    const MNEMONIC: &str =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn add_count_find() {
        let mut m = AgentManager::new();
        m.add(AgentConfig::defaults("alpha", 1), "ob1q_alpha").unwrap();
        m.add(AgentConfig::defaults("beta", 2), "ob1q_beta").unwrap();
        assert_eq!(m.count(), 2);
        assert_eq!(m.get(1).unwrap().config.name, "alpha");
        assert_eq!(m.find_by_name("beta").unwrap().config.wallet_index, 2);
    }

    #[test]
    fn reject_duplicate_index() {
        let mut m = AgentManager::new();
        m.add(AgentConfig::defaults("a", 1), "addr1").unwrap();
        assert!(matches!(
            m.add(AgentConfig::defaults("b", 1), "addr2"),
            Err(ManagerError::DuplicateWalletIndex(1))
        ));
    }

    #[test]
    fn pause_resume_terminate() {
        let mut m = AgentManager::new();
        m.add(AgentConfig::defaults("a", 1), "addr1").unwrap();
        m.pause(1).unwrap();
        assert!(m.get(1).unwrap().executor.state.halted);
        m.resume(1).unwrap();
        assert!(!m.get(1).unwrap().executor.state.halted);
        m.terminate(1).unwrap();
        assert_eq!(m.count(), 0);
    }

    #[test]
    fn tick_one_updates_stats() {
        let mut m = AgentManager::new();
        let mut cfg = AgentConfig::defaults("a", 1);
        cfg.auto_claim_faucet = false;
        m.add(cfg, "addr").unwrap();
        m.get_mut(1)
            .unwrap()
            .executor
            .update_balance(50_000_000_000, 0, 0, 0);
        let d = m.tick_one(1, OracleSnapshot::default(), 100).unwrap();
        assert_eq!(d.kind, DecisionKind::Mine);
        assert_eq!(m.get(1).unwrap().stats.ticks, 1);
    }

    #[test]
    fn queue_then_apply_receipt() {
        let mut m = AgentManager::new();
        m.add(AgentConfig::defaults("a", 1), "addr1").unwrap();
        let d = Decision {
            kind: DecisionKind::Buy,
            venue: Venue::Lcx,
            amount_sat: 1_000_000,
            pair: "BTC/USD".into(),
            reason: "test".into(),
        };
        let id = m.queue_decision(1, 100, d);
        assert_eq!(m.pending_count(), 1);

        let r = ExecReceipt {
            decision_id: id,
            status: ExecStatus::Success,
            external_id: "LCX-1".into(),
            filled_amount_sat: 1_000_000,
            fill_price_micro_usd: 0,
            error_msg: String::new(),
            reported_ms: 0,
        };
        assert!(m.apply_receipt(r.clone()));
        assert!(!m.apply_receipt(r)); // double-report rejected
        assert_eq!(m.pending_count(), 0);
        assert_eq!(m.get(1).unwrap().stats.exec_success, 1);
    }

    #[test]
    fn snapshot_pending_filter() {
        let mut m = AgentManager::new();
        m.add(AgentConfig::defaults("a", 1), "a1").unwrap();
        m.add(AgentConfig::defaults("b", 2), "a2").unwrap();
        m.queue_decision(
            1,
            1,
            Decision {
                kind: DecisionKind::Buy,
                venue: Venue::Lcx,
                ..Default::default()
            },
        );
        m.queue_decision(
            2,
            1,
            Decision {
                kind: DecisionKind::Sell,
                venue: Venue::Kraken,
                ..Default::default()
            },
        );
        m.queue_decision(
            1,
            1,
            Decision {
                kind: DecisionKind::Buy,
                venue: Venue::Coinbase,
                ..Default::default()
            },
        );
        assert_eq!(m.snapshot_pending(None).len(), 3);
        assert_eq!(m.snapshot_pending(Some(1)).len(), 2);
        assert_eq!(m.snapshot_pending(Some(2)).len(), 1);
    }

    #[test]
    fn add_from_mnemonic_derives_address() {
        let mut m = AgentManager::new();
        let id1 = m
            .add_from_mnemonic(AgentConfig::defaults("alpha", 1), MNEMONIC)
            .unwrap();
        let id2 = m
            .add_from_mnemonic(AgentConfig::defaults("beta", 2), MNEMONIC)
            .unwrap();
        assert_eq!(id1, 1);
        assert_eq!(id2, 2);
        let a1 = m.get(1).unwrap();
        let a2 = m.get(2).unwrap();
        assert!(a1.can_sign());
        assert!(a2.can_sign());
        assert_ne!(a1.address, a2.address);
        assert!(a1.address.starts_with("ob1q"));
        let _ = Strategy::Conservative; // ensure import resolves
    }
}
