//! common — endpoint config, HTTP JSON-RPC client, ANSI colors, shared helpers.
//!
//! Ported from core/cli/common.zig (infrastructure sections).

use serde_json::{json, Value};

// ─── Constants ───────────────────────────────────────────────────────────────

pub const SAT_PER_OMNI: u64 = 1_000_000_000;
pub const PORT_MAINNET: u16 = 8332;
pub const PORT_TESTNET: u16 = 18332;
pub const PORT_REGTEST: u16 = 28332;
/// 1-second blocks — divide block_height by 86400 for a calendar-day bucket.
pub const BLOCKS_PER_DAY: u64 = 86_400;

// ─── ANSI color helpers ───────────────────────────────────────────────────────

pub struct Colors {
    pub enabled: bool,
}

impl Colors {
    pub fn new(enabled: bool) -> Self { Self { enabled } }

    pub fn bold(&self)    -> &'static str { if self.enabled { "\x1b[1m"  } else { "" } }
    pub fn reset(&self)   -> &'static str { if self.enabled { "\x1b[0m"  } else { "" } }
    pub fn green(&self)   -> &'static str { if self.enabled { "\x1b[32m" } else { "" } }
    pub fn yellow(&self)  -> &'static str { if self.enabled { "\x1b[33m" } else { "" } }
    pub fn red(&self)     -> &'static str { if self.enabled { "\x1b[31m" } else { "" } }
    pub fn cyan(&self)    -> &'static str { if self.enabled { "\x1b[36m" } else { "" } }
    pub fn gray(&self)    -> &'static str { if self.enabled { "\x1b[90m" } else { "" } }
    pub fn magenta(&self) -> &'static str { if self.enabled { "\x1b[35m" } else { "" } }
}

// ─── Endpoint config ──────────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct Endpoint {
    pub host: String,
    pub port: u16,
    pub path: String,
    pub token: Option<String>,
    /// `true` when the URL is HTTPS — we delegate to curl for TLS.
    pub use_curl: bool,
    /// Set when `--remote` or an `https://` URL is given.
    pub full_url: Option<String>,
}

impl Default for Endpoint {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".into(),
            port: PORT_MAINNET,
            path: "/".into(),
            token: None,
            use_curl: false,
            full_url: None,
        }
    }
}

// ─── CLI args ─────────────────────────────────────────────────────────────────

/// Parsed CLI arguments (mirrors core/cli/common.zig `Args`).
#[derive(Clone, Debug, Default)]
pub struct CliArgs {
    pub cmd: String,
    /// Positional args after the subcommand name.
    pub pos: Vec<String>,
    pub rpc: Option<String>,
    pub chain: String,
    pub remote: bool,
    pub token: Option<String>,
    pub json: bool,
    pub no_color: bool,
    // Write-side flags
    pub yes: bool,
    pub mnemonic: Option<String>,
    pub passphrase: Option<String>,
    pub privkey: Option<String>,
    pub keyfile: Option<String>,
    pub key_index: u32,
    pub signers: Option<String>,
    /// Generic `--foo-bar=baz` pairs.
    pub kvs: Vec<(String, String)>,
}

impl CliArgs {
    /// Parse from `std::env::args()`.
    pub fn parse() -> Self {
        Self::parse_from(std::env::args().skip(1).collect())
    }

