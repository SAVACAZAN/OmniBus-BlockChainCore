// omnibus-node-rust — sibling implementation of BlockChainCore (core/ Zig).
// Same chain protocol; peers with the Zig node via P2P; produces identical
// chain hashes. EVM execution baked in (revm via omnibus-crypto-core).
//
// CLI mirrors the Zig node:
//   omnibus-node-rust --mode seed   --node-id node-1   --port 9000
//   omnibus-node-rust --mode miner  --node-id miner-1  --seed-host 127.0.0.1 --seed-port 9000
//   omnibus-node-rust --mode evm    [--evm-port 8333]   (EVM-only — RPC + sled state, no P2P/consensus)
//
// In `evm` mode the node is reduced to the M2 milestone behaviour: a standalone
// EVM-style JSON-RPC server with persistent sled state, useful for local
// development with MetaMask/Hardhat while the full node modules are wired up.

mod dex;
mod rpc;
mod state;
mod tx;
mod block_exec;
mod evm;
mod storage;
mod crypto;
mod wallet;
mod p2p;
mod consensus;
mod light;
mod mining;
mod types;
mod vault;
mod dns;
mod ws;
mod agents;
mod guardian;
mod shard;
mod governance;
mod validator;
mod identity;
mod chain;
mod node;
mod safety;

use axum::{routing::post, Router, Json};
use serde_json::{Value, json};
use std::sync::Arc;
use std::net::SocketAddr;
use tokio::sync::RwLock;

pub use state::EvmState;
pub use chain::{Chain, SharedChain};
pub use p2p::node::PeerRegistry;

#[derive(Clone)]
pub struct AppState {
    pub state: Arc<EvmState>,
    /// Native chain (None in `--mode evm` to keep the EVM-only path light).
    pub chain: SharedChain,
    pub peers: PeerRegistry,
}

#[derive(Debug, Clone)]
pub struct CliArgs {
    pub mode: NodeMode,
    pub node_id: String,
    pub p2p_port: u16,
    pub rpc_port: u16,
    pub evm_port: u16,
    pub seed_host: Option<String>,
    pub seed_port: u16,
    pub data_dir: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeMode { Seed, Miner, Evm }

impl CliArgs {
    pub fn parse() -> Self {
        let mut args = std::env::args().skip(1);
        let mut mode = NodeMode::Evm;
        let mut node_id = "node-rust".to_string();
        let mut p2p_port = 9000u16;
        let mut rpc_port = 8332u16;
        let mut evm_port = std::env::var("OMNIBUS_EVM_PORT").ok()
            .and_then(|s| s.parse().ok()).unwrap_or(8333);
        let mut seed_host = None::<String>;
        let mut seed_port = 9000u16;
        let mut data_dir = std::env::var("OMNIBUS_EVM_STATE_DIR")
            .unwrap_or_else(|_| "./data/evm-state".to_string());

        while let Some(a) = args.next() {
            match a.as_str() {
                "--mode"      => mode = match args.next().as_deref() {
                    Some("seed")  => NodeMode::Seed,
                    Some("miner") => NodeMode::Miner,
                    Some("evm")   => NodeMode::Evm,
                    Some(other)   => { eprintln!("unknown mode: {other}"); std::process::exit(2); }
                    None          => { eprintln!("--mode needs a value"); std::process::exit(2); }
                },
                "--node-id"   => node_id   = args.next().unwrap_or_default(),
                "--port"      => p2p_port  = args.next().and_then(|v| v.parse().ok()).unwrap_or(p2p_port),
                "--rpc-port"  => rpc_port  = args.next().and_then(|v| v.parse().ok()).unwrap_or(rpc_port),
                "--evm-port"  => evm_port  = args.next().and_then(|v| v.parse().ok()).unwrap_or(evm_port),
                "--seed-host" => seed_host = args.next(),
                "--seed-port" => seed_port = args.next().and_then(|v| v.parse().ok()).unwrap_or(seed_port),
                "--data-dir"  => data_dir  = args.next().unwrap_or(data_dir),
                "-h" | "--help" => {
                    print_usage();
                    std::process::exit(0);
                }
                other => { eprintln!("unknown arg: {other}"); print_usage(); std::process::exit(2); }
            }
        }

        Self { mode, node_id, p2p_port, rpc_port, evm_port, seed_host, seed_port, data_dir }
    }
}

fn print_usage() {
    eprintln!(r#"omnibus-node-rust — BlockChainCore Rust sibling node

USAGE:
  omnibus-node-rust [OPTIONS]

MODES:
  --mode seed     run as P2P seed node (default port 9000)
  --mode miner    run as miner; connects to --seed-host:--seed-port
  --mode evm      run only the EVM JSON-RPC sidecar (default, no P2P)

OPTIONS:
  --node-id <s>    node identifier (default "node-rust")
  --port <p>       P2P port (default 9000)
  --rpc-port <p>   native JSON-RPC port (default 8332)
  --evm-port <p>   EVM JSON-RPC port (default 8333)
  --seed-host <h>  seed host (miner mode)
  --seed-port <p>  seed P2P port (default 9000)
  --data-dir <p>   data directory (default ./data/evm-state)
  -h, --help       this help

EXAMPLES:
  omnibus-node-rust --mode evm
      MetaMask/Hardhat at http://localhost:8333 (chainId 7771)

  omnibus-node-rust --mode seed --node-id node-1 --port 9000
      Run as a P2P seed node, peer with Zig nodes on the same chain.

  omnibus-node-rust --mode miner --seed-host 127.0.0.1 --seed-port 9000
      Mine blocks, sync via the given seed.
"#);
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| "omnibus_node_rust=info,axum=info".into()))
        .init();

