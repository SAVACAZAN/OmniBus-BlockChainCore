//! Witness data — port of Zig core/witness_data.zig.
//!
//! Segregated signature/pubkey data kept separate from transaction body
//! (SegWit-style), enabling compact-tx light proofs.

use byteorder::{ByteOrder, LittleEndian};
use std::collections::HashMap;

/// Max signature length (largest is SPHINCS+).
pub const WITNESS_SIG_MAX: usize = 512;

/// Max public-key length.
pub const WITNESS_PUBKEY_MAX: usize = 128;

#[derive(Debug, thiserror::Error)]
pub enum WitnessError {
    #[error("signature too large (max {WITNESS_SIG_MAX})")]
    SignatureTooLarge,
    #[error("public key too large (max {WITNESS_PUBKEY_MAX})")]
    PublicKeyTooLarge,
    #[error("insufficient data while deserializing")]
    InsufficientData,
}

/// Per-tx witness record.
///
/// Wire layout (variable size):
/// ```text
///   tx_id        u32 LE
///   sig_type     u8         (0=Kyber 1=Dilithium 2=Falcon 3=SPHINCS+)
///   sig_len      u16 LE
///   signature    sig_len bytes
///   pub_key_len  u16 LE
///   public_key   pub_key_len bytes
///   timestamp    u64 LE
///   flags        u8
/// ```
#[derive(Debug, Clone)]
pub struct WitnessData {
    pub tx_id: u32,
    pub sig_type: u8,
    pub signature: Vec<u8>,
    pub public_key: Vec<u8>,
    pub timestamp: u64,
    pub flags: u8,
}

impl WitnessData {
    pub fn new(tx_id: u32, sig_type: u8) -> Self {
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        Self {
            tx_id,
            sig_type,
            signature: Vec::new(),
            public_key: Vec::new(),
            timestamp,
            flags: 0,
        }
    }

    pub fn set_signature(&mut self, sig: &[u8]) -> Result<(), WitnessError> {
        if sig.len() > WITNESS_SIG_MAX {
            return Err(WitnessError::SignatureTooLarge);
        }
        self.signature = sig.to_vec();
        Ok(())
    }

    pub fn set_public_key(&mut self, pk: &[u8]) -> Result<(), WitnessError> {
        if pk.len() > WITNESS_PUBKEY_MAX {
            return Err(WitnessError::PublicKeyTooLarge);
        }
        self.public_key = pk.to_vec();
        Ok(())
    }

    pub fn sig_len(&self) -> u16 {
        self.signature.len() as u16
    }

    pub fn pub_key_len(&self) -> u16 {
        self.public_key.len() as u16
    }

    pub fn serialize(&self) -> Vec<u8> {
        let total = 4 + 1 + 2 + self.signature.len() + 2 + self.public_key.len() + 8 + 1;
        let mut buf = vec![0u8; total];
        let mut off = 0;
        LittleEndian::write_u32(&mut buf[off..off + 4], self.tx_id);
        off += 4;
        buf[off] = self.sig_type;
        off += 1;
        LittleEndian::write_u16(&mut buf[off..off + 2], self.sig_len());
        off += 2;
        buf[off..off + self.signature.len()].copy_from_slice(&self.signature);
        off += self.signature.len();
        LittleEndian::write_u16(&mut buf[off..off + 2], self.pub_key_len());
        off += 2;
        buf[off..off + self.public_key.len()].copy_from_slice(&self.public_key);
        off += self.public_key.len();
        LittleEndian::write_u64(&mut buf[off..off + 8], self.timestamp);
        off += 8;
        buf[off] = self.flags;
        buf
    }

    pub fn deserialize(data: &[u8]) -> Result<Self, WitnessError> {
        // Min size: 4 + 1 + 2 + 0 + 2 + 0 + 8 + 1 = 18
        if data.len() < 18 {
            return Err(WitnessError::InsufficientData);
        }
        let mut off = 0;
        let tx_id = LittleEndian::read_u32(&data[off..off + 4]);
        off += 4;
        let sig_type = data[off];
        off += 1;
        let sig_len = LittleEndian::read_u16(&data[off..off + 2]) as usize;
        off += 2;
        if off + sig_len > data.len() {
            return Err(WitnessError::InsufficientData);
        }
        let signature = data[off..off + sig_len].to_vec();
        off += sig_len;

        if off + 2 > data.len() {
            return Err(WitnessError::InsufficientData);
        }
        let pk_len = LittleEndian::read_u16(&data[off..off + 2]) as usize;
        off += 2;
        if off + pk_len > data.len() {
            return Err(WitnessError::InsufficientData);
        }
        let public_key = data[off..off + pk_len].to_vec();
        off += pk_len;

        if off + 8 + 1 > data.len() {
            return Err(WitnessError::InsufficientData);
        }
        let timestamp = LittleEndian::read_u64(&data[off..off + 8]);
        off += 8;
        let flags = data[off];

        if signature.len() > WITNESS_SIG_MAX {
            return Err(WitnessError::SignatureTooLarge);
        }
        if public_key.len() > WITNESS_PUBKEY_MAX {
            return Err(WitnessError::PublicKeyTooLarge);
        }

        Ok(Self {
            tx_id,
            sig_type,
            signature,
            public_key,
            timestamp,
            flags,
        })
    }
}