    pub fn parse_from(argv: Vec<String>) -> Self {
        let mut out = Self {
            chain: "mainnet".into(),
            ..Default::default()
        };
        let mut i = 0usize;
        while i < argv.len() {
            let a = &argv[i];
            match a.as_str() {
                "--rpc"        => { i += 1; out.rpc = argv.get(i).cloned(); }
                "--chain"      => { i += 1; out.chain = argv.get(i).cloned().unwrap_or_default(); }
                "--remote"     => out.remote = true,
                "--token"      => { i += 1; out.token = argv.get(i).cloned(); }
                "--json"       => out.json = true,
                "--no-color"   => out.no_color = true,
                "--yes" | "-y" => out.yes = true,
                "--mnemonic"   => { i += 1; out.mnemonic = argv.get(i).cloned(); }
                "--passphrase" => { i += 1; out.passphrase = argv.get(i).cloned(); }
                "--privkey"    => { i += 1; out.privkey = argv.get(i).cloned(); }
                "--keyfile"    => { i += 1; out.keyfile = argv.get(i).cloned(); }
                "--key-index"  => {
                    i += 1;
                    out.key_index = argv.get(i)
                        .and_then(|v| v.parse().ok())
                        .unwrap_or(0);
                }
                "--signers"    => { i += 1; out.signers = argv.get(i).cloned(); }
                "-h" | "--help" => out.cmd = "help".into(),
                other if other.starts_with("--") && other.contains('=') => {
                    // Generic --key=value
                    if let Some(eq) = other.find('=') {
                        let k = other[2..eq].to_string();
                        let v = other[eq + 1..].to_string();
                        out.kvs.push((k, v));
                    }
                }
                other => {
                    if out.cmd.is_empty() {
                        out.cmd = other.to_string();
                    } else {
                        out.pos.push(other.to_string());
                    }
                }
            }
            i += 1;
        }
        out
    }

    /// Look up a generic `--foo-bar=baz` flag by key (without the `--` prefix).
    pub fn kv(&self, key: &str) -> Option<&str> {
        self.kvs.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }
}

/// Build an `Endpoint` from parsed `CliArgs`.
pub fn resolve_endpoint(args: &CliArgs) -> Endpoint {
    let mut ep = Endpoint {
        token: args.token.clone(),
        ..Default::default()
    };

    if args.remote {
        ep.use_curl = true;
        ep.full_url = Some(match args.chain.as_str() {
            "testnet" => "https://omnibusblockchain.cc:8443/api-testnet".into(),
            "regtest" => "https://omnibusblockchain.cc:8443/api-regtest".into(),
            _         => "https://omnibusblockchain.cc:8443/api-mainnet".into(),
        });
        return ep;
    }

    if let Some(raw) = &args.rpc {
        let rest = if let Some(r) = raw.strip_prefix("http://") {
            r
        } else if raw.starts_with("https://") {
            ep.use_curl = true;
            ep.full_url = Some(raw.clone());
            return ep;
        } else {
            raw.as_str()
        };
        // Parse host[:port][/path]
        let (hostport, path) = if let Some(slash) = rest.find('/') {
            (&rest[..slash], rest[slash..].to_string())
        } else {
            (rest, "/".to_string())
        };
        ep.path = path;
        if let Some(colon) = hostport.find(':') {
            ep.host = hostport[..colon].to_string();
            ep.port = hostport[colon + 1..].parse().unwrap_or(ep.port);
        } else {
            ep.host = hostport.to_string();
        }
        return ep;
    }

    // chain → port
    ep.port = match args.chain.as_str() {
        "testnet" => PORT_TESTNET,
        "regtest" => PORT_REGTEST,
        _         => PORT_MAINNET,
    };
    ep
}

// ─── HTTP JSON-RPC client ─────────────────────────────────────────────────────

/// Errors that can occur while executing an RPC call.
#[derive(Debug)]
pub enum RpcError {
    Http(reqwest::Error),
    Curl(String),
    Json(serde_json::Error),
    RpcLevel { code: i64, message: String },
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RpcError::Http(e)           => write!(f, "HTTP error: {e}"),
            RpcError::Curl(s)           => write!(f, "curl error: {s}"),
            RpcError::Json(e)           => write!(f, "JSON parse error: {e}"),
            RpcError::RpcLevel { message, .. } => write!(f, "RPC error: {message}"),
        }
    }
}

impl From<reqwest::Error> for RpcError {
    fn from(e: reqwest::Error) -> Self { RpcError::Http(e) }
}
impl From<serde_json::Error> for RpcError {
    fn from(e: serde_json::Error) -> Self { RpcError::Json(e) }
}

/// Build an authenticated `reqwest::Client` for JSON-RPC calls.
fn build_client() -> reqwest::Client {
    reqwest::Client::builder()
        .danger_accept_invalid_certs(false)
        .build()
        .expect("reqwest client build")
}

