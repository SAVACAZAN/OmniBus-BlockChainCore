//! `chain.dat` reader/writer — Rust port of Zig `core/database.zig`.
//!
//! # File format (v2/v3/v4, current `DB_VERSION = 4`)
//!
//! All integers LITTLE-ENDIAN unless noted. CRC32 = IEEE polynomial (matches
//! Zig `std.hash.crc.Crc32`). The `.tmp` + rename idiom is used for atomic
//! writes.
//!
//! ```text
//! [magic:4]     = "OMNI" (0x4F 0x4D 0x4E 0x49)
//! [version:4]   = u32 LE, currently 4. v1 is detected via byte-form
//!                 (magic + 1 at offset 4) and parsed differently.
//!
//! === blocks section ===
//! [block_count:4] u32 LE
//! per block:
//!   [height:8]    u64 LE
//!   [data_len:4]  u32 LE
//!   [data:data_len]
//!     Block payload is mixed:
//!       1. pipe-delimited header: "{idx}|{ts}|{nonce}|{prev}|{hash}|{miner}|{reward}"
//!          (ASCII, 7 fields, 6 `|` separators)
//!       2. (v4 only) followed by [tx_count:4] [tx_wire:N]... binary section.
//! [crc32:4] u32 LE — CRC of section payload (block_count + all block records)
//!
//! === balances section ===
//! [addr_count:4] u32 LE
//! per address: [addr_len:1] [addr:addr_len] [balance:8] u64 LE
//! [crc32:4]
//!
//! === nonces section ===     (same shape as balances, value=nonce u64 LE)
//! [crc32:4]
//!
//! === tx_confirms section === (key=tx_hash 1+N bytes, value=block_height u64 LE)
//! [crc32:4]
//!
//! === stake_state (v2 ext) === same shape, value=stake_sat u64 LE
//! [crc32:4]
//!
//! === agent_state (v2 ext) === key only (no value)
//!   per addr: [addr_len:1] [addr:addr_len]
//! [crc32:4]
//!
//! === orderbook_state (v3 ext) ===
//! [pair_count:4] u32 LE
//! per pair:
//!   [pair_id:2]    u16 LE
//!   [order_count:4] u32 LE
//!   [orders:N * 128 bytes]  — see `Order128` layout below.
//! [crc32:4]
//!
//! === fills_history (v3 ext) ===
//! [block_count:4] u32 LE
//! per block:
//!   [height:4]     u32 LE  (NB: u32, not u64!)
//!   [fill_count:4] u32 LE
//!   [fills:N * FILL_WIRE_SIZE bytes]  — opaque; mirror what Zig writes verbatim.
//! [crc32:4]
//! ```
//!
//! # Order128 (128-byte fixed record, all LE)
//!
//! ```text
//! [ 0.. 8] order_id        u64
//! [ 8..72] trader_address  [u8; 64]
//! [72..73] trader_addr_len u8
//! [73..75] pair_id         u16
//! [75..76] side            u8   (0=buy, 1=sell)
//! [76..84] price_micro_usd u64
//! [84..92] amount_sat      u64
//! [92..100] filled_sat     u64
//! [100..108] timestamp_ms  i64
//! [108..109] status        u8   (0=active, 1=partial, 2=filled, 3=cancelled)
//! [109..128] reserved (zero)
//! ```

use crate::storage::codec::BinaryEncoder;
use byteorder::{ByteOrder, LittleEndian};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

pub const DB_MAGIC: [u8; 4] = *b"OMNI";
pub const DB_VERSION: u32 = 4;
pub const ORDERBOOK_ORDER_BYTES: usize = 128;
pub const LEGACY_DB_FILE: &str = "omnibus-chain.dat";

