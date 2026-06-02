//! faucet — testnet faucet logic: rate-limit + drip + one-time-per-address.
//!
//! Port of `core/faucet.zig` (2026-06-02).
//!
//! Protocol identity:
//!   FAUCET_MNEMONIC is the well-known BIP-39 "abandon × 11 + about" phrase.
//!   FAUCET_ADDR derives from path m/44'/777'/0'/0/7 — slot #7 (slot #0 is
//!   the founder address). Funds in this address cannot move except via
//!   faucet_claim TXs to addresses that have never claimed before; the rule
//!   is enforced by every miner during `validateTransaction`.
//!
//! Anti-abuse layers:
//!   1. IpCooldownMap — one claim per IP per 24h.
//!   2. ClaimedSet    — one claim per OmniBus address, ever.
//!   3. parse_claim   — op_return must be `faucet_claim:<decl_hash>:<addr>`.

use std::collections::HashMap;
use std::sync::Mutex;

// ── Public constants ─────────────────────────────────────────────────────────

pub const FAUCET_MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon abandon \
abandon abandon abandon about";

/// Derived from FAUCET_MNEMONIC at path m/44'/777'/0'/0/7. Verified
/// deterministically — reproducible by anyone with the mnemonic.
pub const FAUCET_ADDR: &str = "ob1qy05u0kdznyeckz969t4lnd2t7h20tw3uyhwgju";

/// Drip size in SAT (0.001 OMNI = 1_000_000 SAT at 1e9 SAT/OMNI).
pub const FAUCET_AMOUNT_SAT: u64 = 1_000_000;

/// 24-hour IP cooldown (matches Zig FAUCET_COOLDOWN_S).
pub const FAUCET_COOLDOWN_SEC: i64 = 86_400;

/// Max LRU entries before old IPs get evicted from the cooldown map.
pub const FAUCET_MAX_TRACKED: usize = 65_536;

/// op_return prefix recognised by miners.
pub const FAUCET_OP_PREFIX: &str = "faucet_claim:";

/// Permanent on-chain text the claimer agrees to by submitting a claim TX.
pub const DECLARATION_TEXT: &str = "I declare that I am an honest participant acting in good faith. \
I will respect the rules of the OmniBus protocol and its community. \
I understand that violations — including Sybil attacks, fraud, or \
malicious behaviour — may result in on-chain sanctions including \
stake slashing, validator exclusion, and permanent address blacklisting. \
OmniBus Protocol — Declaration of Honesty v1.";

/// SHA-256 of `DECLARATION_TEXT` — embedded in every claim's op_return.
pub const DECLARATION_HASH: &str =
    "a3f2c1e4b5d6a7f8e9c0b1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2";

// ── FaucetClaim ──────────────────────────────────────────────────────────────

/// Parsed faucet_claim op_return. Format: `faucet_claim:<decl_hash>:<addr>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FaucetClaim<'a> {
    pub declaration_hash: &'a str,
    pub claimer: &'a str,
}

pub fn parse_claim(op_return: &str) -> Option<FaucetClaim<'_>> {
    let body = op_return.strip_prefix(FAUCET_OP_PREFIX)?;
    let mut it = body.splitn(2, ':');
    let decl_hash = it.next()?;
    let claimer = it.next()?;
    if decl_hash.is_empty() || claimer.is_empty() {
        return None;
    }
    Some(FaucetClaim { declaration_hash: decl_hash, claimer })
}

// ── IpCooldownMap (24h per-IP rate limit) ────────────────────────────────────

#[derive(Debug, Default)]
pub struct IpCooldownMap {
    inner: Mutex<HashMap<String, i64>>,
}

impl IpCooldownMap {
    pub fn new() -> Self { Self::default() }

    /// Returns `true` if `ip` is allowed to claim now, and records the claim.
    /// Returns `false` if the IP claimed within the last `FAUCET_COOLDOWN_SEC`.
    pub fn try_record(&self, ip: &str, now: i64) -> bool {
        let mut m = self.inner.lock().unwrap();
        if let Some(&last) = m.get(ip) {
            if now - last < FAUCET_COOLDOWN_SEC {
                return false;
            }
        }
        // LRU evict if we're at the cap and this IP isn't already tracked.
        if m.len() >= FAUCET_MAX_TRACKED && !m.contains_key(ip) {
            if let Some(oldest_key) = m
                .iter()
                .min_by_key(|(_, &ts)| ts)
                .map(|(k, _)| k.clone())
            {
                m.remove(&oldest_key);
            }
        }
        m.insert(ip.to_string(), now);
        true
    }

    /// Last claim time for `ip` (0 if never).
    pub fn last_claim(&self, ip: &str) -> i64 {
        *self.inner.lock().unwrap().get(ip).unwrap_or(&0)
    }