/// Perform a JSON-RPC 2.0 call and return the raw response `Value`.
/// On HTTP/transport error the function returns `Err`; RPC-level errors
/// (`"error"` key present) are returned as `Err(RpcError::RpcLevel{..})`.
pub async fn rpc_call(ep: &Endpoint, method: &str, params: Value) -> Result<Value, RpcError> {
    let body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    });

    if ep.use_curl {
        return rpc_call_curl(ep, &body).await;
    }

    let url = format!("http://{}:{}{}", ep.host, ep.port, ep.path);
    let client = build_client();
    let mut req = client.post(&url).json(&body);
    if let Some(token) = &ep.token {
        req = req.header("Authorization", format!("Bearer {token}"));
    }
    let resp = req.send().await?;
    let v: Value = resp.json().await?;
    extract_result_or_err(v)
}

/// HTTPS path: delegate to `curl` (mirrors the Zig `ep.use_curl` path).
async fn rpc_call_curl(ep: &Endpoint, body: &Value) -> Result<Value, RpcError> {
    use tokio::process::Command;

    let url = ep.full_url.as_deref().unwrap_or("https://omnibusblockchain.cc:8443/api-mainnet");
    let body_str = serde_json::to_string(body)?;

    let mut cmd = Command::new("curl");
    cmd.args(["-sS", "-X", "POST",
              "-H", "Content-Type: application/json",
              "-d", &body_str]);
    if let Some(token) = &ep.token {
        cmd.args(["-H", &format!("Authorization: Bearer {token}")]);
    }
    cmd.arg(url);

    let out = cmd.output().await
        .map_err(|e| RpcError::Curl(format!("curl spawn failed: {e}")))?;

    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
        return Err(RpcError::Curl(stderr));
    }

    let v: Value = serde_json::from_slice(&out.stdout)?;
    extract_result_or_err(v)
}

/// Unwrap `{"result": ...}` or convert `{"error": ...}` to `Err`.
fn extract_result_or_err(v: Value) -> Result<Value, RpcError> {
    if let Some(err) = v.get("error") {
        if err != &Value::Null {
            let code = err.get("code").and_then(|c| c.as_i64()).unwrap_or(-1);
            let message = err.get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("unknown error")
                .to_string();
            return Err(RpcError::RpcLevel { code, message });
        }
    }
    Ok(v["result"].clone())
}

// ─── JSON field helpers ───────────────────────────────────────────────────────

/// Extract a string field from a JSON object; returns "" if absent.
pub fn json_str<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(|x| x.as_str()).unwrap_or("")
}

/// Extract a u64 field from a JSON object; returns 0 if absent or negative.
pub fn json_u64(v: &Value, key: &str) -> u64 {
    match v.get(key) {
        Some(Value::Number(n)) => n.as_u64()
            .or_else(|| n.as_i64().map(|i| if i < 0 { 0 } else { i as u64 }))
            .or_else(|| n.as_f64().map(|f| if f < 0.0 { 0 } else { f as u64 }))
            .unwrap_or(0),
        Some(Value::String(s)) => s.parse().unwrap_or(0),
        _ => 0,
    }
}

// ─── Formatting helpers ───────────────────────────────────────────────────────

/// Convert satoshis → "1.2346 OMNI" (4 decimals, rounded).
pub fn format_omni(sat: u64) -> String {
    let whole = sat / SAT_PER_OMNI;
    let frac = sat % SAT_PER_OMNI;
    // Round to 4 decimal places (frac is out of 1_000_000_000).
    let four = (frac + 50_000) / 100_000;
    if four == 0 {
        format!("{whole}.0000")
    } else {
        format!("{whole}.{four:04}")
    }
}

/// Day index from a block height (1-second blocks).
pub fn parse_day(block_height: u64) -> u64 {
    block_height / BLOCKS_PER_DAY
}

// ─── Usage / help ─────────────────────────────────────────────────────────────

