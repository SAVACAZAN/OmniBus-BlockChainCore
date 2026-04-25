use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::time::Instant;

type HmacSha256 = Hmac<Sha256>;

#[derive(Serialize, Deserialize, Clone)]
struct Transaction {
    from: String,
    to: String,
    amount: u64,
    signature: String,
}

#[derive(Serialize, Deserialize, Clone)]
struct Block {
    height: u64,
    timestamp: i64,
    prev_hash: String,
    merkle: String,
    nonce: u64,
    txs: [Transaction; 3],
}

fn to_hex(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for byte in b {
        s.push_str(&format!("{:02x}", byte));
    }
    s
}

fn main() {
    // ---------------- BENCH 1: SHA-256 (1M) ----------------
    {
        let mut input = [0u8; 64];
        for i in 0..64 {
            input[i] = (i & 0xff) as u8;
        }
        const N: u64 = 1_000_000;
        let start = Instant::now();
        let mut out = [0u8; 32];
        for _ in 0..N {
            let mut h = Sha256::new();
            h.update(&input);
            let r = h.finalize();
            out.copy_from_slice(&r);
            input[0] ^= out[0];
        }
        let elapsed = start.elapsed();
        let ms = elapsed.as_millis();
        let avg_ns = elapsed.as_nanos() / N as u128;
        println!("SHA256: {} ms ({} iterations, {} ns avg)", ms, N, avg_ns);
    }

    // ---------------- BENCH 2: JSON serde (100K) ----------------
    {
        let raw32: [u8; 32] = core::array::from_fn(|i| i as u8);
        let prev_hex = to_hex(&raw32);
        let merkle_hex = to_hex(&raw32);
        let raw_sig: [u8; 64] = core::array::from_fn(|i| i as u8);
        let sig_hex = to_hex(&raw_sig);

        let block = Block {
            height: 12345,
            timestamp: 1735689600,
            prev_hash: prev_hex,
            merkle: merkle_hex,
            nonce: 987654321,
            txs: [
                Transaction {
                    from: "alice".to_string(),
                    to: "bob".to_string(),
                    amount: 100,
                    signature: sig_hex.clone(),
                },
                Transaction {
                    from: "carol".to_string(),
                    to: "dave".to_string(),
                    amount: 200,
                    signature: sig_hex.clone(),
                },
                Transaction {
                    from: "eve".to_string(),
                    to: "frank".to_string(),
                    amount: 300,
                    signature: sig_hex.clone(),
                },
            ],
        };

        const N: u64 = 100_000;
        let mut sum: u64 = 0;
        let start = Instant::now();
        for _ in 0..N {
            let s = serde_json::to_string(&block).unwrap();
            let b2: Block = serde_json::from_str(&s).unwrap();
            sum = sum.wrapping_add(b2.height);
        }
        let elapsed = start.elapsed();
        let ms = elapsed.as_millis();
        let avg_ns = elapsed.as_nanos() / N as u128;
        println!("JSON: {} ms ({} iterations, {} ns avg) [sum={}]", ms, N, avg_ns, sum);
    }

    // ---------------- BENCH 3: HMAC-SHA256 (100K) ----------------
    {
        let mut key = [0u8; 32];
        for i in 0..32 {
            key[i] = i as u8;
        }
        let mut msg = [0u8; 256];
        for i in 0..256 {
            msg[i] = (i & 0xff) as u8;
        }
        const N: u64 = 100_000;
        let start = Instant::now();
        for _ in 0..N {
            let mut mac = HmacSha256::new_from_slice(&key).unwrap();
            mac.update(&msg);
            let r = mac.finalize().into_bytes();
            msg[0] ^= r[0];
        }
        let elapsed = start.elapsed();
        let ms = elapsed.as_millis();
        let avg_ns = elapsed.as_nanos() / N as u128;
        println!("HMAC: {} ms ({} iterations, {} ns avg)", ms, N, avg_ns);
    }

    // ---------------- BENCH 4: Memory alloc (1M x 64B) ----------------
    {
        const N: u64 = 1_000_000;
        let mut ptrs: Vec<Vec<u8>> = Vec::with_capacity(N as usize);
        let start = Instant::now();
        for i in 0..N {
            let mut v = vec![0u8; 64];
            v[0] = (i & 0xff) as u8;
            ptrs.push(v);
        }
        // free
        ptrs.clear();
        ptrs.shrink_to_fit();
        let elapsed = start.elapsed();
        let ms = elapsed.as_millis();
        let avg_ns = elapsed.as_nanos() / N as u128;
        println!("MEMALLOC: {} ms ({} iterations, {} ns avg)", ms, N, avg_ns);
    }
}
