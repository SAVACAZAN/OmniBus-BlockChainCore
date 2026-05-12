/**
 * OraclePricePanel — Live price oracle + arbitrage opportunities
 *
 * Data sources:
 *   CEX: CoinGecko public API (no key) — ETH, BTC, LCX, OMNI
 *   DEX: Uniswap V3 on-chain RPC — ETH/USDC (Mainnet), BTC/ETH, LCX/ETH
 *   OmniBus chain: exchange_getStats / oracle_btcHeight (existing RPCs)
 *
 * Arbitrage = (DEX price - CEX price) / CEX price × 100%
 *   positive → DEX is more expensive → sell on DEX, buy on CEX
 *   negative → CEX is more expensive → buy on DEX, sell on CEX
 */

import { useCallback, useEffect, useRef, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";

const rpc = new OmniBusRpcClient();

// omnibus-oracle is a separate process on port 28100.
// On VPS, nginx proxies /oracle → http://127.0.0.1:28100
// Locally the oracle may not be running — getZigOraclePrices() handles that gracefully.
function zigOracleUrl(): string {
  const base = window.location.origin;
  // If we're on the VPS (omnibusblockchain.cc), use the nginx proxy path.
  // Locally (localhost) try port 28100 directly.
  if (base.includes("localhost") || base.includes("127.0.0.1")) {
    return "http://127.0.0.1:28100";
  }
  return base + "/oracle";
}

interface ZigOracleEntry {
  exchange: string;
  pair: string;
  bid: number;
  ask: number;
  timestamp_ms: number;
  success: boolean;
}

async function getZigOraclePrices(): Promise<ZigOracleEntry[]> {
  try {
    const url = zigOracleUrl();
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "oracle_getSnapshot", params: [] }),
      signal: AbortSignal.timeout(4000),
    });
    const j = await res.json();
    if (!Array.isArray(j.result)) return [];
    return j.result.filter((e: ZigOracleEntry) => e.success && e.bid > 0);
  } catch {
    return [];
  }
}

// ── CoinGecko public API ──────────────────────────────────────────────────────

const COINGECKO_IDS: Record<string, string> = {
  ETH:  "ethereum",
  BTC:  "bitcoin",
  LCX:  "lcx",
  SOL:  "solana",
  XRP:  "ripple",
  OMNI: "omnibuschain", // may not exist — fallback to 0
};

async function fetchCexPrices(): Promise<Record<string, number>> {
  const ids = Object.values(COINGECKO_IDS).join(",");
  try {
    const res = await fetch(
      `https://api.coingecko.com/api/v3/simple/price?ids=${ids}&vs_currencies=usd`,
      { signal: AbortSignal.timeout(8000) }
    );
    const json = await res.json();
    const out: Record<string, number> = {};
    for (const [sym, id] of Object.entries(COINGECKO_IDS)) {
      out[sym] = json[id]?.usd ?? 0;
    }
    return out;
  } catch {
    return {};
  }
}

// ── Uniswap V3 on-chain prices (same logic as AmmOrderbookPanel) ─────────────

const ETH_RPC = "https://eth.drpc.org";
const ETH_RPC_FB = ["https://eth.llamarpc.com", "https://1rpc.io/eth", "https://ethereum.publicnode.com"];

async function ethCallOne(rpc_url: string, to: string, data: string): Promise<string> {
  const resp = await fetch(rpc_url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to, data }, "latest"] }),
    signal: AbortSignal.timeout(6000),
  });
  const text = await resp.text();
  const j = JSON.parse(text);
  if (j.error || !j.result || j.result === "0x") throw new Error("empty");
  return j.result as string;
}

async function ethCall(to: string, data: string): Promise<string> {
  for (const url of [ETH_RPC, ...ETH_RPC_FB]) {
    try { return await ethCallOne(url, to, data); } catch { /* try next */ }
  }
  throw new Error("all RPCs failed");
}