/// CRC32-IEEE — matches Zig `std.hash.crc.Crc32` (poly 0xEDB88320, reflected).
/// Implemented inline to avoid pulling in another crate; the table is built lazily.
pub fn crc32(data: &[u8]) -> u32 {
    static mut TABLE: [u32; 256] = [0; 256];
    static INIT: std::sync::Once = std::sync::Once::new();
    INIT.call_once(|| {
        // SAFETY: single-threaded init guarded by Once.
        unsafe {
            for i in 0..256u32 {
                let mut c = i;
                for _ in 0..8 {
                    c = if c & 1 != 0 { 0xEDB88320 ^ (c >> 1) } else { c >> 1 };
                }
                TABLE[i as usize] = c;
            }
        }
    });
    let mut crc: u32 = 0xFFFF_FFFF;
    for &b in data {
        let idx = ((crc ^ b as u32) & 0xFF) as usize;
        // SAFETY: table is initialised by Once above and read-only thereafter.
        crc = unsafe { TABLE[idx] } ^ (crc >> 8);
    }
    crc ^ 0xFFFF_FFFF
}

/// Compute `data/<short_name>/chain.dat`. Strips the "omnibus-" prefix from
/// `chain_name` if present and creates the parent directory.
pub fn db_path_for_chain(chain_name: &str) -> io::Result<PathBuf> {
    let short = chain_name.strip_prefix("omnibus-").unwrap_or(chain_name);
    let dir = Path::new("data").join(short);
    fs::create_dir_all(&dir)?;
    Ok(dir.join("chain.dat"))
}

/// One persisted block record (just height + raw payload — we don't try to
/// reinterpret the pipe-delimited header here; that's the chain layer's job).
#[derive(Debug, Clone)]
pub struct BlockRecord {
    pub height: u64,
    pub data: Vec<u8>,
}

/// One on-disk 128-byte order record.
#[derive(Debug, Clone, Copy)]
pub struct Order128 {
    pub order_id: u64,
    pub trader_address: [u8; 64],
    pub trader_addr_len: u8,
    pub pair_id: u16,
    pub side: u8,
    pub price_micro_usd: u64,
    pub amount_sat: u64,
    pub filled_sat: u64,
    pub timestamp_ms: i64,
    pub status: u8,
}

impl Order128 {
    pub fn encode(&self, out: &mut [u8; ORDERBOOK_ORDER_BYTES]) {
        out.fill(0);
        LittleEndian::write_u64(&mut out[0..8], self.order_id);
        out[8..72].copy_from_slice(&self.trader_address);
        out[72] = self.trader_addr_len;
        LittleEndian::write_u16(&mut out[73..75], self.pair_id);
        out[75] = self.side;
        LittleEndian::write_u64(&mut out[76..84], self.price_micro_usd);
        LittleEndian::write_u64(&mut out[84..92], self.amount_sat);
        LittleEndian::write_u64(&mut out[92..100], self.filled_sat);
        LittleEndian::write_i64(&mut out[100..108], self.timestamp_ms);
        out[108] = self.status;
    }

    pub fn decode(buf: &[u8; ORDERBOOK_ORDER_BYTES]) -> Self {
        let mut trader_address = [0u8; 64];
        trader_address.copy_from_slice(&buf[8..72]);
        Self {
            order_id: LittleEndian::read_u64(&buf[0..8]),
            trader_address,
            trader_addr_len: buf[72],
            pair_id: LittleEndian::read_u16(&buf[73..75]),
            side: buf[75],
            price_micro_usd: LittleEndian::read_u64(&buf[76..84]),
            amount_sat: LittleEndian::read_u64(&buf[84..92]),
            filled_sat: LittleEndian::read_u64(&buf[92..100]),
            timestamp_ms: LittleEndian::read_i64(&buf[100..108]),
            status: buf[108],
        }
    }
}

