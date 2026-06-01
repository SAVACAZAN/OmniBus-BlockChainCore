//! HTLC swap registry — Init / Claim / Refund state machine.
//!
//! Mirrors `core/order_swap_link.zig::SwapBindingRegistry`.
//!
//! Critical rules from BlockChainCore CLAUDE.md ("DEX Grid Trading"):
//!   - The preimage is generated SERVER-SIDE (here, in the Zig/Rust backend)
//!     when an HTLC is born — NEVER by the frontend, NEVER sent to the user.
//!     The user only ever sees `hash_lock = SHA256(preimage)`.
//!   - HTLCs are born at FILL time, not at order placement. Resting orders
//!     lock no funds.
//!   - `swap_id == hash_lock`, also acts as the lock on both legs.
//!
//! Persistence: in-memory `HashMap` for fast lookup + optional `sled::Tree`
//! mirror so a node restart is fast (same intent as `swap_bindings.bin`).

use std::collections::HashMap;
use std::sync::Mutex;

use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

use super::pair::Chain;

pub type SwapId = [u8; 32];
pub type Preimage = [u8; 32];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum HtlcState {
    /// `Init`: binding registered, waiting for both HTLCs to be funded.
    Init = 0,
    /// Both legs locked on their respective chains.
    BothLocked = 1,
    /// Preimage revealed, swap settled (Claim).
    Claimed = 2,
    /// Timeout reached — both legs refundable.
    TimedOut = 3,
}

/// Reference to an HTLC on a specific chain (tagged enum, like the Zig
/// `HtlcRef` union).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum HtlcRef {
    Omnibus {
        id: [u8; 32],
    },
    Btc {
        txid: [u8; 32],
        vout: u32,
    },
    Eth {
        chain_id: u64,
        contract: [u8; 20],
        id: [u8; 32],
    },
}

/// One bound order ↔ cross-chain swap.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SwapBinding {
    pub order_id: u64,
    pub swap_id: SwapId, // == SHA256(preimage) == hash_lock
    pub maker_chain: Chain,
    pub taker_chain: Chain,
    pub maker_htlc_ref: HtlcRef,
    pub taker_htlc_ref: HtlcRef,
    pub state: HtlcState,
    pub timeout_block: u64,
    pub created_block: u64,
    /// SECRET — held server-side, revealed only on Claim.
    /// NEVER returned via RPC to the user.
    revealed_preimage: Preimage,
    /// SECRET — the preimage generated at HTLC birth. Kept here so the
    /// settler can reveal it on the taker's chain when the maker's leg is
    /// locked. Never exposed via public getters.
    backend_preimage: Preimage,
}

impl SwapBinding {
    /// Public getter returns the revealed preimage ONLY after Claim, never
    /// before. Callers must NOT expose `backend_preimage` over RPC.
    pub fn revealed_preimage(&self) -> Option<Preimage> {
        if self.state == HtlcState::Claimed {
            Some(self.revealed_preimage)
        } else {
            None
        }
    }
}

#[derive(Debug, Error)]
pub enum HtlcError {
    #[error("binding not found")]
    NotFound,
    #[error("binding already exists")]
    AlreadyExists,
    #[error("invalid state transition")]
    InvalidTransition,
    #[error("registry full")]
    Full,
    #[error("preimage does not hash to swap_id")]
    BadPreimage,
    #[error("timeout not yet reached")]
    TooEarly,
    #[error("persistence error: {0}")]
    Persistence(String),
}

pub const MAX_BINDINGS: usize = 4096;

/// Swap registry. Thread-safe via interior `Mutex` so the RPC server, the
/// matching engine, and the settler can share one instance.
pub struct SwapRegistry {
    inner: Mutex<RegistryInner>,
}

#[derive(Default)]
struct RegistryInner {
    by_swap: HashMap<SwapId, SwapBinding>,
    by_order: HashMap<u64, SwapId>,
    /// Optional persistent mirror (one entry per swap_id). Opened lazily.
    persist: Option<sled::Tree>,
}

