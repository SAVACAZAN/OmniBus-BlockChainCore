//! Light client / SPV / bloom filter / witness data.
//!
//! Ported from Zig core/light_client.zig, core/block_filter.zig,
//! core/witness_data.zig (2026-06-01).
//!
//! Wire-format guarantees (must match Zig peer):
//!   - SpvBlockHeader: 124 bytes (P2P SPV format — see p2p::wire)
//!   - BloomFilter: 513 bytes (1 byte num_hash_funcs + 512 byte bit array)
//!   - BloomHash: 32-bit Murmur-style hash with per-function seed rotation

pub mod spv;
pub mod bloom;
pub mod client;
pub mod witness;

pub use spv::{SpvBlockHeader, MerkleProof, SPV_HEADER_SIZE, MAX_MERKLE_DEPTH, verify_merkle_proof};
pub use bloom::{BloomFilter, BLOOM_BITS_BYTES, BLOOM_WIRE_SIZE, bloom_hash};
pub use client::LightClient;
pub use witness::{WitnessData, WitnessPool, WITNESS_SIG_MAX, WITNESS_PUBKEY_MAX};
