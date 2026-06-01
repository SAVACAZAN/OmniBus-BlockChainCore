//! Price oracle adapter.
//!
//! Higher-level than `core/price_oracle.zig` (which is the DISTRIBUTED
//! consensus oracle aggregating miner submissions). This module is the
//! external price-feed *adapter* used by the grid engine: it fetches the
//! current price for a pair from upstream sources (Chainlink, Pyth,
//! CoinGecko), normalizes to micro-USD, and exposes a simple async
//! `fetch_with_fallback(pair_id)` API.
//!
//! Pair → feed mapping mirrors CLAUDE.md DEX table:
//!   - 0 = OMNI/USDC (CoinGecko fallback; internal-trade preferred)
//!   - 1 = BTC/USDC  (reserved — Chainlink BTC/USD when needed for cross-rate)
//!   - 2 = LCX/USDC  (CoinGecko)
//!   - 3 = ETH/USDC  (Chainlink → Pyth → CoinGecko)
//!   - 4 = OMNI/BTC  (reserved — synthetic from OMNI/USDC ÷ BTC/USDC)
//!   - 5 = OMNI/LCX  (synthetic from OMNI/USDC ÷ LCX/USDC)
//!   - 6 = OMNI/ETH  (synthetic from OMNI/USDC ÷ ETH/USDC)
//!
//! Prices are returned as `u128` in **micro-USD** (1 USD = 1_000_000 units)
//! — same scale as `core/price_oracle.zig::PRICE_SCALE`.

use std::collections::HashMap;
use std::time::Duration;

use thiserror::Error;
use tokio::sync::RwLock;

/// Cache TTL — 30s per spec.
pub const CACHE_TTL_MS: i64 = 30_000;
/// Per-upstream HTTP timeout.
pub const UPSTREAM_TIMEOUT_MS: u64 = 5_000;
/// Internal price scaling — 1 USD == PRICE_SCALE micro-USD units.
pub const PRICE_SCALE: u128 = 1_000_000;

#[derive(Debug, Error)]
pub enum OracleError {
    #[error("no price source configured for pair {0}")]
    NoSource(u64),
    #[error("upstream fetch failed: {0}")]
    Upstream(String),
    #[error("price stale (> {0} ms)")]
    Stale(u64),
    #[error("synthetic compute failed: {0}")]
    Synthetic(String),
}

/// One upstream feed URL.
#[derive(Debug, Clone)]
pub struct FeedUrl {
    pub provider: &'static str,
    pub url: &'static str,
}

/// Canonical feed shortlist per pair_id. Add more rows as new pairs are listed.
pub fn default_feeds(pair_id: u64) -> &'static [FeedUrl] {
    match pair_id {
        // OMNI/USDC — internal trade preferred, CoinGecko fall-back.
        0 => &[FeedUrl {
            provider: "coingecko",
            url: "https://api.coingecko.com/api/v3/simple/price?ids=omnibus&vs_currencies=usd",
        }],
        // BTC/USDC — reserved; Chainlink BTC/USD on Sepolia.
        1 => &[FeedUrl {
            provider: "chainlink",
            url: "BTC-USD",
        }],
        // LCX/USDC
        2 => &[FeedUrl {
            provider: "coingecko",
            url: "https://api.coingecko.com/api/v3/simple/price?ids=lcx&vs_currencies=usd",
        }],
        // ETH/USDC — Chainlink preferred.
        3 => &[
            FeedUrl { provider: "chainlink", url: "ETH-USD" },
            FeedUrl {
                provider: "pyth",
                url: "https://hermes.pyth.network/v2/updates/price/latest?ids[]=0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
            },
            FeedUrl {
                provider: "coingecko",
                url: "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd",
            },
        ],
        // OMNI/BTC, OMNI/LCX, OMNI/ETH — synthesize from the two USD legs upstream.
        4 | 5 | 6 => &[FeedUrl { provider: "synthetic", url: "internal:cross-pair" }],
        _ => &[],
    }
}

