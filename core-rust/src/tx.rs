// Transaction parsing + ECDSA sender recovery.
// Supports EIP-1559 (type 0x02) and legacy (type 0x00 / no prefix) txs.
// Modern wallets (MetaMask post-2022, Hardhat) default to 1559.

use sha3::{Digest, Keccak256};
use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};
use rlp::{Rlp, RlpStream};

#[derive(Debug, Clone)]
pub struct TxParsed {
    pub kind: TxKind,
    pub chain_id: u64,
    pub nonce: u64,
    pub gas_limit: u64,
    pub to: Option<[u8; 20]>,
    pub value: u128,
    pub data: Vec<u8>,
    pub from: [u8; 20],
    pub hash: [u8; 32],
}

#[derive(Debug, Clone, Copy)]
pub enum TxKind { Legacy, Eip1559 }

pub fn parse_raw(raw: &[u8]) -> Result<TxParsed, String> {
    if raw.is_empty() { return Err("empty raw tx".into()); }
    let hash = keccak256(raw);
    if raw[0] == 0x02 { parse_eip1559(raw, hash) }
    else if raw[0] == 0x01 { Err("EIP-2930 (type 1) not supported".into()) }
    else if raw[0] >= 0xc0 { parse_legacy(raw, hash) }
    else { Err(format!("unknown tx type prefix: 0x{:02x}", raw[0])) }
}

fn parse_eip1559(raw: &[u8], hash: [u8; 32]) -> Result<TxParsed, String> {
    let rlp = Rlp::new(&raw[1..]);
    if !rlp.is_list() { return Err("eip1559 payload not a list".into()); }

    let chain_id: u64 = rlp.val_at(0).map_err(|e| format!("chainId: {e}"))?;
    let nonce: u64 = rlp.val_at(1).map_err(|e| format!("nonce: {e}"))?;
    let max_prio: u128 = rlp_u128(&rlp, 2)?;
    let max_fee: u128 = rlp_u128(&rlp, 3)?;
    let gas_limit: u64 = rlp.val_at(4).map_err(|e| format!("gasLimit: {e}"))?;
    let to_bytes: Vec<u8> = rlp.val_at(5).map_err(|e| format!("to: {e}"))?;
    let to = if to_bytes.is_empty() { None } else {
        if to_bytes.len() != 20 { return Err("to must be 20 bytes".into()); }
        let mut a = [0u8; 20]; a.copy_from_slice(&to_bytes); Some(a)
    };
    let value: u128 = rlp_u128(&rlp, 6)?;
    let data: Vec<u8> = rlp.val_at(7).map_err(|e| format!("data: {e}"))?;
    let y_parity: u8 = rlp.val_at(9).map_err(|e| format!("yParity: {e}"))?;
    let r: Vec<u8> = rlp.val_at(10).map_err(|e| format!("r: {e}"))?;
    let s: Vec<u8> = rlp.val_at(11).map_err(|e| format!("s: {e}"))?;

    let mut signing = RlpStream::new_list(9);
    signing.append(&chain_id);
    signing.append(&nonce);
    signing.append(&max_prio);
    signing.append(&max_fee);
    signing.append(&gas_limit);
    match to {
        Some(a) => { signing.append(&a.as_slice()); }
        None    => { signing.append_empty_data(); }
    };
    signing.append(&value);
    signing.append(&data);
    signing.begin_list(0);

    let mut signing_payload = Vec::with_capacity(signing.as_raw().len() + 1);
    signing_payload.push(0x02);
    signing_payload.extend_from_slice(&signing.out());
    let sig_hash = keccak256(&signing_payload);

    let from = recover_sender(&sig_hash, &r, &s, y_parity)?;

    Ok(TxParsed { kind: TxKind::Eip1559, chain_id, nonce, gas_limit, to, value, data, from, hash })
}

