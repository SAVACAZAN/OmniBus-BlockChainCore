//! Backwards-compat re-exports.
//!
//! The real implementations live in `crate::light` (ported from Zig
//! core/light_client.zig + core/block_filter.zig on 2026-06-01). This module
//! used to host minimal stubs of `SpvBlockHeader` + `BloomFilter`; existing
//! call sites (p2p::wire, etc.) keep importing from `crate::types` and get
//! the real types via these re-exports.

pub use crate::light::bloom::BloomFilter;
pub use crate::light::spv::SpvBlockHeader;
