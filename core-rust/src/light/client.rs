//! LightClient — SPV-style light client state.
//!
//! Port of Zig `LightClient` from core/light_client.zig. Stores only block
//! headers (124 B SPV form), validates the header chain, and uses a bloom
//! filter to probe which addresses might be relevant.
//!
//! Full UTXO/balance lookup still requires querying a full node — this struct
//! only knows headers + the watched-address filter.

use super::bloom::BloomFilter;
use super::spv::{validate_against_prev, verify_chain, MerkleProof, SpvBlockHeader, verify_merkle_proof};

#[derive(Debug, thiserror::Error)]
pub enum LightClientError {
    #[error("invalid header (linkage/timestamp/difficulty)")]
    InvalidHeader,
    #[error("invalid checkpoint — first new header does not link to trusted")]
    InvalidCheckpoint,
    #[error("buffer too small for headers payload")]
    InsufficientData,
}

pub struct LightClient {
    pub headers: Vec<SpvBlockHeader>,
    pub trusted_root: [u8; 32],
    pub sync_height: u64,
    pub max_headers_to_keep: usize,
    pub bloom: BloomFilter,
}

impl Default for LightClient {
    fn default() -> Self {
        Self::new()
    }
}

impl LightClient {
    pub fn new() -> Self {
        Self {
            headers: Vec::new(),
            trusted_root: [0u8; 32],
            sync_height: 0,
            max_headers_to_keep: 1000,
            bloom: BloomFilter::new(5),
        }
    }

    /// Append a header (no validation — caller must have validated).
    /// Prunes old headers if over `max_headers_to_keep`.
    pub fn add_header(&mut self, header: SpvBlockHeader) {
        self.sync_height = header.index;
        self.headers.push(header);
        if self.headers.len() > self.max_headers_to_keep {
            let remove = self.headers.len() - self.max_headers_to_keep;
            self.headers.drain(0..remove);
        }
    }

    /// Validate a header against the current tip. Mirrors Zig validateHeader.
    pub fn validate_header(&self, header: &SpvBlockHeader, now_secs: i64) -> bool {
        if header.difficulty == 0 {
            return false;
        }
        if self.headers.is_empty() {
            return header.index == 0;
        }
        let last = self.headers.last().unwrap();
        validate_against_prev(last, header, now_secs)
    }

    pub fn add_validated_header(
        &mut self,
        header: SpvBlockHeader,
        now_secs: i64,
    ) -> Result<(), LightClientError> {
        if !self.validate_header(&header, now_secs) {
            return Err(LightClientError::InvalidHeader);
        }
        self.add_header(header);
        Ok(())
    }

    pub fn verify_chain(&self) -> bool {
        verify_chain(&self.headers)
    }

    pub fn height(&self) -> u64 {
        self.headers.last().map(|h| h.index).unwrap_or(0)
    }

    pub fn get_header(&self, height: u64) -> Option<&SpvBlockHeader> {
        self.headers.iter().find(|h| h.index == height)
    }

    pub fn latest_header(&self) -> Option<&SpvBlockHeader> {
        self.headers.last()
    }

    pub fn header_count(&self) -> usize {
        self.headers.len()
    }

    /// Verify TX is in a block we know about.
    pub fn verify_transaction(&self, proof: &MerkleProof) -> bool {
        let header = match self.get_header(proof.block_index) {
            Some(h) => h,
            None => return false,
        };
        if proof.merkle_root != header.merkle_root {
            return false;
        }
        verify_merkle_proof(proof)
    }

    pub fn watch_address(&mut self, address: &[u8]) {
        self.bloom.add(address);
    }

    pub fn matches_filter(&self, address: &[u8]) -> bool {
        self.bloom.contains(address)
    }

    /// Number of confirmations for a proven TX at the given block height.
    pub fn confirmations(&self, proof: &MerkleProof) -> u32 {
        let tip = self.height();
        if proof.block_index > tip {
            return 0;
        }
        (tip - proof.block_index + 1) as u32
    }

    /// Estimate storage used in bytes — `124 * num_headers` (SPV form).
    pub fn estimate_storage_size(&self) -> u64 {
        (self.headers.len() as u64) * 124
    }

    /// Fast-sync from a trusted checkpoint. First new header must link to it.
    pub fn fast_sync_from_checkpoint(
        &mut self,
        trusted: &SpvBlockHeader,
        new_headers: &[SpvBlockHeader],
    ) -> Result<(), LightClientError> {
        if let Some(first) = new_headers.first() {
            if first.previous_hash != trusted.hash {
                return Err(LightClientError::InvalidCheckpoint);
            }
        }
        for h in new_headers {
            self.add_header(h.clone());
        }
        Ok(())
    }

