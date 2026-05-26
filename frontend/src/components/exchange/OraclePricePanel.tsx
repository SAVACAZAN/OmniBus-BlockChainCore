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

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { rpc } from "../../api/rpc-client";
import { getUnlocked } from "../../api/wallet-keystore";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsOraclePriceEvent, WsOrderbookUpdateEvent } from "../../types";
import { MICRO_PER_USD } from "../../utils/fmt";

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
      // "exchange_orderbook" and "exchange_trades" are snake_case aliases for
      // "exchange_getOrderbook" and "exchange_getTrades" (same handler on backend).
      // We call the canonical camelCase form; aliases are also registered in rpc_server.zig.
      const res = await rpc.request_raw("exchange_getOrderbook", [{ pairId: p.id, depth: 1 }]);
      const bestBid = res?.bestBid ? res.bestBid / MICRO_PER_USD : 0;
      const bestAsk = res?.bestAsk ? res.bestAsk / MICRO_PER_USD : 0;
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

// ── Block Prices Panel ────────────────────────────────────────────────────────

interface BlockPriceEntry {
  exchange: string;
  pair: string;
  bidMicroUsd: number;
  askMicroUsd: number;
  timestampMs: number;
  success: boolean;
}

interface BlockPrices {
  height: number;
  prices: BlockPriceEntry[];
  pricesRoot: string;
  pricesValidated: boolean;
}