// ── Chainlink JSON-RPC feed addresses (Sepolia) ─────────────────────────────
//
// Chainlink AggregatorV3Interface.latestRoundData() — selector 0xfeaf968c.
// We call via eth_call against a public Sepolia RPC. Return tuple:
//   (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
// `answer` is the price scaled by `decimals()` (typically 8 for USD pairs).

/// Sepolia Chainlink aggregator addresses. Hard-coded shortlist of 5 feeds.
pub fn chainlink_address(pair: &str) -> Option<&'static str> {
    match pair {
        // https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1&testnetPage=1#sepolia-testnet
        "ETH-USD"  => Some("0x694AA1769357215DE4FAC081bf1f309aDC325306"),
        "BTC-USD"  => Some("0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43"),
        "LINK-USD" => Some("0xc59E3633BAAC79493d908e63626716e204A45EdF"),
        "USDC-USD" => Some("0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E"),
        "EUR-USD"  => Some("0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910"),
        _ => None,
    }
}

/// Public Sepolia RPC endpoint for Chainlink eth_call.
pub const SEPOLIA_RPC: &str = "https://ethereum-sepolia-rpc.publicnode.com";

// ── PriceOracle ─────────────────────────────────────────────────────────────

/// External oracle adapter. Async HTTP fetcher with per-pair LRU cache (30s).
pub struct PriceOracle {
    cache: RwLock<HashMap<u64, (u128, i64)>>, // pair_id → (price_micro_usd, ts_ms)
    stale_ms: u64,
    http: reqwest::Client,
    /// Optional internal-trade callback — if set and returns Some, used as
    /// the highest-priority price source (matches CLAUDE.md "1. Trade intern").
    internal_trade: Option<Box<dyn Fn(u64) -> Option<u128> + Send + Sync>>,
}

impl Default for PriceOracle {
    fn default() -> Self {
        Self::new(CACHE_TTL_MS as u64)
    }
}

impl std::fmt::Debug for PriceOracle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PriceOracle").field("stale_ms", &self.stale_ms).finish()
    }
}

