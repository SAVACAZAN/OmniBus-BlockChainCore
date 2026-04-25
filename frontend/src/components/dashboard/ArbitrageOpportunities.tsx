import { useEffect, useMemo, useState } from "react";
import { OmniBusRpcClient } from "../../api/rpc-client";

// ── Types ─────────────────────────────────────────────────────────────────

interface ArbOpportunity {
  pair: string;
  buyAt: string;
  buyAskMicroUsd: number;
  sellAt: string;
  sellBidMicroUsd: number;
  spreadMicroUsd: number;
  spreadPct: number;
  buyTimestampMs: number;
  sellTimestampMs: number;
}

interface ArbResponse {
  opportunities: ArbOpportunity[];
}

const POLL_MS = 2000;
const MIN_SPREAD_PCT = 0.05;
const TOP_N = 15;

// ── Format helpers ────────────────────────────────────────────────────────

function formatUsd(microUsd: number, decimals: number): string {
  const dollars = microUsd / 1_000_000;
  return dollars.toLocaleString("en-US", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
}

// Pick decimals based on price magnitude — bigger numbers get fewer decimals.
function decimalsFor(microUsd: number): number {
  const dollars = Math.abs(microUsd / 1_000_000);
  if (dollars >= 1000) return 2;
  if (dollars >= 1) return 2;
  if (dollars >= 0.01) return 4;
  return 4;
}

function formatPct(pct: number): string {
  return `${pct.toLocaleString("en-US", {
    minimumFractionDigits: 3,
    maximumFractionDigits: 3,
  })}%`;
}

function formatAge(ms: number): string {
  const sec = Math.max(0, Math.floor(ms / 1000));
  if (sec < 60) return `${sec}s`;
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m ${sec % 60}s`;
  const hr = Math.floor(min / 60);
  return `${hr}h ${min % 60}m`;
}

function spreadPctColor(pct: number): string {
  if (pct > 0.5) return "text-mempool-green";
  if (pct >= 0.1) return "text-mempool-orange";
  return "text-mempool-text-dim";
}

// ── Main component ────────────────────────────────────────────────────────

export default function ArbitrageOpportunities() {
  const rpc = useMemo(() => new OmniBusRpcClient(), []);
  const [opps, setOpps] = useState<ArbOpportunity[]>([]);
  const [now, setNow] = useState<number>(Date.now());
  const [backendReady, setBackendReady] = useState<boolean>(true);
  const [loaded, setLoaded] = useState<boolean>(false);

  useEffect(() => {
    let cancelled = false;

    const fetchArb = async () => {
      try {
        const result = (await rpc.request_raw(
          "omnibus_getarbitrage",
        )) as ArbResponse | null;
        if (cancelled) return;
        if (result && Array.isArray(result.opportunities)) {
          setOpps(result.opportunities);
          setBackendReady(true);
        } else {
          setOpps([]);
        }
        setNow(Date.now());
        setLoaded(true);
      } catch (e) {
        if (cancelled) return;
        const msg = e instanceof Error ? e.message : String(e);
        // Method-not-found or other backend issues → friendly empty state.
        if (
          msg.toLowerCase().includes("method") ||
          msg.toLowerCase().includes("not found") ||
          msg.toLowerCase().includes("not ready") ||
          msg.toLowerCase().includes("failed") ||
          msg.toLowerCase().includes("rpc error")
        ) {
          setBackendReady(false);
        } else {
          setBackendReady(false);
        }
        setOpps([]);
        setLoaded(true);
      }
    };

    fetchArb();
    const id = setInterval(fetchArb, POLL_MS);

    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [rpc]);

  // Sort desc by spreadPct, top N.
  const sorted = useMemo(() => {
    const filtered = opps.filter((o) => o.spreadPct > MIN_SPREAD_PCT);
    return [...filtered]
      .sort((a, b) => b.spreadPct - a.spreadPct)
      .slice(0, TOP_N);
  }, [opps]);

  return (
    <section className="bg-mempool-card rounded-lg p-4 border border-mempool-border">
      <div className="flex items-center gap-2 mb-3">
        <h2 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
          Arbitrage Opportunities (cross-exchange)
        </h2>
        <div className="flex-1 h-px bg-mempool-border" />
        <span className="text-xs text-mempool-text-dim font-mono">
          {sorted.length} shown
        </span>
      </div>

      {!backendReady && loaded ? (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          Backend not ready...
        </p>
      ) : sorted.length === 0 && loaded ? (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          No arbitrage &gt; 0.05% right now
        </p>
      ) : !loaded ? (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          Loading...
        </p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-xs font-mono">
            <thead>
              <tr className="text-left text-mempool-text-dim uppercase tracking-wider">
                <th className="py-2 px-2 font-medium">Pair</th>
                <th className="py-2 px-2 font-medium">Buy at</th>
                <th className="py-2 px-2 font-medium text-right">Ask</th>
                <th className="py-2 px-2 font-medium">Sell at</th>
                <th className="py-2 px-2 font-medium text-right">Bid</th>
                <th className="py-2 px-2 font-medium text-right">Spread USD</th>
                <th className="py-2 px-2 font-medium text-right">Spread %</th>
                <th className="py-2 px-2 font-medium text-right">Age</th>
              </tr>
            </thead>
            <tbody>
              {sorted.map((o, idx) => {
                const askDec = decimalsFor(o.buyAskMicroUsd);
                const bidDec = decimalsFor(o.sellBidMicroUsd);
                const spreadDec = decimalsFor(o.spreadMicroUsd);
                const ageMs = Math.max(
                  now - o.buyTimestampMs,
                  now - o.sellTimestampMs,
                );
                return (
                  <tr
                    key={`${o.pair}-${o.buyAt}-${o.sellAt}-${idx}`}
                    className="border-t border-mempool-border"
                  >
                    <td className="py-2 px-2 text-mempool-text">{o.pair}</td>
                    <td className="py-2 px-2 text-mempool-blue">{o.buyAt}</td>
                    <td className="py-2 px-2 text-right text-mempool-orange">
                      ${formatUsd(o.buyAskMicroUsd, askDec)}
                    </td>
                    <td className="py-2 px-2 text-mempool-purple">{o.sellAt}</td>
                    <td className="py-2 px-2 text-right text-mempool-green">
                      ${formatUsd(o.sellBidMicroUsd, bidDec)}
                    </td>
                    <td className="py-2 px-2 text-right text-mempool-text">
                      ${formatUsd(o.spreadMicroUsd, spreadDec)}
                    </td>
                    <td
                      className={`py-2 px-2 text-right font-semibold ${spreadPctColor(
                        o.spreadPct,
                      )}`}
                    >
                      {formatPct(o.spreadPct)}
                    </td>
                    <td className="py-2 px-2 text-right text-mempool-text-dim">
                      {formatAge(ageMs)}
                    </td>
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
