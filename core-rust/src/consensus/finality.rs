//! Casper-FFG-style checkpoint finality.
//! Port of `core/finality.zig` — domain-separated attestations, 2/3+
//! supermajority justification, justified-N+1 → finalize-N.

use sha2::{Digest, Sha256};

/// Domain separator mixed into every attestation. MUST match the Zig
/// constant so cross-impl attestations verify.
pub const ATTESTATION_DOMAIN: &[u8] = b"OmniBus-FFG-Attestation-v1";

/// Checkpoint cadence. ~1 minute at 1s block time.
pub const CHECKPOINT_INTERVAL: u64 = 64;

/// Soft finality (Bitcoin-style probabilistic).
pub const SOFT_FINALITY_CONFIRMS: u32 = 6;

pub const MAX_CHECKPOINTS: usize = 256;
pub const MAX_VALIDATORS: usize = 128;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum CheckpointStatus {
    Pending = 0,
    Justified = 1,
    Finalized = 2,
}

#[derive(Debug, Clone, Copy)]
pub struct Checkpoint {
    pub epoch: u64,
    pub block_height: u64,
    pub block_hash: [u8; 32],
    pub status: CheckpointStatus,
    pub attestation_count: u32,
    pub attested_power: u64,
    pub first_attestation_block: u64,
    pub parent_epoch: u64,
}

impl Checkpoint {
    /// True when 2/3+ of total voting power has attested.
    /// `attested * 3 >= total * 2`.
    pub fn has_supermajority(&self, total_power: u64) -> bool {
        if total_power == 0 {
            return false;
        }
        self.attested_power as u128 * 3 >= total_power as u128 * 2
    }
}

/// Single validator attestation. ECDSA signature lives in `signature`,
/// derived public key in `pubkey`. The signature commits ONLY to the
/// consensus-relevant fields via `signing_bytes()`.
#[derive(Debug, Clone, Copy)]
pub struct Attestation {
    pub validator_id: u16,
    pub target_epoch: u64,
    pub source_epoch: u64,
    /// Advisory weight — engine ignores in favour of the registry value.
    pub voting_power: u64,
    pub block_hash: [u8; 32],
    pub timestamp: i64,
    /// Compressed secp256k1 pubkey (33 bytes). All-zero = unsigned.
    pub pubkey: [u8; 33],
    /// 64-byte low-S secp256k1 signature over `signing_bytes`.
    pub signature: [u8; 64],
}

impl Attestation {
    pub fn new(validator_id: u16, target_epoch: u64, source_epoch: u64, block_hash: [u8; 32]) -> Self {
        Self {
            validator_id,
            target_epoch,
            source_epoch,
            voting_power: 0,
            block_hash,
            timestamp: 0,
            pubkey: [0u8; 33],
            signature: [0u8; 64],
        }
    }

    /// The exact byte string the signature commits to. Layout:
    /// `ATTESTATION_DOMAIN || target_epoch:u64-BE || source_epoch:u64-BE || block_hash:[32]`.
    /// Total length = 26 + 8 + 8 + 32 = 74 bytes.
    pub fn signing_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(ATTESTATION_DOMAIN.len() + 48);
        out.extend_from_slice(ATTESTATION_DOMAIN);
        out.extend_from_slice(&self.target_epoch.to_be_bytes());
        out.extend_from_slice(&self.source_epoch.to_be_bytes());
        out.extend_from_slice(&self.block_hash);
        out
    }

    /// Hash of `signing_bytes` — what an ECDSA signer should actually sign.
    pub fn signing_hash(&self) -> [u8; 32] {
        let mut hasher = Sha256::new();
        hasher.update(self.signing_bytes());
        let mut out = [0u8; 32];
        out.copy_from_slice(&hasher.finalize());
        out
    }
}

/// Slashing evidence: same validator attested two different hashes at the
/// same epoch.
#[derive(Debug, Clone, Copy)]
pub struct SlashingEvidence {
    pub validator_id: u16,
    pub epoch: u64,
    pub hash_a: [u8; 32],
    pub hash_b: [u8; 32],
}

/// Validator registry entry: (id → pubkey + advertised voting power).
#[derive(Debug, Clone, Copy)]
pub struct ValidatorRegEntry {
    pub validator_id: u16,
    pub pubkey: [u8; 33],
    pub voting_power: u64,
    pub active: bool,
}

