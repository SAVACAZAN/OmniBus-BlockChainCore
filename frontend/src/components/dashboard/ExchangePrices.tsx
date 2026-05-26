import { useEffect, useMemo, useState } from "react";
import { OmniBusRpcClient } from "../../api/rpc-client";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsOraclePriceEvent } from "../../types/index";
import { fmtUsd } from "../../utils/fmt";

// ── Types ─────────────────────────────────────────────────────────────────

interface PriceEntry {
  exchange: string;
  pair: string;
  bidMicroUsd: number;
  askMicroUsd: number;
  timestampMs: number;
  success: boolean;
}

interface ExchangeFeed {
  prices: PriceEntry[];
  medianBtcMicroUsd?: number;
  medianLcxMicroUsd?: number;
}

type AssetKey = "BTC" | "LCX";

const POLL_MS = 2000;
const STALE_MS = 30_000;
const EXCHANGES = ["Coinbase", "Kraken", "LCX"] as const;
const ASSETS: { key: AssetKey; label: string; pair: string }[] = [
  { key: "BTC", label: "BTC/USD", pair: "BTC/USD" },
  { key: "LCX", label: "LCX/USD", pair: "LCX/USD" },
];


// Match an exchange entry by name (case-insensitive) and asset symbol.
function findEntry(
  prices: PriceEntry[],
  exchange: string,
  asset: AssetKey,
): PriceEntry | undefined {
  const exLower = exchange.toLowerCase();
  return prices.find(
    (p) =>
      p.exchange.toLowerCase() === exLower &&
      p.pair.toUpperCase().startsWith(asset),
  );
}

// ── Sub-components ────────────────────────────────────────────────────────

function ExchangeRow({
  exchange,
  entry,
  asset,
  now,
}: {
  exchange: string;
  entry: PriceEntry | undefined;
  asset: AssetKey;
  now: number;
}) {
  if (!entry || !entry.success) {
    return (
      <div className="flex items-center justify-between py-2 border-t border-mempool-border first:border-t-0">
        <span className="text-xs text-mempool-text-dim uppercase tracking-wider">
          {exchange}
        </span>
        <span className="text-xs font-mono text-mempool-text-dim">n/a</span>
      </div>
    );
  }

  const isStale = now - entry.timestampMs > STALE_MS;

  return (
    <div className="flex flex-col gap-1 py-2 border-t border-mempool-border first:border-t-0">
      <div className="flex items-center justify-between">
        <span className="text-xs text-mempool-text-dim uppercase tracking-wider">
          {exchange}
        </span>
        {isStale && (
          <span className="text-[10px] uppercase tracking-wider px-1.5 py-0.5 rounded bg-mempool-bg border border-mempool-border text-mempool-red">
            stale
          </span>
        )}
      </div>
      <div className="flex items-center justify-between font-mono text-sm">
        <span className="text-mempool-green">
          {fmtUsd(entry.bidMicroUsd)}
        </span>
        <span className="text-mempool-orange">
          {fmtUsd(entry.askMicroUsd)}
        </span>
      </div>
      <span className="text-[10px] text-mempool-text-dim">
        spread {fmtUsd(entry.askMicroUsd - entry.bidMicroUsd)}
      </span>
    </div>
  );
}

function AssetColumn({
  label,
  asset,
  medianMicroUsd,
  prices,
  now,
}: {
  label: string;
  asset: AssetKey;
  medianMicroUsd?: number;
  prices: PriceEntry[];
  now: number;
}) {
  return (
    <div className="bg-mempool-bg rounded-lg p-3 border border-mempool-border">
      <div className="flex items-baseline justify-between mb-1">
        <h3 className="text-sm font-semibold text-mempool-text">{label}</h3>
        <span className="text-[10px] text-mempool-text-dim uppercase tracking-wider">
          median
        </span>
      </div>
      <p className="text-xl font-mono font-bold text-mempool-blue mb-2">
        {medianMicroUsd !== undefined && medianMicroUsd > 0
          ? fmtUsd(medianMicroUsd)
          : "—"}
      </p>
      <div>
        {EXCHANGES.map((ex) => (
          <ExchangeRow
            key={`${asset}-${ex}`}
            exchange={ex}
            entry={findEntry(prices, ex, asset)}
            asset={asset}
            now={now}
          />
        ))}
      </div>
    </div>
  );
}

// ── Main component ────────────────────────────────────────────────────────

export default function ExchangePrices() {
  const rpc = useMemo(() => new OmniBusRpcClient(), []);
  const [feed, setFeed] = useState<ExchangeFeed | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [now, setNow] = useState<number>(Date.now());

  useEffect(() => {
    let cancelled = false;

    const fetchFeed = async () => {
      try {
        const result = (await rpc.request_raw(
          "omnibus_getexchangefeed",
        )) as ExchangeFeed | null;
        if (cancelled) return;
        if (result && Array.isArray(result.prices)) {
          setFeed(result);
          setError(null);
        } else {
          setFeed({ prices: [] });
        }
        setNow(Date.now());
      } catch (e) {
        if (cancelled) return;
        setError(e instanceof Error ? e.message : String(e));
      }
    };

    fetchFeed();
    // oracle_price fires when backend refreshes feed — update immediately.
    const unsub = wsSubscribe<WsOraclePriceEvent>("oracle_price", () => { void fetchFeed(); });
    const id = setInterval(fetchFeed, 30_000);

    return () => {
      cancelled = true;
      clearInterval(id);
      unsub();
    };
  }, [rpc]);

  const prices = feed?.prices ?? [];

  return (
    <section className="bg-mempool-bg-elev rounded-lg p-4 border border-mempool-border">
      <div className="flex items-center gap-2 mb-3">
        <h2 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
          Exchange Feed
        </h2>
        <div className="flex-1 h-px bg-mempool-border" />
        <span className="text-xs text-mempool-text-dim font-mono">
          {prices.length} feed{prices.length !== 1 ? "s" : ""}
        </span>
      </div>

      {error && (
        <p className="text-xs text-mempool-red mb-2 font-mono">
          {error}
        </p>
      )}

      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        {ASSETS.map((a) => (
          <AssetColumn
            key={a.key}
            label={a.label}
            asset={a.key}
            medianMicroUsd={
              a.key === "BTC" ? feed?.medianBtcMicroUsd : feed?.medianLcxMicroUsd
            }
            prices={prices}
            now={now}
          />
        ))}
      </div>
    </section>
  );
}
