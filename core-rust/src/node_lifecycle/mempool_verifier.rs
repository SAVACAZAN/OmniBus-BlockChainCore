//! mempool_verifier — signature gate the mempool runs before accepting a TX.
//!
//! Mirrors the dispatch in the Zig validator: ECDSA TXs verify against
//! either an embedded pubkey or a registry lookup; PQ TXs carry the
//! pubkey inline and self-verify; multisig TXs are admitted and re-checked
//! by `applyBlock`. The gate returns `false` on any decode / lookup error
//! so the mempool drops the TX.
//!
//! Ported from `core/node/mempool_verifier.zig` (2026-06-02).
//!
//! TODO: full port pending the Rust native `Transaction` type (with
//! `scheme` / `from_address` / `signature` / `public_key` fields) and a
//! `Chain::pubkey_registry` accessor. Today the Rust `tx.rs` only models
//! EVM transactions, so this module exposes the wire surface as a stub
//! the runtime can call against once the native TX struct lands.

/// Multisig address prefix — moved here as a constant so the verifier
/// doesn't pull from the (unported) multisig module.
pub const MULTISIG_PREFIX: &str = "ob1q_ms_";

/// Minimal view of a native chain transaction the verifier needs.
/// Mirrors the Zig `Transaction` shape narrowly so callers can adapt.
pub trait MempoolTx {
    fn signature(&self) -> &[u8];
    fn from_address(&self) -> &str;
    /// Hex-encoded compressed pubkey (66 chars) if embedded, else empty.
    fn public_key_hex(&self) -> &str;
    /// 0 = OMNI ECDSA, 1..N = PQ schemes — matches Zig `Scheme` enum.
    fn scheme_id(&self) -> u8;
    /// Self-verify against an explicit pubkey (or `None` for PQ where the
    /// pubkey is embedded in the TX body).
    fn verify_signature(&self, pubkey_hex: Option<&str>) -> bool;
}

/// Trait for the chain-side pubkey registry lookup.
pub trait PubkeyLookup {
    fn lookup_pubkey_hex(&self, address: &str) -> Option<String>;
}

/// Scheme IDs — mirror the Zig `Scheme` enum values.
pub mod scheme {
    /// Standard ECDSA secp256k1 (OMNI native + EVM-compat).
    pub const ECDSA: u8 = 0;
    /// ML-DSA-87 (CRYSTALS-Dilithium, NIST ML-DSA Level 5).
    pub const ML_DSA: u8 = 1;
    /// Falcon-512.
    pub const FALCON: u8 = 2;
    /// SLH-DSA-256s (SPHINCS+).
    pub const SLH_DSA: u8 = 3;
    /// ML-KEM-768 (key-encapsulation — used for address domains only, not TX signing).
    pub const ML_KEM: u8 = 4;
    /// CROSS-RSDPG-128 (code-based, EDU badge).
    pub const CROSS: u8 = 5;
    /// MAYO-3 (multivariate, GOV badge).
    pub const MAYO: u8 = 6;
}

/// Returns `true` if `scheme_id` identifies a post-quantum signing scheme
/// (not ECDSA, not KEM). PQ TXs carry the pubkey inline and self-verify.
#[inline]
pub fn is_pq_signing_scheme(scheme_id: u8) -> bool {
    matches!(
        scheme_id,
        scheme::ML_DSA | scheme::FALCON | scheme::SLH_DSA | scheme::CROSS | scheme::MAYO
    )
}

/// Verify a TX for mempool admission. Mirrors `mempoolVerifierFn` in Zig.
///
/// Dispatch table:
///   - Empty signature → coinbase / system TX → accept.
///   - Multisig prefix → defers to `applyBlock` M-of-N → accept.
///   - ECDSA (scheme 0) → embedded pubkey (66 hex chars) → registry lookup → accept by default.
///   - PQ (schemes 1-6) → inline pubkey, self-verifies → reject if bad.
pub fn verify_for_mempool<T: MempoolTx, L: PubkeyLookup>(tx: &T, registry: &L) -> bool {
    // Coinbase / system TXs come with empty signatures.
    if tx.signature().is_empty() {
        return true;
    }
    // Multisig defers to applyBlock (M-of-N can't be verified mempool-side).
    if tx.from_address().starts_with(MULTISIG_PREFIX) {
        return true;
    }

    let sid = tx.scheme_id();

    if sid == scheme::ECDSA {
        // ECDSA: embedded pubkey first, then registry, then accept by default.
        let embedded = tx.public_key_hex();
        if embedded.len() == 66 {
            return tx.verify_signature(Some(embedded));
        }
        if let Some(pk) = registry.lookup_pubkey_hex(tx.from_address()) {
            return tx.verify_signature(Some(&pk));
        }
        // Unknown sender, no embedded pk — backward-compat: accept.
        true
    } else if is_pq_signing_scheme(sid) {
        // PQ schemes carry the public key inline in the TX body.
        // `verify_signature(None)` means "use the embedded pubkey from the TX".
        tx.verify_signature(None)
    } else {
        // Unknown / ML-KEM scheme — not a signing scheme; accept unconditionally
        // (ML-KEM is only used for address-domain key exchange, never TX signing).
        true
    }
}

