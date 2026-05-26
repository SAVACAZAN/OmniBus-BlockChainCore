import { useEffect, useMemo, useState } from "react";
import { OmniBusRpcClient } from "../../api/rpc-client";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsOraclePriceEvent } from "../../types";
import { MICRO_PER_USD, decimalsForUsd } from "../../utils/fmt";
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

const MIN_SPREAD_PCT = 0.05;
const TOP_N = 15;

// ── Format helpers ────────────────────────────────────────────────────────

function formatUsd(microUsd: number, decimals: number): string {
  const dollars = microUsd / MICRO_PER_USD;
  return dollars.toLocaleString("en-US", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
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
  const [fxRate, setFxRate] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    const fetchArb = async () => {
      try {
        // Run arb + FX in parallel — they share the same backend.
        const [arbResult, fxResult] = await Promise.all([
          rpc.request_raw("omnibus_getarbitrage"),
          rpc.request_raw("omnibus_getfxrate").catch(() => null),
        ]);
        if (cancelled) return;
        const result = arbResult as ArbResponse | null;
        if (result && Array.isArray(result.opportunities)) {
          setOpps(result.opportunities);
          setBackendReady(true);
        } else {
          setOpps([]);
        }
        // Pull EUR→USD rate (string with 6 decimals, or null).
        const fx = fxResult as { eurToUsd?: string | null } | null;
        setFxRate(fx?.eurToUsd ?? null);
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
    // Arbitrage opportunities change when prices change — subscribe to oracle_price.
    const unsub = wsSubscribe<WsOraclePriceEvent>("oracle_price", () => {
      void fetchArb();
    });
    // Slow fallback poll (30 s) for when WS is disconnected.
    const id = setInterval(() => { void fetchArb(); }, 30_000);

    return () => {
      cancelled = true;
      clearInterval(id);
      unsub();
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
    <section className="bg-mempool-bg-elev rounded-lg p-4 border border-mempool-border backdrop-blur-sm">
      <div className="flex items-center gap-2 mb-3">
        <h2 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
          Arbitrage Opportunities (cross-exchange)
        </h2>
        {fxRate && (
          <span
            className="text-[10px] font-mono text-mempool-purple bg-mempool-bg px-2 py-0.5 rounded border border-mempool-border"
            title="Median USDC/EUR mid-price across Coinbase, Kraken, LCX. Used to convert EUR-quoted bids/asks to USD-equivalent for cross-region arbitrage."
          >
            EUR→USD {parseFloat(fxRate).toFixed(4)}
          </span>
        )}
        <div className="flex-1 h-px bg-mempool-border" />
        {sorted.length > 0 && (
          <button
            onClick={() => {
              const rows = [
                ["pair","buy_at","buy_ask_usd","sell_at","sell_bid_usd","spread_usd","spread_pct"].join(","),
                ...sorted.map((o) => [
                  o.pair,
                  o.buyAt,
                  (o.buyAskMicroUsd / MICRO_PER_USD).toFixed(6),
                  o.sellAt,
                  (o.sellBidMicroUsd / MICRO_PER_USD).toFixed(6),
                  (o.spreadMicroUsd / MICRO_PER_USD).toFixed(6),
                  o.spreadPct.toFixed(4),
                ].join(",")),
              ].join("\n");
              const blob = new Blob([rows], { type: "text/csv" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url; a.download = "omnibus-arb-opportunities.csv";
              a.click(); URL.revokeObjectURL(url);
            }}
            className="px-2 py-1 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue"
          >
            ⬇ CSV
          </button>
        )}
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
                const askDec = decimalsForUsd(o.buyAskMicroUsd);
                const bidDec = decimalsForUsd(o.sellBidMicroUsd);
                const spreadDec = decimalsForUsd(o.spreadMicroUsd);
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
