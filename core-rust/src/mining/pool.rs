//! OmniBus mining-pool participant + pool-side state (port of
//! `core/mining_pool.zig`).
//!
//! There are two roles here:
//!
//! - [`MiningPool`]       Pool-server state — list of registered miners,
//!                        hashrate accounting, share recording, proportional
//!                        reward distribution. Used by the node when it is
//!                        acting as a pool.
//! - [`MiningPoolClient`] Pool participant — the miner's view of the pool.
//!                        Talks to the OmniBus pool over JSON-RPC on port
//!                        8332, the same protocol used by
//!                        `scripts/miner-client.js`: `registerminer` then
//!                        periodic `minerkeepalive`.

use std::time::Duration;

use serde::{Deserialize, Serialize};

// ─── Pool server state (port of core/mining_pool.zig) ────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PoolMinerStatus {
    Offline,
    Idle,
    Mining,
    SubmittedShare,
}

#[derive(Debug, Clone)]
pub struct PoolMiner {
    pub miner_id: String,
    pub address: String,
    pub hashrate: u64,
    pub shares: u64,
    pub last_share_time: i64,
    pub status: PoolMinerStatus,
}

#[derive(Debug, Clone)]
pub struct MiningPool {
    pub pool_id: String,
    pub miners: Vec<PoolMiner>,
    pub total_hashrate: u64,
    pub blocks_found: u64,
    pub pool_reward_address: String,
}

impl MiningPool {
    pub fn new(pool_id: impl Into<String>, reward_address: impl Into<String>) -> Self {
        Self {
            pool_id: pool_id.into(),
            miners: Vec::new(),
            total_hashrate: 0,
            blocks_found: 0,
            pool_reward_address: reward_address.into(),
        }
    }

    pub fn add_miner(&mut self, miner_id: impl Into<String>, address: impl Into<String>, hashrate: u64) {
        self.miners.push(PoolMiner {
            miner_id: miner_id.into(),
            address: address.into(),
            hashrate,
            shares: 0,
            last_share_time: now_secs(),
            status: PoolMinerStatus::Idle,
        });
        self.total_hashrate = self.total_hashrate.saturating_add(hashrate);
    }

    pub fn update_status(&mut self, miner_id: &str, status: PoolMinerStatus) -> bool {
        for m in &mut self.miners {
            if m.miner_id == miner_id {
                m.status = status;
                m.last_share_time = now_secs();
                return true;
            }
        }
        false
    }

    pub fn record_share(&mut self, miner_id: &str) -> bool {
        for m in &mut self.miners {
            if m.miner_id == miner_id {
                m.shares += 1;
                m.status = PoolMinerStatus::SubmittedShare;
                m.last_share_time = now_secs();
                return true;
            }
        }
        false
    }

    pub fn record_block_found(&mut self) {
        self.blocks_found += 1;
    }

    pub fn miner_count(&self) -> usize {
        self.miners.len()
    }

    /// Proportional reward: `(miner_hashrate / total_hashrate) * block_reward`.
    pub fn miner_reward_share(&self, miner_id: &str, block_reward: u64) -> Option<u64> {
        if self.total_hashrate == 0 {
            return Some(0);
        }
        for m in &self.miners {
            if m.miner_id == miner_id {
                return Some(
                    (m.hashrate as u128 * block_reward as u128 / self.total_hashrate as u128) as u64,
                );
            }
        }
        None
    }

    pub fn stats(&self) -> PoolStats {
        let active = self
            .miners
            .iter()
            .filter(|m| m.status != PoolMinerStatus::Offline)
            .count() as u32;
        PoolStats {
            total_miners: self.miners.len(),
            active_miners: active,
            total_hashrate: self.total_hashrate,
            blocks_found: self.blocks_found,
        }
    }

    /// Drop miners that haven't sent a share in `> 300s` (5 min).
    pub fn remove_inactive(&mut self) {
        let now = now_secs();
        let timeout: i64 = 300;
        self.miners.retain(|m| {
            let keep = (now - m.last_share_time) <= timeout;
            if !keep {
                self.total_hashrate = self.total_hashrate.saturating_sub(m.hashrate);
            }
            keep
        });
    }
}

#[derive(Debug, Clone, Copy)]
pub struct PoolStats {
    pub total_miners: usize,
    pub active_miners: u32,
    pub total_hashrate: u64,
    pub blocks_found: u64,
}

// ─── Pool client (port of scripts/miner-client.js) ───────────────────────────

#[derive(Debug, Clone)]
pub struct MiningPoolClient {
    pub pool_host: String,
    pub pool_port: u16,
    pub miner_id: String,
    pub miner_name: String,
    pub miner_address: String,
    pub hashrate: u64,
    pub keepalive: Duration,
    http: reqwest_like::Client,
}

impl MiningPoolClient {
    pub fn new(
        pool_host: impl Into<String>,
        pool_port: u16,
        miner_id: impl Into<String>,
        miner_address: impl Into<String>,
        hashrate: u64,
    ) -> Self {
        let mid: String = miner_id.into();
        Self {
            pool_host: pool_host.into(),
            pool_port,
            miner_name: mid.clone(),
            miner_id: mid,
            miner_address: miner_address.into(),
            hashrate,
            keepalive: Duration::from_secs(5),
            http: reqwest_like::Client::new(),
        }
    }

    /// `registerminer` RPC — call once on startup.
    pub async fn register(&self) -> anyhow::Result<RegisterResult> {
        let params = serde_json::json!([{
            "id":       self.miner_id,
            "name":     self.miner_name,
            "address":  self.miner_address,
            "hashrate": self.hashrate,
        }]);
        let v = self.rpc("registerminer", params).await?;
        Ok(serde_json::from_value(v)?)
    }

