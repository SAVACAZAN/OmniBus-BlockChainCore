//! Distributed consensus-layer price oracle.
//!
//! Mirrors `core/price_oracle.zig::DistributedPriceOracle`. Miners submit
//! price votes per (pair, block); at block production the chain tallies
//! votes from the recent window, computes the median, derives a TWAP over
//! a longer window, and Merkle-commits the per-pair observations into
//! `Block::prices_root`.
//!
//! Storage layout (sled):
//!   * `oracle/votes`        — key = pair_id_be (8) || block_be (8) ||
//!                              miner (20)              → bincoded `PriceVote`
//!   * `oracle/observations` — key = pair_id_be (8) || block_be (8)
//!                                                     → bincoded `PriceObservation`
//!   * `oracle/outliers`     — key = miner (20)        → u32 BE consecutive
//!                                                       outlier count
//!
//! Anti-manipulation:
//!   * vote sig must verify (secp256k1, ECDSA, prehash = sha256 of canonical
//!     vote bytes)
//!   * miner must currently be in `ValidatorSet::get_active_set()` AND have
//!     `uptime_pct() >= 90`
//!   * within tally window, votes more than 2σ off the median are dropped
//!     and the submitter's outlier counter is bumped
//!   * 3+ consecutive outliers → vote rejected at submit time
//!   * observation only emitted if ≥ MIN_VOTERS distinct voters cleared.

use serde::{Deserialize, Serialize};
use serde_big_array::BigArray;
use sha2::{Digest, Sha256};
use sled::{Db, Tree};
use std::sync::Arc;
use thiserror::Error;

use crate::validator::set::ValidatorSet;

pub const VOTE_WINDOW_BLOCKS: u64 = 10;
pub const DEFAULT_TWAP_WINDOW_BLOCKS: u64 = 60;
pub const MIN_VOTERS: u32 = 5;
pub const MIN_UPTIME_PCT_FOR_VOTE: u8 = 90;
pub const OUTLIER_STRIKES_MAX: u32 = 3;

