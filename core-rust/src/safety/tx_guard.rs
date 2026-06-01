//! Pre-flight transaction safety check.
//!
//! Called BEFORE `block_exec::apply_tx`. Decides whether the tx is:
//!
//! * `Allowed` — proceed silently
//! * `WarnReceiver(reason)` — proceed but emit a WS warn event (sender is
//!    flagged; receiver should know).
//! * `WarnSender(reason)` — proceed but emit a WS warn event (receiver is
//!    flagged; sender should know).
//! * `Block(reason)` — reject the tx outright. Reserved for `Sanctioned`
//!    senders/recipients.

use super::flags::{FlagSeverity, FlagsRegistry};
use crate::tx::TxParsed;
use crate::state::EvmState;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SafetyVerdict {
    Allowed,
    WarnReceiver(String),
    WarnSender(String),
    Block(String),
}

/// Inspect the tx's `from`/`to` against the flag registry and return a
/// verdict. EvmState is currently unused but is part of the signature
/// since future rules (account-age, KYC tier, …) will read from it.
pub fn check_tx_safety(
    _state: &EvmState,
    flags: &FlagsRegistry,
    tx: &TxParsed,
) -> SafetyVerdict {
    // Sender side — sanctioned senders blocked outright; other tiers ignored
    // for sender (sender willingly chose to send).
    if let Ok(Some(rec)) = flags.get_flag(&tx.from) {
        if rec.is_enforced() && rec.severity == FlagSeverity::Sanctioned {
            return SafetyVerdict::Block(format!(
                "sender 0x{} is sanctioned: {}",
                hex::encode(tx.from),
                rec.reason
            ));
        }
    }

    if let Some(to) = tx.to {
        if let Ok(Some(rec)) = flags.get_flag(&to) {
            if !rec.is_enforced() {
                return SafetyVerdict::Allowed;
            }
            match rec.severity {
                FlagSeverity::Sanctioned => {
                    return SafetyVerdict::Block(format!(
                        "recipient 0x{} is sanctioned: {}",
                        hex::encode(to),
                        rec.reason
                    ));
                }
                _ => {
                    return SafetyVerdict::WarnSender(format!(
                        "recipient flagged ({}): {}",
                        rec.severity.as_str(),
                        rec.reason
                    ));
                }
            }
        }
    }

    SafetyVerdict::Allowed
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::flags::{FlagsRegistry, FlagSeverity};

    fn open_state_and_flags() -> (EvmState, FlagsRegistry, sled::Db) {
        let tmp = std::env::temp_dir().join(format!(
            "omnibus-txguard-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();
        let state = EvmState::open_at(&tmp).unwrap();
        // Separate sled db for flags so we don't fight EvmState's trees.
        let db = sled::Config::new().temporary(true).open().unwrap();
        let flags = FlagsRegistry::open(&db).unwrap();
        (state, flags, db)
    }

    fn mk_tx(from: [u8; 20], to: Option<[u8; 20]>) -> TxParsed {
        TxParsed {
            kind: crate::tx::TxKind::Legacy,
            chain_id: 7771,
            nonce: 0,
            gas_limit: 21000,
            to,
            value: 1,
            data: vec![],
            from,
            hash: [0u8; 32],
        }
    }

    #[test]
    fn unflagged_allowed() {
        let (state, flags, _db) = open_state_and_flags();
        let tx = mk_tx([1u8; 20], Some([2u8; 20]));
        assert_eq!(check_tx_safety(&state, &flags, &tx), SafetyVerdict::Allowed);
    }

    #[test]
    fn sanctioned_recipient_blocked() {
        let (state, flags, _db) = open_state_and_flags();
        let bad = [0xBBu8; 20];
        flags.flag_address(bad, FlagSeverity::Sanctioned, "OFAC".into(), [0u8; 32], [1u8; 20], 1).unwrap();
        let tx = mk_tx([1u8; 20], Some(bad));
        assert!(matches!(check_tx_safety(&state, &flags, &tx), SafetyVerdict::Block(_)));
    }

    #[test]
    fn phishing_recipient_warns_when_attested() {
        let (state, flags, _db) = open_state_and_flags();
        let bad = [0xCCu8; 20];
        flags.flag_address(bad, FlagSeverity::Phishing, "phish".into(), [0u8; 32], [1u8; 20], 1).unwrap();
        flags.add_attestation(&bad, [2u8; 20]).unwrap();
        let tx = mk_tx([1u8; 20], Some(bad));
        assert!(matches!(check_tx_safety(&state, &flags, &tx), SafetyVerdict::WarnSender(_)));
    }

    #[test]
    fn under_attested_flag_skipped() {
        let (state, flags, _db) = open_state_and_flags();
        let bad = [0xDDu8; 20];
        flags.flag_address(bad, FlagSeverity::Scam, "x".into(), [0u8; 32], [1u8; 20], 1).unwrap();
        let tx = mk_tx([1u8; 20], Some(bad));
        // 1 attestation < MIN_ATTESTATIONS (2) → not enforced → allowed
        assert_eq!(check_tx_safety(&state, &flags, &tx), SafetyVerdict::Allowed);
    }
}
