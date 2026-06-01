//! On-chain name registry. See module docs.

use std::collections::HashMap;
use thiserror::Error;

pub const MAX_NAME_LEN: usize = 25;
pub const MIN_NAME_LEN: usize = 3;
pub const MAX_TLD_LEN: usize = 16;
pub const MAX_ENTRIES: usize = 4096;
pub const DEFAULT_TLD: &str = "omnibus";

/// Block time assumption: ~1 second per block.
pub const BLOCKS_PER_YEAR: u64 = 31_557_600;
/// Default 1-year period.
pub const RENEWAL_PERIOD_BLOCKS: u64 = BLOCKS_PER_YEAR;
/// Grace period after expiry — owner can still renew.
pub const GRACE_PERIOD_BLOCKS: u64 = 2_592_000; // ~30 days

/// Per-owner cap (registrar slots exempt — not modeled here).
pub const MAX_NAMES_PER_OWNER: usize = 10;

/// Allowed TLDs (Phase 1 + Phase 2 from the Zig source).
pub const ALLOWED_TLDS: &[&str] = &[
    "omnibus", "arbitraje", "quantum",
    "bank", "gov", "mil", "fin",
    "edu", "org", "dev",
];

#[derive(Debug, Error)]
pub enum DnsError {
    #[error("invalid name (length / charset / leading char)")]
    InvalidName,
    #[error("invalid tld")]
    InvalidTld,
    #[error("registry is full")]
    RegistryFull,
    #[error("name is taken")]
    NameTaken,
    #[error("name held under another TLD by a different owner")]
    NameTakenCrossTld,
    #[error("name is reserved")]
    ReservedName,
    #[error("owner has reached the per-owner cap")]
    OwnerCapExceeded,
    #[error("name not found")]
    NameNotFound,
    #[error("caller is not the current owner")]
    NotOwner,
}

/// PQ scheme slot index — aligns with the Zig `PqSlot` enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum PqSlot {
    MlDsa = 0,
    Falcon = 1,
    Dilithium = 2,
    SlhDsa = 3,
}

/// Phase 2 category badge — derived from TLD by default.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Category {
    None = 0,
    Personal = 1,
    Bank = 2,
    Gov = 3,
    Mil = 4,
    Fin = 5,
    Edu = 6,
    Org = 7,
    Dev = 8,
    Trading = 9,
}

impl Category {
    pub fn from_tld(tld: &str) -> Self {
        match tld {
            "omnibus" | "quantum" => Category::Personal,
            "arbitraje" => Category::Trading,
            "bank" => Category::Bank,
            "gov" => Category::Gov,
            "mil" => Category::Mil,
            "fin" => Category::Fin,
            "edu" => Category::Edu,
            "org" => Category::Org,
            "dev" => Category::Dev,
            _ => Category::None,
        }
    }
}

/// A single DNS record.
#[derive(Debug, Clone)]
pub struct DnsEntry {
    pub name: String,
    pub tld: String,
    pub address: String,
    pub owner: String,
    pub registered_block: u64,
    pub expires_block: u64,
    pub grace_until_block: u64,
    pub last_action_block: u64,
    pub last_nonce: u64,
    pub registered_years: u32,
    pub category: Category,
    pub preferred_slot: u8,
    /// PQ-scheme slot addresses (empty string = unset, falls back to `address`).
    pub addr_pq: [String; 4],
    pub active: bool,
}

impl DnsEntry {
    pub fn is_expired(&self, current_block: u64) -> bool {
        current_block >= self.expires_block
    }
    pub fn is_in_grace(&self, current_block: u64) -> bool {
        current_block >= self.expires_block && current_block < self.grace_until_block
    }
    pub fn is_auctionable(&self, current_block: u64) -> bool {
        current_block >= self.grace_until_block
    }

    /// Full label "alice.omnibus".
    pub fn full_label(&self) -> String {
        format!("{}.{}", self.name, self.tld)
    }

    /// Get PQ-slot address with fallback to primary.
    pub fn pq_address(&self, slot: PqSlot) -> &str {
        let s = &self.addr_pq[slot as usize];
        if s.is_empty() { &self.address } else { s }
    }
}

/// Validate a name (lowercase alphanumeric + underscore, starts with letter).
pub fn is_valid_name(name: &str) -> bool {
    if name.len() < MIN_NAME_LEN || name.len() > MAX_NAME_LEN {
        return false;
    }
    let bytes = name.as_bytes();
    if !(bytes[0].is_ascii_lowercase()) {
        return false;
    }
    bytes.iter().all(|&c| {
        c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_'
    })
}

