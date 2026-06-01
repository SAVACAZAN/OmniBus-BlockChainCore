//! Stratum v1 client — connect to an external mining pool over plain TCP
//! line-delimited JSON-RPC. The Zig node uses an HTTP JSON-RPC pool of its
//! own (see [`super::pool`]); this client lets the Rust node also point at
//! a third-party pool (slushpool, F2Pool, Antpool, …).
//!
//! Stratum v2 is not implemented — v1 is what every public BTC pool still
//! speaks, so the Zig codebase has no v2 reference for us to mirror. The
//! type names below (`StratumJob`, `StratumShare`) leave room for a v2 swap
//! when there's an actual user.
//!
//! Wire flow (v1):
//!   1. TCP connect.
//!   2. → `{"id":1,"method":"mining.subscribe","params":["omnibus/0.0.1"]}`.
//!   3. ← `{"id":1,"result":[[...subs...], "<extranonce1>", <extranonce2_size>]}`.
//!   4. → `mining.authorize` with [worker, password].
//!   5. ← `mining.notify` jobs (server-pushed).
//!   6. → `mining.submit` with [worker, job_id, extranonce2, ntime, nonce].

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, Mutex};

#[derive(Debug, Clone)]
pub struct StratumJob {
    pub job_id: String,
    pub prevhash_hex: String,
    pub coinb1_hex: String,
    pub coinb2_hex: String,
    pub merkle_branches: Vec<String>,
    pub version_hex: String,
    pub nbits_hex: String,
    pub ntime_hex: String,
    pub clean_jobs: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct StratumShare {
    pub worker: String,
    pub job_id: String,
    pub extranonce2_hex: String,
    pub ntime_hex: String,
    pub nonce_hex: String,
}

#[derive(Debug, Serialize)]
struct RpcCall<'a> {
    id: u64,
    method: &'a str,
    params: serde_json::Value,
}

#[derive(Debug, Deserialize)]
struct RpcReply {
    id: Option<u64>,
    method: Option<String>,
    params: Option<serde_json::Value>,
    result: Option<serde_json::Value>,
    error: Option<serde_json::Value>,
}

pub struct StratumClient {
    pub host: String,
    pub port: u16,
    pub worker: String,
    pub password: String,
    pub extranonce1: Arc<Mutex<Option<String>>>,
    pub extranonce2_size: Arc<Mutex<u32>>,
    job_tx: mpsc::Sender<StratumJob>,
    job_rx: Arc<Mutex<mpsc::Receiver<StratumJob>>>,
    write: Arc<Mutex<Option<tokio::net::tcp::OwnedWriteHalf>>>,
}

impl StratumClient {
    pub fn new(host: impl Into<String>, port: u16, worker: impl Into<String>, password: impl Into<String>) -> Self {
        let (tx, rx) = mpsc::channel(32);
        Self {
            host: host.into(),
            port,
            worker: worker.into(),
            password: password.into(),
            extranonce1: Arc::new(Mutex::new(None)),
            extranonce2_size: Arc::new(Mutex::new(4)),
            job_tx: tx,
            job_rx: Arc::new(Mutex::new(rx)),
            write: Arc::new(Mutex::new(None)),
        }
    }

    /// Connect, subscribe, authorize, then spawn a background reader that
    /// turns `mining.notify` lines into `StratumJob`s on the channel
    /// returned by [`Self::next_job`].
    pub async fn connect(&self) -> anyhow::Result<()> {
        let stream = TcpStream::connect((self.host.as_str(), self.port)).await?;
        let (rd, wr) = stream.into_split();
        *self.write.lock().await = Some(wr);

        // 1. subscribe
        self.send_call(1, "mining.subscribe", serde_json::json!(["omnibus-rust/0.0.1"])).await?;
        // 2. authorize
        self.send_call(2, "mining.authorize", serde_json::json!([self.worker, self.password])).await?;

        // Spawn reader.
        let job_tx = self.job_tx.clone();
        let xn1 = self.extranonce1.clone();
        let xn2 = self.extranonce2_size.clone();
        tokio::spawn(async move {
            let mut reader = BufReader::new(rd);
            let mut line = String::new();
            loop {
                line.clear();
                match reader.read_line(&mut line).await {
                    Ok(0) => break,
                    Ok(_) => {}
                    Err(e) => {
                        tracing::warn!("stratum read error: {e:#}");
                        break;
                    }
                }
                let reply: RpcReply = match serde_json::from_str(line.trim()) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                if let Some(method) = reply.method.as_deref() {
                    match method {
                        "mining.notify" => {
                            if let Some(j) = parse_notify(&reply.params) {
                                let _ = job_tx.send(j).await;
                            }
                        }
                        "mining.set_difficulty" => {
                            // TODO: track per-share difficulty target.
                        }
                        _ => {}
                    }
                } else if reply.id == Some(1) {
                    // subscribe result: [[subs...], extranonce1, extranonce2_size]
                    if let Some(arr) = reply.result.as_ref().and_then(|v| v.as_array()) {
                        if let Some(x1) = arr.get(1).and_then(|v| v.as_str()) {
                            *xn1.lock().await = Some(x1.to_string());
                        }
                        if let Some(sz) = arr.get(2).and_then(|v| v.as_u64()) {
                            *xn2.lock().await = sz as u32;
                        }
                    }
                }
            }
        });
        Ok(())
    }

