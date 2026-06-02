//! Strategy Registry — on-chain operator-defined trading programs.
//!
//! Port of `core/strategy_registry.zig`. Fixed-cap store, process-global,
//! mutex-guarded. Each strategy is a (id, agent_id, owner, name, type,
//! status, params_json, pnl_sat, fill_count) record.

use std::sync::Mutex;

pub const MAX_STRATEGIES: usize = 512;
pub const MAX_PARAM_LEN: usize = 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum StrategyType {
    Grid = 0,
    Arb = 1,
    Mm = 2,
    Snipe = 3,
    Custom = 4,
}

impl StrategyType {
    pub fn from_str(s: &str) -> Self {
        match s {
            "grid" => Self::Grid,
            "arb" => Self::Arb,
            "mm" => Self::Mm,
            "snipe" => Self::Snipe,
            _ => Self::Custom,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Grid => "grid",
            Self::Arb => "arb",
            Self::Mm => "mm",
            Self::Snipe => "snipe",
            Self::Custom => "custom",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum StrategyStatus {
    Draft = 0,
    Active = 1,
    Paused = 2,
    Cancelled = 3,
}

impl StrategyStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Draft => "draft",
            Self::Active => "active",
            Self::Paused => "paused",
            Self::Cancelled => "cancelled",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Strategy {
    pub id: u64,
    pub agent_id: u64,
    pub owner: String,
    pub name: String,
    pub stype: StrategyType,
    pub status: StrategyStatus,
    pub params: String,
    pub created_at: i64,
    pub activated_at: i64,
    pub fill_count: u64,
    /// Signed: PnL can be negative.
    pub pnl_sat: i64,
}

pub struct StrategyRegistry {
    store: Vec<Strategy>,
    next_id: u64,
}

impl StrategyRegistry {
    pub fn new() -> Self {
        Self {
            store: Vec::with_capacity(MAX_STRATEGIES),
            next_id: 1,
        }
    }

    /// Register a new strategy. Returns the new id, or `0` if the registry is full.
    pub fn register(
        &mut self,
        agent_id: u64,
        owner: &str,
        name: &str,
        type_str: &str,
        params_json: &str,
        timestamp: i64,
    ) -> u64 {
        if self.store.len() >= MAX_STRATEGIES {
            return 0;
        }
        let sid = self.next_id;
        self.next_id += 1;

        let owner_trim: String = owner.chars().take(63).collect();
        let name_trim: String = name.chars().take(63).collect();
        let params_trim: String = params_json.chars().take(MAX_PARAM_LEN).collect();

        self.store.push(Strategy {
            id: sid,
            agent_id,
            owner: owner_trim,
            name: name_trim,
            stype: StrategyType::from_str(type_str),
            status: StrategyStatus::Draft,
            params: params_trim,
            created_at: timestamp,
            activated_at: 0,
            fill_count: 0,
            pnl_sat: 0,
        });
        sid
    }

    pub fn activate(&mut self, id: u64, now_secs: i64) -> bool {
        if let Some(s) = self.store.iter_mut().find(|s| s.id == id) {
            s.status = StrategyStatus::Active;
            s.activated_at = now_secs;
            true
        } else {
            false
        }
    }

    pub fn deactivate(&mut self, id: u64) -> bool {
        if let Some(s) = self.store.iter_mut().find(|s| s.id == id) {
            s.status = StrategyStatus::Paused;
            true
        } else {
            false
        }
    }

    pub fn get_by_id(&self, id: u64) -> Option<&Strategy> {
        self.store.iter().find(|s| s.id == id)
    }

    pub fn list_by_agent(&self, agent_id: u64) -> Vec<u64> {
        self.store
            .iter()
            .filter(|s| s.agent_id == agent_id)
            .map(|s| s.id)
            .collect()
    }

    pub fn list_by_owner(&self, owner: &str) -> Vec<u64> {
        self.store
            .iter()
            .filter(|s| s.owner == owner)
            .map(|s| s.id)
            .collect()
    }

    pub fn update_pnl(&mut self, id: u64, delta_sat: i64, fill_delta: u64) {
        if let Some(s) = self.store.iter_mut().find(|s| s.id == id) {
            s.pnl_sat = s.pnl_sat.saturating_add(delta_sat);
            s.fill_count = s.fill_count.saturating_add(fill_delta);
        }
    }

    pub fn len(&self) -> usize {
        self.store.len()
    }

    pub fn is_empty(&self) -> bool {
        self.store.is_empty()
    }
}

impl Default for StrategyRegistry {
    fn default() -> Self {
        Self::new()
    }
}

// ─── Process-global singleton (matches Zig module-level storage) ─────────────

static GLOBAL: Mutex<Option<StrategyRegistry>> = Mutex::new(None);

fn with_global<R>(f: impl FnOnce(&mut StrategyRegistry) -> R) -> R {
    let mut guard = GLOBAL.lock().unwrap();
    if guard.is_none() {
        *guard = Some(StrategyRegistry::new());
    }
    f(guard.as_mut().unwrap())
}

pub fn register(
    agent_id: u64,
    owner: &str,
    name: &str,
    type_str: &str,
    params_json: &str,
    timestamp: i64,
) -> u64 {
    with_global(|r| r.register(agent_id, owner, name, type_str, params_json, timestamp))
}

pub fn activate(id: u64) -> bool {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    with_global(|r| r.activate(id, now))
}

pub fn deactivate(id: u64) -> bool {
    with_global(|r| r.deactivate(id))
}

pub fn get_by_id(id: u64) -> Option<Strategy> {
    with_global(|r| r.get_by_id(id).cloned())
}

pub fn list_by_agent(agent_id: u64) -> Vec<u64> {
    with_global(|r| r.list_by_agent(agent_id))
}

pub fn list_by_owner(owner: &str) -> Vec<u64> {
    with_global(|r| r.list_by_owner(owner))
}

pub fn update_pnl(id: u64, delta_sat: i64, fill_delta: u64) {
    with_global(|r| r.update_pnl(id, delta_sat, fill_delta))
}

#[cfg(test)]
pub fn clear_global_for_test() {
    let mut g = GLOBAL.lock().unwrap();
    *g = Some(StrategyRegistry::new());
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_returns_monotonic_ids() {
        let mut r = StrategyRegistry::new();
        let a = r.register(7, "ob1qa", "n1", "grid", "{}", 1);
        let b = r.register(7, "ob1qa", "n2", "arb", "{}", 2);
        assert_eq!(a, 1);
        assert_eq!(b, 2);
        assert_eq!(r.len(), 2);
    }

    #[test]
    fn register_full_returns_zero() {
        let mut r = StrategyRegistry::new();
        for i in 0..MAX_STRATEGIES {
            assert_ne!(r.register(1, "o", &format!("n{i}"), "grid", "{}", 0), 0);
        }
        assert_eq!(r.register(1, "o", "overflow", "grid", "{}", 0), 0);
    }

    #[test]
    fn activate_and_deactivate() {
        let mut r = StrategyRegistry::new();
        let id = r.register(1, "ob", "s", "mm", "{}", 0);
        assert!(r.activate(id, 999));
        assert_eq!(r.get_by_id(id).unwrap().status, StrategyStatus::Active);
        assert_eq!(r.get_by_id(id).unwrap().activated_at, 999);
        assert!(r.deactivate(id));
        assert_eq!(r.get_by_id(id).unwrap().status, StrategyStatus::Paused);
        assert!(!r.activate(9999, 1));
        assert!(!r.deactivate(9999));
    }

    #[test]
    fn list_by_agent_and_owner() {
        let mut r = StrategyRegistry::new();
        r.register(1, "alice", "a1", "grid", "{}", 0);
        r.register(2, "bob",   "b1", "arb",  "{}", 0);
        r.register(1, "alice", "a2", "snipe", "{}", 0);
        let by_agent = r.list_by_agent(1);
        let by_owner = r.list_by_owner("alice");
        assert_eq!(by_agent, vec![1, 3]);
        assert_eq!(by_owner, vec![1, 3]);
        assert_eq!(r.list_by_owner("nobody"), Vec::<u64>::new());
    }

    #[test]
    fn update_pnl_accumulates_signed() {
        let mut r = StrategyRegistry::new();
        let id = r.register(1, "o", "n", "mm", "{}", 0);
        r.update_pnl(id, 100, 1);
        r.update_pnl(id, -30, 2);
        let s = r.get_by_id(id).unwrap();
        assert_eq!(s.pnl_sat, 70);
        assert_eq!(s.fill_count, 3);
    }

    #[test]
    fn strategy_type_round_trip() {
        for s in ["grid", "arb", "mm", "snipe", "custom", "unknown"] {
            let t = StrategyType::from_str(s);
            let back = t.as_str();
            if s == "unknown" {
                assert_eq!(back, "custom");
            } else {
                assert_eq!(back, s);
            }
        }
    }

    #[test]
    fn global_singleton_persists() {
        clear_global_for_test();
        let id1 = register(7, "ob1q", "x", "grid", "{}", 1);
        assert_eq!(id1, 1);
        let id2 = register(7, "ob1q", "y", "mm", "{}", 1);
        assert_eq!(id2, 2);
        assert!(activate(id1));
        let got = get_by_id(id1).unwrap();
        assert_eq!(got.status, StrategyStatus::Active);
        assert_eq!(list_by_agent(7), vec![1, 2]);
        assert_eq!(list_by_owner("ob1q"), vec![1, 2]);
    }
}