pub fn is_valid_tld(tld: &str) -> bool {
    ALLOWED_TLDS.iter().any(|t| *t == tld)
}

/// Hardcoded reserved labels (subset of the Zig RESERVED_NAMES list — same
/// principle: TLD-agnostic brand-protection floor).
const RESERVED_NAMES: &[&str] = &[
    "omnibus", "omni", "blockchain", "satoshi", "nakamoto",
    "exchange", "wallet", "node", "miner", "validator", "treasury",
    "admin", "root", "system", "api", "support",
    "google", "apple", "microsoft", "amazon", "meta", "facebook",
    "binance", "coinbase", "kraken", "uniswap",
    "ethereum", "bitcoin", "solana", "lcx", "liberty",
    "usdc", "usdt", "dai", "tether", "circle",
];

pub fn is_reserved_name(name: &str) -> bool {
    RESERVED_NAMES.contains(&name)
}

/// In-memory DNS registry. Persistence/file I/O lives at the integration
/// layer (snapshotted with the rest of chain state).
pub struct DnsRegistry {
    /// Indexed by "name.tld" → entry.
    entries: HashMap<String, DnsEntry>,
}

impl Default for DnsRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl DnsRegistry {
    pub fn new() -> Self {
        Self { entries: HashMap::new() }
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    fn key(name: &str, tld: &str) -> String {
        format!("{}.{}", name, tld)
    }

    /// Count active, non-expired names owned by `owner`.
    pub fn count_names_owned_by(&self, owner: &str, current_block: u64) -> usize {
        self.entries
            .values()
            .filter(|e| e.active && !e.is_expired(current_block) && e.owner == owner)
            .count()
    }

    /// Register a new name with the default TLD (1 year).
    pub fn register(
        &mut self,
        name: &str,
        address: &str,
        owner: &str,
        current_block: u64,
    ) -> Result<(), DnsError> {
        self.register_with_tld_years(name, DEFAULT_TLD, address, owner, current_block, 1)
    }

    /// Full register with explicit TLD + years tier.
    pub fn register_with_tld_years(
        &mut self,
        name: &str,
        tld: &str,
        address: &str,
        owner: &str,
        current_block: u64,
        years: u32,
    ) -> Result<(), DnsError> {
        if !is_valid_name(name) { return Err(DnsError::InvalidName); }
        if !is_valid_tld(tld) { return Err(DnsError::InvalidTld); }
        if self.entries.len() >= MAX_ENTRIES { return Err(DnsError::RegistryFull); }
        if is_reserved_name(name) { return Err(DnsError::ReservedName); }
        if self.count_names_owned_by(owner, current_block) >= MAX_NAMES_PER_OWNER {
            return Err(DnsError::OwnerCapExceeded);
        }

        // Cross-TLD uniqueness: same `name` held on another TLD by a
        // different owner blocks the claim. Same owner across TLDs is OK.
        for e in self.entries.values() {
            if !e.active || e.is_auctionable(current_block) { continue; }
            if e.name != name { continue; }
            if e.owner != owner {
                return Err(DnsError::NameTakenCrossTld);
            }
            if e.tld == tld {
                return Err(DnsError::NameTaken);
            }
        }

        // If the slot exists but is past grace, mark inactive and reuse.
        let key = Self::key(name, tld);
        if let Some(existing) = self.entries.get(&key) {
            if !existing.is_auctionable(current_block) {
                return Err(DnsError::NameTaken);
            }
            self.entries.remove(&key);
        }

        let years_u64 = years.max(1) as u64;
        let expires_block = current_block + years_u64 * BLOCKS_PER_YEAR;
        let entry = DnsEntry {
            name: name.to_string(),
            tld: tld.to_string(),
            address: address.to_string(),
            owner: owner.to_string(),
            registered_block: current_block,
            expires_block,
            grace_until_block: expires_block + GRACE_PERIOD_BLOCKS,
            last_action_block: current_block,
            last_nonce: 0,
            registered_years: years.max(1),
            category: Category::from_tld(tld),
            preferred_slot: 0,
            addr_pq: [String::new(), String::new(), String::new(), String::new()],
            active: true,
        };
        self.entries.insert(key, entry);

        // WS event — NameRegistered. No-op if no broadcaster installed.
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        crate::ws::try_broadcast(crate::ws::Event::NameRegistered {
            name: name.to_string(),
            tld: tld.to_string(),
            full_label: format!("{}.{}", name, tld),
            address: address.to_string(),
            years: years.max(1).min(255) as u8,
            timestamp: now,
        });
        Ok(())
    }

    /// Resolve `name` on the default TLD.
    pub fn resolve(&self, name: &str, current_block: u64) -> Option<&str> {
        self.resolve_with_tld(name, DEFAULT_TLD, current_block)
    }

    /// Resolve `name.tld` to address (only if active + non-expired).
    pub fn resolve_with_tld(&self, name: &str, tld: &str, current_block: u64) -> Option<&str> {
        let key = Self::key(name, tld);
        let e = self.entries.get(&key)?;
        if !e.active || e.is_expired(current_block) {
            return None;
        }
        Some(&e.address)
    }

    /// Reverse-resolve: address → first matching name found.
    pub fn reverse_resolve(&self, address: &str, current_block: u64) -> Option<&str> {
        self.entries
            .values()
            .find(|e| e.active && !e.is_expired(current_block) && e.address == address)
            .map(|e| e.name.as_str())
    }

    /// Transfer ownership + primary address. Requires current owner.
    pub fn transfer(
        &mut self,
        name: &str,
        tld: &str,
        current_owner: &str,
        new_owner: &str,
        new_address: &str,
        current_block: u64,
    ) -> Result<(), DnsError> {
        let key = Self::key(name, tld);
        let e = self.entries.get_mut(&key).ok_or(DnsError::NameNotFound)?;
        if e.owner != current_owner {
            return Err(DnsError::NotOwner);
        }
        e.owner = new_owner.to_string();
        e.address = new_address.to_string();
        e.last_action_block = current_block;
        Ok(())
    }

    /// Renew (default 1y).
    pub fn renew(&mut self, name: &str, tld: &str, owner: &str, current_block: u64) -> Result<(), DnsError> {
        let key = Self::key(name, tld);
        let e = self.entries.get_mut(&key).ok_or(DnsError::NameNotFound)?;
        if e.owner != owner {
            return Err(DnsError::NotOwner);
        }
        e.expires_block = current_block + RENEWAL_PERIOD_BLOCKS;
        e.grace_until_block = e.expires_block + GRACE_PERIOD_BLOCKS;
        e.last_action_block = current_block;
        Ok(())
    }

    /// Iterate all active entries.
    pub fn iter(&self) -> impl Iterator<Item = &DnsEntry> {
        self.entries.values().filter(|e| e.active)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_name_basic() {
        assert!(is_valid_name("alice"));
        assert!(is_valid_name("ab1"));
        assert!(is_valid_name("alex_omni"));
        assert!(!is_valid_name("ab")); // too short
        assert!(!is_valid_name("1abc")); // starts with digit
        assert!(!is_valid_name("Alice")); // uppercase
    }

    #[test]
    fn register_resolve() {
        let mut r = DnsRegistry::new();
        r.register("alice", "ob1qabc", "ob1qabc", 100).unwrap();
        assert_eq!(r.resolve("alice", 200), Some("ob1qabc"));
    }

    #[test]
    fn register_reserved_rejected() {
        let mut r = DnsRegistry::new();
        let err = r.register("omnibus", "ob1qabc", "ob1qabc", 100).unwrap_err();
        matches!(err, DnsError::ReservedName);
    }

    #[test]
    fn cross_tld_owner_match_ok() {
        let mut r = DnsRegistry::new();
        r.register_with_tld_years("alice", "omnibus", "ob1qabc", "ob1qabc", 100, 1).unwrap();
        r.register_with_tld_years("alice", "dev", "ob1qabc", "ob1qabc", 100, 1).unwrap();
    }

    #[test]
    fn cross_tld_different_owner_blocked() {
        let mut r = DnsRegistry::new();
        r.register_with_tld_years("alice", "omnibus", "ob1qabc", "ob1qabc", 100, 1).unwrap();
        let err = r
            .register_with_tld_years("alice", "dev", "ob1qxyz", "ob1qxyz", 100, 1)
            .unwrap_err();
        matches!(err, DnsError::NameTakenCrossTld);
    }

    #[test]
    fn transfer_requires_owner() {
        let mut r = DnsRegistry::new();
        r.register("alice", "ob1qabc", "ob1qabc", 100).unwrap();
        assert!(r.transfer("alice", "omnibus", "wrong", "ob1qxyz", "ob1qxyz", 200).is_err());
        r.transfer("alice", "omnibus", "ob1qabc", "ob1qxyz", "ob1qxyz", 200).unwrap();
        assert_eq!(r.resolve("alice", 300), Some("ob1qxyz"));
    }
}