pub fn print_usage() {
    eprintln!(r#"omnibus-cli — OmniBus audit/management CLI (Rust port)

USAGE:
  omnibus-cli <SUBCOMMAND> [OPTIONS]

SUBCOMMANDS (read):
  balance <addr>              Full balance breakdown
  wallet-summary <addr>       Atomic wallet snapshot
  stake <addr>                Current stake + activity log
  reputation <addr>           Cups + tier
  daily <addr> [days]         Per-day TX breakdown (default 30 days)
  validators                  All validators
  stakers [limit]             Top stakers (default 10)
  health                      Chain stats (height / mempool / peers)
  history <addr> [filter]     TX history (all/stake/sent/received/mined)
  verify <addr>               Sanity check: chain stake vs TX history

SUBCOMMANDS (wallet):
  derive-key [index]          Derive one BIP-44 child key offline
  wallet-list [count]         List N addresses from one mnemonic

SUBCOMMANDS (advanced — passthrough to node RPC):
  ns <sub> [args]             Name-service
  oracle <sub> [args]         Oracle feed
  grid <sub> [args]           Grid-bot
  agents <sub> [args]         Agent registry
  pq <sub> [args]             Post-quantum wallet
  htlc <sub> [args]           HTLC
  escrow <sub> [args]         Escrow
  mining <sub> [args]         Mining
  exchange <sub> [args]       DEX orders / pairs
  gov <sub> [args]            Governance
  social <sub> [args]         Social graph
  notarize <sub> [args]       Document-hash anchor
  audit <sub> [args]          Audit / richlist
  admin <sub> [args]          Admin

SUBCOMMANDS (sprint-2026-06-02 — JSON-object params via --key=value):
  spark status                       Last SPARK consensus snapshot
  spark votes --block_hash=<hex64>   10-layer vote breakdown for a block
  strategy register --agent_id=N --owner=ob1q --name=X --type=grid --params={{}}
                                     Register a new operator strategy
  strategy activate --id=N           Mark a Draft strategy as Active
  strategy get --id=N                Fetch a strategy by id
  strategy list --owner=ob1q         List ids by owner (or --agent_id=N)
  slot-calendar                      60 pre-computed slot leaders (head + 60)

GLOBAL FLAGS:
  --rpc <url>         Override RPC URL (default http://127.0.0.1:8332)
  --chain <c>         mainnet|testnet|regtest (ports 8332/18332/28332)
  --remote            Use https://omnibusblockchain.cc:8443/api-{{chain}}
  --token <bearer>    RPC bearer token
  --json              Raw JSON output
  --no-color          Disable ANSI colours

WRITE FLAGS:
  --yes / -y          Confirm write operation
  --mnemonic "<12w>"  BIP-39 mnemonic (or set OMNIBUS_MNEMONIC env)
  --passphrase <p>    BIP-39 25th word
  --privkey <hex>     Raw 32-byte private key hex
  --keyfile <path>    File containing 32-byte hex private key
  --key-index <n>     BIP-44 child index (default 0)

EXAMPLES:
  omnibus-cli health
  omnibus-cli balance ob1q...
  omnibus-cli daily ob1q... 7
  omnibus-cli history ob1q... stake
  omnibus-cli validators --json
  omnibus-cli --chain testnet health
  omnibus-cli --remote balance ob1q...
"#);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn args(s: &[&str]) -> CliArgs {
        CliArgs::parse_from(s.iter().map(|x| x.to_string()).collect())
    }

    #[test]
    fn parse_kv_flags() {
        let a = args(&["strategy", "register", "--agent_id=7", "--owner=ob1q", "--type=grid"]);
        assert_eq!(a.cmd, "strategy");
        assert_eq!(a.pos, vec!["register"]);
        assert_eq!(a.kv("agent_id"), Some("7"));
        assert_eq!(a.kv("owner"), Some("ob1q"));
        assert_eq!(a.kv("type"), Some("grid"));
        assert_eq!(a.kv("missing"), None);
    }

    #[test]
    fn parse_slot_calendar_basic() {
        let a = args(&["slot-calendar", "--json"]);
        assert_eq!(a.cmd, "slot-calendar");
        assert!(a.json);
    }

    #[test]
    fn parse_spark_votes_with_block_hash() {
        let a = args(&["spark", "votes", "--block_hash=deadbeef"]);
        assert_eq!(a.cmd, "spark");
        assert_eq!(a.pos, vec!["votes"]);
        assert_eq!(a.kv("block_hash"), Some("deadbeef"));
    }

    #[test]
    fn parse_strategy_list_by_owner() {
        let a = args(&["strategy", "list", "--owner=ob1qowner"]);
        assert_eq!(a.cmd, "strategy");
        assert_eq!(a.pos, vec!["list"]);
        assert_eq!(a.kv("owner"), Some("ob1qowner"));
    }
}