/// In-memory representation of a `chain.dat` file. The chain layer reads
/// blocks/balances/etc out of this, and the persistence layer rebuilds it
/// from live state on save. Sections that the Rust node doesn't care about
/// yet (orderbook, fills) are kept as opaque bytes so round-trip works.
#[derive(Debug, Default)]
pub struct ChainDb {
    pub version: u32,
    pub blocks: Vec<BlockRecord>,
    pub balances: Vec<(Vec<u8>, u64)>,
    pub nonces: Vec<(Vec<u8>, u64)>,
    pub tx_confirms: Vec<(Vec<u8>, u64)>,
    pub stakes: Vec<(Vec<u8>, u64)>,
    pub agents: Vec<Vec<u8>>,
    /// Opaque orderbook payload (NO CRC32 trailer). Kept verbatim from the file
    /// so a Rust-side save round-trips bit-identically to the Zig save.
    pub orderbook_state: Vec<u8>,
    /// Opaque fills history payload (NO CRC32 trailer).
    pub fills_history: Vec<u8>,
}

impl ChainDb {
    pub fn new() -> Self { Self { version: DB_VERSION, ..Default::default() } }

    /// Read `path`, returning `Ok(ChainDb::default())` if the file doesn't exist
    /// (matches Zig behaviour of "start from genesis on missing file").
    pub fn load<P: AsRef<Path>>(path: P) -> io::Result<Self> {
        let path = path.as_ref();
        let mut file = match File::open(path) {
            Ok(f) => f,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Self::new()),
            Err(e) => return Err(e),
        };
        let mut buf = Vec::new();
        file.read_to_end(&mut buf)?;
        Self::parse(&buf)
    }

    /// Parse a full chain.dat buffer. Returns InvalidData on magic mismatch.
    pub fn parse(buf: &[u8]) -> io::Result<Self> {
        if buf.len() < 8 {
            return Ok(Self::new());
        }
        if buf[0..4] != DB_MAGIC {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "bad magic"));
        }
        // Distinguish v1 (single byte version=1) from v2+ (u32 LE version).
        let ver_u32 = LittleEndian::read_u32(&buf[4..8]);
        if ver_u32 >= 2 && ver_u32 <= DB_VERSION {
            return Self::parse_v2plus(buf, ver_u32);
        }
        if buf[4] == 1 {
            return Self::parse_v1(buf);
        }
        Err(io::Error::new(io::ErrorKind::InvalidData, "unknown version"))
    }

    /// v1 layout: [magic:4][ver:1][block_count:4] + blocks + [addr_count:4]+entries
    /// + optional [nonce_count]+entries + [tx_confirm_count]+entries. No CRCs.
    fn parse_v1(buf: &[u8]) -> io::Result<Self> {
        let mut db = Self::new();
        db.version = 1;
        let mut pos = 5usize;
        if pos + 4 > buf.len() { return Ok(db); }
        let block_count = LittleEndian::read_u32(&buf[pos..pos + 4]);
        pos += 4;
        for _ in 0..block_count {
            if pos + 12 > buf.len() { return Ok(db); }
            let height = LittleEndian::read_u64(&buf[pos..pos + 8]);
            pos += 8;
            let data_len = LittleEndian::read_u32(&buf[pos..pos + 4]) as usize;
            pos += 4;
            if pos + data_len > buf.len() { return Ok(db); }
            db.blocks.push(BlockRecord { height, data: buf[pos..pos + data_len].to_vec() });
            pos += data_len;
        }
        pos = read_lp1_u64_section(buf, pos, &mut db.balances);
        pos = read_lp1_u64_section(buf, pos, &mut db.nonces);
        let _ = read_lp1_u64_section(buf, pos, &mut db.tx_confirms);
        Ok(db)
    }

    fn parse_v2plus(buf: &[u8], version: u32) -> io::Result<Self> {
        let mut db = Self::new();
        db.version = version;
        let mut pos = 8usize;

        // --- blocks section ---
        let sec_start = pos;
        if pos + 4 > buf.len() { return Ok(db); }
        let block_count = LittleEndian::read_u32(&buf[pos..pos + 4]);
        pos += 4;
        for _ in 0..block_count {
            if pos + 12 > buf.len() { break; }
            let height = LittleEndian::read_u64(&buf[pos..pos + 8]);
            pos += 8;
            let data_len = LittleEndian::read_u32(&buf[pos..pos + 4]) as usize;
            pos += 4;
            if pos + data_len > buf.len() { break; }
            db.blocks.push(BlockRecord { height, data: buf[pos..pos + data_len].to_vec() });
            pos += data_len;
        }
        pos = verify_and_skip_crc(buf, sec_start, pos, "blocks");

        // --- 4 length-prefixed u64-value sections (balances, nonces, tx_confirms, stakes) ---
        pos = parse_lp1_u64_section_v2(buf, pos, &mut db.balances, "balances");
        pos = parse_lp1_u64_section_v2(buf, pos, &mut db.nonces, "nonces");
        pos = parse_lp1_u64_section_v2(buf, pos, &mut db.tx_confirms, "tx_confirms");
        pos = parse_lp1_u64_section_v2(buf, pos, &mut db.stakes, "stakes");

        // --- agent_state: keys only, no value ---
        if pos + 4 <= buf.len() {
            let sec_start = pos;
            let count = LittleEndian::read_u32(&buf[pos..pos + 4]);
            pos += 4;
            for _ in 0..count {
                if pos + 1 > buf.len() { break; }
                let addr_len = buf[pos] as usize;
                pos += 1;
                if pos + addr_len > buf.len() { break; }
                db.agents.push(buf[pos..pos + addr_len].to_vec());
                pos += addr_len;
            }
            pos = verify_and_skip_crc(buf, sec_start, pos, "agents");
        }

        // --- orderbook_state (v3+) ---
        if pos + 4 <= buf.len() {
            let sec_start = pos;
            let size = orderbook_section_size(&buf[pos..])?;
            db.orderbook_state = buf[pos..pos + size].to_vec();
            pos += size;
            pos = verify_and_skip_crc(buf, sec_start, pos, "orderbook");
        }

        // --- fills_history (v3+) ---
        if pos + 4 <= buf.len() {
            let sec_start = pos;
            let size = fills_section_size(&buf[pos..])?;
            db.fills_history = buf[pos..pos + size].to_vec();
            pos += size;
            let _ = verify_and_skip_crc(buf, sec_start, pos, "fills");
        }

        Ok(db)
    }

    /// Atomic write: <path>.tmp + rename.
    pub fn save<P: AsRef<Path>>(&self, path: P) -> io::Result<()> {
        let path = path.as_ref();
        let tmp_path = {
            let mut p = path.as_os_str().to_owned();
            p.push(".tmp");
            PathBuf::from(p)
        };

        let bytes = self.encode();
        {
            let mut f = File::create(&tmp_path)?;
            f.write_all(&bytes)?;
            f.sync_all()?;
        }
        fs::rename(&tmp_path, path)?;
        Ok(())
    }

    /// Encode to v4 bytes — must be byte-for-byte identical to Zig's
    /// `PersistentBlockchain.saveBlockchain` output for the same inputs.
    pub fn encode(&self) -> Vec<u8> {
        let mut e = BinaryEncoder::new();

        // Header: magic + version(u32 LE)
        e.write_bytes(&DB_MAGIC);
        e.write_u32_le(DB_VERSION);

        // blocks
        let s = e.size();
        e.write_u32_le(self.blocks.len() as u32);
        for b in &self.blocks {
            e.write_u64_le(b.height);
            e.write_u32_le(b.data.len() as u32);
            e.write_bytes(&b.data);
        }
        append_crc32(&mut e, s);

        write_lp1_u64_section(&mut e, &self.balances);
        write_lp1_u64_section(&mut e, &self.nonces);
        write_lp1_u64_section(&mut e, &self.tx_confirms);
        write_lp1_u64_section(&mut e, &self.stakes);

        // agents (key only)
        let s = e.size();
        e.write_u32_le(self.agents.len() as u32);
        for a in &self.agents {
            // truncate addr to 255 to match Zig's `if (addr.len > 255) continue;`
            if a.len() > 255 { continue; }
            e.buffer.push(a.len() as u8);
            e.write_bytes(a);
        }
        append_crc32(&mut e, s);

        // orderbook_state (verbatim opaque payload)
        let s = e.size();
        e.write_bytes(&self.orderbook_state);
        append_crc32(&mut e, s);

        // fills_history
        let s = e.size();
        e.write_bytes(&self.fills_history);
        append_crc32(&mut e, s);

        e.into_bytes()
    }
}

