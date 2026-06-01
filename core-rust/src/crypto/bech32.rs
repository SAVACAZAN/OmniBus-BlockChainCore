// Bech32 / Bech32m encoder + decoder. Port of core/bech32.zig (BIP-173 + BIP-350).
//
// HRP = "ob" for OmniBus.
//   witness v0 -> Bech32 (P2WPKH ob1q... — 20-byte hash160; ob1q... for P2WSH 32B)
//   witness v1+ -> Bech32m (Taproot ob1p...)
//
// Output is byte-identical to core/bech32.zig — both implement the same
// BIP-173/350 polymod, charset, and bit-conversion.

pub const OB_HRP: &str = "ob";

const BECH32_CONST: u32 = 1;
const BECH32M_CONST: u32 = 0x2bc830a3;
const CHARSET: &[u8; 32] = b"qpzry9x8gf2tvdw0s3jn54khce6mua7l";
const GEN: [u32; 5] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Encoding {
    Bech32,
    Bech32m,
}

#[derive(Debug, thiserror::Error)]
pub enum Bech32Error {
    #[error("no separator '1' in bech32 string")] NoSeparator,
    #[error("bech32 string too short")] TooShort,
    #[error("bech32 string too long (>90 chars)")] TooLong,
    #[error("invalid bech32 character")] InvalidChar,
    #[error("invalid bech32 checksum")] InvalidChecksum,
    #[error("wrong bech32 variant for witness version")] WrongVariant,
    #[error("invalid HRP (expected '{0}')")] InvalidHrp(String),
    #[error("invalid witness version")] InvalidWitnessVersion,
    #[error("invalid witness program length")] InvalidWitnessLength,
    #[error("invalid v0 witness program length (must be 20 or 32)")] InvalidV0WitnessLength,
    #[error("non-zero padding in bit conversion")] NonZeroPadding,
    #[error("invalid bit conversion")] InvalidBitConversion,
}

fn polymod(values: &[u8]) -> u32 {
    let mut chk: u32 = 1;
    for &v in values {
        let b = chk >> 25;
        chk = ((chk & 0x1ffffff) << 5) ^ (v as u32);
        for i in 0..5 {
            if ((b >> i) & 1) != 0 {
                chk ^= GEN[i];
            }
        }
    }
    chk
}

fn hrp_expand(hrp: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(hrp.len() * 2 + 1);
    for &c in hrp { out.push(c >> 5); }
    out.push(0);
    for &c in hrp { out.push(c & 0x1f); }
    out
}

fn create_checksum(hrp: &[u8], data: &[u8], encoding: Encoding) -> [u8; 6] {
    let mut values = hrp_expand(hrp);
    values.extend_from_slice(data);
    values.extend_from_slice(&[0u8; 6]);
    let target = match encoding {
        Encoding::Bech32 => BECH32_CONST,
        Encoding::Bech32m => BECH32M_CONST,
    };
    let p = polymod(&values) ^ target;
    let mut out = [0u8; 6];
    for i in 0..6 {
        out[i] = ((p >> (5 * (5 - i))) & 31) as u8;
    }
    out
}

fn verify_checksum(hrp: &[u8], data: &[u8]) -> Option<Encoding> {
    let mut combined = hrp_expand(hrp);
    combined.extend_from_slice(data);
    let p = polymod(&combined);
    if p == BECH32_CONST { Some(Encoding::Bech32) }
    else if p == BECH32M_CONST { Some(Encoding::Bech32m) }
    else { None }
}

/// Encode 5-bit data + HRP to a bech32/bech32m string. `data` must contain
/// values in [0, 31].
pub fn encode(hrp: &str, data: &[u8], encoding: Encoding) -> String {
    let checksum = create_checksum(hrp.as_bytes(), data, encoding);
    let mut s = String::with_capacity(hrp.len() + 1 + data.len() + 6);
    for c in hrp.chars() { s.push(c.to_ascii_lowercase()); }
    s.push('1');
    for &d in data { s.push(CHARSET[d as usize] as char); }
    for &d in &checksum { s.push(CHARSET[d as usize] as char); }
    s
}

/// Decode a bech32/bech32m string. Returns (hrp, 5-bit data including checksum-stripped, encoding).
pub fn decode(input: &str) -> Result<(String, Vec<u8>, Encoding), Bech32Error> {
    if input.len() > 90 { return Err(Bech32Error::TooLong); }
    let bytes = input.as_bytes();
    // last '1'
    let pos = bytes.iter().rposition(|&c| c == b'1').ok_or(Bech32Error::NoSeparator)?;
    if pos < 1 || pos + 7 > bytes.len() { return Err(Bech32Error::TooShort); }

    let mut hrp = String::with_capacity(pos);
    for &c in &bytes[..pos] {
        hrp.push((c as char).to_ascii_lowercase());
    }

    let data_part = &bytes[pos + 1..];
    let mut data = Vec::with_capacity(data_part.len());
    for &c in data_part {
        let lower = if (b'A'..=b'Z').contains(&c) { c + 32 } else { c };
        if lower >= 128 { return Err(Bech32Error::InvalidChar); }
        let idx = CHARSET.iter().position(|&x| x == lower).ok_or(Bech32Error::InvalidChar)? as u8;
        data.push(idx);
    }

    let enc = verify_checksum(hrp.as_bytes(), &data).ok_or(Bech32Error::InvalidChecksum)?;
    data.truncate(data.len() - 6);
    Ok((hrp, data, enc))
}