    let cli = CliArgs::parse();
    tracing::info!(?cli, "omnibus-node-rust starting");

    let evm_state = EvmState::open()?;
    tracing::info!(
        chain_id = evm_state.chain_id(),
        block = evm_state.block_number(),
        "EVM state ready"
    );

    let chain = Chain::open(&cli.data_dir).unwrap_or_else(|e| {
        tracing::warn!(error = %e, "chain open failed; starting empty");
        Chain::open("./data/omnibus-rust").expect("fallback chain open")
    });
    tracing::info!(height = chain.height(), tip = %chain.tip().hash, "chain ready");
    let shared_chain: SharedChain = Arc::new(RwLock::new(chain));

    let registry = PeerRegistry::new();

    let app_state = AppState {
        state: Arc::new(evm_state),
        chain: shared_chain,
        peers: registry.clone(),
    };

    match cli.mode {
        NodeMode::Evm => run_evm_only(app_state, cli.evm_port).await?,
        NodeMode::Seed => node::run_seed(cli, app_state, registry).await?,
        NodeMode::Miner => node::run_miner(cli, app_state, registry).await?,
    }

    Ok(())
}

pub(crate) async fn run_evm_only(app_state: AppState, port: u16) -> anyhow::Result<()> {
    let app = Router::new()
        .route("/", post(handle_rpc))
        .with_state(app_state);

    let addr: SocketAddr = format!("0.0.0.0:{port}").parse()?;
    tracing::info!("EVM JSON-RPC listening on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

async fn handle_rpc(
    axum::extract::State(app): axum::extract::State<AppState>,
    Json(req): Json<Value>,
) -> Json<Value> {
    let id = req.get("id").cloned().unwrap_or(json!(null));
    let method = req.get("method").and_then(|m| m.as_str()).unwrap_or("");
    let params = req.get("params").cloned().unwrap_or(json!([]));

    tracing::debug!(method, "rpc call");

    let result = match rpc::dispatch(&app, method, params).await {
        Ok(v) => json!({ "jsonrpc": "2.0", "id": id, "result": v }),
        Err(e) => json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32601, "message": e } }),
    };

    Json(result)
}