    pub async fn next_job(&self) -> Option<StratumJob> {
        self.job_rx.lock().await.recv().await
    }

    pub async fn submit(&self, share: &StratumShare) -> anyhow::Result<()> {
        let params = serde_json::json!([
            share.worker,
            share.job_id,
            share.extranonce2_hex,
            share.ntime_hex,
            share.nonce_hex,
        ]);
        self.send_call(rand_id(), "mining.submit", params).await
    }

    async fn send_call(&self, id: u64, method: &str, params: serde_json::Value) -> anyhow::Result<()> {
        let call = RpcCall { id, method, params };
        let mut line = serde_json::to_string(&call)?;
        line.push('\n');
        let mut guard = self.write.lock().await;
        let w = guard
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("stratum not connected"))?;
        w.write_all(line.as_bytes()).await?;
        w.flush().await?;
        Ok(())
    }
}

fn parse_notify(params: &Option<serde_json::Value>) -> Option<StratumJob> {
    let arr = params.as_ref()?.as_array()?;
    Some(StratumJob {
        job_id:          arr.get(0)?.as_str()?.to_string(),
        prevhash_hex:    arr.get(1)?.as_str()?.to_string(),
        coinb1_hex:      arr.get(2)?.as_str()?.to_string(),
        coinb2_hex:      arr.get(3)?.as_str()?.to_string(),
        merkle_branches: arr.get(4)?.as_array()?.iter()
                            .filter_map(|v| v.as_str().map(String::from)).collect(),
        version_hex:     arr.get(5)?.as_str()?.to_string(),
        nbits_hex:       arr.get(6)?.as_str()?.to_string(),
        ntime_hex:       arr.get(7)?.as_str()?.to_string(),
        clean_jobs:      arr.get(8).and_then(|v| v.as_bool()).unwrap_or(false),
    })
}

fn rand_id() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
}

// ─── GPU / ASIC backend stubs ────────────────────────────────────────────────
//
// Hardware-specific code lives behind these stubs. They keep the engine
// pluggable: the engine grinds nonces via [`super::pow::mine_block_nonce`]
// on CPU today, and tomorrow can call into one of these backends instead.
// All real ASIC/GPU integration is hardware-vendor specific and is left as
// TODO until we have an actual device on the bench.

pub mod gpu {
    //! GPU mining backend stub. TODO: hardware backend (OpenCL/CUDA/Vulkan).
    //! Reference: `core/` has no GPU code yet — only CPU + pool clients.
    use super::*;
    pub struct GpuMiner;
    impl GpuMiner {
        pub fn new() -> Self {
            Self
        }
        /// TODO: hardware backend — OpenCL/CUDA/Vulkan kernel for SHA-256 grind.
        pub fn mine(
            &self,
            _header_prefix: &[u8],
            _difficulty: u32,
            _max_attempts: u64,
        ) -> Option<(u64, [u8; 32])> {
            None
        }
    }
    impl Default for GpuMiner {
        fn default() -> Self {
            Self::new()
        }
    }
}

pub mod asic {
    //! ASIC mining backend stub. TODO: hardware backend (cgminer/bfgminer
    //! style — talk to USB Antminer / Whatsminer via vendor protocol).
    pub struct AsicMiner;
    impl AsicMiner {
        pub fn new() -> Self {
            Self
        }
        /// TODO: hardware backend — USB / serial dialog with ASIC device.
        pub fn mine(
            &self,
            _header_prefix: &[u8],
            _difficulty: u32,
        ) -> Option<(u64, [u8; 32])> {
            None
        }
    }
    impl Default for AsicMiner {
        fn default() -> Self {
            Self::new()
        }
    }
}