impl PriceOracle {
    pub fn new(stale_ms: u64) -> Self {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_millis(UPSTREAM_TIMEOUT_MS))
            .user_agent("omnibus-node-rust/0.0.1")
            .build()
            .expect("reqwest client");
        Self {
            cache: RwLock::new(HashMap::new()),
            stale_ms,
            http,
            internal_trade: None,
        }
    }

    /// Install an internal-trade lookup. Returning `Some(price)` short-circuits
    /// upstream HTTP fetches.
    pub fn set_internal_trade<F>(&mut self, f: F)
    where
        F: Fn(u64) -> Option<u128> + Send + Sync + 'static,
    {
        self.internal_trade = Some(Box::new(f));
    }

    /// Synchronous accessor for cached values (used by sync code paths).
    pub fn fetch(&self, pair_id: u64, now_ms: i64) -> Result<u128, OracleError> {
        let cache = self.cache.try_read().map_err(|_| {
            OracleError::Upstream("cache lock contended".into())
        })?;
        if let Some(&(price, ts)) = cache.get(&pair_id) {
            if (now_ms - ts) as u64 <= self.stale_ms {
                return Ok(price);
            }
            return Err(OracleError::Stale(self.stale_ms));
        }
        if default_feeds(pair_id).is_empty() {
            return Err(OracleError::NoSource(pair_id));
        }
        Err(OracleError::Upstream("cache miss — call fetch_with_fallback".into()))
    }

    /// Test/manual override — injects a price into the cache.
    pub fn set_for_test(&self, pair_id: u64, price_micro_usd: u128, ts_ms: i64) {
        // try_write OK in tests; in prod use prime_cache.
        let mut g = self.cache.try_write().expect("uncontended write in test");
        g.insert(pair_id, (price_micro_usd, ts_ms));
    }

    /// Async cache primer.
    pub async fn prime_cache(&self, pair_id: u64, price: u128, ts_ms: i64) {
        self.cache.write().await.insert(pair_id, (price, ts_ms));
    }

    /// Async fetch with full fallback chain:
    ///   1. internal-trade callback (if installed)
    ///   2. cached value, if fresh
    ///   3. provider order from `default_feeds()`
    ///   4. synthetic, for pairs 4/5/6
    pub async fn fetch_with_fallback(&self, pair_id: u64) -> Result<u128, OracleError> {
        let now = now_ms();
        // 1. Internal trade.
        if let Some(f) = &self.internal_trade {
            if let Some(p) = f(pair_id) {
                self.prime_cache(pair_id, p, now).await;
                return Ok(p);
            }
        }
        // 2. Fresh cache.
        {
            let g = self.cache.read().await;
            if let Some(&(p, ts)) = g.get(&pair_id) {
                if (now - ts) as u64 <= self.stale_ms {
                    return Ok(p);
                }
            }
        }
        let feeds = default_feeds(pair_id);
        if feeds.is_empty() {
            return Err(OracleError::NoSource(pair_id));
        }
        // 3. Walk providers in order.
        let mut last_err: Option<OracleError> = None;
        for feed in feeds {
            let res = match feed.provider {
                "chainlink" => self.fetch_chainlink_pair(feed.url).await,
                "pyth" => self.fetch_pyth_url(feed.url).await,
                "coingecko" => self.fetch_coingecko_url(feed.url).await,
                "synthetic" => self.fetch_synthetic(pair_id).await,
                other => Err(OracleError::Upstream(format!("unknown provider {other}"))),
            };
            match res {
                Ok(p) => {
                    self.prime_cache(pair_id, p, now).await;
                    return Ok(p);
                }
                Err(e) => {
                    tracing::debug!(provider = %feed.provider, error = %e, "oracle upstream failed");
                    last_err = Some(e);
                }
            }
        }
        Err(last_err.unwrap_or_else(|| OracleError::Upstream("all providers failed".into())))
    }

    // ── Per-provider fetchers ──────────────────────────────────────────────

    /// Fetch a Chainlink feed by **pair_id**, mapping to a known feed key.
    /// Public entry-point per spec — picks the canonical feed for the pair.
    pub async fn fetch_chainlink(&self, pair_id: u64) -> Result<u128, OracleError> {
        let pair = match pair_id {
            1 => "BTC-USD",
            3 => "ETH-USD",
            _ => return Err(OracleError::NoSource(pair_id)),
        };
        self.fetch_chainlink_pair(pair).await
    }

    /// Chainlink eth_call to AggregatorV3Interface.latestRoundData().
    /// `pair` matches one of the keys in [`chainlink_address`].
    async fn fetch_chainlink_pair(&self, pair: &str) -> Result<u128, OracleError> {
        let addr = chainlink_address(pair)
            .ok_or_else(|| OracleError::Upstream(format!("no chainlink address for {pair}")))?;
        // Selector for latestRoundData() = keccak("latestRoundData()")[..4] = 0xfeaf968c
        let body = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_call",
            "params": [{
                "to": addr,
                "data": "0xfeaf968c"
            }, "latest"]
        });
        let resp = self
            .http
            .post(SEPOLIA_RPC)
            .json(&body)
            .send()
            .await
            .map_err(|e| OracleError::Upstream(format!("chainlink http: {e}")))?;
        let v: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| OracleError::Upstream(format!("chainlink json: {e}")))?;
        let result = v
            .get("result")
            .and_then(|x| x.as_str())
            .ok_or_else(|| OracleError::Upstream(format!("chainlink no result: {v}")))?;
        // Strip 0x; decode 5×32 byte tuple.
        let hex_s = result.strip_prefix("0x").unwrap_or(result);
        let bytes = hex::decode(hex_s)
            .map_err(|e| OracleError::Upstream(format!("chainlink hex: {e}")))?;
        if bytes.len() < 64 {
            return Err(OracleError::Upstream("chainlink short result".into()));
        }
        // `answer` is words[1] — int256 big-endian.
        let answer_bytes = &bytes[32..64];
        // Treat as unsigned (USD price feeds are always positive).
        let mut answer: u128 = 0;
        for &b in answer_bytes {
            answer = (answer << 8) | b as u128;
        }
        // Chainlink USD feeds use 8 decimals → scale to PRICE_SCALE (1e6).
        // result_micro_usd = answer / 100.
        let micro = answer / 100;
        Ok(micro)
    }

    /// Pyth Hermes — parse latest price/expo from JSON.
    pub async fn fetch_pyth(&self, pair_id: u64) -> Result<u128, OracleError> {
        let url = match pair_id {
            3 => "https://hermes.pyth.network/v2/updates/price/latest?ids[]=0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
            1 => "https://hermes.pyth.network/v2/updates/price/latest?ids[]=0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
            _ => return Err(OracleError::NoSource(pair_id)),
        };
        self.fetch_pyth_url(url).await
    }

    async fn fetch_pyth_url(&self, url: &str) -> Result<u128, OracleError> {
        let resp = self
            .http
            .get(url)
            .send()
            .await
            .map_err(|e| OracleError::Upstream(format!("pyth http: {e}")))?;
        let v: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| OracleError::Upstream(format!("pyth json: {e}")))?;
        // Hermes v2: { parsed: [ { price: { price: "N", expo: -E, ... } } ] }
        let parsed = v
            .get("parsed")
            .and_then(|p| p.as_array())
            .and_then(|a| a.first())
            .ok_or_else(|| OracleError::Upstream("pyth no parsed[0]".into()))?;
        let price_obj = parsed
            .get("price")
            .ok_or_else(|| OracleError::Upstream("pyth no price".into()))?;
        let price_str = price_obj
            .get("price")
            .and_then(|x| x.as_str())
            .ok_or_else(|| OracleError::Upstream("pyth no price.price".into()))?;
        let expo: i64 = price_obj
            .get("expo")
            .and_then(|x| x.as_i64())
            .ok_or_else(|| OracleError::Upstream("pyth no expo".into()))?;
        let raw: i128 = price_str
            .parse()
            .map_err(|e| OracleError::Upstream(format!("pyth parse: {e}")))?;
        let raw = raw.max(0) as u128;
        // Result = raw * 10^expo USD; we want micro-USD = raw * 10^(expo+6).
        let shift: i64 = expo + 6;
        let micro = if shift >= 0 {
            raw.checked_mul(10u128.pow(shift as u32))
                .ok_or_else(|| OracleError::Upstream("pyth overflow".into()))?
        } else {
            raw / 10u128.pow((-shift) as u32)
        };
        Ok(micro)
    }

    /// CoinGecko simple/price — `ids=<id>&vs_currencies=usd`.
    pub async fn fetch_coingecko(&self, pair_id: u64) -> Result<u128, OracleError> {
        let url = match pair_id {
            0 => "https://api.coingecko.com/api/v3/simple/price?ids=omnibus&vs_currencies=usd",
            2 => "https://api.coingecko.com/api/v3/simple/price?ids=lcx&vs_currencies=usd",
            3 => "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd",
            1 => "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd",
            _ => return Err(OracleError::NoSource(pair_id)),
        };
        self.fetch_coingecko_url(url).await
    }

    async fn fetch_coingecko_url(&self, url: &str) -> Result<u128, OracleError> {
        let resp = self
            .http
            .get(url)
            .send()
            .await
            .map_err(|e| OracleError::Upstream(format!("coingecko http: {e}")))?;
        let v: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| OracleError::Upstream(format!("coingecko json: {e}")))?;
        // { "<id>": { "usd": 1234.5 } } — pick the first value blindly.
        let obj = v
            .as_object()
            .and_then(|m| m.values().next())
            .ok_or_else(|| OracleError::Upstream("coingecko empty body".into()))?;
        let usd = obj
            .get("usd")
            .and_then(|x| x.as_f64())
            .ok_or_else(|| OracleError::Upstream("coingecko no usd field".into()))?;
        if usd.is_sign_negative() || !usd.is_finite() {
            return Err(OracleError::Upstream(format!("coingecko bad usd {usd}")));
        }
        let micro = (usd * PRICE_SCALE as f64) as u128;
        Ok(micro)
    }

    /// Synthetic pair = base/USDC ÷ quote/USDC. Used for pairs 4/5/6.
    pub async fn fetch_synthetic(&self, pair_id: u64) -> Result<u128, OracleError> {
        let (base_pid, quote_pid) = match pair_id {
            // OMNI/BTC = OMNI/USDC ÷ BTC/USDC
            4 => (0u64, 1u64),
            // OMNI/LCX = OMNI/USDC ÷ LCX/USDC
            5 => (0u64, 2u64),
            // OMNI/ETH = OMNI/USDC ÷ ETH/USDC
            6 => (0u64, 3u64),
            _ => {
                return Err(OracleError::Synthetic(format!(
                    "no synthetic recipe for pair {pair_id}"
                )))
            }
        };
        // Box recursion across the async fn so the future stays Sized.
        let base = Box::pin(self.fetch_with_fallback(base_pid)).await?;
        let quote = Box::pin(self.fetch_with_fallback(quote_pid)).await?;
        if quote == 0 {
            return Err(OracleError::Synthetic("quote leg is zero".into()));
        }
        // Result in micro-USD-of-quote: (base_micro / quote_micro) * PRICE_SCALE.
        let result = base
            .checked_mul(PRICE_SCALE)
            .ok_or_else(|| OracleError::Synthetic("overflow".into()))?
            / quote;
        Ok(result)
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cache_returns_fresh() {
        let o = PriceOracle::new(10_000);
        o.set_for_test(0, 1_500_000, now_ms());
        assert_eq!(o.fetch(0, now_ms()).unwrap(), 1_500_000);
    }

    #[test]
    fn no_source_for_unlisted_pair() {
        let o = PriceOracle::new(1000);
        assert!(matches!(o.fetch(999, 0), Err(OracleError::NoSource(999))));
    }

    #[test]
    fn default_feeds_present_for_listed_pairs() {
        for &pid in &[0u64, 1, 2, 3, 4, 5, 6] {
            assert!(!default_feeds(pid).is_empty(), "missing feed for pair {pid}");
        }
    }

    #[test]
    fn chainlink_addresses_resolve() {
        for k in &["ETH-USD", "BTC-USD", "LINK-USD", "USDC-USD", "EUR-USD"] {
            assert!(chainlink_address(k).is_some(), "missing addr for {k}");
        }
    }

    #[tokio::test]
    async fn synthetic_uses_primed_legs() {
        let o = PriceOracle::new(60_000);
        // OMNI/USDC = $0.10 → 100_000 micro
        o.prime_cache(0, 100_000, now_ms()).await;
        // LCX/USDC = $0.05 → 50_000 micro
        o.prime_cache(2, 50_000, now_ms()).await;
        // synthetic OMNI/LCX = 0.10 / 0.05 = 2.0 → 2_000_000 micro
        let r = o.fetch_synthetic(5).await.expect("synthetic ok");
        assert_eq!(r, 2_000_000);
    }

    #[tokio::test]
    async fn internal_trade_short_circuits() {
        let mut o = PriceOracle::new(60_000);
        o.set_internal_trade(|pid| if pid == 0 { Some(123_456) } else { None });
        let r = o.fetch_with_fallback(0).await.unwrap();
        assert_eq!(r, 123_456);
    }
}
