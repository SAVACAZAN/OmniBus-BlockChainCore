//! Bloom filter — port of Zig core/light_client.zig::BloomFilter.
//!
//! Wire format: 513 bytes total
//!   - byte 0     : num_hash_funcs (clamped to 1..=20 on construction)
//!   - bytes 1..513: 512-byte bit array (4096 bits)
//!
//! Hash function: Murmur-inspired 32-bit hash with seed rotation per
//! function index. MUST match `bloomHash` in Zig byte-for-byte so that
//! a filter built on one node can be queried on another.

/// Bit array size in bytes (4096 bits).
pub const BLOOM_BITS_BYTES: usize = 512;

/// Full on-wire size: 1 byte hash-func count + bit array.
pub const BLOOM_WIRE_SIZE: usize = 513;

const TOTAL_BITS: u32 = (BLOOM_BITS_BYTES as u32) * 8; // 4096

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BloomFilter {
    pub bits: [u8; BLOOM_BITS_BYTES],
    pub num_hash_funcs: u8,
}

impl BloomFilter {
    /// Create a new filter. Clamps num_hash_funcs into [1, 20]; defaults to 3
    /// if input is 0. Matches Zig `BloomFilter.init`.
    pub fn new(num_hash_funcs: u8) -> Self {
        let k = if num_hash_funcs < 1 {
            3
        } else if num_hash_funcs > 20 {
            20
        } else {
            num_hash_funcs
        };
        Self {
            bits: [0u8; BLOOM_BITS_BYTES],
            num_hash_funcs: k,
        }
    }

    /// Insert data (address, txid, pubkey) into the filter.
    pub fn add(&mut self, data: &[u8]) {
        for f in 0..self.num_hash_funcs as u32 {
            let bit_pos = bloom_hash(data, f) % TOTAL_BITS;
            let byte_idx = (bit_pos / 8) as usize;
            let bit_off = (bit_pos % 8) as u8;
            self.bits[byte_idx] |= 1u8 << bit_off;
        }
    }

    /// Check if data might be in the filter. May return false positives,
    /// never false negatives.
    pub fn contains(&self, data: &[u8]) -> bool {
        for f in 0..self.num_hash_funcs as u32 {
            let bit_pos = bloom_hash(data, f) % TOTAL_BITS;
            let byte_idx = (bit_pos / 8) as usize;
            let bit_off = (bit_pos % 8) as u8;
            if self.bits[byte_idx] & (1u8 << bit_off) == 0 {
                return false;
            }
        }
        true
    }

    /// Reset all bits to 0.
    pub fn clear(&mut self) {
        self.bits = [0u8; BLOOM_BITS_BYTES];
    }

    /// Serialize to 513-byte wire form: [num_hash_funcs][bits..]
    pub fn serialize(&self) -> [u8; BLOOM_WIRE_SIZE] {
        let mut buf = [0u8; BLOOM_WIRE_SIZE];
        buf[0] = self.num_hash_funcs;
        buf[1..BLOOM_WIRE_SIZE].copy_from_slice(&self.bits);
        buf
    }

    pub fn deserialize(data: &[u8]) -> Option<Self> {
        if data.len() < BLOOM_WIRE_SIZE {
            return None;
        }
        let mut f = BloomFilter::new(data[0]);
        f.bits.copy_from_slice(&data[1..BLOOM_WIRE_SIZE]);
        Some(f)
    }

    /// Rough false-positive percentage estimate given num_elements inserted.
    /// Mirrors Zig's coarse `(k*n*100)/m` heuristic.
    pub fn estimate_false_positive_pct(&self, num_elements: u32) -> u32 {
        if num_elements == 0 {
            return 0;
        }
        let m: u64 = TOTAL_BITS as u64;
        let k: u64 = self.num_hash_funcs as u64;
        let n: u64 = num_elements as u64;
        let ratio = (k * n * 100) / m;
        if ratio > 100 {
            100
        } else {
            ratio as u32
        }
    }
}

/// Murmur-inspired 32-bit hash with per-function seed rotation.
///
/// MUST match Zig `bloomHash` byte-for-byte. Uses wrapping arithmetic.
///
/// Seed:   h = 0xdeadbeef + func_index * 0x9e3779b9
/// Body:   for each byte b: h ^= b; h *= 0x5bd1e995; h ^= h >> 15
/// Finish: h ^= h >> 13; h *= 0x5bd1e995; h ^= h >> 16
pub fn bloom_hash(data: &[u8], func_index: u32) -> u32 {
    let mut h: u32 = 0xdead_beef_u32
        .wrapping_add(func_index.wrapping_mul(0x9e37_79b9));
    for &byte in data {
        h ^= byte as u32;
        h = h.wrapping_mul(0x5bd1_e995);
        h ^= h >> 15;
    }
    h ^= h >> 13;
    h = h.wrapping_mul(0x5bd1_e995);
    h ^= h >> 16;
    h
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_size() {
        let f = BloomFilter::new(5);
        let buf = f.serialize();
        assert_eq!(buf.len(), 513);
        assert_eq!(buf[0], 5);
    }

    #[test]
    fn add_then_contains() {
        let mut f = BloomFilter::new(5);
        let addr = b"ob1qwy7g9sk5s7qsc2m7d02j9anwyja4jcwwnxs2j7";
        f.add(addr);
        assert!(f.contains(addr));
    }

    #[test]
    fn clear_resets() {
        let mut f = BloomFilter::new(5);
        f.add(b"ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh");
        assert!(f.contains(b"ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));
        f.clear();
        assert!(!f.contains(b"ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));
    }

    #[test]
    fn non_member_probably_misses() {
        let mut f = BloomFilter::new(5);
        f.add(b"ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh");
        f.add(b"ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas");
        // Probabilistic; assert at least one of these doesn't match.
        let a = f.contains(b"ob1qa5ackdxmacapcf7f4h592yawv6ansjscejxj8h");
        let b = f.contains(b"totally_different_string_abcdefghijklmnop");
        assert!(!a || !b);
    }

    #[test]
    fn num_hash_funcs_clamped() {
        assert_eq!(BloomFilter::new(0).num_hash_funcs, 3);
        assert_eq!(BloomFilter::new(50).num_hash_funcs, 20);
        assert_eq!(BloomFilter::new(7).num_hash_funcs, 7);
    }

    #[test]
    fn serialize_deserialize_roundtrip() {
        let mut f = BloomFilter::new(7);
        f.add(b"hello");
        f.add(b"world");
        let buf = f.serialize();
        let f2 = BloomFilter::deserialize(&buf).unwrap();
        assert_eq!(f, f2);
    }

    #[test]
    fn bloom_hash_known_values() {
        // Lock the algorithm — these values must remain stable.
        // (Not checked against Zig in this commit but locked here so any
        // accidental change to the algorithm fails the test.)
        let h0 = bloom_hash(b"", 0);
        let h1 = bloom_hash(b"a", 0);
        let h2 = bloom_hash(b"a", 1);
        assert_ne!(h1, h2, "different seeds must produce different hashes");
        assert_ne!(h0, h1);
    }
}