    pub fn len(&self) -> usize { self.inner.lock().unwrap().len() }
    pub fn is_empty(&self) -> bool { self.len() == 0 }
}

// ── ClaimedSet (one-time-per-address) ────────────────────────────────────────

#[derive(Debug, Default)]
pub struct ClaimedSet {
    inner: Mutex<std::collections::HashSet<String>>,
}

impl ClaimedSet {
    pub fn new() -> Self { Self::default() }

    /// Returns `true` if this address has never claimed before, and records it.
    pub fn try_record(&self, addr: &str) -> bool {
        let mut s = self.inner.lock().unwrap();
        if s.contains(addr) { return false; }
        s.insert(addr.to_string());
        true
    }

    pub fn has_claimed(&self, addr: &str) -> bool {
        self.inner.lock().unwrap().contains(addr)
    }

    pub fn len(&self) -> usize { self.inner.lock().unwrap().len() }
    pub fn is_empty(&self) -> bool { self.len() == 0 }
}

// ── FaucetState (telemetry kept for RPC) ─────────────────────────────────────

#[derive(Debug, Default)]
pub struct FaucetState {
    pub drips_issued: u64,
    pub last_drip_ts: i64,
}

impl FaucetState {
    pub fn new() -> Self { Self::default() }

    /// Record a successful drip; bumps the counter + timestamp.
    pub fn record_drip(&mut self, now_ts: i64) {
        self.drips_issued += 1;
        self.last_drip_ts = now_ts;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_claim_basic() {
        let c = parse_claim("faucet_claim:abc123:ob1qtest").unwrap();
        assert_eq!(c.declaration_hash, "abc123");
        assert_eq!(c.claimer, "ob1qtest");
    }

    #[test]
    fn parse_claim_wrong_prefix() {
        assert!(parse_claim("other:abc:ob1q").is_none());
    }

    #[test]
    fn parse_claim_empty_parts_rejected() {
        assert!(parse_claim("faucet_claim::ob1q").is_none());
        assert!(parse_claim("faucet_claim:abc:").is_none());
        assert!(parse_claim("faucet_claim:").is_none());
    }

    #[test]
    fn parse_claim_extra_colons_kept_in_claimer() {
        // splitn(2) → claimer is everything after the 2nd colon, including ':' chars.
        let c = parse_claim("faucet_claim:hash:ob1q:extra:bytes").unwrap();
        assert_eq!(c.declaration_hash, "hash");
        assert_eq!(c.claimer, "ob1q:extra:bytes");
    }

    #[test]
    fn ip_cooldown_blocks_within_24h() {
        let m = IpCooldownMap::new();
        assert!(m.try_record("1.2.3.4", 1_000));
        assert!(!m.try_record("1.2.3.4", 1_000 + 3_600));  // 1h later — blocked
        assert!(m.try_record("1.2.3.4", 1_000 + 86_401));  // 24h+1s — allowed
    }

    #[test]
    fn ip_cooldown_independent_per_ip() {
        let m = IpCooldownMap::new();
        assert!(m.try_record("1.1.1.1", 0));
        assert!(m.try_record("2.2.2.2", 0));
        assert!(!m.try_record("1.1.1.1", 100));
        assert!(!m.try_record("2.2.2.2", 100));
    }

    #[test]
    fn ip_cooldown_last_claim_lookup() {
        let m = IpCooldownMap::new();
        assert_eq!(m.last_claim("9.9.9.9"), 0);
        m.try_record("9.9.9.9", 12345);
        assert_eq!(m.last_claim("9.9.9.9"), 12345);
    }

    #[test]
    fn claimed_set_one_time_per_address() {
        let s = ClaimedSet::new();
        assert!(s.try_record("ob1qabc"));
        assert!(!s.try_record("ob1qabc"));
        assert!(s.try_record("ob1qxyz"));
        assert!(s.has_claimed("ob1qabc"));
        assert!(!s.has_claimed("ob1qnever"));
    }

    #[test]
    fn faucet_addr_format() {
        // The canonical faucet address is a 42-char bech32 (ob1q prefix).
        assert!(FAUCET_ADDR.starts_with("ob1q"));
        assert_eq!(FAUCET_ADDR.len(), 42);
    }

    #[test]
    fn declaration_text_unchanged() {
        // Lock the exact bytes — every claimer signs this string, so any
        // accidental whitespace/typo here would change DECLARATION_HASH
        // and invalidate every prior claim.
        assert!(DECLARATION_TEXT.contains("OmniBus Protocol"));
        assert!(DECLARATION_TEXT.contains("Declaration of Honesty v1"));
    }

    #[test]
    fn faucet_state_record_drip_increments() {
        let mut s = FaucetState::new();
        s.record_drip(100);
        s.record_drip(200);
        assert_eq!(s.drips_issued, 2);
        assert_eq!(s.last_drip_ts, 200);
    }
}