fn parse_legacy(raw: &[u8], hash: [u8; 32]) -> Result<TxParsed, String> {
    let rlp = Rlp::new(raw);
    let nonce: u64 = rlp.val_at(0).map_err(|e| format!("nonce: {e}"))?;
    let gas_price: u128 = rlp_u128(&rlp, 1)?;
    let gas_limit: u64 = rlp.val_at(2).map_err(|e| format!("gasLimit: {e}"))?;
    let to_bytes: Vec<u8> = rlp.val_at(3).map_err(|e| format!("to: {e}"))?;
    let to = if to_bytes.is_empty() { None } else {
        if to_bytes.len() != 20 { return Err("to must be 20 bytes".into()); }
        let mut a = [0u8; 20]; a.copy_from_slice(&to_bytes); Some(a)
    };
    let value: u128 = rlp_u128(&rlp, 4)?;
    let data: Vec<u8> = rlp.val_at(5).map_err(|e| format!("data: {e}"))?;
    let v: u64 = rlp.val_at(6).map_err(|e| format!("v: {e}"))?;
    let r: Vec<u8> = rlp.val_at(7).map_err(|e| format!("r: {e}"))?;
    let s: Vec<u8> = rlp.val_at(8).map_err(|e| format!("s: {e}"))?;

    let (chain_id, y_parity) = if v >= 35 {
        ((v - 35) / 2, ((v - 35) % 2) as u8)
    } else {
        (0u64, if v == 27 { 0 } else { 1 })
    };

    let mut signing = RlpStream::new();
    if chain_id > 0 {
        signing.begin_list(9);
    } else {
        signing.begin_list(6);
    }
    signing.append(&nonce);
    signing.append(&gas_price);
    signing.append(&gas_limit);
    match to {
        Some(a) => { signing.append(&a.as_slice()); }
        None    => { signing.append_empty_data(); }
    };
    signing.append(&value);
    signing.append(&data);
    if chain_id > 0 {
        signing.append(&chain_id);
        signing.append(&0u8);
        signing.append(&0u8);
    }
    let sig_hash = keccak256(&signing.out());
    let from = recover_sender(&sig_hash, &r, &s, y_parity)?;

    Ok(TxParsed { kind: TxKind::Legacy, chain_id, nonce, gas_limit, to, value, data, from, hash })
}

fn rlp_u128(rlp: &Rlp, idx: usize) -> Result<u128, String> {
    let bytes: Vec<u8> = rlp.val_at(idx).map_err(|e| format!("idx {idx}: {e}"))?;
    if bytes.len() > 16 { return Err(format!("u128 overflow at idx {idx}")); }
    let mut padded = [0u8; 16];
    padded[16 - bytes.len()..].copy_from_slice(&bytes);
    Ok(u128::from_be_bytes(padded))
}

fn recover_sender(sig_hash: &[u8; 32], r: &[u8], s: &[u8], y_parity: u8) -> Result<[u8; 20], String> {
    let mut sig_bytes = [0u8; 64];
    if r.len() > 32 || s.len() > 32 { return Err("sig r/s too long".into()); }
    sig_bytes[32 - r.len()..32].copy_from_slice(r);
    sig_bytes[64 - s.len()..64].copy_from_slice(s);

    let sig = Signature::from_slice(&sig_bytes).map_err(|e| format!("bad sig: {e}"))?;
    let rec_id = RecoveryId::from_byte(y_parity).ok_or("bad recovery id")?;
    let vk = VerifyingKey::recover_from_prehash(sig_hash, &sig, rec_id)
        .map_err(|e| format!("recover failed: {e}"))?;
    let pubkey = vk.to_encoded_point(false);
    let pubkey_bytes = pubkey.as_bytes();
    if pubkey_bytes.len() != 65 || pubkey_bytes[0] != 0x04 {
        return Err("bad uncompressed pubkey".into());
    }
    let hash = keccak256(&pubkey_bytes[1..65]);
    let mut addr = [0u8; 20];
    addr.copy_from_slice(&hash[12..32]);
    Ok(addr)
}

pub fn keccak256(data: &[u8]) -> [u8; 32] {
    let mut hasher = Keccak256::new();
    hasher.update(data);
    let out = hasher.finalize();
    let mut h = [0u8; 32];
    h.copy_from_slice(&out);
    h
}