#[derive(Debug, Error)]
pub enum OracleConsensusError {
    #[error("sled error: {0}")]
    Sled(#[from] sled::Error),
    #[error("serde error: {0}")]
    Serde(#[from] serde_json::Error),
    #[error("bad signature")]
    BadSignature,
    #[error("voter not eligible (not validator or low uptime)")]
    NotEligible,
    #[error("voter has too many recent outlier strikes")]
    Banned,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PriceVote {
    pub miner_addr: [u8; 20],
    pub pair_id: u64,
    /// Price in SAT per unit (u128 to support tiny micros + huge tokens).
    pub price_sat: u128,
    /// Unix seconds.
    pub timestamp: i64,
    /// Block at which this vote is valid (gets binned into that block's
    /// tally window).
    pub block: u64,
    /// 65-byte secp256k1 recoverable signature over `canonical_bytes()`.
    #[serde(with = "BigArray")]
    pub signature: [u8; 65],
}

impl PriceVote {
    /// Canonical encoding for signing: pair_id || price || timestamp || block.
    /// All big-endian. (No miner_addr — sig recovery yields it.)
    pub fn canonical_bytes(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(8 + 16 + 8 + 8);
        v.extend_from_slice(&self.pair_id.to_be_bytes());
        v.extend_from_slice(&self.price_sat.to_be_bytes());
        v.extend_from_slice(&self.timestamp.to_be_bytes());
        v.extend_from_slice(&self.block.to_be_bytes());
        v
    }

    pub fn signing_hash(&self) -> [u8; 32] {
        let mut h = Sha256::new();
        h.update(&self.canonical_bytes());
        let mut out = [0u8; 32];
        out.copy_from_slice(&h.finalize());
        out
    }

    /// ECDSA-recover the 20-byte address (last 20 of keccak-style here we
    /// use sha256-of-pubkey for parity with the rest of native chain; the
    /// signer must match `miner_addr`).
    pub fn verify(&self) -> Result<(), OracleConsensusError> {
        use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};
        if self.signature.len() != 65 { return Err(OracleConsensusError::BadSignature); }
        let r = &self.signature[0..32];
        let s = &self.signature[32..64];
        let v = self.signature[64];
        let mut sig_bytes = [0u8; 64];
        sig_bytes[0..32].copy_from_slice(r);
        sig_bytes[32..64].copy_from_slice(s);
        let sig = Signature::from_slice(&sig_bytes).map_err(|_| OracleConsensusError::BadSignature)?;
        let y_parity = if v >= 27 { v - 27 } else { v };
        let rec_id = RecoveryId::from_byte(y_parity).ok_or(OracleConsensusError::BadSignature)?;
        let prehash = self.signing_hash();
        let vk = VerifyingKey::recover_from_prehash(&prehash, &sig, rec_id)
            .map_err(|_| OracleConsensusError::BadSignature)?;
        let enc = vk.to_encoded_point(false);
        let bytes = enc.as_bytes();
        if bytes.len() != 65 || bytes[0] != 0x04 {
            return Err(OracleConsensusError::BadSignature);
        }
        // SHA-256 over uncompressed pubkey body, take last 20 bytes.
        let mut h = Sha256::new();
        h.update(&bytes[1..65]);
        let digest = h.finalize();
        let mut addr = [0u8; 20];
        addr.copy_from_slice(&digest[12..32]);
        if addr != self.miner_addr {
            return Err(OracleConsensusError::BadSignature);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct PriceObservation {
    pub pair_id: u64,
    pub block: u64,
    pub median_price: u128,
    pub twap_price: u128,
    pub n_voters: u32,
}

/// Distributed price oracle anchored in sled. Cloning is cheap — sled
/// trees are themselves Arc'd internally.
#[derive(Clone)]
pub struct DistributedOracle {
    _db: Arc<Db>,
    votes_tree: Tree,
    observations_tree: Tree,
    outliers_tree: Tree,
    pub twap_window_blocks: u64,
}

impl DistributedOracle {
    pub fn open(db: Arc<Db>) -> Result<Self, OracleConsensusError> {
        let votes_tree = db.open_tree("oracle/votes")?;
        let observations_tree = db.open_tree("oracle/observations")?;
        let outliers_tree = db.open_tree("oracle/outliers")?;
        Ok(Self {
            _db: db,
            votes_tree,
            observations_tree,
            outliers_tree,
            twap_window_blocks: DEFAULT_TWAP_WINDOW_BLOCKS,
        })
    }

    fn vote_key(pair_id: u64, block: u64, miner: &[u8; 20]) -> [u8; 36] {
        let mut k = [0u8; 36];
        k[0..8].copy_from_slice(&pair_id.to_be_bytes());
        k[8..16].copy_from_slice(&block.to_be_bytes());
        k[16..36].copy_from_slice(miner);
        k
    }
    fn obs_key(pair_id: u64, block: u64) -> [u8; 16] {
        let mut k = [0u8; 16];
        k[0..8].copy_from_slice(&pair_id.to_be_bytes());
        k[8..16].copy_from_slice(&block.to_be_bytes());
        k
    }

    /// Validate + persist a single miner vote.
    pub fn submit_vote(
        &self,
        vote: PriceVote,
        validators: &ValidatorSet,
    ) -> Result<(), OracleConsensusError> {
        vote.verify()?;
        // Validator eligibility — must be active + uptime ≥ threshold.
        let mut addr32 = [0u8; 32];
        addr32[12..32].copy_from_slice(&vote.miner_addr);
        match validators.get(&addr32) {
            Ok(Some(rec)) => {
                use crate::validator::set::ValidatorStatus;
                if rec.status != ValidatorStatus::Active
                    || rec.uptime_pct() < MIN_UPTIME_PCT_FOR_VOTE
                {
                    return Err(OracleConsensusError::NotEligible);
                }
            }
            _ => return Err(OracleConsensusError::NotEligible),
        }
        if self.outlier_strikes(&vote.miner_addr)? >= OUTLIER_STRIKES_MAX {
            return Err(OracleConsensusError::Banned);
        }

        let bytes = serde_json::to_vec(&vote)?;
        self.votes_tree
            .insert(Self::vote_key(vote.pair_id, vote.block, &vote.miner_addr), bytes)?;
        Ok(())
    }

    fn outlier_strikes(&self, miner: &[u8; 20]) -> Result<u32, OracleConsensusError> {
        match self.outliers_tree.get(miner)? {
            Some(b) if b.len() == 4 => {
                let mut a = [0u8; 4];
                a.copy_from_slice(&b);
                Ok(u32::from_be_bytes(a))
            }
            _ => Ok(0),
        }
    }

    fn bump_outlier(&self, miner: &[u8; 20]) -> Result<(), OracleConsensusError> {
        let cur = self.outlier_strikes(miner)?;
        let new = cur.saturating_add(1);
        self.outliers_tree.insert(miner, &new.to_be_bytes())?;
        Ok(())
    }

    fn clear_outlier(&self, miner: &[u8; 20]) -> Result<(), OracleConsensusError> {
        self.outliers_tree.insert(miner, &0u32.to_be_bytes())?;
        Ok(())
    }

    /// Tally votes for every pair that has at least one vote in
    /// `[block - VOTE_WINDOW_BLOCKS, block]`. Returns one observation per
    /// pair where ≥ MIN_VOTERS distinct voters cleared the outlier filter.
    pub fn tally_at_block(&self, block: u64) -> Result<Vec<PriceObservation>, OracleConsensusError> {
        let lo = block.saturating_sub(VOTE_WINDOW_BLOCKS);

        // Group votes by pair_id.
        let mut by_pair: std::collections::BTreeMap<u64, Vec<PriceVote>> =
            std::collections::BTreeMap::new();
        for kv in self.votes_tree.iter() {
            let (k, v) = kv?;
            if k.len() != 36 { continue; }
            let mut pair_be = [0u8; 8];
            pair_be.copy_from_slice(&k[0..8]);
            let pair_id = u64::from_be_bytes(pair_be);
            let mut blk_be = [0u8; 8];
            blk_be.copy_from_slice(&k[8..16]);
            let blk = u64::from_be_bytes(blk_be);
            if blk < lo || blk > block { continue; }
            let vote: PriceVote = serde_json::from_slice(&v)?;
            by_pair.entry(pair_id).or_default().push(vote);
        }

        let mut out = Vec::new();
        for (pair_id, votes) in by_pair {
            // Compute provisional median across raw prices.
            let mut prices: Vec<u128> = votes.iter().map(|v| v.price_sat).collect();
            if prices.is_empty() { continue; }
            prices.sort_unstable();
            let prov_median = median_u128(&prices);
            // 2σ filter (variance computed in u128 → f64 only for sqrt).
            let mean: f64 = prices.iter().map(|&p| p as f64).sum::<f64>() / prices.len() as f64;
            let var: f64 = prices.iter().map(|&p| {
                let d = p as f64 - mean; d * d
            }).sum::<f64>() / prices.len() as f64;
            let sigma = var.sqrt();
            let lo_bound = (mean - 2.0 * sigma).max(0.0);
            let hi_bound = mean + 2.0 * sigma;

            let mut filtered: Vec<u128> = Vec::new();
            let mut voters: std::collections::BTreeSet<[u8; 20]> = std::collections::BTreeSet::new();
            for v in &votes {
                let pf = v.price_sat as f64;
                let dist_from_median = if v.price_sat > prov_median {
                    v.price_sat - prov_median
                } else {
                    prov_median - v.price_sat
                };
                // sigma==0 edge: only the exact median counts.
                let in_range = if sigma == 0.0 {
                    dist_from_median == 0
                } else {
                    pf >= lo_bound && pf <= hi_bound
                };
                if in_range {
                    filtered.push(v.price_sat);
                    voters.insert(v.miner_addr);
                    let _ = self.clear_outlier(&v.miner_addr);
                } else {
                    let _ = self.bump_outlier(&v.miner_addr);
                }
            }
            if (voters.len() as u32) < MIN_VOTERS { continue; }
            filtered.sort_unstable();
            let median_price = median_u128(&filtered);
            let twap_price = self.compute_twap(pair_id, block, median_price)?;

            let obs = PriceObservation {
                pair_id, block, median_price, twap_price,
                n_voters: voters.len() as u32,
            };
            let bytes = serde_json::to_vec(&obs)?;
            self.observations_tree.insert(Self::obs_key(pair_id, block), bytes)?;
            out.push(obs);
        }

        Ok(out)
    }

    fn compute_twap(
        &self,
        pair_id: u64,
        block: u64,
        latest_price: u128,
    ) -> Result<u128, OracleConsensusError> {
        let lo = block.saturating_sub(self.twap_window_blocks);
        let mut seq: Vec<(u64, u128)> = Vec::new();
        // Walk all observations for this pair within window.
        for kv in self.observations_tree.iter() {
            let (k, v) = kv?;
            if k.len() != 16 { continue; }
            let mut pair_be = [0u8; 8];
            pair_be.copy_from_slice(&k[0..8]);
            if u64::from_be_bytes(pair_be) != pair_id { continue; }
            let mut blk_be = [0u8; 8];
            blk_be.copy_from_slice(&k[8..16]);
            let b = u64::from_be_bytes(blk_be);
            if b < lo || b >= block { continue; }
            let obs: PriceObservation = serde_json::from_slice(&v)?;
            seq.push((b, obs.median_price));
        }
        seq.push((block, latest_price));
        seq.sort_by_key(|x| x.0);

        if seq.len() <= 1 {
            return Ok(latest_price);
        }
        // Δt weight per observation; simple time-weighted mean.
        let mut weighted: u128 = 0;
        let mut total_dt: u128 = 0;
        for win in seq.windows(2) {
            let (b1, p1) = win[0];
            let (b2, _p2) = win[1];
            let dt = (b2 - b1) as u128;
            weighted = weighted.saturating_add(p1.saturating_mul(dt));
            total_dt = total_dt.saturating_add(dt);
        }
        if total_dt == 0 { return Ok(latest_price); }
        Ok(weighted / total_dt)
    }

    /// Latest persisted observation for `pair_id` (highest block).
    pub fn current_price(&self, pair_id: u64) -> Option<u128> {
        let mut best: Option<(u64, u128)> = None;
        for kv in self.observations_tree.iter() {
            let (k, v) = kv.ok()?;
            if k.len() != 16 { continue; }
            let mut pb = [0u8; 8]; pb.copy_from_slice(&k[0..8]);
            if u64::from_be_bytes(pb) != pair_id { continue; }
            let mut bb = [0u8; 8]; bb.copy_from_slice(&k[8..16]);
            let blk = u64::from_be_bytes(bb);
            let obs: PriceObservation = serde_json::from_slice(&v).ok()?;
            if best.map(|(h, _)| blk > h).unwrap_or(true) {
                best = Some((blk, obs.twap_price));
            }
        }
        best.map(|(_, p)| p)
    }

    /// Historical observations for a pair in [from_block, to_block].
    pub fn history(
        &self,
        pair_id: u64,
        from_block: u64,
        to_block: u64,
    ) -> Result<Vec<PriceObservation>, OracleConsensusError> {
        let mut out = Vec::new();
        for kv in self.observations_tree.iter() {
            let (k, v) = kv?;
            if k.len() != 16 { continue; }
            let mut pb = [0u8; 8]; pb.copy_from_slice(&k[0..8]);
            if u64::from_be_bytes(pb) != pair_id { continue; }
            let mut bb = [0u8; 8]; bb.copy_from_slice(&k[8..16]);
            let b = u64::from_be_bytes(bb);
            if b < from_block || b > to_block { continue; }
            let obs: PriceObservation = serde_json::from_slice(&v)?;
            out.push(obs);
        }
        out.sort_by_key(|o| o.block);
        Ok(out)
    }
}

/// Median over a SORTED u128 slice. For even-length slices we return the
/// arithmetic mean of the two middle elements (integer division).
pub fn median_u128(sorted: &[u128]) -> u128 {
    if sorted.is_empty() { return 0; }
    let n = sorted.len();
    if n % 2 == 1 {
        sorted[n / 2]
    } else {
        let a = sorted[n / 2 - 1];
        let b = sorted[n / 2];
        // average without overflow: (a/2 + b/2 + (a%2 + b%2)/2)
        (a / 2) + (b / 2) + ((a & 1) + (b & 1)) / 2
    }
}

/// Merkle root over observations sorted by `pair_id`. Each leaf hash =
/// sha256(pair_id_be(8) || block_be(8) || median_be(16) || twap_be(16)
/// || n_voters_be(4)). Odd-count layers duplicate-last, matching Bitcoin.
pub fn merkle_root(observations: &[PriceObservation]) -> [u8; 32] {
    if observations.is_empty() { return [0u8; 32]; }
    let mut layer: Vec<[u8; 32]> = {
        let mut sorted = observations.to_vec();
        sorted.sort_by_key(|o| o.pair_id);
        sorted.iter().map(|o| leaf_hash(o)).collect()
    };
    while layer.len() > 1 {
        let next_count = (layer.len() + 1) / 2;
        let mut next = Vec::with_capacity(next_count);
        for i in 0..next_count {
            let l = i * 2;
            let r = if l + 1 < layer.len() { l + 1 } else { l };
            let mut h = Sha256::new();
            h.update(&layer[l]);
            h.update(&layer[r]);
            let mut out = [0u8; 32];
            out.copy_from_slice(&h.finalize());
            next.push(out);
        }
        layer = next;
    }
    layer[0]
}

fn leaf_hash(o: &PriceObservation) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(&o.pair_id.to_be_bytes());
    h.update(&o.block.to_be_bytes());
    h.update(&o.median_price.to_be_bytes());
    h.update(&o.twap_price.to_be_bytes());
    h.update(&o.n_voters.to_be_bytes());
    let mut out = [0u8; 32];
    out.copy_from_slice(&h.finalize());
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use k256::ecdsa::{SigningKey, signature::hazmat::PrehashSigner};
    use k256::ecdsa::{Signature, RecoveryId};

    #[test]
    fn median_odd() {
        let mut v = vec![100u128, 200, 300, 400, 500];
        v.sort();
        assert_eq!(median_u128(&v), 300);
    }

    #[test]
    fn median_even() {
        let mut v = vec![100u128, 200, 300, 400];
        v.sort();
        assert_eq!(median_u128(&v), 250);
    }

    #[test]
    fn twap_equal_time_equals_mean() {
        let db = Arc::new(sled::Config::new().temporary(true).open().unwrap());
        let oracle = DistributedOracle::open(db.clone()).unwrap();
        // Manually seed 5 observations at blocks 1..=5 with equal spacing.
        for (i, p) in [100u128, 200, 300, 400, 500].iter().enumerate() {
            let b = (i as u64) + 1;
            let obs = PriceObservation { pair_id: 0, block: b, median_price: *p, twap_price: *p, n_voters: 5 };
            let bytes = serde_json::to_vec(&obs).unwrap();
            oracle.observations_tree.insert(DistributedOracle::obs_key(0, b), bytes).unwrap();
        }
        // Compute TWAP at block 6 with the 5 prior obs in window.
        let twap = oracle.compute_twap(0, 6, 500).unwrap();
        // Δt = 1 between each → weighted mean of [100,200,300,400,500] = 300.
        assert_eq!(twap, 300);
    }

    #[test]
    fn merkle_root_stable_for_one_obs() {
        let obs = PriceObservation { pair_id: 0, block: 1, median_price: 100, twap_price: 100, n_voters: 5 };
        let r1 = merkle_root(&[obs]);
        let r2 = merkle_root(&[obs]);
        assert_eq!(r1, r2);
        assert_ne!(r1, [0u8; 32]);
    }

    /// Build a recoverable signature so `verify()` succeeds.
    fn sign_vote(sk: &SigningKey, mut vote: PriceVote) -> PriceVote {
        let prehash = vote.signing_hash();
        let (sig, rec_id): (Signature, RecoveryId) =
            sk.sign_prehash_recoverable(&prehash).unwrap();
        let bytes = sig.to_bytes();
        vote.signature[0..32].copy_from_slice(&bytes[0..32]);
        vote.signature[32..64].copy_from_slice(&bytes[32..64]);
        vote.signature[64] = rec_id.to_byte();
        vote
    }

    fn addr_from_sk(sk: &SigningKey) -> [u8; 20] {
        let vk = sk.verifying_key();
        let enc = vk.to_encoded_point(false);
        let bytes = enc.as_bytes();
        let mut h = Sha256::new();
        h.update(&bytes[1..65]);
        let d = h.finalize();
        let mut a = [0u8; 20]; a.copy_from_slice(&d[12..32]); a
    }

    #[test]
    fn signature_verifies_and_tampered_rejected() {
        let sk = SigningKey::random(&mut rand::thread_rng());
        let addr = addr_from_sk(&sk);
        let v = PriceVote {
            miner_addr: addr, pair_id: 0, price_sat: 1000, timestamp: 1,
            block: 1, signature: [0u8; 65],
        };
        let v = sign_vote(&sk, v);
        v.verify().unwrap();
        let mut tampered = v.clone();
        tampered.price_sat = 9999;
        assert!(tampered.verify().is_err());
    }

    #[test]
    fn outlier_rejected_in_tally() {
        // Seed 5 votes at price ~100 and one at 10_000 — the outlier vote
        // must be dropped (and observation still ≥ MIN_VOTERS).
        let db = Arc::new(sled::Config::new().temporary(true).open().unwrap());
        let oracle = DistributedOracle::open(db.clone()).unwrap();
        let mut votes = Vec::new();
        for i in 0..5u8 {
            let sk = SigningKey::random(&mut rand::thread_rng());
            let addr = addr_from_sk(&sk);
            let _ = i;
            let v = PriceVote {
                miner_addr: addr, pair_id: 0, price_sat: 100,
                timestamp: 1, block: 1, signature: [0u8; 65],
            };
            votes.push(sign_vote(&sk, v));
        }
        let sk = SigningKey::random(&mut rand::thread_rng());
        let addr = addr_from_sk(&sk);
        let outlier = sign_vote(&sk, PriceVote {
            miner_addr: addr, pair_id: 0, price_sat: 10_000,
            timestamp: 1, block: 1, signature: [0u8; 65],
        });
        votes.push(outlier);
        // Insert raw (bypassing eligibility check that requires real ValidatorSet)
        for v in &votes {
            let bytes = serde_json::to_vec(v).unwrap();
            oracle.votes_tree.insert(
                DistributedOracle::vote_key(0, 1, &v.miner_addr), bytes,
            ).unwrap();
        }
        let obs = oracle.tally_at_block(1).unwrap();
        assert_eq!(obs.len(), 1);
        assert_eq!(obs[0].median_price, 100);
        assert_eq!(obs[0].n_voters, 5);
    }
}
