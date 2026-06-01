//! OmniBus Identity layer — Rust port of `core/identity/` (Zig).
//!
//! Provides: DID, OBM, Manifest (10 leaves), 4 facets (Social, Professional,
//! Cultural, Economic), Selective Disclosure, Salt + GDPR §17, KYC + MiCA,
//! and `.omnibus` ENS-style NS registry.
//!
//! Persistence: each domain may open its own `sled::Tree`. Hashing: SHA-256
//! with leaf tag 0x00 / node tag 0x01 (matches Zig `id_merkle.zig`).

pub mod merkle;
pub mod did;
pub mod obm;
pub mod manifest;
pub mod selective_disclosure;
pub mod salt;
pub mod kyc;
pub mod mica;
pub mod ns;
pub mod facets;

pub use merkle::{Hash, ProofStep, hash_leaf, hash_node, root_of_leaf_hashes, prove_leaf, verify_proof};
pub use did::{Did, DID_PREFIX, did_from_compressed_pubkey, did_from_hash160, parse_did};
pub use obm::{Obm, ObmBit, ObmInputs, ReputationCups, compute_obm, BADGE_THRESHOLD_STORED};
pub use manifest::{Manifest, FieldIndex, FIELD_COUNT, compute_root as compute_manifest_root};
pub use selective_disclosure::{Disclosure, DisclosureBundle, DisclosureRequest, disclose_fields, verify_disclosure};
pub use salt::{Salt, SaltManager, FileSaltManager, MemorySaltManager};
pub use kyc::{KycStatus, KycStore};
pub use mica::{MicaRiskCategory, MicaDisclosure, AmlAttestation, KycAttestation, MicaSummary, MicaReport, build_mica_summary, mica_report_json};
pub use ns::{NsEntry, NsRegistry, NsError, REGISTER_COST_SAT, COST_OMNIBUS_SAT, COST_ARBITRAJE_SAT, ENS_FEE_TESTNET_SAT};
