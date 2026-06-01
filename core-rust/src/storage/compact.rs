//! Compact transaction — port of `core/compact_transaction.zig`.
//!
//! Fixed 161-byte SegWit-style transaction record, all integers LITTLE-ENDIAN.
//!
//! ```text
//! offset  size  field
//!   0      4    id              u32 LE
//!   4     20    from            [u8; 20]   (truncated/compressed address)
//!  24     20    to              [u8; 20]
//!  44      8    amount          u64 LE
//!  52      4    timestamp       u32 LE
//!  56      4    nonce           u32 LE
//!  60     32    data_hash       [u8; 32]   (SHA-256 of "{id}:{amount}:{timestamp}")
//!  92      1    sig_type        u8         (0=Kyber, 1=Dilithium, ...)
//!  93     32    sig_hash        [u8; 32]
//! 125     36    (Zig wrote 161 total — last byte at offset 124)
//! ```
//!
//! NB: Zig advances offset by `1` after writing sig_type but the buffer is
//! exactly 161 bytes; final field ends at byte 124 + 32 = 156... but Zig
//! allocates `[161]` and the layout above (4+20+20+8+4+4+32+1+32 = 125) leaves
//! 36 reserved bytes at the tail. We replicate exactly: total record = 161 bytes,
//! bytes [125..161] = 0.

use byteorder::{ByteOrder, LittleEndian};
use sha2::{Digest, Sha256};

pub const COMPACT_TX_BYTES: usize = 161;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CompactTransaction {
    pub id: u32,
    pub from: [u8; 20],
    pub to: [u8; 20],
    pub amount: u64,
    pub timestamp: u32,
    pub nonce: u32,
    pub data_hash: [u8; 32],
    pub sig_type: u8,
    pub sig_hash: [u8; 32],
}

impl Default for CompactTransaction {
    fn default() -> Self {
        Self {
            id: 0, from: [0; 20], to: [0; 20], amount: 0, timestamp: 0, nonce: 0,
            data_hash: [0; 32], sig_type: 0, sig_hash: [0; 32],
        }
    }
}

impl CompactTransaction {
    /// Build from a full Transaction-like input (Rust mirror of `fromTransaction`).
    /// Truncates from/to to 20 bytes and recomputes `data_hash`.
    pub fn from_parts(id: u32, from_addr: &[u8], to_addr: &[u8], amount: u64, timestamp: u64) -> Self {
        let mut tx = Self::default();
        tx.id = id;
        tx.amount = amount;
        tx.timestamp = (timestamp & 0xFFFF_FFFF) as u32;
        if from_addr.len() >= 20 { tx.from.copy_from_slice(&from_addr[0..20]); }
        if to_addr.len() >= 20 { tx.to.copy_from_slice(&to_addr[0..20]); }
        let s = format!("{}:{}:{}", tx.id, tx.amount, tx.timestamp);
        let mut h = Sha256::new();
        h.update(s.as_bytes());
        tx.data_hash.copy_from_slice(&h.finalize());
        tx
    }

    /// Serialize to exactly 161 bytes.
    pub fn serialize(&self) -> [u8; COMPACT_TX_BYTES] {
        let mut buf = [0u8; COMPACT_TX_BYTES];
        LittleEndian::write_u32(&mut buf[0..4], self.id);
        buf[4..24].copy_from_slice(&self.from);
        buf[24..44].copy_from_slice(&self.to);
        LittleEndian::write_u64(&mut buf[44..52], self.amount);
        LittleEndian::write_u32(&mut buf[52..56], self.timestamp);
        LittleEndian::write_u32(&mut buf[56..60], self.nonce);
        buf[60..92].copy_from_slice(&self.data_hash);
        buf[92] = self.sig_type;
        buf[93..125].copy_from_slice(&self.sig_hash);
        // [125..161] left zero, matching Zig's `try allocator.alloc(u8, 161)` + only
        // writes up to offset 124 + 32 = 156 (and Zig forgot to use the extra; we
        // keep parity by also leaving the tail zeroed).
        buf
    }

    pub fn deserialize(data: &[u8]) -> Result<Self, &'static str> {
        if data.len() < COMPACT_TX_BYTES { return Err("insufficient data"); }
        let mut tx = Self::default();
        tx.id = LittleEndian::read_u32(&data[0..4]);
        tx.from.copy_from_slice(&data[4..24]);
        tx.to.copy_from_slice(&data[24..44]);
        tx.amount = LittleEndian::read_u64(&data[44..52]);
        tx.timestamp = LittleEndian::read_u32(&data[52..56]);
        tx.nonce = LittleEndian::read_u32(&data[56..60]);
        tx.data_hash.copy_from_slice(&data[60..92]);
        tx.sig_type = data[92];
        tx.sig_hash.copy_from_slice(&data[93..125]);
        Ok(tx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixed_size() {
        let tx = CompactTransaction::default();
        assert_eq!(tx.serialize().len(), 161);
    }

    #[test]
    fn roundtrip() {
        let tx = CompactTransaction {
            id: 0xDEAD_BEEF,
            from: [1; 20],
            to: [2; 20],
            amount: 1_000_000_000,
            timestamp: 1_700_000_000,
            nonce: 42,
            data_hash: [3; 32],
            sig_type: 1,
            sig_hash: [4; 32],
        };
        let bytes = tx.serialize();
        // First 4 bytes = id LE = EF BE AD DE
        assert_eq!(&bytes[0..4], &[0xEF, 0xBE, 0xAD, 0xDE]);
        let back = CompactTransaction::deserialize(&bytes).unwrap();
        assert_eq!(back, tx);
    }

    #[test]
    fn from_parts_hash_stable() {
        let a = CompactTransaction::from_parts(7, &[9u8; 32], &[10u8; 32], 500, 1_700_000_000);
        let b = CompactTransaction::from_parts(7, &[9u8; 32], &[10u8; 32], 500, 1_700_000_000);
        assert_eq!(a.data_hash, b.data_hash);
    }
}