/// Nonce-gap detection: returns `true` when the TX's nonce is exactly
/// `chain_nonce + pending_count`, i.e. there is no gap. A gap would
/// mean a prior TX is missing from the mempool, causing this TX to be
/// unexecutable. The mempool should reject gapped TXs.
///
/// `chain_nonce`: the last confirmed nonce for `from_address` on-chain.
/// `pending_count`: number of TXs from this sender already in mempool.
pub fn is_nonce_contiguous(tx_nonce: u64, chain_nonce: u64, pending_count: u64) -> bool {
    tx_nonce == chain_nonce.saturating_add(pending_count)
}

/// Lightweight fee-rate check: `fee / size_bytes >= min_feerate`.
/// Returns `true` if the TX passes the minimum fee-rate floor.
pub fn fee_rate_ok(fee_sat: u64, size_bytes: usize, min_feerate_sat_per_byte: u64) -> bool {
    if size_bytes == 0 {
        return fee_sat >= 1;
    }
    fee_sat / (size_bytes as u64) >= min_feerate_sat_per_byte
}

/// Combined gate used by the node to pre-screen incoming TXs before they
/// even reach the mempool. Returns an `Err` with a reason string on the
/// first failed check. Mirrors the inline checks in `rpc_server.zig` that
/// front the mempool `add()` call.
pub fn pre_screen<T: MempoolTxExt, L: PubkeyLookup>(
    tx: &T,
    registry: &L,
    chain_nonce: u64,
    pending_count: u64,
    size_bytes: usize,
    min_feerate_sat_per_byte: u64,
) -> Result<(), &'static str> {
    // 1. Signature gate (HIGH-05).
    if !verify_for_mempool(tx, registry) {
        return Err("bad signature");
    }
    // 2. Nonce-gap guard — prevent stuck TX chains.
    if !tx.signature().is_empty() && !tx.from_address().starts_with(MULTISIG_PREFIX) {
        // Only enforce for non-coinbase, non-multisig TXs.
        // nonce 0 is always allowed (first TX from a new address).
        if tx.nonce() > 0 && !is_nonce_contiguous(tx.nonce(), chain_nonce, pending_count) {
            return Err("nonce gap");
        }
    }
    // 3. Fee-rate floor.
    if min_feerate_sat_per_byte > 0 && !fee_rate_ok(tx.fee(), size_bytes, min_feerate_sat_per_byte)
    {
        return Err("fee rate too low");
    }
    Ok(())
}

/// Extended `MempoolTx` with nonce + fee accessors needed for `pre_screen`.
pub trait MempoolTxExt: MempoolTx {
    fn nonce(&self) -> u64;
    fn fee(&self) -> u64;
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FakeTx { sig: Vec<u8>, from: String, pk_hex: String, scheme: u8, ok: bool }
    impl MempoolTx for FakeTx {
        fn signature(&self) -> &[u8] { &self.sig }
        fn from_address(&self) -> &str { &self.from }
        fn public_key_hex(&self) -> &str { &self.pk_hex }
        fn scheme_id(&self) -> u8 { self.scheme }
        fn verify_signature(&self, _pk: Option<&str>) -> bool { self.ok }
    }
    struct EmptyLookup;
    impl PubkeyLookup for EmptyLookup {
        fn lookup_pubkey_hex(&self, _a: &str) -> Option<String> { None }
    }

    #[test]
    fn empty_signature_is_admitted() {
        let tx = FakeTx { sig: vec![], from: "ob1q".into(), pk_hex: "".into(), scheme: 0, ok: false };
        assert!(verify_for_mempool(&tx, &EmptyLookup));
    }

    #[test]
    fn multisig_admitted_without_verification() {
        let tx = FakeTx {
            sig: vec![1,2,3], from: format!("{MULTISIG_PREFIX}deadbeef"),
            pk_hex: "".into(), scheme: 0, ok: false,
        };
        assert!(verify_for_mempool(&tx, &EmptyLookup));
    }

    #[test]
    fn unknown_ecdsa_sender_accepted_for_backward_compat() {
        let tx = FakeTx {
            sig: vec![9; 64],
            from: "ob1qunknown".into(),
            pk_hex: "".into(),
            scheme: 0,
            ok: false,
        };
        assert!(verify_for_mempool(&tx, &EmptyLookup));
    }

    // ─── PQ scheme tests ─────────────────────────────────────────────────────

