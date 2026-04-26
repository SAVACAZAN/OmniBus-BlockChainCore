import { useEffect, useMemo, useState } from "react";
import { OmniBusRpcClient } from "../../api/rpc-client";

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

const POLL_MS = 3000;
const PAGE_LIMIT = 1000;
const EXCHANGES = ["Coinbase", "Kraken", "LCX"] as const;
type Exchange = (typeof EXCHANGES)[number];

type SortDir = "asc" | "desc";

// ── Format helpers ────────────────────────────────────────────────────────

function formatUsd(microUsd: number, decimals: number): string {
  const dollars = microUsd / 1_000_000;
  return dollars.toLocaleString("en-US", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
}

// Pick decimals based on price magnitude — bigger prices get fewer decimals.
function decimalsFor(microUsd: number): number {
  const dollars = Math.abs(microUsd / 1_000_000);
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

// ── Cell sub-component ────────────────────────────────────────────────────

function PriceCell({ entry }: { entry: PriceEntry | undefined }) {
  // Defensive: any missing field → render an empty cell. Never throw or
  // print 'n/a'. This protects the whole grid from a single bad entry
  // breaking the React tree.
  if (!entry || !entry.success || typeof entry.bidMicroUsd !== "number"
      || typeof entry.askMicroUsd !== "number"
      || (entry.bidMicroUsd === 0 && entry.askMicroUsd === 0)) {
    return <div className="font-mono text-xs">&nbsp;</div>;
  }

  const dimClass = entry.stale ? "opacity-50" : "";
  const askDec = decimalsFor(entry.askMicroUsd);
  const bidDec = decimalsFor(entry.bidMicroUsd);

  return (
    <div className={`flex flex-col font-mono text-xs ${dimClass}`}>
      <span className="text-mempool-green">
        ${formatUsd(entry.bidMicroUsd, bidDec)}
      </span>
      <span className="text-mempool-orange">
        ${formatUsd(entry.askMicroUsd, askDec)}
      </span>
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
    const id = setInterval(fetchAll, POLL_MS);

    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [rpc]);

  // Pivot prices into a map: pair → exchange → entry.
  const pivot = useMemo(() => {
    const map = new Map<string, Partial<Record<Exchange, PriceEntry>>>();
    for (const p of prices) {
      const ex = canonicalExchange(p.exchange);
      if (!ex) continue;
      let row = map.get(p.pair);
      if (!row) {
        row = {};
        map.set(p.pair, row);
      }
      // Keep the freshest entry per (pair, exchange).
      const existing = row[ex];
      if (!existing || p.timestampMs > existing.timestampMs) {
        row[ex] = p;
      }
    }
    return map;
  }, [prices]);

  // Filter + sort pairs.
  const visiblePairs = useMemo(() => {
    const allPairs = Array.from(pivot.keys());
    const q = search.trim().toLowerCase();
    const filtered = q
      ? allPairs.filter((pair) => pair.toLowerCase().includes(q))
      : allPairs;
    filtered.sort((a, b) =>
      sortDir === "asc" ? a.localeCompare(b) : b.localeCompare(a),
    );
    return filtered;
  }, [pivot, search, sortDir]);

  const toggleSort = () => setSortDir((d) => (d === "asc" ? "desc" : "asc"));

  return (
    <section className="bg-mempool-card rounded-lg p-4 border border-mempool-border">
      <div className="flex items-center gap-2 mb-3">
        <h2 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
          Full Market Feed (3 exchanges)
        </h2>
        <div className="flex-1 h-px bg-mempool-border" />
        <span className="text-xs text-mempool-text-dim font-mono">
          {visiblePairs.length}/{count} pairs
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
      </div>

      {!backendReady && loaded ? (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          Backend not ready...
        </p>
      ) : !loaded ? (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          Loading...
        </p>
      ) : visiblePairs.length === 0 ? (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          No pairs match
        </p>
      ) : (
        <div className="overflow-x-auto max-h-[600px] overflow-y-auto">
          <table className="w-full text-xs font-mono">
            <thead className="sticky top-0 bg-mempool-card">
              <tr className="text-left text-mempool-text-dim uppercase tracking-wider">
                <th
                  className="py-2 px-2 font-medium cursor-pointer select-none hover:text-mempool-blue"
                  onClick={toggleSort}
                  title="Toggle sort direction"
                >
                  Pair {sortDir === "asc" ? "↑" : "↓"}
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
              {visiblePairs.map((pair) => {
                const row = pivot.get(pair) ?? {};
                return (
                  <tr key={pair} className="border-t border-mempool-border">
                    <td className="py-2 px-2 text-mempool-text whitespace-nowrap">
                      {pair}
                    </td>
                    {EXCHANGES.map((ex) => (
                      <td key={ex} className="py-2 px-2">
                        <PriceCell entry={row[ex]} />
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
