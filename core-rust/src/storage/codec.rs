//! Binary codec — direct port of `core/binary_codec.zig`.
//!
//! Two layers:
//!
//! 1. **Varint** (Protobuf/LEB128 style): u32/u64 split into 7-bit groups,
//!    little-endian, continuation-bit `0x80` set on every byte except the last.
//!    Example: `127`  -> `[0x7F]`
//!             `128`  -> `[0x80, 0x01]`
//!             `300`  -> `[0xAC, 0x02]`
//!
//! 2. **Fixed-width LE** primitives: u8/u16/u32/u64/i64 written via the
//!    `byteorder` crate with `LittleEndian`. Matches `std.mem.writeInt(..., .little)`
//!    in the Zig code.
//!
//! Length-prefixed bytes use a 1-byte length (Zig: `out.append(@intCast(addr.len))`),
//! capped at 255. Variable-length slices longer than that use a u32 LE prefix.

use byteorder::{ByteOrder, LittleEndian};
use std::io;

/// LEB128-style varint encoder/decoder (matches Zig `Varint` in `binary_codec.zig`).
pub struct Varint;

impl Varint {
    /// Encode `value` as varint into `out`. Returns number of bytes written.
    ///
    /// Byte-level contract:
    /// ```text
    /// while v >= 128: emit (v & 0x7F) | 0x80; v >>= 7
    /// emit (v & 0x7F)
    /// ```
    pub fn encode_u64(mut value: u64, out: &mut Vec<u8>) -> usize {
        let start = out.len();
        while value >= 128 {
            out.push(((value & 0x7F) as u8) | 0x80);
            value >>= 7;
        }
        out.push((value & 0x7F) as u8);
        out.len() - start
    }

    pub fn encode_u32(value: u32, out: &mut Vec<u8>) -> usize {
        Self::encode_u64(value as u64, out)
    }

    /// Decode a varint. Returns `(value, bytes_read)`.
    pub fn decode_u64(data: &[u8]) -> io::Result<(u64, usize)> {
        let mut result: u64 = 0;
        let mut shift: u32 = 0;
        let mut bytes_read: usize = 0;
        for &byte in data {
            result |= ((byte & 0x7F) as u64) << shift;
            bytes_read += 1;
            if byte < 128 {
                return Ok((result, bytes_read));
            }
            shift += 7;
            if shift >= 64 {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "varint too long"));
            }
        }
        // The Zig version "breaks" on byte<128 but also returns when buf exhausted;
        // we keep the loose semantics for compatibility.
        Ok((result, bytes_read))
    }

    pub fn decode_u32(data: &[u8]) -> io::Result<(u32, usize)> {
        let (v, n) = Self::decode_u64(data)?;
        Ok((v as u32, n))
    }
}

/// Buffered binary encoder — counterpart of `BinaryEncoder` in Zig.
#[derive(Default)]
pub struct BinaryEncoder {
    pub buffer: Vec<u8>,
}

impl BinaryEncoder {
    pub fn new() -> Self { Self { buffer: Vec::new() } }
    pub fn with_capacity(n: usize) -> Self { Self { buffer: Vec::with_capacity(n) } }

    pub fn bytes(&self) -> &[u8] { &self.buffer }
    pub fn size(&self) -> usize { self.buffer.len() }
    pub fn into_bytes(self) -> Vec<u8> { self.buffer }

    pub fn write_u8(&mut self, v: u8) { self.buffer.push(v); }

    pub fn write_u16_le(&mut self, v: u16) {
        let mut b = [0u8; 2];
        LittleEndian::write_u16(&mut b, v);
        self.buffer.extend_from_slice(&b);
    }

    pub fn write_u32_le(&mut self, v: u32) {
        let mut b = [0u8; 4];
        LittleEndian::write_u32(&mut b, v);
        self.buffer.extend_from_slice(&b);
    }

    pub fn write_u64_le(&mut self, v: u64) {
        let mut b = [0u8; 8];
        LittleEndian::write_u64(&mut b, v);
        self.buffer.extend_from_slice(&b);
    }

    pub fn write_i64_le(&mut self, v: i64) {
        let mut b = [0u8; 8];
        LittleEndian::write_i64(&mut b, v);
        self.buffer.extend_from_slice(&b);
    }

    pub fn write_var_u32(&mut self, v: u32) { Varint::encode_u32(v, &mut self.buffer); }
    pub fn write_var_u64(&mut self, v: u64) { Varint::encode_u64(v, &mut self.buffer); }

    pub fn write_bytes(&mut self, b: &[u8]) { self.buffer.extend_from_slice(b); }

    /// 1-byte length prefix, then raw bytes. Used by Zig for short addresses /
    /// tx hashes (Zig: `out.append(@intCast(addr.len)); out.appendSlice(addr);`).
    /// `bytes.len()` MUST be <= 255 or this returns Err.
    pub fn write_lp1(&mut self, bytes: &[u8]) -> io::Result<()> {
        if bytes.len() > 255 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "lp1 len > 255"));
        }
        self.buffer.push(bytes.len() as u8);
        self.buffer.extend_from_slice(bytes);
        Ok(())
    }

    /// u32 LE length prefix + raw bytes. Used for variable-size payloads.
    pub fn write_lp4(&mut self, bytes: &[u8]) {
        self.write_u32_le(bytes.len() as u32);
        self.buffer.extend_from_slice(bytes);
    }
}