impl Default for SwapRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl SwapRegistry {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(RegistryInner::default()),
        }
    }

    /// Attach a persistent backing store (sled tree). New entries and state
    /// transitions will be mirrored. Existing entries are loaded.
    pub fn with_persist(tree: sled::Tree) -> Result<Self, HtlcError> {
        let mut inner = RegistryInner::default();
        for kv in tree.iter() {
            let (_k, v) = kv.map_err(|e| HtlcError::Persistence(e.to_string()))?;
            let b: SwapBinding =
                bincode_deserialize(&v).map_err(|e| HtlcError::Persistence(e))?;
            inner.by_order.insert(b.order_id, b.swap_id);
            inner.by_swap.insert(b.swap_id, b);
        }
        inner.persist = Some(tree);
        Ok(Self {
            inner: Mutex::new(inner),
        })
    }

    /// Generate a fresh preimage (32 random bytes) and its hash_lock.
    /// This is the BACKEND-ONLY entry point — callers must never leak the
    /// returned preimage to the user. Used internally by `open_at_fill`.
    pub fn generate_preimage() -> (Preimage, SwapId) {
        let mut preimage = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut preimage);
        let mut h = Sha256::new();
        h.update(preimage);
        let mut hash = [0u8; 32];
        hash.copy_from_slice(&h.finalize());
        (preimage, hash)
    }

    /// Register a new binding. The preimage is provided by the caller (it
    /// must have been generated server-side via `generate_preimage`) and is
    /// stored privately. Returns `swap_id` (== hash_lock, safe to expose).
    pub fn open_at_fill(
        &self,
        order_id: u64,
        preimage: Preimage,
        maker_chain: Chain,
        taker_chain: Chain,
        maker_htlc_ref: HtlcRef,
        taker_htlc_ref: HtlcRef,
        timeout_block: u64,
        current_block: u64,
    ) -> Result<SwapId, HtlcError> {
        let mut h = Sha256::new();
        h.update(preimage);
        let mut swap_id = [0u8; 32];
        swap_id.copy_from_slice(&h.finalize());

        let mut inner = self.inner.lock().unwrap();
        if inner.by_swap.contains_key(&swap_id) {
            return Err(HtlcError::AlreadyExists);
        }
        if inner.by_swap.len() >= MAX_BINDINGS {
            return Err(HtlcError::Full);
        }
        let binding = SwapBinding {
            order_id,
            swap_id,
            maker_chain,
            taker_chain,
            maker_htlc_ref,
            taker_htlc_ref,
            state: HtlcState::Init,
            timeout_block,
            created_block: current_block,
            revealed_preimage: [0u8; 32],
            backend_preimage: preimage,
        };
        Self::persist(&mut inner, &binding)?;
        inner.by_order.insert(order_id, swap_id);
        inner.by_swap.insert(swap_id, binding);
        Ok(swap_id)
    }

    /// Confirm maker leg locked.
    pub fn lock_maker(&self, swap_id: SwapId, new_ref: HtlcRef) -> Result<(), HtlcError> {
        self.with_mut(swap_id, |b| {
            if b.state != HtlcState::Init {
                return Err(HtlcError::InvalidTransition);
            }
            b.maker_htlc_ref = new_ref;
            Ok(())
        })
    }

    /// Confirm taker leg locked → transition to `BothLocked`.
    pub fn lock_taker(&self, swap_id: SwapId, new_ref: HtlcRef) -> Result<(), HtlcError> {
        self.with_mut(swap_id, |b| {
            if b.state != HtlcState::Init {
                return Err(HtlcError::InvalidTransition);
            }
            b.taker_htlc_ref = new_ref;
            b.state = HtlcState::BothLocked;
            Ok(())
        })
    }

    /// Settle (Claim) — verify SHA256(preimage) == swap_id, then transition.
    pub fn settle(&self, swap_id: SwapId, preimage: Preimage) -> Result<(), HtlcError> {
        self.with_mut(swap_id, |b| {
            if b.state != HtlcState::BothLocked {
                return Err(HtlcError::InvalidTransition);
            }
            let mut h = Sha256::new();
            h.update(preimage);
            let mut hash = [0u8; 32];
            hash.copy_from_slice(&h.finalize());
            if hash != b.swap_id {
                return Err(HtlcError::BadPreimage);
            }
            b.revealed_preimage = preimage;
            b.state = HtlcState::Claimed;
            Ok(())
        })
    }

    /// Mark Refund-able when timeout passed.
    pub fn timeout(&self, swap_id: SwapId, current_block: u64) -> Result<(), HtlcError> {
        self.with_mut(swap_id, |b| {
            if b.state == HtlcState::Claimed || b.state == HtlcState::TimedOut {
                return Err(HtlcError::InvalidTransition);
            }
            if current_block < b.timeout_block {
                return Err(HtlcError::TooEarly);
            }
            b.state = HtlcState::TimedOut;
            Ok(())
        })
    }

    /// Read-only lookup by swap_id. The returned binding has any secret
    /// preimage cleared — only `revealed_preimage()` (post-Claim) is safe.
    pub fn find(&self, swap_id: SwapId) -> Option<SwapBinding> {
        let inner = self.inner.lock().unwrap();
        inner.by_swap.get(&swap_id).cloned().map(scrub_secret)
    }

    pub fn find_by_order(&self, order_id: u64) -> Option<SwapBinding> {
        let inner = self.inner.lock().unwrap();
        let sid = inner.by_order.get(&order_id)?;
        inner.by_swap.get(sid).cloned().map(scrub_secret)
    }

    /// Backend-only: fetch the secret preimage of a binding so the settler
    /// can reveal it on the taker's chain. Must NEVER be exposed via RPC.
    pub fn backend_preimage(&self, swap_id: SwapId) -> Option<Preimage> {
        let inner = self.inner.lock().unwrap();
        inner.by_swap.get(&swap_id).map(|b| b.backend_preimage)
    }

    pub fn len(&self) -> usize {
        self.inner.lock().unwrap().by_swap.len()
    }
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    // ── private helpers ────────────────────────────────────────────────

    fn with_mut<F>(&self, swap_id: SwapId, f: F) -> Result<(), HtlcError>
    where
        F: FnOnce(&mut SwapBinding) -> Result<(), HtlcError>,
    {
        let mut inner = self.inner.lock().unwrap();
        let b = inner.by_swap.get_mut(&swap_id).ok_or(HtlcError::NotFound)?;
        f(b)?;
        let snapshot = b.clone();
        Self::persist(&mut inner, &snapshot)?;
        Ok(())
    }

    fn persist(inner: &mut RegistryInner, b: &SwapBinding) -> Result<(), HtlcError> {
        if let Some(tree) = &inner.persist {
            let bytes =
                bincode_serialize(b).map_err(|e| HtlcError::Persistence(e))?;
            tree.insert(b.swap_id, bytes)
                .map_err(|e| HtlcError::Persistence(e.to_string()))?;
            tree.flush()
                .map_err(|e| HtlcError::Persistence(e.to_string()))?;
        }
        Ok(())
    }
}