/// Casper FFG engine.
///
/// TODO(p2p-agent): wire `process_attestation` into the P2P attestation
/// gossip channel. TODO(crypto-agent): plug in real secp256k1 verify here —
/// for now `verify_sig` always returns true so callers compile.
#[derive(Debug, Clone)]
pub struct FinalityEngine {
    pub checkpoints: Vec<Checkpoint>,
    pub last_justified_epoch: u64,
    pub last_finalized_epoch: u64,
    pub last_finalized_height: u64,
    pub total_voting_power: u64,
    pub validators: Vec<ValidatorRegEntry>,
}

impl FinalityEngine {
    pub fn new() -> Self {
        Self {
            checkpoints: Vec::with_capacity(MAX_CHECKPOINTS),
            last_justified_epoch: 0,
            last_finalized_epoch: 0,
            last_finalized_height: 0,
            total_voting_power: 0,
            validators: Vec::new(),
        }
    }

    pub fn register_validator(&mut self, entry: ValidatorRegEntry) {
        if entry.active {
            self.total_voting_power = self.total_voting_power.saturating_add(entry.voting_power);
        }
        self.validators.push(entry);
    }

    fn find_validator(&self, id: u16) -> Option<&ValidatorRegEntry> {
        self.validators.iter().find(|v| v.validator_id == id && v.active)
    }

    /// Verify an attestation against the registry. Returns the authoritative
    /// voting power for the attesting validator on success.
    ///
    /// TODO(crypto-agent): replace `verify_sig` stub with real secp256k1
    /// verify using `signing_hash` as the message digest.
    pub fn verify_attestation(&self, att: &Attestation) -> Option<u64> {
        let v = self.find_validator(att.validator_id)?;
        if v.pubkey != att.pubkey {
            return None;
        }
        if !Self::verify_sig(&att.pubkey, &att.signing_hash(), &att.signature) {
            return None;
        }
        Some(v.voting_power)
    }

    fn verify_sig(_pubkey: &[u8; 33], _msg: &[u8; 32], _sig: &[u8; 64]) -> bool {
        // TODO(crypto-agent): real secp256k1 verify.
        true
    }

    /// Propose a new checkpoint (called every `CHECKPOINT_INTERVAL` blocks).
    pub fn propose_checkpoint(&mut self, epoch: u64, block_height: u64, block_hash: [u8; 32]) {
        if self.checkpoints.len() >= MAX_CHECKPOINTS {
            // Drop oldest non-finalized.
            if let Some(pos) = self
                .checkpoints
                .iter()
                .position(|c| c.status != CheckpointStatus::Finalized)
            {
                self.checkpoints.remove(pos);
            }
        }
        self.checkpoints.push(Checkpoint {
            epoch,
            block_height,
            block_hash,
            status: CheckpointStatus::Pending,
            attestation_count: 0,
            attested_power: 0,
            first_attestation_block: 0,
            parent_epoch: self.last_justified_epoch,
        });
    }

    /// Add an attestation to its target epoch, promoting Pending→Justified
    /// at 2/3+ and Justified(N-1)→Finalized when Justified(N) lands.
    pub fn process_attestation(&mut self, att: &Attestation) -> Option<CheckpointStatus> {
        let power = self.verify_attestation(att)?;

        // Snapshot the parent_epoch BEFORE taking a mutable borrow so we can
        // walk back to finalise the predecessor without aliasing trouble.
        let (status, parent_epoch) = {
            let cp = self
                .checkpoints
                .iter_mut()
                .find(|c| c.epoch == att.target_epoch)?;
            cp.attestation_count += 1;
            cp.attested_power = cp.attested_power.saturating_add(power);

            if cp.status == CheckpointStatus::Pending
                && cp.has_supermajority(self.total_voting_power)
            {
                cp.status = CheckpointStatus::Justified;
            }
            (cp.status, cp.parent_epoch)
        };

        if status == CheckpointStatus::Justified {
            self.last_justified_epoch = self.last_justified_epoch.max(att.target_epoch);
            // Finalize parent (Casper FFG rule).
            if let Some(parent) = self.checkpoints.iter_mut().find(|c| c.epoch == parent_epoch) {
                if parent.status == CheckpointStatus::Justified {
                    parent.status = CheckpointStatus::Finalized;
                    self.last_finalized_epoch = self.last_finalized_epoch.max(parent.epoch);
                    self.last_finalized_height = parent.block_height;
                }
            }
        }
        Some(status)
    }

    /// True iff the given block height is at or below the last finalized
    /// height — i.e. impossible to revert.
    pub fn is_finalized(&self, height: u64) -> bool {
        height <= self.last_finalized_height && self.last_finalized_height > 0
    }
}

impl Default for FinalityEngine {
    fn default() -> Self {
        Self::new()
    }
}
