// Persistent event logs. Keyed by tx_hash. Plus a per-block index used by
// eth_getLogs to filter without scanning every tx.
//
// Encoding (custom, compact, BE):
//   u32 count
//   for each log:
//     20  address
//     u32 block
//     32  tx_hash
//     u8  topic_count        (0..=4)
//     32*topic_count topics
//     u32 data_len
//     data_len data bytes
//
// We re-derive a bloom-style index per block by serialising the list of unique
// (address, topic0) pairs encountered in that block. eth_getLogs scans this
// index to skip irrelevant blocks before opening the per-tx log blob.

use sled::Tree;

use crate::state::EvmState;

#[derive(Debug, Clone)]
pub struct Log {
    pub address: [u8; 20],
    pub topics: Vec<[u8; 32]>,
    pub data: Vec<u8>,
    pub block: u64,
    pub tx_hash: [u8; 32],
}

pub fn encode_logs(logs: &[Log]) -> Vec<u8> {
    let mut out = Vec::with_capacity(64 + logs.len() * 96);
    out.extend_from_slice(&(logs.len() as u32).to_be_bytes());
    for l in logs {
        out.extend_from_slice(&l.address);
        out.extend_from_slice(&(l.block as u32).to_be_bytes());
        out.extend_from_slice(&l.tx_hash);
        let tc = l.topics.len().min(4) as u8;
        out.push(tc);
        for t in l.topics.iter().take(4) { out.extend_from_slice(t); }
        out.extend_from_slice(&(l.data.len() as u32).to_be_bytes());
        out.extend_from_slice(&l.data);
    }
    out
}

pub fn decode_logs(bytes: &[u8]) -> Vec<Log> {
    let mut out = Vec::new();
    if bytes.len() < 4 { return out; }
    let count = u32::from_be_bytes(bytes[0..4].try_into().unwrap()) as usize;
    let mut o = 4usize;
    for _ in 0..count {
        if o + 20 + 4 + 32 + 1 > bytes.len() { break; }
        let mut address = [0u8; 20]; address.copy_from_slice(&bytes[o..o+20]); o += 20;
        let block = u32::from_be_bytes(bytes[o..o+4].try_into().unwrap()) as u64; o += 4;
        let mut tx_hash = [0u8; 32]; tx_hash.copy_from_slice(&bytes[o..o+32]); o += 32;
        let tc = bytes[o] as usize; o += 1;
        if o + tc*32 + 4 > bytes.len() { break; }
        let mut topics = Vec::with_capacity(tc);
        for _ in 0..tc {
            let mut t = [0u8; 32]; t.copy_from_slice(&bytes[o..o+32]); o += 32;
            topics.push(t);
        }
        let dl = u32::from_be_bytes(bytes[o..o+4].try_into().unwrap()) as usize; o += 4;
        if o + dl > bytes.len() { break; }
        let data = bytes[o..o+dl].to_vec(); o += dl;
        out.push(Log { address, topics, data, block, tx_hash });
    }
    out
}

pub fn write_logs(state: &EvmState, tx_hash: &[u8; 32], logs: &[Log]) -> Result<(), String> {
    if logs.is_empty() { return Ok(()); }
    let enc = encode_logs(logs);
    state.evm_logs.insert(tx_hash, enc).map_err(|e| format!("logs insert: {e}"))?;

    // Index per block: append (address || topic0) entries for fast getLogs filtering.
    if let Some(first) = logs.first() {
        let block = first.block;
        let key = format!("idx:{:020}", block);
        let mut acc: Vec<u8> = state.evm_logs.get(key.as_bytes()).ok().flatten()
            .map(|v| v.to_vec()).unwrap_or_default();
        for l in logs {
            acc.extend_from_slice(&l.address);
            if let Some(t0) = l.topics.first() { acc.extend_from_slice(t0); }
            else { acc.extend_from_slice(&[0u8; 32]); }
        }
        state.evm_logs.insert(key.as_bytes(), acc)
            .map_err(|e| format!("logs index insert: {e}"))?;
    }
    Ok(())
}

pub fn read_logs(state: &EvmState, tx_hash: &[u8; 32]) -> Vec<Log> {
    match state.evm_logs.get(tx_hash).ok().flatten() {
        Some(v) => decode_logs(&v),
        None => Vec::new(),
    }
}

/// Iterate block log indexes for blocks in [from, to] inclusive.
/// Each yielded entry is the raw (addr || topic0) pairs blob; caller scans it.
pub fn block_index_blob(logs_tree: &Tree, block: u64) -> Option<Vec<u8>> {
    let key = format!("idx:{:020}", block);
    logs_tree.get(key.as_bytes()).ok().flatten().map(|v| v.to_vec())
}

/// Walk all logs for a block range and filter by optional address + topics.
/// This is the workhorse for eth_getLogs.
pub fn query_logs(
    state: &EvmState,
    from_block: u64,
    to_block: u64,
    address_filter: Option<[u8; 20]>,
    topics_filter: &[Option<[u8; 32]>],
) -> Vec<Log> {
    let mut out = Vec::new();
    // We don't currently store a block→tx_hash index for logs, so iterate the
    // whole evm_logs tree skipping the "idx:" prefix entries. For typical
    // OmniBus loads (small dev chains) this is fast enough; a future Bloom
    // filter index can replace this scan.
    for entry in state.evm_logs.iter() {
        let (k, v) = match entry { Ok(kv) => kv, Err(_) => continue };
        if k.starts_with(b"idx:") { continue; }
        if k.len() != 32 { continue; }
        let logs = decode_logs(&v);
        for l in logs {
            if l.block < from_block || l.block > to_block { continue; }
            if let Some(a) = address_filter {
                if l.address != a { continue; }
            }
            let mut topic_ok = true;
            for (i, filt) in topics_filter.iter().enumerate() {
                if let Some(want) = filt {
                    match l.topics.get(i) {
                        Some(have) if have == want => {}
                        _ => { topic_ok = false; break; }
                    }
                }
            }
            if !topic_ok { continue; }
            out.push(l);
        }
    }
    out
}