fn append_crc32(e: &mut BinaryEncoder, section_start: usize) {
    let crc = crc32(&e.buffer[section_start..]);
    e.write_u32_le(crc);
}

fn verify_and_skip_crc(buf: &[u8], sec_start: usize, sec_end: usize, label: &str) -> usize {
    if sec_end + 4 > buf.len() { return sec_end; }
    let stored = LittleEndian::read_u32(&buf[sec_end..sec_end + 4]);
    let computed = crc32(&buf[sec_start..sec_end]);
    if stored != computed {
        eprintln!("[chain.dat] CRC32 mismatch in {label} section (stored={stored:#x}, computed={computed:#x})");
    }
    sec_end + 4
}

/// V1 helper: read addr_count + entries with NO trailing CRC.
fn read_lp1_u64_section(buf: &[u8], mut pos: usize, out: &mut Vec<(Vec<u8>, u64)>) -> usize {
    if pos + 4 > buf.len() { return pos; }
    let count = LittleEndian::read_u32(&buf[pos..pos + 4]);
    pos += 4;
    for _ in 0..count {
        if pos + 1 > buf.len() { return pos; }
        let addr_len = buf[pos] as usize;
        pos += 1;
        if pos + addr_len + 8 > buf.len() { return pos; }
        let key = buf[pos..pos + addr_len].to_vec();
        pos += addr_len;
        let v = LittleEndian::read_u64(&buf[pos..pos + 8]);
        pos += 8;
        out.push((key, v));
    }
    pos
}