    /// `minerkeepalive` RPC — call every `self.keepalive`.
    pub async fn keepalive_once(&self) -> anyhow::Result<serde_json::Value> {
        self.rpc(
            "minerkeepalive",
            serde_json::json!([self.miner_address]),
        )
        .await
    }

    /// Submit a found share/block to the pool. Pool decides reward routing.
    pub async fn submit_share(&self, block_hash_hex: &str, nonce: u64) -> anyhow::Result<serde_json::Value> {
        self.rpc(
            "submitshare",
            serde_json::json!([{
                "miner_id": self.miner_id,
                "hash":     block_hash_hex,
                "nonce":    nonce,
            }]),
        )
        .await
    }

    /// `getpoolstats` RPC.
    pub async fn pool_stats(&self) -> anyhow::Result<serde_json::Value> {
        self.rpc("getpoolstats", serde_json::json!([])).await
    }

    /// Run register + keepalive forever (until error). Convenience wrapper
    /// that mirrors `scripts/miner-client.js` behaviour.
    pub async fn run_forever(&self) -> anyhow::Result<()> {
        let _ = self.register().await?;
        loop {
            tokio::time::sleep(self.keepalive).await;
            if let Err(e) = self.keepalive_once().await {
                tracing::warn!("pool keepalive failed: {e:#}");
            }
        }
    }

    async fn rpc(&self, method: &str, params: serde_json::Value) -> anyhow::Result<serde_json::Value> {
        let url = format!("http://{}:{}/", self.pool_host, self.pool_port);
        let body = serde_json::json!({
            "jsonrpc": "2.0",
            "method":  method,
            "params":  params,
            "id":      rand_id(),
        });
        let resp = self.http.post_json(&url, &body).await?;
        if let Some(err) = resp.get("error") {
            anyhow::bail!("pool RPC error: {err}");
        }
        Ok(resp.get("result").cloned().unwrap_or(serde_json::Value::Null))
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RegisterResult {
    #[serde(rename = "minerCount", default)]
    pub miner_count: u32,
    #[serde(rename = "activeMiners", default)]
    pub active_miners: u32,
}

fn now_secs() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn rand_id() -> u32 {
    use std::time::{SystemTime, UNIX_EPOCH};
    (SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0)
        % 10_000) as u32
}

// ─── Tiny HTTP+JSON client (kept here so we don't pull in `reqwest` just
//     for two POSTs). Talks JSON-RPC 2.0 over plain HTTP/1.1.
mod reqwest_like {
    use std::io::{Read, Write};
    use std::net::TcpStream;
    use std::time::Duration;

    #[derive(Debug, Clone, Default)]
    pub struct Client;
    impl Client {
        pub fn new() -> Self {
            Self
        }
        pub async fn post_json(
            &self,
            url: &str,
            body: &serde_json::Value,
        ) -> anyhow::Result<serde_json::Value> {
            let body_bytes = serde_json::to_vec(body)?;
            let url = url.to_string();
            tokio::task::spawn_blocking(move || -> anyhow::Result<serde_json::Value> {
                // Parse `http://host:port/path`.
                let rest = url
                    .strip_prefix("http://")
                    .ok_or_else(|| anyhow::anyhow!("only http:// supported"))?;
                let (hostport, path) = rest.split_once('/').unwrap_or((rest, ""));
                let path = if path.is_empty() {
                    "/".to_string()
                } else {
                    format!("/{path}")
                };
                let mut stream = TcpStream::connect(hostport)?;
                stream.set_read_timeout(Some(Duration::from_secs(10)))?;
                stream.set_write_timeout(Some(Duration::from_secs(10)))?;
                let req = format!(
                    "POST {path} HTTP/1.1\r\n\
                     Host: {hostport}\r\n\
                     Content-Type: application/json\r\n\
                     Content-Length: {}\r\n\
                     Connection: close\r\n\r\n",
                    body_bytes.len(),
                );
                stream.write_all(req.as_bytes())?;
                stream.write_all(&body_bytes)?;
                let mut buf = Vec::with_capacity(4096);
                stream.read_to_end(&mut buf)?;
                // Skip headers up to `\r\n\r\n`.
                let sep = b"\r\n\r\n";
                let mut i = 0;
                while i + sep.len() <= buf.len() {
                    if &buf[i..i + sep.len()] == sep {
                        break;
                    }
                    i += 1;
                }
                let body_start = i + sep.len();
                let json: serde_json::Value =
                    serde_json::from_slice(&buf[body_start.min(buf.len())..])?;
                Ok(json)
            })
            .await?
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_and_reward_share() {
        let mut p = MiningPool::new("omnibus-pool", "ob1qrewardxxx");
        p.add_miner("a", "ob1aaa", 1000);
        p.add_miner("b", "ob1bbb", 1000);
        let r_a = p.miner_reward_share("a", 50_000_000_000).unwrap();
        let r_b = p.miner_reward_share("b", 50_000_000_000).unwrap();
        assert_eq!(r_a, 25_000_000_000);
        assert_eq!(r_b, 25_000_000_000);
    }

    #[test]
    fn record_share_updates_count() {
        let mut p = MiningPool::new("omnibus-pool", "ob1qrewardxxx");
        p.add_miner("a", "ob1aaa", 1000);
        assert!(p.record_share("a"));
        assert!(p.record_share("a"));
        assert_eq!(p.miners[0].shares, 2);
    }
}