    #[test]
    fn pq_scheme_rejected_on_bad_sig() {
        for sid in [
            scheme::ML_DSA,
            scheme::FALCON,
            scheme::SLH_DSA,
            scheme::CROSS,
            scheme::MAYO,
        ] {
            let tx = FakeTx {
                sig: vec![1, 2, 3],
                from: "ob1qpq".into(),
                pk_hex: "".into(),
                scheme: sid,
                ok: false,
            };
            assert!(
                !verify_for_mempool(&tx, &EmptyLookup),
                "scheme {} should be rejected when verify_signature returns false",
                sid
            );
        }
    }

    #[test]
    fn pq_scheme_accepted_on_good_sig() {
        let tx = FakeTx {
            sig: vec![1; 100],
            from: "ob1qml".into(),
            pk_hex: "".into(),
            scheme: scheme::ML_DSA,
            ok: true,
        };
        assert!(verify_for_mempool(&tx, &EmptyLookup));
    }

    #[test]
    fn mlkem_scheme_always_accepted() {
        // ML-KEM is not a signing scheme — any TX with this scheme_id is let through.
        let tx = FakeTx {
            sig: vec![1, 2, 3],
            from: "ob1qkem".into(),
            pk_hex: "".into(),
            scheme: scheme::ML_KEM,
            ok: false, // would fail if checked
        };
        assert!(verify_for_mempool(&tx, &EmptyLookup));
    }

    #[test]
    fn is_pq_signing_scheme_correct() {
        assert!(is_pq_signing_scheme(scheme::ML_DSA));
        assert!(is_pq_signing_scheme(scheme::FALCON));
        assert!(is_pq_signing_scheme(scheme::SLH_DSA));
        assert!(is_pq_signing_scheme(scheme::CROSS));
        assert!(is_pq_signing_scheme(scheme::MAYO));
        assert!(!is_pq_signing_scheme(scheme::ECDSA));
        assert!(!is_pq_signing_scheme(scheme::ML_KEM));
    }

    // ─── Nonce-gap tests ─────────────────────────────────────────────────────

    #[test]
    fn nonce_contiguous_basic() {
        // chain_nonce=5, pending=2 → next expected = 7
        assert!(is_nonce_contiguous(7, 5, 2));
        assert!(!is_nonce_contiguous(8, 5, 2)); // gap
        assert!(!is_nonce_contiguous(6, 5, 2)); // duplicate
    }

    #[test]
    fn nonce_contiguous_first_tx() {
        // New address: chain_nonce=0, pending=0 → nonce 0 is ok
        assert!(is_nonce_contiguous(0, 0, 0));
    }

    // ─── fee_rate_ok tests ────────────────────────────────────────────────────

    #[test]
    fn fee_rate_ok_basic() {
        assert!(fee_rate_ok(100, 50, 2)); // 100/50 = 2 >= 2
        assert!(!fee_rate_ok(99, 50, 2)); // 99/50 = 1 < 2
        assert!(fee_rate_ok(5, 0, 1));    // zero-size: fee >= 1 → ok
    }

    // ─── pre_screen tests ────────────────────────────────────────────────────

    struct ExtTx {
        inner: FakeTx,
        nonce: u64,
        fee: u64,
    }
    impl MempoolTx for ExtTx {
        fn signature(&self) -> &[u8] {
            self.inner.signature()
        }
        fn from_address(&self) -> &str {
            self.inner.from_address()
        }
        fn public_key_hex(&self) -> &str {
            self.inner.public_key_hex()
        }
        fn scheme_id(&self) -> u8 {
            self.inner.scheme_id()
        }
        fn verify_signature(&self, pk: Option<&str>) -> bool {
            self.inner.verify_signature(pk)
        }
    }
    impl MempoolTxExt for ExtTx {
        fn nonce(&self) -> u64 {
            self.nonce
        }
        fn fee(&self) -> u64 {
            self.fee
        }
    }

    #[test]
    fn pre_screen_ok() {
        let tx = ExtTx {
            inner: FakeTx {
                sig: vec![],
                from: "ob1qa".into(),
                pk_hex: "".into(),
                scheme: 0,
                ok: true,
            },
            nonce: 0,
            fee: 10,
        };
        assert!(pre_screen(&tx, &EmptyLookup, 0, 0, 100, 0).is_ok());
    }

    #[test]
    fn pre_screen_rejects_bad_sig() {
        let tx = ExtTx {
            inner: FakeTx {
                sig: vec![1, 2, 3],
                from: "ob1qa".into(),
                pk_hex: "a".repeat(66),
                scheme: 0,
                ok: false,
            },
            nonce: 0,
            fee: 10,
        };
        assert_eq!(pre_screen(&tx, &EmptyLookup, 0, 0, 100, 0), Err("bad signature"));
    }
}
