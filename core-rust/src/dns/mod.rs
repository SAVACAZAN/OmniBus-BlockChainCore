//! DNS / Herotag registry — port of `core/dns_registry.zig`.
//!
//! Human-readable on-chain name registry mapping `name.tld` → address.
//! Subset of the Zig original (which has Phase 2 fee curves, PQ slots, MiCA
//! attestations, etc.): this Rust port covers the consensus-critical core —
//! register, resolve, transfer, plus name/TLD validation. Extended fields
//! (years tier, PQ slots, categories) are tracked on the entry but the
//! lifecycle hooks live in the wider node integration, not here.

pub mod registry;

pub use registry::{DnsEntry, DnsRegistry, DnsError, Category, PqSlot};
