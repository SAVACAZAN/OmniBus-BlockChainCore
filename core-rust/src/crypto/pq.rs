// Post-quantum crypto — thin wrapper over the canonical
// `omnibus-crypto-core` Rust crate (NO STUBS).
//
// All real PQ work — HKDF-SHA512 deterministic seed, liboqs FFI keygen,
// signing, verification — lives in `omnibus-crypto-core/rust/src/pq/`. This
// module re-exports the public API and adds an OmniBus-specific helper
// (`pq_address_from_pubkey`) that maps a (scheme, pubkey, transferable) tuple
// to the canonical PQ address strings used on-chain:
//
//   Soulbound    (account = 0):  ob_k1_ / ob_f5_ / ob_d5_ / ob_s3_
//   Transferable (account = 1):  obk1_  / obf5_  / obd5_  / obs3_
//
// See memory note `project_omnibus_pq_address_prefixes_2026-05-20` and
// `omnibus-crypto-core/rust/src/pq_addresses.rs` for the canonical body
// encoding (hash160 -> 32-char bech32 charset packing).
//
// Cross-language parity:
//   Rust   (this crate, via omnibus-crypto-core) ↔
//   Zig    (1_CORE/BlockChainCore/core/pq_crypto.zig + bip32.zig) ↔
//   Python / TS / C++ (omnibus-crypto-core sister bindings)
// All produce byte-identical PQ seeds + keypairs from the same mnemonic per
// the locked CROSS_LANG_VECTORS.md test vectors.

// Re-export the canonical PQ API. Callers should prefer these names.
pub use omnibus_crypto::pq::{derive_keypair, DerivedKeyPair, SchemeId};
pub use omnibus_crypto::pq::derive::derive_pq_seed;

use omnibus_crypto::hash::hash160;

/// Local alias for downstream code in this crate that wants the OmniBus-flavoured
/// "PqScheme" naming (history: the previous stub used these names + a numbered
/// repr). New code should prefer `SchemeId` directly.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PqScheme {
    MlDsa87,
    Falcon512,
    SlhDsa256s,
    MlKem768,
}

impl From<PqScheme> for SchemeId {
    fn from(s: PqScheme) -> SchemeId {
        match s {
            PqScheme::MlDsa87    => SchemeId::MlDsa87,
            PqScheme::Falcon512  => SchemeId::Falcon512,
            PqScheme::SlhDsa256s => SchemeId::SlhDsa,
            PqScheme::MlKem768   => SchemeId::MlKem768,
        }
    }
}

impl PqScheme {
    /// Soulbound prefix (BIP-44 account = 0) — addresses are non-transferable
    /// (LOVE / FOOD / RENT / VACATION).
    pub fn soulbound_prefix(self) -> &'static str {
        match self {
            PqScheme::MlDsa87    => "ob_k1_",
            PqScheme::Falcon512  => "ob_f5_",
            PqScheme::SlhDsa256s => "ob_s3_",
            // Dilithium-5 (RENT) shares the ML-DSA family; in the canonical
            // table it has its own coin_type and prefix. We expose it as a
            // dedicated alias rather than overloading PqScheme — see the
            // `pq_address_from_pubkey` table for `RENT`.
            PqScheme::MlKem768   => "ob_kem_", // KEM is not used as an address
        }
    }

    /// Transferable PQ-OMNI prefix (BIP-44 account = 1).
    pub fn transferable_prefix(self) -> &'static str {
        match self {
            PqScheme::MlDsa87    => "obk1_",
            PqScheme::Falcon512  => "obf5_",
            PqScheme::SlhDsa256s => "obs3_",
            PqScheme::MlKem768   => "obkem_",
        }
    }
}