async function fetchV3Price(pool: string, token0Dec: number, token1Dec: number, showToken0Price: boolean): Promise<number> {
  const raw = await ethCall(pool, "0x3850c7bd");
  const hex = raw.slice(2);
  const sqrtPriceX96 = BigInt("0x" + hex.slice(0, 64));
  if (sqrtPriceX96 === 0n) throw new Error("not initialised");
  const Q96 = 2 ** 96;
  const sqrtRatio = Number(sqrtPriceX96) / Q96;
  const rawRatio = sqrtRatio * sqrtRatio;
  const decAdj = Math.pow(10, token0Dec - token1Dec);
  const p1in0 = rawRatio * decAdj;
  return showToken0Price ? p1in0 : 1 / p1in0;
}

async function fetchV2Price(pool: string, token0Dec: number, token1Dec: number, showToken0Price: boolean): Promise<number> {
  const raw = await ethCall(pool, "0x0902f1ac");
  const hex = raw.slice(2);
  const r0 = Number(BigInt("0x" + hex.slice(0, 64))) / Math.pow(10, token0Dec);
  const r1 = Number(BigInt("0x" + hex.slice(64, 128))) / Math.pow(10, token1Dec);
  return showToken0Price ? r1 / r0 : r0 / r1;
}

interface DexSource {
  sym: string;         // e.g. "ETH", "BTC", "LCX"
  label: string;       // display label for pool
  fetch: () => Promise<number>;
  ethQuoted?: boolean; // if true, result is ETH price, need × ethUsd to get USD
}

const DEX_SOURCES: DexSource[] = [
  {
    sym: "ETH",
    label: "ETH/USDC 0.05% (V3 Mainnet)",
    fetch: () => fetchV3Price("0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640", 6, 18, false),
  },
  {
    sym: "BTC",
    label: "BTC/ETH 0.3% (V3 Mainnet)",
    fetch: () => fetchV3Price("0xCBCdF9626bC03E24f779434178A73a0B4bad62eD", 8, 18, true),
    ethQuoted: true,
  },
  {
    sym: "LCX",
    label: "LCX/ETH 1% (V3 Mainnet)",
    fetch: () => fetchV3Price("0x5aaa28ca43c6646fd1403e508f0fca1d92357dde", 18, 18, true),
    ethQuoted: true,
  },
  {
    sym: "LCX",
    label: "LCX/USDC 0.3% (V3 Mainnet)",
    fetch: () => fetchV3Price("0xf152f10e4781c0d3844310193a2050384a5581f2", 18, 6, true),
  },
  {
    sym: "LCX",
    label: "LCX/ETH V2 (Mainnet)",
    fetch: () => fetchV2Price("0xfcb910d871d7e94f5a566b7b32fb2b19583c09d7", 18, 18, true),
    ethQuoted: true,
  },
];

// ── OmniBus DEX price from orderbook best bid/ask ─────────────────────────────

interface OmniDexPrice {
  pair: string;
  bestBid: number;
  bestAsk: number;
  midPrice: number;
}

async function fetchOmniDexPrices(): Promise<OmniDexPrice[]> {
  const pairs = [
    { id: 0,  label: "OMNI/USDC" },
    { id: 2,  label: "LCX/USDC"  },
    { id: 3,  label: "ETH/USDC"  },
    { id: 5,  label: "OMNI/LCX"  },
    { id: 6,  label: "OMNI/ETH"  },
  ];
  const out: OmniDexPrice[] = [];
  for (const p of pairs) {
    try {
      const res = await rpc.request_raw("exchange_getOrderbook", [{ pairId: p.id, depth: 1 }]);
      const bestBid = res?.bestBid ? res.bestBid / 1_000_000 : 0;
      const bestAsk = res?.bestAsk ? res.bestAsk / 1_000_000 : 0;
      if (bestBid > 0 || bestAsk > 0) {
        out.push({
          pair: p.label,
          bestBid,
          bestAsk,
          midPrice: bestBid > 0 && bestAsk > 0 ? (bestBid + bestAsk) / 2 : bestBid || bestAsk,
        });
      }
    } catch { /* ignore empty pairs */ }
  }
  return out;
}

// ── Types ─────────────────────────────────────────────────────────────────────