/// V2 helper: same shape but with a CRC32 trailer.
fn parse_lp1_u64_section_v2(buf: &[u8], pos: usize, out: &mut Vec<(Vec<u8>, u64)>, label: &str) -> usize {
    if pos + 4 > buf.len() { return pos; }
    let sec_start = pos;
    let new_pos = read_lp1_u64_section(buf, pos, out);
    verify_and_skip_crc(buf, sec_start, new_pos, label)
}

fn write_lp1_u64_section(e: &mut BinaryEncoder, entries: &[(Vec<u8>, u64)]) {
    let s = e.size();
    // Zig counts ALL entries via map.count() but skips records with len>255 at
    // write time. We match the count-then-skip behaviour for parity.
    e.write_u32_le(entries.len() as u32);
    for (k, v) in entries {
        if k.len() > 255 { continue; }
        e.buffer.push(k.len() as u8);
        e.write_bytes(k);
        e.write_u64_le(*v);
    }
    append_crc32(e, s);
}

/// Walk the orderbook section header to compute its exact byte length.
/// Mirrors Zig `orderbookSectionSize`.
pub fn orderbook_section_size(buf: &[u8]) -> io::Result<usize> {
    if buf.len() < 4 { return Ok(0); }
    let pair_count = LittleEndian::read_u32(&buf[0..4]);
    let mut off = 4usize;
    for _ in 0..pair_count {
        if off + 6 > buf.len() {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "orderbook truncated"));
        }
        off += 2; // pair_id
        let order_count = LittleEndian::read_u32(&buf[off..off + 4]) as usize;
        off += 4;
        let orders_bytes = order_count * ORDERBOOK_ORDER_BYTES;
        if off + orders_bytes > buf.len() {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "orderbook truncated"));
        }
        off += orders_bytes;
    }
    Ok(off)
}