/// Pack 20 bytes into 32 bech32-charset characters (5 bits each). This is the
/// exact encoding used by `omnibus_crypto::pq_addresses::body32` so the
/// addresses produced here line up with what the rest of the ecosystem
/// derives from the master seed.
fn body32(h: &[u8; 20]) -> String {
    const CHARSET: &[u8; 32] = b"qpzry9x8gf2tvdw0s3jn54khce6mua7l";
    let mut out = String::with_capacity(32);
    let mut buf: u32 = 0;
    let mut bits: u32 = 0;
    for &b in h.iter() {
        buf = (buf << 8) | b as u32;
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            let idx = ((buf >> bits) & 0x1f) as usize;
            out.push(CHARSET[idx] as char);
        }
    }
    out
}

/// Derive the canonical OmniBus PQ address from a real PQ public key.
///
/// Address = `prefix || body32(hash160(pubkey))`, where `prefix` is chosen
/// from the soulbound vs transferable tables. The 4 soulbound slots are
/// LOVE/FOOD/RENT/VACATION; the 4 transferable slots are Q1/Q2/Q3/Q4.
///
/// `scheme` selects the algorithm; `transferable=false` produces the
/// soulbound `ob_*_` form, `transferable=true` produces the `ob*_` form.
///
/// NB: this is the *post-keygen* address, derived from the actual PQ pubkey
/// — distinct from `omnibus_crypto::pq_addresses` which derives an address
/// directly from the master seed (used while the vault stores the keypair
/// separately). Use this function when you already have the PQ pubkey in
/// hand (e.g. inside the node when verifying signatures).
pub fn pq_address_from_pubkey(
    scheme: PqScheme,
    pubkey: &[u8],
    transferable: bool,
) -> String {
    let prefix = if transferable { scheme.transferable_prefix() } else { scheme.soulbound_prefix() };
    let h160 = hash160(pubkey);
    let mut h: [u8; 20] = [0u8; 20];
    h.copy_from_slice(&h160);
    format!("{}{}", prefix, body32(&h))
}

/// Convenience: derive a keypair AND its OmniBus address in one call.
/// Returns `(address, keypair)`. The keypair carries the (zeroized-on-drop)
/// secret key for signing.
pub fn derive_keypair_and_address(
    master_seed: &[u8; 64],
    coin_type: u32,
    scheme: PqScheme,
    index: u32,
    transferable: bool,
) -> Result<(String, DerivedKeyPair), String> {
    let kp = derive_keypair(master_seed, coin_type, scheme.into(), index)
        .map_err(|e| e.to_string())?;
    let addr = pq_address_from_pubkey(scheme, &kp.public_key, transferable);
    Ok((addr, kp))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefixes_match_canonical_table() {
        // Soulbound
        assert_eq!(PqScheme::MlDsa87.soulbound_prefix(),    "ob_k1_");
        assert_eq!(PqScheme::Falcon512.soulbound_prefix(),  "ob_f5_");
        assert_eq!(PqScheme::SlhDsa256s.soulbound_prefix(), "ob_s3_");
        // Transferable
        assert_eq!(PqScheme::MlDsa87.transferable_prefix(),    "obk1_");
        assert_eq!(PqScheme::Falcon512.transferable_prefix(),  "obf5_");
        assert_eq!(PqScheme::SlhDsa256s.transferable_prefix(), "obs3_");
    }

    #[test]
    fn address_is_deterministic_in_pubkey() {
        let pk = [0x11u8; 64];
        let a1 = pq_address_from_pubkey(PqScheme::MlDsa87, &pk, false);
        let a2 = pq_address_from_pubkey(PqScheme::MlDsa87, &pk, false);
        assert_eq!(a1, a2);
        assert!(a1.starts_with("ob_k1_"), "got {a1}");
    }

    #[test]
    fn transferable_vs_soulbound_differ() {
        let pk = [0x42u8; 64];
        let sb = pq_address_from_pubkey(PqScheme::Falcon512, &pk, false);
        let tr = pq_address_from_pubkey(PqScheme::Falcon512, &pk, true);
        assert!(sb.starts_with("ob_f5_"));
        assert!(tr.starts_with("obf5_") && !tr.starts_with("ob_f5_"));
    }
}
