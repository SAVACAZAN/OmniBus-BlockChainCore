//! Storage layer — Rust port of the Zig `core/database.zig`, `core/binary_codec.zig`,
//! `core/state_trie.zig`, `core/archive_manager.zig`, `core/compact_transaction.zig`.
//!
//! Goal: read/write `chain.dat` files that are byte-identical to the Zig node's
//! output so the two implementations can co-exist on the same data directory.
//!
//! All multi-byte integers are LITTLE-ENDIAN (`std.mem.writeInt(... .little)` in
//! Zig). The only exceptions are inside the binary varint codec (Bitcoin/Protobuf
//! style 7-bit-per-byte big-endian-shifted; see `codec`).
//!
//! Sub-modules:
//!
//! - [`codec`]   — varints, fixed-width LE primitives, length-prefixed bytes.
//! - [`database`] — `chain.dat` file format: header + 8 length-prefixed sections,
//!                  each followed by a CRC32 (Zig `std.hash.crc.Crc32`, IEEE).
//! - [`state_trie`] — in-memory account-state trie keyed by 20-byte address.
//! - [`archive`]  — block archive manager (compression stub for now).
//! - [`compact`]  — 161-byte fixed-size SegWit-style transaction record.

pub mod archive;
pub mod codec;
pub mod compact;
pub mod database;
pub mod state_trie;

pub use codec::{BinaryDecoder, BinaryEncoder, Varint};
pub use database::{ChainDb, DB_MAGIC, DB_VERSION};