/// Buffered binary decoder — counterpart of `BinaryDecoder` in Zig.
pub struct BinaryDecoder<'a> {
    pub data: &'a [u8],
    pub offset: usize,
}

impl<'a> BinaryDecoder<'a> {
    pub fn new(data: &'a [u8]) -> Self { Self { data, offset: 0 } }

    pub fn remaining(&self) -> usize { self.data.len().saturating_sub(self.offset) }
    pub fn eof(&self) -> bool { self.offset >= self.data.len() }

    pub fn read_u8(&mut self) -> io::Result<u8> {
        if self.eof() { return Err(eof()); }
        let v = self.data[self.offset];
        self.offset += 1;
        Ok(v)
    }

    pub fn read_u16_le(&mut self) -> io::Result<u16> {
        if self.remaining() < 2 { return Err(eof()); }
        let v = LittleEndian::read_u16(&self.data[self.offset..self.offset + 2]);
        self.offset += 2;
        Ok(v)
    }

    pub fn read_u32_le(&mut self) -> io::Result<u32> {
        if self.remaining() < 4 { return Err(eof()); }
        let v = LittleEndian::read_u32(&self.data[self.offset..self.offset + 4]);
        self.offset += 4;
        Ok(v)
    }

    pub fn read_u64_le(&mut self) -> io::Result<u64> {
        if self.remaining() < 8 { return Err(eof()); }
        let v = LittleEndian::read_u64(&self.data[self.offset..self.offset + 8]);
        self.offset += 8;
        Ok(v)
    }

    pub fn read_i64_le(&mut self) -> io::Result<i64> {
        if self.remaining() < 8 { return Err(eof()); }
        let v = LittleEndian::read_i64(&self.data[self.offset..self.offset + 8]);
        self.offset += 8;
        Ok(v)
    }

    pub fn read_var_u32(&mut self) -> io::Result<u32> {
        let (v, n) = Varint::decode_u32(&self.data[self.offset..])?;
        self.offset += n;
        Ok(v)
    }

    pub fn read_var_u64(&mut self) -> io::Result<u64> {
        let (v, n) = Varint::decode_u64(&self.data[self.offset..])?;
        self.offset += n;
        Ok(v)
    }

    pub fn read_bytes(&mut self, n: usize) -> io::Result<&'a [u8]> {
        if self.remaining() < n { return Err(eof()); }
        let s = &self.data[self.offset..self.offset + n];
        self.offset += n;
        Ok(s)
    }

    pub fn read_lp1(&mut self) -> io::Result<&'a [u8]> {
        let len = self.read_u8()? as usize;
        self.read_bytes(len)
    }

    pub fn read_lp4(&mut self) -> io::Result<&'a [u8]> {
        let len = self.read_u32_le()? as usize;
        self.read_bytes(len)
    }
}

fn eof() -> io::Error { io::Error::new(io::ErrorKind::UnexpectedEof, "end of data") }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn varint_small() {
        // 127 -> single byte 0x7F
        let mut out = Vec::new();
        Varint::encode_u32(127, &mut out);
        assert_eq!(out, vec![0x7F]);
        // expected Zig output: [0x7F]
    }

    #[test]
    fn varint_two_bytes() {
        // 128 -> 0x80, 0x01
        let mut out = Vec::new();
        Varint::encode_u32(128, &mut out);
        assert_eq!(out, vec![0x80, 0x01]);
        // expected Zig output: [0x80, 0x01]
    }

    #[test]
    fn varint_300() {
        // 300 = 0b100101100 -> low7 0101100=0x2C with cont -> 0xAC, high 0b10 = 0x02
        let mut out = Vec::new();
        Varint::encode_u32(300, &mut out);
        assert_eq!(out, vec![0xAC, 0x02]);
    }

    #[test]
    fn varint_roundtrip() {
        for &v in &[0u64, 1, 127, 128, 300, 16_383, 16_384, 50_000, u32::MAX as u64, u64::MAX] {
            let mut out = Vec::new();
            Varint::encode_u64(v, &mut out);
            let (decoded, n) = Varint::decode_u64(&out).unwrap();
            assert_eq!(decoded, v);
            assert_eq!(n, out.len());
        }
    }

    #[test]
    fn le_primitives_match_zig() {
        // u32 LE: 0x12345678 -> 78 56 34 12
        let mut e = BinaryEncoder::new();
        e.write_u32_le(0x1234_5678);
        assert_eq!(e.bytes(), &[0x78, 0x56, 0x34, 0x12]);
        // expected: same bytes from std.mem.writeInt(u32, ..., 0x12345678, .little)

        // u64 LE: 1 -> 01 00 00 00 00 00 00 00
        let mut e = BinaryEncoder::new();
        e.write_u64_le(1);
        assert_eq!(e.bytes(), &[0x01, 0, 0, 0, 0, 0, 0, 0]);
    }

    #[test]
    fn lp1_roundtrip() {
        let mut e = BinaryEncoder::new();
        e.write_lp1(b"hello").unwrap();
        assert_eq!(e.bytes(), &[5, b'h', b'e', b'l', b'l', b'o']);
        let mut d = BinaryDecoder::new(e.bytes());
        assert_eq!(d.read_lp1().unwrap(), b"hello");
    }
}