/// Walk the fills_history section header to compute its byte length.
/// `FILL_WIRE_SIZE` in Zig is 180 — we hardcode it here too. If the Zig side
/// ever changes it, update this constant.
pub const FILL_WIRE_SIZE: usize = 180;

pub fn fills_section_size(buf: &[u8]) -> io::Result<usize> {
    if buf.len() < 4 { return Ok(0); }
    let block_count = LittleEndian::read_u32(&buf[0..4]);
    let mut off = 4usize;
    for _ in 0..block_count {
        if off + 8 > buf.len() {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "fills truncated"));
        }
        off += 4; // block_height u32
        let fill_count = LittleEndian::read_u32(&buf[off..off + 4]) as usize;
        off += 4;
        let fills_bytes = fill_count * FILL_WIRE_SIZE;
        if off + fills_bytes > buf.len() {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "fills truncated"));
        }
        off += fills_bytes;
    }
    Ok(off)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc32_known_vector() {
        // "123456789" -> 0xCBF43926 (standard IEEE CRC32 test vector)
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
    }

    #[test]
    fn empty_db_roundtrips() {
        let db = ChainDb::new();
        let bytes = db.encode();
        // Header (8) + 4 u64-value sections (4 + 4 each) + agents (4+4) + 2 verbatim (0+4) = 8 + 6*8 = 56
        assert_eq!(&bytes[0..4], b"OMNI");
        assert_eq!(LittleEndian::read_u32(&bytes[4..8]), DB_VERSION);
        let parsed = ChainDb::parse(&bytes).unwrap();
        assert_eq!(parsed.blocks.len(), 0);
        assert_eq!(parsed.balances.len(), 0);
        assert_eq!(parsed.agents.len(), 0);
    }

    #[test]
    fn balances_roundtrip() {
        let mut db = ChainDb::new();
        db.balances.push((b"alice".to_vec(), 100));
        db.balances.push((b"bob".to_vec(), 250));
        let bytes = db.encode();
        let parsed = ChainDb::parse(&bytes).unwrap();
        assert_eq!(parsed.balances, db.balances);
    }

    #[test]
    fn block_roundtrip() {
        let mut db = ChainDb::new();
        db.blocks.push(BlockRecord { height: 1, data: b"1|2|3|prev|hash|miner|50".to_vec() });
        db.blocks.push(BlockRecord { height: 2, data: vec![0xAA; 64] });
        let bytes = db.encode();
        let parsed = ChainDb::parse(&bytes).unwrap();
        assert_eq!(parsed.blocks.len(), 2);
        assert_eq!(parsed.blocks[1].data, vec![0xAA; 64]);
    }

    #[test]
    fn order128_roundtrip() {
        let o = Order128 {
            order_id: 0x1122_3344_5566_7788,
            trader_address: [0xCC; 64],
            trader_addr_len: 42,
            pair_id: 0x0203,
            side: 1,
            price_micro_usd: 1_000_000,
            amount_sat: 5_000_000_000,
            filled_sat: 2_500_000_000,
            timestamp_ms: 1_700_000_000_000,
            status: 1,
        };
        let mut buf = [0u8; ORDERBOOK_ORDER_BYTES];
        o.encode(&mut buf);
        // First 8 bytes: order_id LE = 88 77 66 55 44 33 22 11
        assert_eq!(&buf[0..8], &[0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11]);
        let back = Order128::decode(&buf);
        assert_eq!(back.order_id, o.order_id);
        assert_eq!(back.pair_id, o.pair_id);
        assert_eq!(back.status, o.status);
        assert_eq!(back.trader_addr_len, o.trader_addr_len);
    }
}