    /// Serialize: `[count u32 LE][header0 124B][header1 124B]...`
    pub fn serialize_to_bytes(&self) -> Vec<u8> {
        use byteorder::{ByteOrder, LittleEndian};
        let total = 4 + self.headers.len() * 124;
        let mut buf = vec![0u8; total];
        LittleEndian::write_u32(&mut buf[0..4], self.headers.len() as u32);
        for (i, h) in self.headers.iter().enumerate() {
            let off = 4 + i * 124;
            let mut tmp = [0u8; 124];
            h.write_to(&mut tmp);
            buf[off..off + 124].copy_from_slice(&tmp);
        }
        buf
    }

    pub fn deserialize_from_bytes(&mut self, data: &[u8]) -> Result<(), LightClientError> {
        use byteorder::{ByteOrder, LittleEndian};
        if data.len() < 4 {
            return Err(LightClientError::InsufficientData);
        }
        let count = LittleEndian::read_u32(&data[0..4]) as usize;
        if data.len() < 4 + count * 124 {
            return Err(LightClientError::InsufficientData);
        }
        for i in 0..count {
            let off = 4 + i * 124;
            let mut arr = [0u8; 124];
            arr.copy_from_slice(&data[off..off + 124]);
            self.add_header(SpvBlockHeader::deserialize(&arr));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk(idx: u64, prev_hash: [u8; 32], self_hash: [u8; 32], ts: i64) -> SpvBlockHeader {
        let mut h = SpvBlockHeader::new(idx);
        h.previous_hash = prev_hash;
        h.hash = self_hash;
        h.timestamp = ts;
        h
    }

    #[test]
    fn add_and_height() {
        let mut c = LightClient::new();
        c.add_header(mk(0, [0; 32], [0xAA; 32], 100));
        c.add_header(mk(1, [0xAA; 32], [0xBB; 32], 110));
        assert_eq!(c.height(), 1);
        assert_eq!(c.header_count(), 2);
    }

    #[test]
    fn pruning() {
        let mut c = LightClient::new();
        c.max_headers_to_keep = 5;
        for i in 0..10u64 {
            c.add_header(SpvBlockHeader::new(i));
        }
        assert_eq!(c.header_count(), 5);
    }

    #[test]
    fn validate_chain_linkage() {
        let mut c = LightClient::new();
        let now = 1_743_000_000;
        c.add_header(mk(0, [0; 32], [0xAA; 32], now));
        let next = mk(1, [0xAA; 32], [0xBB; 32], now + 10);
        assert!(c.validate_header(&next, now + 20));

        let bad = mk(1, [0xCC; 32], [0xBB; 32], now + 10); // wrong prev
        assert!(!c.validate_header(&bad, now + 20));
    }

    #[test]
    fn confirmations() {
        let mut c = LightClient::new();
        for i in 0..10u64 {
            c.add_header(SpvBlockHeader::new(i));
        }
        let proof = MerkleProof::new([0; 32], [0; 32], 5, 0);
        assert_eq!(c.confirmations(&proof), 5);
    }

    #[test]
    fn storage_estimate() {
        let mut c = LightClient::new();
        for i in 0..10u64 {
            c.add_header(SpvBlockHeader::new(i));
        }
        assert_eq!(c.estimate_storage_size(), 10 * 124);
    }

    #[test]
    fn serialize_roundtrip() {
        let mut c = LightClient::new();
        for i in 0..3u64 {
            c.add_header(SpvBlockHeader::new(i));
        }
        let buf = c.serialize_to_bytes();

        let mut c2 = LightClient::new();
        c2.deserialize_from_bytes(&buf).unwrap();
        assert_eq!(c2.header_count(), 3);
        assert_eq!(c2.headers[0].index, 0);
        assert_eq!(c2.headers[2].index, 2);
    }

    #[test]
    fn fast_sync() {
        let mut c = LightClient::new();
        let trusted = mk(99, [0; 32], [0x99; 32], 500);
        let h100 = mk(100, [0x99; 32], [0xAA; 32], 510);
        let h101 = mk(101, [0xAA; 32], [0xBB; 32], 520);
        assert!(c.fast_sync_from_checkpoint(&trusted, &[h100, h101]).is_ok());
        assert_eq!(c.header_count(), 2);

        // Bad checkpoint
        let mut c2 = LightClient::new();
        let bad = mk(100, [0x00; 32], [0xAA; 32], 510); // doesn't link
        assert!(c2.fast_sync_from_checkpoint(&trusted, &[bad]).is_err());
    }

    #[test]
    fn bloom_watch_address() {
        let mut c = LightClient::new();
        c.watch_address(b"ob1qabc");
        assert!(c.matches_filter(b"ob1qabc"));
    }
}