/// Compression stats relative to the fixed-size 512+128 layout.
#[derive(Debug, Clone, Copy)]
pub struct CompressionStats {
    pub full_size: u64,
    pub witness_size: u64,
    pub reduction_percent: u64,
}

/// Per-block pool of witness records, indexed by tx_id.
pub struct WitnessPool {
    pub witnesses: Vec<WitnessData>,
    pub witness_map: HashMap<u32, usize>,
    pub total_size: u64,
}

impl Default for WitnessPool {
    fn default() -> Self {
        Self::new()
    }
}

impl WitnessPool {
    pub fn new() -> Self {
        Self {
            witnesses: Vec::new(),
            witness_map: HashMap::new(),
            total_size: 0,
        }
    }

    pub fn add(&mut self, w: WitnessData) {
        let sz = 18u64 + w.signature.len() as u64 + w.public_key.len() as u64;
        self.witness_map.insert(w.tx_id, self.witnesses.len());
        self.witnesses.push(w);
        self.total_size += sz;
    }

    pub fn get(&self, tx_id: u32) -> Option<&WitnessData> {
        self.witness_map.get(&tx_id).map(|&i| &self.witnesses[i])
    }

    pub fn contains(&self, tx_id: u32) -> bool {
        self.witness_map.contains_key(&tx_id)
    }

    pub fn count(&self) -> usize {
        self.witnesses.len()
    }

    pub fn estimate_size(&self) -> u64 {
        self.total_size
    }

    pub fn serialize(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(4 + self.total_size as usize);
        let mut count_buf = [0u8; 4];
        LittleEndian::write_u32(&mut count_buf, self.witnesses.len() as u32);
        out.extend_from_slice(&count_buf);
        for w in &self.witnesses {
            out.extend_from_slice(&w.serialize());
        }
        out
    }

    pub fn clear(&mut self) {
        self.witnesses.clear();
        self.witness_map.clear();
        self.total_size = 0;
    }

    pub fn compression_stats(&self) -> CompressionStats {
        let mut full = 0u64;
        let mut wit = 0u64;
        for w in &self.witnesses {
            full += (WITNESS_SIG_MAX + WITNESS_PUBKEY_MAX) as u64;
            wit += 18 + w.signature.len() as u64 + w.public_key.len() as u64;
        }
        let reduction = if full > 0 {
            (100 * (full - wit)) / full
        } else {
            0
        };
        CompressionStats {
            full_size: full,
            witness_size: wit,
            reduction_percent: reduction,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn witness_roundtrip() {
        let mut w = WitnessData::new(42, 1);
        w.set_signature(b"test_sig_data").unwrap();
        w.set_public_key(b"test_pubkey_data").unwrap();
        let buf = w.serialize();
        let w2 = WitnessData::deserialize(&buf).unwrap();
        assert_eq!(w2.tx_id, 42);
        assert_eq!(w2.sig_type, 1);
        assert_eq!(w2.signature, b"test_sig_data");
        assert_eq!(w2.public_key, b"test_pubkey_data");
    }

    #[test]
    fn sig_too_large() {
        let mut w = WitnessData::new(1, 0);
        let big = vec![0u8; WITNESS_SIG_MAX + 1];
        assert!(w.set_signature(&big).is_err());
    }

    #[test]
    fn pool_add_and_lookup() {
        let mut pool = WitnessPool::new();
        let mut w1 = WitnessData::new(1, 0);
        w1.set_signature(b"sig1").unwrap();
        pool.add(w1);

        let mut w2 = WitnessData::new(2, 1);
        w2.set_signature(b"sig2").unwrap();
        pool.add(w2);

        assert_eq!(pool.count(), 2);
        assert!(pool.contains(1));
        assert!(pool.contains(2));
        assert!(!pool.contains(3));
        assert_eq!(pool.get(1).unwrap().signature, b"sig1");
    }

    #[test]
    fn compression_makes_sense() {
        let mut pool = WitnessPool::new();
        let mut w1 = WitnessData::new(1, 0);
        w1.set_signature(b"short").unwrap();
        pool.add(w1);
        let stats = pool.compression_stats();
        assert!(stats.reduction_percent > 50);
    }
}