/// 8-bit -> 5-bit conversion with optional padding (for encoding witness program).
pub fn convert_bits(data: &[u8], from_bits: u32, to_bits: u32, pad: bool) -> Result<Vec<u8>, Bech32Error> {
    let mut acc: u32 = 0;
    let mut bits: u32 = 0;
    let maxv: u32 = (1u32 << to_bits) - 1;
    let mut out = Vec::with_capacity((data.len() * from_bits as usize + to_bits as usize - 1) / to_bits as usize + 1);
    for &val in data {
        if (val as u32) >> from_bits != 0 { return Err(Bech32Error::InvalidBitConversion); }
        acc = (acc << from_bits) | (val as u32);
        bits += from_bits;
        while bits >= to_bits {
            bits -= to_bits;
            out.push(((acc >> bits) & maxv) as u8);
        }
    }
    if pad {
        if bits > 0 {
            out.push(((acc << (to_bits - bits)) & maxv) as u8);
        }
    } else if bits >= from_bits || ((acc << (to_bits - bits)) & maxv) != 0 {
        return Err(Bech32Error::NonZeroPadding);
    }
    Ok(out)
}

/// Encode a witness address (hrp + witness_version + 8-bit program bytes).
/// v0 -> Bech32, v1+ -> Bech32m.
pub fn encode_witness_address(hrp: &str, witness_version: u8, witness_program: &[u8]) -> Result<String, Bech32Error> {
    if witness_program.len() < 2 || witness_program.len() > 40 {
        return Err(Bech32Error::InvalidWitnessLength);
    }
    if witness_version == 0 && witness_program.len() != 20 && witness_program.len() != 32 {
        return Err(Bech32Error::InvalidV0WitnessLength);
    }
    if witness_version > 16 { return Err(Bech32Error::InvalidWitnessVersion); }

    let converted = convert_bits(witness_program, 8, 5, true)?;
    let mut data = Vec::with_capacity(1 + converted.len());
    data.push(witness_version);
    data.extend_from_slice(&converted);

    let encoding = if witness_version == 0 { Encoding::Bech32 } else { Encoding::Bech32m };
    Ok(encode(hrp, &data, encoding))
}

#[derive(Debug, Clone)]
pub struct WitnessResult {
    pub version: u8,
    pub program: Vec<u8>,
}

pub fn decode_witness_address(expected_hrp: &str, addr: &str) -> Result<WitnessResult, Bech32Error> {
    let (hrp, data, enc) = decode(addr)?;
    if hrp != expected_hrp { return Err(Bech32Error::InvalidHrp(expected_hrp.to_string())); }
    if data.is_empty() { return Err(Bech32Error::InvalidWitnessLength); }
    let version = data[0];
    if version > 16 { return Err(Bech32Error::InvalidWitnessVersion); }
    let expected_enc = if version == 0 { Encoding::Bech32 } else { Encoding::Bech32m };
    if enc != expected_enc { return Err(Bech32Error::WrongVariant); }

    let program = convert_bits(&data[1..], 5, 8, false)?;
    if program.len() < 2 || program.len() > 40 { return Err(Bech32Error::InvalidWitnessLength); }
    if version == 0 && program.len() != 20 && program.len() != 32 {
        return Err(Bech32Error::InvalidV0WitnessLength);
    }
    Ok(WitnessResult { version, program })
}

/// Encode an OmniBus P2WPKH address: ob1q... (HRP="ob", v0, 20-byte hash160).
pub fn encode_ob_address(hash160: &[u8; 20]) -> String {
    // unwrap: 20-byte program, v0 -> always valid
    encode_witness_address(OB_HRP, 0, hash160).expect("ob P2WPKH encode")
}

/// Encode an OmniBus Taproot address: ob1p... (HRP="ob", v1, 32-byte x-only pubkey).
pub fn encode_ob_taproot_address(pubkey_x: &[u8; 32]) -> String {
    encode_witness_address(OB_HRP, 1, pubkey_x).expect("ob taproot encode")
}

pub fn decode_ob_address(addr: &str) -> Result<WitnessResult, Bech32Error> {
    decode_witness_address(OB_HRP, addr)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Vector mirrors core/bech32.zig "Bech32 — encode and decode roundtrip (witness v0, P2WPKH)"
    // hash160 = 751e76e819919...3bd6 -> "ob1q..." starts.
    #[test]
    fn ob1q_roundtrip() {
        let hash160: [u8; 20] = [
            0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4, 0x54, 0x94,
            0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23, 0xf1, 0x43, 0x3b, 0xd6,
        ];
        let addr = encode_ob_address(&hash160);
        assert!(addr.starts_with("ob1q"), "got {addr}");
        let decoded = decode_ob_address(&addr).unwrap();
        assert_eq!(decoded.version, 0);
        assert_eq!(decoded.program, hash160.to_vec());
    }

    #[test]
    fn taproot_roundtrip() {
        let mut pk = [0u8; 32];
        for (i, b) in pk.iter_mut().enumerate() { *b = (i as u8).wrapping_add(1); }
        let addr = encode_ob_taproot_address(&pk);
        assert!(addr.starts_with("ob1p"), "got {addr}");
        let decoded = decode_ob_address(&addr).unwrap();
        assert_eq!(decoded.version, 1);
        assert_eq!(decoded.program, pk.to_vec());
    }

    #[test]
    fn rejects_corrupt_checksum() {
        let h: [u8; 20] = [0xaa; 20];
        let addr = encode_ob_address(&h);
        let mut bad: Vec<u8> = addr.into_bytes();
        let last = bad.len() - 1;
        bad[last] = if bad[last] == b'q' { b'p' } else { b'q' };
        let s = String::from_utf8(bad).unwrap();
        assert!(decode_ob_address(&s).is_err());
    }
}
