import { useEffect, useMemo, useState } from "react";
import { OmniBusRpcClient } from "../../api/rpc-client";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsOraclePriceEvent } from "../../types";
import { MICRO_PER_USD } from "../../utils/fmt";

const MICRO = MICRO_PER_USD;
// ── Types ─────────────────────────────────────────────────────────────────

interface PriceEntry {
  exchange: string;
  pair: string;
  bidMicroUsd: number;
  askMicroUsd: number;
  timestampMs: number;
  success: boolean;
  stale: boolean;
}

interface AllPricesResponse {
  prices: PriceEntry[];
  count: number;
  lastUpdateMs: number;
}

// Bumped from 1000 → 5000 to cover the full pair_registry (~1006 routes today,
// could grow to ~3000 if exchanges list more shared pairs). Backend caps via
// MAX_TOTAL_PAIRS=5000 in ws_exchange_feed.zig, so 5000 is a safe upper bound.
const PAGE_LIMIT = 5000;
const EXCHANGES = ["Coinbase", "Kraken", "LCX"] as const;
type Exchange = (typeof EXCHANGES)[number];

type SortDir = "asc" | "desc";

// ── Format helpers ────────────────────────────────────────────────────────

function formatUsd(microUsd: number, decimals: number): string {
  const dollars = microUsd / MICRO;
  return dollars.toLocaleString("en-US", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
}

// Pick decimals based on price magnitude — bigger prices get fewer decimals.
function decimalsFor(microUsd: number): number {
  const dollars = Math.abs(microUsd / MICRO);
  if (dollars >= 1000) return 2;
  if (dollars >= 1) return 2;
  if (dollars >= 0.01) return 4;
  return 4;
}

// Resolve the canonical exchange label (case-insensitive match).
function canonicalExchange(name: string): Exchange | null {
  const lower = name.toLowerCase();
  for (const ex of EXCHANGES) {
    if (ex.toLowerCase() === lower) return ex;
  }
  return null;
}

// Stable equivalence — keep parallel with pair_discovery.py / pair_registry.zig.
const USD_STABLES = new Set(["USD", "USDC", "USDT", "DAI", "USDS"]);
const EUR_STABLES = new Set(["EUR", "EURC"]);

// Parse a raw symbol from any exchange into (base, real_quote, bucket).
// Handles both `/` (LCX, Kraken WS v2) and `-` (Coinbase) separators.
// Kraken legacy bases: XBT→BTC, XDG→DOGE.
function splitSymbol(sym: string): { base: string; quote: string; bucket: string } | null {
  const sep = sym.includes("/") ? "/" : sym.includes("-") ? "-" : null;
  if (!sep) return null;
  const idx = sym.indexOf(sep);
  let base = sym.slice(0, idx).toUpperCase();
  const quote = sym.slice(idx + 1).toUpperCase();
  if (!base || !quote) return null;
  // Kraken legacy normalization
  if (base === "XBT") base = "BTC";
  if (base === "XDG") base = "DOGE";
  let qBase = quote;
  if (qBase === "XBT") qBase = "BTC";
  if (qBase === "XDG") qBase = "DOGE";
  let bucket = qBase;
  if (USD_STABLES.has(qBase)) bucket = "USD*";
  else if (EUR_STABLES.has(qBase)) bucket = "EUR*";
  return { base, quote: qBase, bucket };
}

// Compose canonical row key: "<BASE> @ <BUCKET>" (e.g., "1INCH @ USD*").
function rowKey(base: string, bucket: string): string {
  return `${base} @ ${bucket}`;
}

// Bucket display label. USD*/EUR* are canonical (any stable).
function bucketLabel(bucket: string): string {
  return bucket;
}

// Pretty-print currency prefix for a bucket — $ for USD*, € for EUR*, etc.
function bucketSymbol(bucket: string): string {
  if (bucket === "USD*") return "$";
  if (bucket === "EUR*") return "€";
  if (bucket === "GBP") return "£";
  if (bucket === "JPY") return "¥";
  return "";
}

// ── Cell sub-component ────────────────────────────────────────────────────

interface CellEntry {
  bidMicroUsd: number;
  askMicroUsd: number;
  timestampMs: number;
  success: boolean;
  stale: boolean;
  realQuote: string; // e.g., "USD", "USDC", "USDT", "EUR"
  rawPair: string;   // e.g., "1INCH-USD" — for tooltip
}

function PriceCell({ entry, prefix }: { entry: CellEntry | undefined; prefix: string }) {
  if (!entry || !entry.success
      || typeof entry.bidMicroUsd !== "number"
      || typeof entry.askMicroUsd !== "number"
      || (entry.bidMicroUsd === 0 && entry.askMicroUsd === 0)) {
    return <div className="font-mono text-xs">&nbsp;</div>;
  }

  const dimClass = entry.stale ? "opacity-50" : "";
  const askDec = decimalsFor(entry.askMicroUsd);
  const bidDec = decimalsFor(entry.bidMicroUsd);
  // Show real quote (USDC vs USD vs USDT) as a tiny suffix when it differs
  // from the bucket prefix — helps users spot stable mismatches.
  const realQuoteHint = entry.realQuote;

  return (
    <div className={`flex flex-col font-mono text-xs ${dimClass}`} title={`${entry.rawPair} (${realQuoteHint})`}>
      <span className="text-mempool-green">
        {prefix}{formatUsd(entry.bidMicroUsd, bidDec)}
      </span>
      <span className="text-mempool-orange">
        {prefix}{formatUsd(entry.askMicroUsd, askDec)}
      </span>
      <span className="text-[9px] text-mempool-text-dim opacity-60">{realQuoteHint}</span>
    </div>
  );
}

// ── Main component ────────────────────────────────────────────────────────

export default function AllPricesGrid() {
  const rpc = useMemo(() => new OmniBusRpcClient(), []);
  const [prices, setPrices] = useState<PriceEntry[]>([]);
  const [count, setCount] = useState<number>(0);
  const [search, setSearch] = useState<string>("");
  const [sortDir, setSortDir] = useState<SortDir>("asc");
  const [backendReady, setBackendReady] = useState<boolean>(true);
  const [loaded, setLoaded] = useState<boolean>(false);

  useEffect(() => {
    let cancelled = false;

    const fetchAll = async () => {
      try {
        const result = (await rpc.request_raw("omnibus_getallprices", [
          0,
          PAGE_LIMIT,
        ])) as AllPricesResponse | null;
        if (cancelled) return;
        if (result && Array.isArray(result.prices)) {
          setPrices(result.prices);
          setCount(result.count ?? result.prices.length);
          setBackendReady(true);
        } else {
          setPrices([]);
          setCount(0);
        }
        setLoaded(true);
      } catch (e) {
        if (cancelled) return;
        // Any error → treat as backend not ready, don't crash.
        setBackendReady(false);
        setPrices([]);
        setCount(0);
        setLoaded(true);
      }
    };

    fetchAll();
    // oracle_price fires whenever the node gets fresh prices from Chainlink/Pyth.
    // This is the event that should drive price grid updates, not a 3 s timer.
    const unsub = wsSubscribe<WsOraclePriceEvent>("oracle_price", () => {
      void fetchAll();
    });
    // Slow fallback poll (30 s) for when WS is disconnected.
    const id = setInterval(fetchAll, 30_000);

    return () => {
      cancelled = true;
      clearInterval(id);
      unsub();
    };
  }, [rpc]);

  // Pivot prices into a map keyed by `(base, bucket)` — same canonical
  // form used by pair_discovery.py. Same base + same bucket from different
  // exchanges land in the SAME row, so 1INCH-USD on Coinbase and 1INCH/USD
  // on Kraken share a row instead of duplicating.
  type RowMeta = {
    base: string;
    bucket: string;
    cells: Partial<Record<Exchange, CellEntry>>;
  };

  const pivot = useMemo(() => {
    const map = new Map<string, RowMeta>();
    for (const p of prices) {
      const ex = canonicalExchange(p.exchange);
      if (!ex) continue;
      const split = splitSymbol(p.pair);
      if (!split) continue; // skip un-parseable pairs (very rare)
      const key = rowKey(split.base, split.bucket);
      let row = map.get(key);
      if (!row) {
        row = { base: split.base, bucket: split.bucket, cells: {} };
        map.set(key, row);
      }
      const cell: CellEntry = {
        bidMicroUsd: p.bidMicroUsd,
        askMicroUsd: p.askMicroUsd,
        timestampMs: p.timestampMs,
        success: p.success,
        stale: p.stale,
        realQuote: split.quote,
        rawPair: p.pair,
      };
      // Keep the freshest entry per (base, bucket, exchange) — if same
      // exchange reports the same base in the same bucket via multiple raw
      // symbols (e.g. Kraken XBTUSD + XBTUSDT), the most recent one wins.
      const existing = row.cells[ex];
      if (!existing || p.timestampMs > existing.timestampMs) {
        row.cells[ex] = cell;
      }
    }
    return map;
  }, [prices]);

  // Filter + sort rows. Filter matches both base and bucket (so user can
  // search "BTC" or "USD*" or "1INCH USD").
  const visibleRows = useMemo(() => {
    const all = Array.from(pivot.values());
    const q = search.trim().toLowerCase();
    const filtered = q
      ? all.filter((r) =>
          r.base.toLowerCase().includes(q) ||
          r.bucket.toLowerCase().includes(q) ||
          rowKey(r.base, r.bucket).toLowerCase().includes(q))
      : all;
    filtered.sort((a, b) => {
      // Primary: base alpha. Secondary: bucket order USD* < EUR* < others.
      const baseCmp = a.base.localeCompare(b.base);
      if (baseCmp !== 0) return sortDir === "asc" ? baseCmp : -baseCmp;
      // Buckets: prefer USD* > EUR* > others (alpha after).
      const bucketRank = (b: string) => b === "USD*" ? 0 : b === "EUR*" ? 1 : 2;
      const ra = bucketRank(a.bucket);
      const rb = bucketRank(b.bucket);
      if (ra !== rb) return ra - rb;
      return a.bucket.localeCompare(b.bucket);
    });
    return filtered;
  }, [pivot, search, sortDir]);

  const toggleSort = () => setSortDir((d) => (d === "asc" ? "desc" : "asc"));

  return (
    <section className="bg-mempool-bg-elev rounded-lg p-4 border border-mempool-border backdrop-blur-sm">
      <div className="flex items-center gap-2 mb-3">
        <h2 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
          Full Market Feed — normalized (3 exchanges, USD*/EUR* buckets)
        </h2>
        <div className="flex-1 h-px bg-mempool-border" />
        <span className="text-xs text-mempool-text-dim font-mono">
          {visibleRows.length} rows / {count} routes
        </span>
      </div>

      <div className="mb-3 flex items-center gap-2">
        <input
          type="text"
          placeholder="Filter pairs..."
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-1.5 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
        />
        {visibleRows.length > 0 && (
          <button
            onClick={() => {
              const rows = [
                ["asset","quote_bucket","coinbase_bid_usd","coinbase_ask_usd","kraken_bid_usd","kraken_ask_usd","lcx_bid_usd","lcx_ask_usd"].join(","),
                ...visibleRows.map((r) => {
                  const fmtCell = (ex: Exchange) => {
                    const c = r.cells[ex];
                    if (!c || !c.success) return ",";
                    return `${(c.bidMicroUsd / MICRO).toFixed(6)},${(c.askMicroUsd / MICRO).toFixed(6)}`;
                  };
                  return [r.base, r.bucket, fmtCell("Coinbase"), fmtCell("Kraken"), fmtCell("LCX")].join(",");
                }),
              ].join("\n");
              const blob = new Blob([rows], { type: "text/csv" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url; a.download = "omnibus-prices-snapshot.csv";
              a.click(); URL.revokeObjectURL(url);
            }}
            className="px-2 py-1.5 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue whitespace-nowrap"
          >
            ⬇ CSV
          </button>
        )}
      </div>

      {!backendReady && loaded ? (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          Backend not ready...
        </p>
      ) : !loaded ? (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          Loading...
        </p>
      ) : visibleRows.length === 0 ? (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          No pairs match
        </p>
      ) : (
        <div className="overflow-x-auto max-h-[600px] overflow-y-auto">
          <table className="w-full text-xs font-mono">
            <thead className="sticky top-0 bg-mempool-bg-elev">
              <tr className="text-left text-mempool-text-dim uppercase tracking-wider">
                <th
                  className="py-2 px-2 font-medium cursor-pointer select-none hover:text-mempool-blue"
                  onClick={toggleSort}
                  title="Toggle sort direction"
                >
                  Asset {sortDir === "asc" ? "↑" : "↓"}
                </th>
                <th className="py-2 px-2 font-medium text-mempool-text-dim">
                  Quote
                </th>
                {EXCHANGES.map((ex) => (
                  <th
                    key={ex}
                    className="py-2 px-2 font-medium text-mempool-blue"
                  >
                    {ex}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {visibleRows.map((row, idx) => {
                const prefix = bucketSymbol(row.bucket);
                // Show base name only on first row of each base group, so eye
                // can group "1INCH USD* / 1INCH EUR*" visually.
                const prevBase = idx > 0 ? visibleRows[idx - 1].base : null;
                const showBase = prevBase !== row.base;
                return (
                  <tr
                    key={`${row.base}|${row.bucket}`}
                    className={`border-t ${showBase ? "border-mempool-border" : "border-mempool-border/30"}`}
                  >
                    <td className="py-2 px-2 text-mempool-text whitespace-nowrap">
                      {showBase ? row.base : <span className="opacity-30">{row.base}</span>}
                    </td>
                    <td className="py-2 px-2 text-mempool-text-dim whitespace-nowrap">
                      <span className={
                        row.bucket === "USD*" ? "text-green-400/80"
                        : row.bucket === "EUR*" ? "text-blue-400/80"
                        : "text-mempool-text-dim"
                      }>
                        {bucketLabel(row.bucket)}
                      </span>
                    </td>
                    {EXCHANGES.map((ex) => (
                      <td key={ex} className="py-2 px-2">
                        <PriceCell entry={row.cells[ex]} prefix={prefix} />
                      </td>
                    ))}
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