interface PriceRow {
  sym: string;
  cexUsd: number;
  dexUsd: number;
  dexLabel: string;
  spreadPct: number; // (dex-cex)/cex × 100
}

interface ArbOpportunity {
  pair: string;
  directionLabel: string;
  spreadPct: number;
  action: string;
  urgency: "high" | "medium" | "low";
}

function classifyArb(spreadPct: number): ArbOpportunity["urgency"] {
  const abs = Math.abs(spreadPct);
  if (abs >= 2) return "high";
  if (abs >= 0.5) return "medium";
  return "low";
}

// ── Component ─────────────────────────────────────────────────────────────────

export function OraclePricePanel() {
  const [cexPrices, setCexPrices]     = useState<Record<string, number>>({});
  const [priceRows, setPriceRows]     = useState<PriceRow[]>([]);
  const [omniDex, setOmniDex]         = useState<OmniDexPrice[]>([]);
  const [zigOracle, setZigOracle]     = useState<ZigOracleEntry[]>([]);
  const [ethUsd, setEthUsd]           = useState<number>(0);
  const [loading, setLoading]         = useState(false);
  const [updatedAt, setUpdatedAt]     = useState<Date | null>(null);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      // Fetch everything in parallel
      const [cex, omniPrices, zigPrices] = await Promise.all([
        fetchCexPrices(),
        fetchOmniDexPrices(),
        getZigOraclePrices(),
      ]);
      setCexPrices(cex);
      setOmniDex(omniPrices);
      setZigOracle(zigPrices);

      // Fetch DEX prices with ETH/USD first
      const ethDex = await fetchV3Price("0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640", 6, 18, false).catch(() => 0);
      const ethRef = ethDex > 0 ? ethDex : (cex["ETH"] ?? 0);
      setEthUsd(ethRef);

      // Build price rows from all DEX sources
      const rowMap: Record<string, PriceRow> = {};
      await Promise.allSettled(
        DEX_SOURCES.map(async (src) => {
          try {
            let dexRaw = await src.fetch();
            if (src.ethQuoted && ethRef > 0) dexRaw = dexRaw * ethRef;
            const cexUsd = cex[src.sym] ?? 0;
            const spread = cexUsd > 0 ? ((dexRaw - cexUsd) / cexUsd) * 100 : 0;
            const key = `${src.sym}:${src.label}`;
            rowMap[key] = {
              sym: src.sym,
              cexUsd,
              dexUsd: dexRaw,
              dexLabel: src.label,
              spreadPct: spread,
            };
          } catch { /* pool unavailable */ }
        })
      );

      setPriceRows(Object.values(rowMap).sort((a, b) => Math.abs(b.spreadPct) - Math.abs(a.spreadPct)));
      setUpdatedAt(new Date());
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
    if (timerRef.current) clearInterval(timerRef.current);
    timerRef.current = setInterval(load, 30000); // refresh every 30s (CoinGecko rate limit)
    return () => { if (timerRef.current) clearInterval(timerRef.current); };
  }, [load]);

  // Compute arbitrage opportunities
  const arbOpps: ArbOpportunity[] = priceRows
    .filter(r => Math.abs(r.spreadPct) >= 0.3 && r.dexUsd > 0 && r.cexUsd > 0)
    .map(r => ({
      pair: `${r.sym}/USD`,
      directionLabel: r.spreadPct > 0 ? `DEX > CEX (+${r.spreadPct.toFixed(2)}%)` : `CEX > DEX (${r.spreadPct.toFixed(2)}%)`,
      spreadPct: r.spreadPct,
      action: r.spreadPct > 0
        ? `Sell ${r.sym} on ${r.dexLabel.split("(")[0].trim()} → Buy ${r.sym} on CEX`
        : `Buy ${r.sym} on ${r.dexLabel.split("(")[0].trim()} → Sell ${r.sym} on CEX`,
      urgency: classifyArb(r.spreadPct),
    }));

  const urgencyColor = {
    high:   "text-red-400 bg-red-500/10 border-red-500/30",
    medium: "text-yellow-400 bg-yellow-500/10 border-yellow-500/30",
    low:    "text-blue-400 bg-blue-500/10 border-blue-500/30",
  };

  return (
    <div className="space-y-4">

      {/* Header */}
      <div className="flex items-center justify-between rounded-lg border border-mempool-border bg-mempool-bg-elev px-4 py-2.5">
        <div>
          <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
            📡 Oracle Prices + Arbitrage
          </h2>
          <p className="text-[10px] text-mempool-text-dim mt-0.5">
            CEX via CoinGecko · DEX via Uniswap on-chain · OmniBus DEX live orderbook · refreshes every 30s
          </p>
        </div>
        <div className="flex items-center gap-2">
          {updatedAt && (
            <span className="text-[9px] text-mempool-text-dim font-mono">
              {updatedAt.toLocaleTimeString()}
            </span>
          )}
          <button
            onClick={load}
            disabled={loading}
            className="px-2 py-1 text-[10px] rounded bg-mempool-blue/20 text-mempool-blue hover:bg-mempool-blue/30 disabled:opacity-40"
          >
            {loading ? "…" : "↻"}
          </button>
        </div>
      </div>

      {/* ETH reference */}
      {ethUsd > 0 && (
        <div className="text-[9px] text-mempool-text-dim px-1">
          ETH reference: <span className="text-yellow-300 font-mono">${ethUsd.toFixed(2)}</span>
          {cexPrices["ETH"] > 0 && (
            <span className="ml-2">CoinGecko: <span className="text-white font-mono">${cexPrices["ETH"].toFixed(2)}</span></span>
          )}
        </div>
      )}

      {/* CEX prices strip */}
      {Object.keys(cexPrices).length > 0 && (
        <div className="flex flex-wrap gap-2 p-2 rounded-lg bg-mempool-bg border border-mempool-border">
          <span className="text-[9px] text-mempool-text-dim self-center uppercase tracking-wider mr-1">CEX:</span>
          {Object.entries(cexPrices).filter(([, v]) => v > 0).map(([sym, price]) => (
            <div key={sym} className="flex items-center gap-1 px-2 py-0.5 rounded bg-mempool-bg-elev border border-mempool-border/50">
              <span className="text-[10px] font-bold text-mempool-text">{sym}</span>
              <span className="text-[10px] font-mono text-green-400">
                ${price >= 1000 ? price.toLocaleString("en-US", { maximumFractionDigits: 0 })
                  : price >= 1 ? price.toFixed(4)
                  : price.toFixed(6)}
              </span>
            </div>
          ))}
        </div>
      )}

      {/* CEX vs DEX table */}
      {priceRows.length > 0 && (
        <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-hidden">
          <div className="px-3 py-2 border-b border-mempool-border">
            <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim font-semibold">CEX vs DEX Price Comparison</span>
          </div>
          <table className="w-full text-[10px] font-mono">
            <thead>
              <tr className="text-[8px] uppercase tracking-wider text-mempool-text-dim border-b border-mempool-border/40">
                <th className="text-left px-3 py-1.5">Asset</th>
                <th className="text-right px-3 py-1.5">CEX (USD)</th>
                <th className="text-right px-3 py-1.5">DEX (USD)</th>
                <th className="text-left px-3 py-1.5 text-mempool-text-dim/60">Pool</th>
                <th className="text-right px-3 py-1.5">Spread</th>
                <th className="text-left px-2 py-1.5">Signal</th>
              </tr>
            </thead>
            <tbody>
              {priceRows.map((row, i) => {
                const spreadColor = Math.abs(row.spreadPct) < 0.3
                  ? "text-mempool-text-dim"
                  : row.spreadPct > 0 ? "text-orange-400" : "text-green-400";
                return (
                  <tr key={i} className="border-b border-mempool-border/20 hover:bg-mempool-bg/40">
                    <td className="px-3 py-1.5 font-bold text-mempool-text">{row.sym}</td>
                    <td className="px-3 py-1.5 text-right text-white">
                      {row.cexUsd > 0 ? `$${row.cexUsd >= 1000 ? row.cexUsd.toLocaleString("en-US", {maximumFractionDigits: 0}) : row.cexUsd >= 1 ? row.cexUsd.toFixed(4) : row.cexUsd.toFixed(6)}` : "—"}
                    </td>
                    <td className={`px-3 py-1.5 text-right ${row.dexUsd > 0 ? "text-purple-300" : "text-mempool-text-dim"}`}>
                      {row.dexUsd > 0 ? `$${row.dexUsd >= 1000 ? row.dexUsd.toLocaleString("en-US", {maximumFractionDigits: 0}) : row.dexUsd >= 1 ? row.dexUsd.toFixed(4) : row.dexUsd.toFixed(6)}` : "—"}
                    </td>
                    <td className="px-3 py-1.5 text-mempool-text-dim/60 text-[9px] max-w-[120px] truncate">
                      {row.dexLabel.split("(")[0].trim()}
                    </td>
                    <td className={`px-3 py-1.5 text-right font-semibold ${spreadColor}`}>
                      {row.dexUsd > 0 && row.cexUsd > 0
                        ? `${row.spreadPct >= 0 ? "+" : ""}${row.spreadPct.toFixed(3)}%`
                        : "—"}
                    </td>
                    <td className="px-2 py-1.5 text-[8px]">
                      {Math.abs(row.spreadPct) >= 2 && <span className="text-red-400">🔥 HOT</span>}
                      {Math.abs(row.spreadPct) >= 0.5 && Math.abs(row.spreadPct) < 2 && <span className="text-yellow-400">⚡</span>}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {/* Arbitrage opportunities */}
      {arbOpps.length > 0 && (
        <div className="space-y-2">
          <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim font-semibold px-1">
            Arbitrage Opportunities
          </div>
          {arbOpps.map((arb, i) => (
            <div key={i} className={`rounded-lg border p-3 ${urgencyColor[arb.urgency]}`}>
              <div className="flex items-center justify-between mb-1">
                <span className="font-bold text-[11px]">{arb.pair}</span>
                <span className="font-mono text-[11px] font-bold">{arb.directionLabel}</span>
                <span className={`text-[8px] uppercase font-bold px-1.5 py-0.5 rounded border ${urgencyColor[arb.urgency]}`}>
                  {arb.urgency}
                </span>
              </div>
              <div className="text-[9px] opacity-80">{arb.action}</div>
            </div>
          ))}
          {arbOpps.length === 0 && (
            <div className="text-[10px] text-mempool-text-dim text-center py-3">
              No significant arbitrage detected (threshold: ±0.3%)
            </div>
          )}
        </div>
      )}

      {/* OmniBus DEX live orderbook prices */}
      {omniDex.length > 0 && (
        <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-hidden">
          <div className="px-3 py-2 border-b border-mempool-border">
            <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim font-semibold">OmniBus DEX Live Orderbook</span>
          </div>
          <table className="w-full text-[10px] font-mono">
            <thead>
              <tr className="text-[8px] uppercase tracking-wider text-mempool-text-dim border-b border-mempool-border/40">
                <th className="text-left px-3 py-1.5">Pair</th>
                <th className="text-right px-3 py-1.5 text-green-400/70">Best Bid</th>
                <th className="text-right px-3 py-1.5 text-orange-400/70">Best Ask</th>
                <th className="text-right px-3 py-1.5">Mid</th>
                <th className="text-right px-3 py-1.5">Spread</th>
              </tr>
            </thead>
            <tbody>
              {omniDex.map((d, i) => {
                const spread = d.bestBid > 0 && d.bestAsk > 0
                  ? ((d.bestAsk - d.bestBid) / d.bestBid) * 100
                  : 0;
                return (
                  <tr key={i} className="border-b border-mempool-border/20 hover:bg-mempool-bg/40">
                    <td className="px-3 py-1.5 font-bold text-mempool-text">{d.pair}</td>
                    <td className="px-3 py-1.5 text-right text-green-400">{d.bestBid > 0 ? `$${d.bestBid.toFixed(4)}` : "—"}</td>
                    <td className="px-3 py-1.5 text-right text-orange-400">{d.bestAsk > 0 ? `$${d.bestAsk.toFixed(4)}` : "—"}</td>
                    <td className="px-3 py-1.5 text-right text-white">{d.midPrice > 0 ? `$${d.midPrice.toFixed(4)}` : "—"}</td>
                    <td className="px-3 py-1.5 text-right text-mempool-text-dim">{spread > 0 ? `${spread.toFixed(2)}%` : "—"}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {/* OmniBus Oracle — Zig process on port 28100 (Coinbase / Kraken / LCX WS feeds) */}
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-hidden">
        <div className="px-3 py-2 border-b border-mempool-border flex items-center justify-between">
          <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim font-semibold">
            OmniBus Oracle (Zig · port 28100)
          </span>
          <span className={`text-[9px] font-mono px-1.5 py-0.5 rounded ${zigOracle.length > 0 ? "text-green-400 bg-green-500/10" : "text-mempool-text-dim bg-mempool-bg"}`}>
            {zigOracle.length > 0 ? `${zigOracle.length} feeds live` : "offline — start omnibus-oracle on VPS"}
          </span>
        </div>
        {zigOracle.length > 0 ? (
          <table className="w-full text-[10px] font-mono">
            <thead>
              <tr className="text-[8px] uppercase tracking-wider text-mempool-text-dim border-b border-mempool-border/40">
                <th className="text-left px-3 py-1.5">Exchange</th>
                <th className="text-left px-3 py-1.5">Pair</th>
                <th className="text-right px-3 py-1.5 text-green-400/70">Bid (USD)</th>
                <th className="text-right px-3 py-1.5 text-orange-400/70">Ask (USD)</th>
                <th className="text-right px-3 py-1.5">Age</th>
              </tr>
            </thead>
            <tbody>
              {zigOracle.map((e, i) => {
                const bidUsd = e.bid / 1_000_000;
                const askUsd = e.ask / 1_000_000;
                const ageSec = Math.floor((Date.now() - e.timestamp_ms) / 1000);
                return (
                  <tr key={i} className="border-b border-mempool-border/20 hover:bg-mempool-bg/40">
                    <td className="px-3 py-1.5 font-semibold text-mempool-text">{e.exchange}</td>
                    <td className="px-3 py-1.5 text-mempool-text-dim">{e.pair}</td>
                    <td className="px-3 py-1.5 text-right text-green-400">
                      ${bidUsd >= 1000 ? bidUsd.toLocaleString("en-US", {maximumFractionDigits: 0}) : bidUsd.toFixed(4)}
                    </td>
                    <td className="px-3 py-1.5 text-right text-orange-400">
                      ${askUsd >= 1000 ? askUsd.toLocaleString("en-US", {maximumFractionDigits: 0}) : askUsd.toFixed(4)}
                    </td>
                    <td className={`px-3 py-1.5 text-right ${ageSec > 60 ? "text-red-400" : "text-mempool-text-dim"}`}>
                      {ageSec}s ago
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        ) : (
          <div className="px-3 py-4 text-[10px] text-mempool-text-dim space-y-1">
            <div>The <span className="text-yellow-300 font-mono">omnibus-oracle</span> process is not reachable.</div>
            <div className="text-[9px] font-mono bg-mempool-bg rounded p-2 mt-2 space-y-1">
              <div className="text-mempool-text-dim/60"># Build on VPS:</div>
              <div>cd /root/omnibus-blockchain && zig build</div>
              <div className="text-mempool-text-dim/60"># Start oracle:</div>
              <div>./zig-out/bin/omnibus-oracle &amp;</div>
              <div className="text-mempool-text-dim/60"># Or as systemd service:</div>
              <div>systemctl start omnibus-oracle</div>
            </div>
          </div>
        )}
      </div>

      {loading && priceRows.length === 0 && omniDex.length === 0 && (
        <div className="text-center py-8 text-mempool-text-dim text-sm animate-pulse">
          Fetching prices from CoinGecko + Uniswap on-chain…
        </div>
      )}

    </div>
  );
}