/// Strip the secret preimage before handing a binding out to callers.
fn scrub_secret(mut b: SwapBinding) -> SwapBinding {
    b.backend_preimage = [0u8; 32];
    if b.state != HtlcState::Claimed {
        b.revealed_preimage = [0u8; 32];
    }
    b
}

// ── tiny serde helpers (no bincode dep in workspace — use serde_json as
// a placeholder; swap to bincode/postcard for production) ──────────────

fn bincode_serialize<T: Serialize>(t: &T) -> Result<Vec<u8>, String> {
    serde_json::to_vec(t).map_err(|e| e.to_string())
}

fn bincode_deserialize<T: for<'a> Deserialize<'a>>(b: &[u8]) -> Result<T, String> {
    serde_json::from_slice(b).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn omni_ref() -> HtlcRef {
        HtlcRef::Omnibus { id: [0u8; 32] }
    }
    fn eth_ref() -> HtlcRef {
        HtlcRef::Eth {
            chain_id: 11_155_111,
            contract: [0u8; 20],
            id: [0u8; 32],
        }
    }

    #[test]
    fn open_lock_settle_round_trip() {
        let reg = SwapRegistry::new();
        let (preimage, _expected_swap) = SwapRegistry::generate_preimage();
        let swap_id = reg
            .open_at_fill(42, preimage, Chain::Omnibus, Chain::Eth, omni_ref(), eth_ref(), 1_000, 100)
            .unwrap();
        assert_eq!(reg.find(swap_id).unwrap().state, HtlcState::Init);

        reg.lock_taker(swap_id, eth_ref()).unwrap();
        assert_eq!(reg.find(swap_id).unwrap().state, HtlcState::BothLocked);

        reg.settle(swap_id, preimage).unwrap();
        let b = reg.find(swap_id).unwrap();
        assert_eq!(b.state, HtlcState::Claimed);
        assert_eq!(b.revealed_preimage().unwrap(), preimage);
    }

    #[test]
    fn user_never_sees_preimage_before_claim() {
        let reg = SwapRegistry::new();
        let (preimage, _) = SwapRegistry::generate_preimage();
        let swap_id = reg
            .open_at_fill(1, preimage, Chain::Omnibus, Chain::Eth, omni_ref(), eth_ref(), 100, 1)
            .unwrap();
        let b = reg.find(swap_id).unwrap();
        // Pre-claim: revealed_preimage() returns None.
        assert!(b.revealed_preimage().is_none());
        // The scrubbed copy has zero backend_preimage too.
        assert_eq!(b.backend_preimage, [0u8; 32]);
    }

    #[test]
    fn bad_preimage_rejected() {
        let reg = SwapRegistry::new();
        let (preimage, _) = SwapRegistry::generate_preimage();
        let swap_id = reg
            .open_at_fill(1, preimage, Chain::Omnibus, Chain::Eth, omni_ref(), eth_ref(), 100, 1)
            .unwrap();
        reg.lock_taker(swap_id, eth_ref()).unwrap();
        let mut bad = preimage;
        bad[0] ^= 0xFF;
        assert!(matches!(reg.settle(swap_id, bad), Err(HtlcError::BadPreimage)));
    }

    #[test]
    fn timeout_transition() {
        let reg = SwapRegistry::new();
        let (preimage, _) = SwapRegistry::generate_preimage();
        let swap_id = reg
            .open_at_fill(7, preimage, Chain::Omnibus, Chain::Eth, omni_ref(), eth_ref(), 200, 50)
            .unwrap();
        assert!(matches!(reg.timeout(swap_id, 100), Err(HtlcError::TooEarly)));
        reg.timeout(swap_id, 250).unwrap();
        assert_eq!(reg.find(swap_id).unwrap().state, HtlcState::TimedOut);
        assert!(matches!(
            reg.timeout(swap_id, 300),
            Err(HtlcError::InvalidTransition)
        ));
    }
}