function BlockPricesPanel() {
  const [blocks, setBlocks]   = useState<BlockPrices[]>([]);
  const [loading, setLoading] = useState(false);
  const [count, setCount]     = useState("20");
  const [fromHeight, setFromHeight] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const c = Math.min(parseInt(count, 10) || 20, 100);
      const from = fromHeight !== "" ? parseInt(fromHeight, 10) : null;
      if (from !== null && !isNaN(from)) {
        const r = await rpc.request_raw("omnibus_getpricerange", [from, c]);
        if (r && typeof r === "object" && Array.isArray((r as {blocks?: BlockPrices[]}).blocks)) {
          setBlocks((r as {blocks: BlockPrices[]}).blocks.filter((b) => b.prices.length > 0));
        }
      } else {
        // Get current tip height first
        const tipH = await rpc.getBlockCount();
        const startH = Math.max(0, tipH - c);
        const r = await rpc.request_raw("omnibus_getpricerange", [startH, c]);
        if (r && typeof r === "object" && Array.isArray((r as {blocks?: BlockPrices[]}).blocks)) {
          setBlocks((r as {blocks: BlockPrices[]}).blocks.filter((b) => b.prices.length > 0).reverse());
        }
      }
    } catch { /* no blocks */ } finally {
      setLoading(false);
    }
  }, [count, fromHeight]);

  useEffect(() => { load(); }, [load]);

  const pairSummary = useMemo(() => {
    const m: Record<string, { lastBid: number; lastAsk: number; exchange: string; height: number }> = {};
    for (const b of blocks) {
      for (const e of b.prices) {
        if (!e.success || e.bidMicroUsd === 0) continue;
        const key = `${e.exchange}:${e.pair}`;
        if (!m[key] || b.height > m[key].height) {
          m[key] = { lastBid: e.bidMicroUsd, lastAsk: e.askMicroUsd, exchange: e.exchange, height: b.height };
        }
      }
    }
    return m;
  }, [blocks]);

  return (
    <div className="space-y-4">
      {/* Controls */}
      <div className="flex flex-wrap items-center gap-3 rounded-lg border border-mempool-border bg-mempool-bg-elev px-3 py-2.5">
        <div className="flex items-center gap-2">
          <label className="text-[10px] text-mempool-text-dim">From height</label>
          <input
            type="number"
            min="0"
            value={fromHeight}
            onChange={(e) => setFromHeight(e.target.value)}
            placeholder="latest"
            className="w-24 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs font-mono text-mempool-text focus:outline-none focus:border-mempool-blue"
          />
        </div>
        <div className="flex items-center gap-2">
          <label className="text-[10px] text-mempool-text-dim">Count</label>
          <select
            value={count}
            onChange={(e) => setCount(e.target.value)}
            className="bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text focus:outline-none focus:border-mempool-blue"
          >
            {["10", "20", "50", "100"].map((v) => <option key={v} value={v}>{v} blocks</option>)}
          </select>
        </div>
        <button
          onClick={load}
          disabled={loading}
          className="px-3 py-1 rounded text-xs bg-mempool-blue/20 text-mempool-blue hover:bg-mempool-blue/30 disabled:opacity-40"
        >
          {loading ? "Loading…" : "↻ Refresh"}
        </button>
        <span className="text-[9px] text-mempool-text-dim ml-auto">
          Oracle prices committed to blocks · max 100
        </span>
      </div>

      {/* Latest prices summary */}
      {Object.keys(pairSummary).length > 0 && (
        <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-hidden">
          <div className="px-3 py-2 border-b border-mempool-border">
            <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim font-semibold">
              Latest On-Chain Oracle Prices (committed to blocks)
            </span>
          </div>
          <table className="w-full text-[10px] font-mono">
            <thead>
              <tr className="text-[8px] uppercase tracking-wider text-mempool-text-dim border-b border-mempool-border/40">
                <th className="text-left px-3 py-1.5">Exchange</th>
                <th className="text-left px-3 py-1.5">Pair</th>
                <th className="text-right px-3 py-1.5 text-green-400/70">Bid</th>
                <th className="text-right px-3 py-1.5 text-orange-400/70">Ask</th>
                <th className="text-right px-3 py-1.5">At block</th>
              </tr>
            </thead>
            <tbody>
              {Object.entries(pairSummary).map(([key, v]) => {
                const bid = v.lastBid / MICRO_PER_USD;
                const ask = v.lastAsk / MICRO_PER_USD;
                return (
                  <tr key={key} className="border-b border-mempool-border/20 hover:bg-mempool-bg/40">
                    <td className="px-3 py-1.5 text-mempool-text">{v.exchange}</td>
                    <td className="px-3 py-1.5 text-mempool-text-dim">{key.split(":")[1]}</td>
                    <td className="px-3 py-1.5 text-right text-green-400">
                      ${bid >= 1000 ? bid.toLocaleString("en-US", {maximumFractionDigits: 0}) : bid.toFixed(4)}
                    </td>
                    <td className="px-3 py-1.5 text-right text-orange-400">
                      ${ask >= 1000 ? ask.toLocaleString("en-US", {maximumFractionDigits: 0}) : ask.toFixed(4)}
                    </td>
                    <td className="px-3 py-1.5 text-right text-mempool-text-dim">#{v.height}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {/* Block-by-block history */}
      {blocks.length === 0 && !loading && (
        <div className="text-[11px] text-mempool-text-dim text-center py-6">
          No oracle price data found in these blocks. The oracle process must be running to commit prices.
        </div>
      )}
      {blocks.length > 0 && (
        <div className="space-y-1.5 max-h-96 overflow-y-auto pr-1">
          {blocks.map((b) => (
            <div key={b.height} className="rounded border border-mempool-border/40 bg-mempool-bg-elev">
              <div className="flex items-center justify-between px-3 py-1.5 border-b border-mempool-border/20">
                <span className="text-[10px] text-mempool-text font-mono">Block #{b.height}</span>
                <div className="flex items-center gap-2">
                  {b.pricesValidated && (
                    <span className="text-[8px] text-green-400 bg-green-500/10 px-1.5 py-0.5 rounded">✓ validated</span>
                  )}
                  <span className="text-[8px] font-mono text-mempool-text-dim truncate max-w-[80px]">
                    {b.pricesRoot.slice(0, 8)}…
                  </span>
                </div>
              </div>
              <div className="flex flex-wrap gap-2 px-3 py-1.5">
                {b.prices.filter(e => e.success).map((e) => {
                  const bid = e.bidMicroUsd / MICRO_PER_USD;
                  return (
                    <div key={`${e.exchange}${e.pair}`} className="flex items-center gap-1 text-[9px] font-mono">
                      <span className="text-mempool-text-dim">{e.exchange}·{e.pair}</span>
                      <span className="text-green-400">{bid >= 1000 ? bid.toLocaleString("en-US", {maximumFractionDigits: 0}) : bid.toFixed(4)}</span>
                    </div>
                  );
                })}
                {b.prices.every(e => !e.success) && (
                  <span className="text-[9px] text-mempool-text-dim italic">no successful feeds this block</span>
                )}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// ── Oracle Policy Panel ───────────────────────────────────────────────────────

interface OraclePolicy {
  warn_pct: number;
  reject_pct: number;
  fillgap_pct: number;
  enabled: boolean;
}

function OraclePolicyPanel() {
  const [policy, setPolicy]     = useState<OraclePolicy | null>(null);
  const [loading, setLoading]   = useState(true);
  const [saving, setSaving]     = useState(false);
  const [msg, setMsg]           = useState<{ ok: boolean; text: string } | null>(null);

  // Editable form state
  const [warnPct, setWarnPct]       = useState("2.0");
  const [rejectPct, setRejectPct]   = useState("5.0");
  const [fillgapPct, setFillgapPct] = useState("10.0");
  const [enabled, setEnabled]       = useState(true);

  useEffect(() => {
    let cancelled = false;
    rpc.request_raw("omnibus_getoraclepolicy", [])
      .then((r) => {
        if (!cancelled && r && typeof r === "object") {
          const p = r as OraclePolicy;
          setPolicy(p);
          setWarnPct(String(p.warn_pct));
          setRejectPct(String(p.reject_pct));
          setFillgapPct(String(p.fillgap_pct));
          setEnabled(p.enabled);
        }
      })
      .catch(() => {})
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, []);

  const save = async () => {
    setSaving(true);
    setMsg(null);
    try {
      const result = await rpc.request_raw("omnibus_setoraclepolicy", [{
        warn_pct:    parseFloat(warnPct)    || 0,
        reject_pct:  parseFloat(rejectPct)  || 0,
        fillgap_pct: parseFloat(fillgapPct) || 0,
        enabled,
      }]);
      if (result && typeof result === "object") {
        setPolicy(result as OraclePolicy);
        setMsg({ ok: true, text: "Policy updated successfully." });
      }
    } catch (e: unknown) {
      setMsg({ ok: false, text: String(e) });
    } finally {
      setSaving(false);
    }
  };

  const u = getUnlocked();

  return (
    <div className="space-y-4">
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev px-4 py-3">
        <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider mb-1">
          Oracle Price Policy
        </h2>
        <p className="text-[10px] text-mempool-text-dim leading-relaxed">
          Controls how the OmniBus chain reacts to external oracle price feeds.
          <span className="text-yellow-400"> warn_pct</span> — log warning if price deviates more than N%.
          <span className="text-orange-400"> reject_pct</span> — reject TX if price deviates more than N%.
          <span className="text-purple-400"> fillgap_pct</span> — fill price gaps up to N% with last known price.
        </p>
      </div>

      {/* Current policy */}
      {loading ? (
        <div className="text-xs text-mempool-text-dim animate-pulse text-center py-4">Loading policy…</div>
      ) : policy ? (
        <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-hidden">
          <div className="px-3 py-2 border-b border-mempool-border">
            <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim font-semibold">Current Active Policy</span>
          </div>
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 p-3">
            {[
              { label: "Warn %", value: policy.warn_pct.toFixed(4), color: "text-yellow-400" },
              { label: "Reject %", value: policy.reject_pct.toFixed(4), color: "text-orange-400" },
              { label: "FillGap %", value: policy.fillgap_pct.toFixed(4), color: "text-purple-400" },
              { label: "Enabled", value: policy.enabled ? "Yes" : "No", color: policy.enabled ? "text-green-400" : "text-red-400" },
            ].map((item) => (
              <div key={item.label} className="text-center">
                <div className="text-[9px] uppercase tracking-wider text-mempool-text-dim mb-0.5">{item.label}</div>
                <div className={`text-lg font-mono font-bold ${item.color}`}>{item.value}</div>
              </div>
            ))}
          </div>
        </div>
      ) : (
        <div className="text-[11px] text-mempool-text-dim text-center py-3">
          Oracle policy RPC not available on this node.
        </div>
      )}

      {/* Edit form */}
      {!u ? (
        <div className="text-[11px] text-mempool-text-dim text-center py-2">
          Connect a wallet to update the oracle policy (requires founder authority).
        </div>
      ) : (
        <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 space-y-3">
          <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim font-semibold mb-2">
            Update Policy
          </div>
          <div className="grid grid-cols-3 gap-3">
            {[
              { label: "Warn %", value: warnPct, set: setWarnPct, color: "text-yellow-400", placeholder: "2.0" },
              { label: "Reject %", value: rejectPct, set: setRejectPct, color: "text-orange-400", placeholder: "5.0" },
              { label: "FillGap %", value: fillgapPct, set: setFillgapPct, color: "text-purple-400", placeholder: "10.0" },
            ].map(({ label, value, set, color, placeholder }) => (
              <div key={label}>
                <label className={`block text-[10px] mb-1 ${color}`}>{label}</label>
                <input
                  type="number"
                  step="0.1"
                  min="0"
                  value={value}
                  onChange={(e) => set(e.target.value)}
                  placeholder={placeholder}
                  className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text focus:outline-none focus:border-mempool-blue"
                />
              </div>
            ))}
          </div>
          <div className="flex items-center gap-3 pt-1">
            <label className="flex items-center gap-2 text-xs text-mempool-text cursor-pointer select-none">
              <input
                type="checkbox"
                checked={enabled}
                onChange={(e) => setEnabled(e.target.checked)}
                className="accent-mempool-blue"
              />
              Oracle enforcement enabled
            </label>
            <button
              onClick={save}
              disabled={saving}
              className="ml-auto px-4 py-1.5 rounded text-xs bg-mempool-blue hover:bg-blue-600 text-white disabled:opacity-50"
            >
              {saving ? "Saving…" : "Save Policy"}
            </button>
          </div>
          {msg && (
            <div className={`rounded px-3 py-2 text-[11px] ${msg.ok ? "bg-green-500/10 text-green-300 border border-green-500/30" : "bg-red-500/10 text-red-300 border border-red-500/30"}`}>
              {msg.text}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// ── Component ─────────────────────────────────────────────────────────────────

export function OraclePricePanel() {
  const [tab, setTab] = useState<"prices" | "policy" | "blocks" | "cross" | "dex">("prices");
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
    void load();
    if (timerRef.current) clearInterval(timerRef.current);
    // oracle_price fires when node fetches from Chainlink/Pyth — supplement CoinGecko poll.
    const unsub = wsSubscribe<WsOraclePriceEvent>("oracle_price", () => { void load(); });
    timerRef.current = setInterval(() => { void load(); }, 30000); // CoinGecko rate limit fallback
    return () => { if (timerRef.current) clearInterval(timerRef.current); unsub(); };
  }, [load]);

  // Compute arbitrage opportunities
  const arbOpps = useMemo<ArbOpportunity[]>(() => priceRows
    .filter(r => Math.abs(r.spreadPct) >= 0.3 && r.dexUsd > 0 && r.cexUsd > 0)
    .map(r => ({
      pair: `${r.sym}/USD`,
      directionLabel: r.spreadPct > 0 ? `DEX > CEX (+${r.spreadPct.toFixed(2)}%)` : `CEX > DEX (${r.spreadPct.toFixed(2)}%)`,
      spreadPct: r.spreadPct,
      action: r.spreadPct > 0
        ? `Sell ${r.sym} on ${r.dexLabel.split("(")[0].trim()} → Buy ${r.sym} on CEX`
        : `Buy ${r.sym} on ${r.dexLabel.split("(")[0].trim()} → Sell ${r.sym} on CEX`,
      urgency: classifyArb(r.spreadPct),
    })), [priceRows]);

  const urgencyColor = {
    high:   "text-red-400 bg-red-500/10 border-red-500/30",
    medium: "text-yellow-400 bg-yellow-500/10 border-yellow-500/30",
    low:    "text-blue-400 bg-blue-500/10 border-blue-500/30",
  };

  return (
    <div className="space-y-4">

      {/* Tab bar */}
      <div className="flex gap-1 border-b border-mempool-border pb-1 flex-wrap">
        {([
          { id: "prices", label: "📡 Prices & Arbitrage" },
          { id: "blocks", label: "📦 Block Prices" },
          { id: "policy", label: "⚙️ Policy" },
          { id: "cross", label: "🔗 Cross-Chain Heights" },
          { id: "dex", label: "🏛️ DEX Orderbook" },
        ] as const).map((t) => (
          <button
            key={t.id}
            onClick={() => setTab(t.id)}
            className={`px-3 py-1.5 rounded-t text-xs font-semibold transition-colors ${
              tab === t.id
                ? "bg-mempool-blue/20 text-mempool-blue border border-mempool-blue/30"
                : "text-mempool-text-dim hover:text-mempool-text"
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {tab === "policy" && <OraclePolicyPanel />}
      {tab === "blocks" && <BlockPricesPanel />}
      {tab === "cross" && <CrossChainHeightsPanel />}
      {tab === "dex" && <DexOrderbookPanel />}

      {tab === "prices" && (<>

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
          {priceRows.length > 0 && (
            <button
              onClick={() => {
                const rows = [
                  ["asset","cex_usd","dex_usd","dex_pool","spread_pct"].join(","),
                  ...priceRows.map((r) => [
                    r.sym,
                    r.cexUsd > 0 ? r.cexUsd.toFixed(6) : "",
                    r.dexUsd > 0 ? r.dexUsd.toFixed(6) : "",
                    `"${r.dexLabel}"`,
                    r.dexUsd > 0 && r.cexUsd > 0 ? r.spreadPct.toFixed(4) : "",
                  ].join(",")),
                ].join("\n");
                const blob = new Blob([rows], { type: "text/csv" });
                const url = URL.createObjectURL(blob);
                const a = document.createElement("a");
                a.href = url; a.download = "omnibus-oracle-prices.csv";
                a.click(); URL.revokeObjectURL(url);
              }}
              className="px-2 py-1 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue"
            >
              ⬇ CSV
            </button>
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
              {priceRows.map((row) => {
                const spreadColor = Math.abs(row.spreadPct) < 0.3
                  ? "text-mempool-text-dim"
                  : row.spreadPct > 0 ? "text-orange-400" : "text-green-400";
                return (
                  <tr key={row.sym} className="border-b border-mempool-border/20 hover:bg-mempool-bg/40">
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
          {arbOpps.map((arb) => (
            <div key={`${arb.pair}${arb.directionLabel}`} className={`rounded-lg border p-3 ${urgencyColor[arb.urgency]}`}>
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
              {omniDex.map((d) => {
                const spread = d.bestBid > 0 && d.bestAsk > 0
                  ? ((d.bestAsk - d.bestBid) / d.bestBid) * 100
                  : 0;
                return (
                  <tr key={d.pair} className="border-b border-mempool-border/20 hover:bg-mempool-bg/40">
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
        <div className="px-3 py-2 border-b border-mempool-border flex items-center justify-between gap-2 flex-wrap">
          <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim font-semibold">
            OmniBus Oracle (Zig · port 28100)
          </span>
          <div className="flex items-center gap-2 ml-auto">
            <span className={`text-[9px] font-mono px-1.5 py-0.5 rounded ${zigOracle.length > 0 ? "text-green-400 bg-green-500/10" : "text-mempool-text-dim bg-mempool-bg"}`}>
              {zigOracle.length > 0 ? `${zigOracle.length} feeds live` : "offline — start omnibus-oracle on VPS"}
            </span>
            {zigOracle.length > 0 && (
              <button
                onClick={() => {
                  const rows = [
                    ["exchange","pair","bid_usd","ask_usd","age_s"].join(","),
                    ...zigOracle.map((e) => [
                      e.exchange,
                      e.pair,
                      (e.bid / MICRO_PER_USD).toFixed(6),
                      (e.ask / MICRO_PER_USD).toFixed(6),
                      Math.floor((Date.now() - e.timestamp_ms) / 1000),
                    ].join(",")),
                  ].join("\n");
                  const blob = new Blob([rows], { type: "text/csv" });
                  const url = URL.createObjectURL(blob);
                  const a = document.createElement("a");
                  a.href = url; a.download = "omnibus-zig-oracle.csv";
                  a.click(); URL.revokeObjectURL(url);
                }}
                className="px-2 py-0.5 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue"
              >
                ⬇ CSV
              </button>
            )}
          </div>
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
              {zigOracle.map((e) => {
                const bidUsd = e.bid / MICRO_PER_USD;
                const askUsd = e.ask / MICRO_PER_USD;
                const ageSec = Math.floor((Date.now() - e.timestamp_ms) / 1000);
                return (
                  <tr key={`${e.exchange}${e.pair}`} className="border-b border-mempool-border/20 hover:bg-mempool-bg/40">
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

      </>)}

    </div>
  );
}

// ── Cross-chain heights panel (oracle_btcHeight + oracle_ethHeight) ────────

function CrossChainHeightsPanel() {
  const [btcHeight, setBtcHeight] = useState<number | null>(null);
  const [ethHeight, setEthHeight] = useState<number | null>(null);
  const [lastUpdate, setLastUpdate] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      try {
        const [b, e] = await Promise.allSettled([
          rpc.request_raw("oracle_btcHeight", []) as Promise<number | { height: number }>,
          rpc.request_raw("oracle_ethHeight", []) as Promise<number | { height: number }>,
        ]);
        if (cancelled) return;
        if (b.status === "fulfilled") {
          const v = b.value;
          setBtcHeight(typeof v === "number" ? v : (v as { height: number }).height ?? null);
        }
        if (e.status === "fulfilled") {
          const v = e.value;
          setEthHeight(typeof v === "number" ? v : (v as { height: number }).height ?? null);
        }
        setLastUpdate(Date.now());
      } finally {
        if (!cancelled) setLoading(false);
      }
    };
    void refresh();
    const id = setInterval(() => { void refresh(); }, 30_000);
    return () => { cancelled = true; clearInterval(id); };
  }, []);

  return (
    <div className="space-y-4">
      <p className="text-[11px] text-mempool-text-dim">
        Chain heights as observed by the OmniBus oracle node (polled every 30s). Used for
        cross-chain settlement finality checks.
      </p>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div className={`rounded-xl border p-4 space-y-2 ${btcHeight ? "border-orange-500/30 bg-orange-500/5" : "border-mempool-border bg-mempool-bg-elev"}`}>
          <div className="flex items-center gap-2">
            <span className="text-lg">₿</span>
            <h4 className="text-sm font-semibold text-orange-300">Bitcoin (oracle)</h4>
          </div>
          {loading ? (
            <p className="text-[11px] text-mempool-text-dim animate-pulse">Fetching…</p>
          ) : btcHeight !== null ? (
            <div>
              <div className="text-2xl font-mono font-bold text-orange-300">
                #{btcHeight.toLocaleString()}
              </div>
              <div className="text-[10px] text-mempool-text-dim mt-1">
                oracle_btcHeight · updated {lastUpdate ? new Date(lastUpdate).toLocaleTimeString() : "—"}
              </div>
            </div>
          ) : (
            <p className="text-[11px] text-mempool-text-dim">Not available (oracle may be offline).</p>
          )}
        </div>

        <div className={`rounded-xl border p-4 space-y-2 ${ethHeight ? "border-blue-500/30 bg-blue-500/5" : "border-mempool-border bg-mempool-bg-elev"}`}>
          <div className="flex items-center gap-2">
            <span className="text-lg">Ξ</span>
            <h4 className="text-sm font-semibold text-blue-300">Ethereum (oracle)</h4>
          </div>
          {loading ? (
            <p className="text-[11px] text-mempool-text-dim animate-pulse">Fetching…</p>
          ) : ethHeight !== null ? (
            <div>
              <div className="text-2xl font-mono font-bold text-blue-300">
                #{ethHeight.toLocaleString()}
              </div>
              <div className="text-[10px] text-mempool-text-dim mt-1">
                oracle_ethHeight · updated {lastUpdate ? new Date(lastUpdate).toLocaleTimeString() : "—"}
              </div>
            </div>
          ) : (
            <p className="text-[11px] text-mempool-text-dim">Not available (oracle may be offline).</p>
          )}
        </div>
      </div>

      <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev p-4 text-[11px] text-mempool-text-dim space-y-1">
        <p className="font-semibold text-mempool-text text-xs mb-1">How this is used</p>
        <p>BTC height: confirms Bitcoin HTLC finality (≥6 confirmations) before OMNI release.</p>
        <p>ETH height: confirms EVM HTLC finality (≥12 confirmations) for Sepolia/Base settlements.</p>
        <p>The oracle records each height as an on-chain oracle price entry via <code className="font-mono text-purple-400">oracle_recordHeader</code>.</p>
      </div>
    </div>
  );
}

// ── DEX Orderbook panel (omnibus_getorderbook + omnibus_gettotalmined + omnibus_getblockprices) ─

interface DexOrderbookResp {
  bids: [number, number][];
  asks: [number, number][];
  note?: string;
}

interface TotalMinedResp {
  totalMinedSAT: number;
  totalMinedOMNI: string;
  blockHeight: number;
}

interface BlockPricesEntry {
  exchange: string;
  pair: string;
  bidMicroUsd: number;
  askMicroUsd: number;
  success: boolean;
}

interface BlockPricesResult {
  height: number;
  prices: BlockPricesEntry[];
  prices_root: string;
  valid: boolean;
}

function DexOrderbookPanel() {
  const [orderbook, setOrderbook] = useState<DexOrderbookResp | null>(null);
  const [totalMined, setTotalMined] = useState<TotalMinedResp | null>(null);
  const [pair, setPair] = useState("OMNI/USDC");
  const [blockHeight, setBlockHeight] = useState("");
  const [blockPrices, setBlockPrices] = useState<BlockPricesResult | null>(null);
  const [blockErr, setBlockErr] = useState("");
  const [loadingBlock, setLoadingBlock] = useState(false);

  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      const [ob, tm] = await Promise.allSettled([
        rpc.request_raw("omnibus_getorderbook", [{ pair }]) as Promise<DexOrderbookResp>,
        rpc.getTotalMined() as Promise<TotalMinedResp>,
      ]);
      if (cancelled) return;
      if (ob.status === "fulfilled") setOrderbook(ob.value);
      if (tm.status === "fulfilled") setTotalMined(tm.value);
    };
    void refresh();
    const unsub = wsSubscribe<WsOrderbookUpdateEvent>("orderbook_update", (ev) => {
      if (ev.pair === pair) void refresh();
    });
    const id = setInterval(() => { void refresh(); }, 30_000);
    return () => { cancelled = true; clearInterval(id); unsub(); };
  }, [pair]);

  const lookupBlockPrices = async () => {
    const h = parseInt(blockHeight, 10);
    if (isNaN(h) || h < 0) { setBlockErr("Enter a valid block height"); return; }
    setLoadingBlock(true);
    setBlockErr("");
    setBlockPrices(null);
    try {
      const r = await rpc.request_raw("omnibus_getblockprices", [h]) as BlockPricesResult;
      if (r && typeof r === "object" && "prices" in r) setBlockPrices(r);
      else setBlockErr("Block not found or no prices");
    } catch (e) {
      setBlockErr(String(e));
    } finally {
      setLoadingBlock(false);
    }
  };

  return (
    <div className="space-y-5">
      {/* Total mined */}
      {totalMined && (
        <div className="rounded-xl border border-purple-500/30 bg-purple-500/5 p-4">
          <h3 className="text-xs font-semibold text-purple-300 mb-2 uppercase tracking-wider">
            Total Mined (omnibus_gettotalmined)
          </h3>
          <div className="grid grid-cols-3 gap-3 text-xs">
            {[
              ["Block Height", String(totalMined.blockHeight)],
              ["Total OMNI", totalMined.totalMinedOMNI],
              ["Total SAT_PER_OMNI", totalMined.totalMinedSAT.toLocaleString()],
            ].map(([k, v]) => (
              <div key={k} className="bg-mempool-bg/50 rounded p-2">
                <div className="text-[9px] uppercase text-mempool-text-dim">{k}</div>
                <div className="font-mono text-purple-300 mt-0.5">{v}</div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Orderbook */}
      <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev p-4 space-y-3">
        <div className="flex items-center gap-3 flex-wrap">
          <h3 className="text-xs font-semibold text-mempool-text-dim uppercase tracking-wider">
            DEX Orderbook (omnibus_getorderbook)
          </h3>
          <select
            value={pair}
            onChange={(e) => setPair(e.target.value)}
            className="bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text"
          >
            {["OMNI/USDC", "LCX/USDC", "ETH/USDC", "OMNI/LCX", "OMNI/ETH"].map((p) => (
              <option key={p} value={p}>{p}</option>
            ))}
          </select>
        </div>
        {orderbook?.note && (
          <p className="text-[11px] text-mempool-text-dim italic">{orderbook.note}</p>
        )}
        <div className="grid grid-cols-2 gap-4 text-xs">
          <div>
            <div className="text-[9px] text-green-400 uppercase font-semibold mb-1">Bids</div>
            {orderbook?.bids?.length ? (
              <table className="w-full">
                <thead className="text-[9px] text-mempool-text-dim">
                  <tr><th className="text-left">Price</th><th className="text-right">Qty</th></tr>
                </thead>
                <tbody>
                  {orderbook.bids.slice(0, 8).map(([p, q]) => (
                    <tr key={p} className="font-mono text-green-400">
                      <td>{p}</td><td className="text-right">{q}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : (
              <p className="text-mempool-text-dim text-[11px]">No bids (P2P matching active)</p>
            )}
          </div>
          <div>
            <div className="text-[9px] text-red-400 uppercase font-semibold mb-1">Asks</div>
            {orderbook?.asks?.length ? (
              <table className="w-full">
                <thead className="text-[9px] text-mempool-text-dim">
                  <tr><th className="text-left">Price</th><th className="text-right">Qty</th></tr>
                </thead>
                <tbody>
                  {orderbook.asks.slice(0, 8).map(([p, q]) => (
                    <tr key={p} className="font-mono text-red-400">
                      <td>{p}</td><td className="text-right">{q}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : (
              <p className="text-mempool-text-dim text-[11px]">No asks (P2P matching active)</p>
            )}
          </div>
        </div>
      </div>

      {/* Block prices lookup */}
      <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev p-4 space-y-3">
        <h3 className="text-xs font-semibold text-mempool-text-dim uppercase tracking-wider">
          Block Oracle Prices (omnibus_getblockprices)
        </h3>
        <div className="flex gap-2">
          <input
            type="number"
            min="0"
            value={blockHeight}
            onChange={(e) => setBlockHeight(e.target.value)}
            placeholder="Block height"
            className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-1.5 text-xs font-mono text-mempool-text"
          />
          <button
            onClick={lookupBlockPrices}
            disabled={loadingBlock || !blockHeight}
            className="px-4 py-1.5 text-xs font-medium bg-mempool-blue/20 hover:bg-mempool-blue/40 text-mempool-blue border border-mempool-blue/30 rounded disabled:opacity-50"
          >
            {loadingBlock ? "…" : "Lookup"}
          </button>
        </div>
        {blockErr && <p className="text-xs text-red-400">{blockErr}</p>}
        {blockPrices && (
          <div className="space-y-1">
            <div className="flex items-center gap-2 text-[11px] text-mempool-text-dim">
              <span>Block #{blockPrices.height}</span>
              <span className="font-mono text-[9px]">{blockPrices.prices_root?.slice(0, 16)}…</span>
              <span className={blockPrices.valid ? "text-green-400" : "text-red-400"}>
                {blockPrices.valid ? "✓ valid" : "✗ invalid"}
              </span>
            </div>
            {blockPrices.prices.length === 0 ? (
              <p className="text-xs text-mempool-text-dim">No oracle prices in this block.</p>
            ) : (
              <table className="w-full text-xs">
                <thead className="text-[9px] text-mempool-text-dim uppercase">
                  <tr>
                    <th className="text-left py-1">Exchange</th>
                    <th className="text-left">Pair</th>
                    <th className="text-right">Bid (µUSD)</th>
                    <th className="text-right">Ask (µUSD)</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-mempool-border/20">
                  {blockPrices.prices.map((e) => (
                    <tr key={`${e.exchange}${e.pair}`} className={e.success ? "" : "opacity-40"}>
                      <td className="py-0.5 font-mono text-mempool-text-dim">{e.exchange}</td>
                      <td className="font-mono text-mempool-blue">{e.pair}</td>
                      <td className="text-right font-mono text-green-400">{e.bidMicroUsd}</td>
                      <td className="text-right font-mono text-red-400">{e.askMicroUsd}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
