import { useEffect, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";

const rpc = new OmniBusRpcClient();

const PAIRS = ["OMNI/USDC", "OMNI/EUR", "BTC/USDC", "ETH/USDC"] as const;
type Pair = typeof PAIRS[number];

type OrderbookEntry = {
  price: number;
  size: number;
};

type OrderbookResp = {
  bids: OrderbookEntry[];
  asks: OrderbookEntry[];
  note?: string;
};

type TradeEntry = {
  price: number;
  amount: number;
  side: string;
  timestamp: number;
};

export function ExchangePage() {
  const [pair, setPair] = useState<Pair>("OMNI/USDC");
  const [orderbook, setOrderbook] = useState<OrderbookResp | null>(null);
  const [trades, setTrades] = useState<TradeEntry[] | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [methodMissing, setMethodMissing] = useState(false);
  const [tradesMissing, setTradesMissing] = useState(false);

  useEffect(() => {
    let cancelled = false;

    const refresh = async () => {
      try {
        const ob = (await rpc.request_raw("omnibus_getorderbook", [
          { pair },
        ])) as OrderbookResp;
        if (!cancelled) {
          setOrderbook(ob);
          setMethodMissing(false);
          setError(null);
        }
      } catch (e: any) {
        const msg = e?.message || "RPC error";
        if (!cancelled) {
          if (msg.includes("Method not found")) {
            setMethodMissing(true);
          } else {
            setError(msg);
          }
        }
      }

      // Try trades — best effort
      try {
        const t = (await rpc.request_raw("omnibus_gettrades", [
          { pair, limit: 50 },
        ])) as { trades?: TradeEntry[] } | null;
        if (!cancelled) {
          setTrades(t?.trades || []);
          setTradesMissing(false);
        }
      } catch (e: any) {
        const msg = e?.message || "";
        if (!cancelled && msg.includes("Method not found")) {
          setTradesMissing(true);
          setTrades([]);
        }
      }

      if (!cancelled) setLoading(false);
    };

    refresh();
    const id = setInterval(refresh, 3000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [pair]);

  const bids = orderbook?.bids || [];
  const asks = orderbook?.asks || [];
  const maxSize = Math.max(
    1,
    ...bids.map((b) => b.size),
    ...asks.map((a) => a.size)
  );

  const fmtPrice = (p: number) => p.toFixed(4);
  const fmtSize = (s: number) => s.toFixed(2);

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      <h1 className="text-2xl font-bold text-mempool-text mb-2">
        OmniBus Exchange
      </h1>
      <p className="text-mempool-text-dim text-sm mb-6">
        On-chain orderbook and recent trades. Prices are provided by the
        distributed oracle network.
      </p>

      {methodMissing && (
        <div className="mb-6 p-4 rounded-lg border border-amber-500/40 bg-amber-500/10 text-amber-200 text-sm">
          <p className="font-semibold mb-1">Exchange RPC not exposed by this node — old build</p>
          <p>
            The connected node does not expose <code>omnibus_getorderbook</code> RPC.
          </p>
        </div>
      )}

      {error && !methodMissing && (
        <div className="mb-4 p-3 rounded-lg border border-red-500/40 bg-red-500/10 text-red-300 text-xs">
          RPC error: {error}
        </div>
      )}

      {/* Pair selector */}
      <div className="flex items-center gap-2 mb-6">
        <span className="text-xs text-mempool-text-dim">Pair:</span>
        {PAIRS.map((p) => (
          <button
            key={p}
            onClick={() => setPair(p)}
            className={`px-3 py-1.5 text-xs rounded transition-colors ${
              pair === p
                ? "bg-mempool-blue text-white font-semibold"
                : "bg-mempool-bg-elev text-mempool-text-dim hover:text-mempool-text"
            }`}
          >
            {p}
          </button>
        ))}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Orderbook */}
        <div className="lg:col-span-2 rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
          <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider mb-3">
            Order Book — {pair}
          </h2>

          {loading && !orderbook && (
            <div className="p-8 text-center text-mempool-text-dim text-sm">
              Loading orderbook…
            </div>
          )}

          {orderbook && orderbook.note && (
            <div className="mb-3 p-2 rounded bg-mempool-bg border border-mempool-border text-xs text-mempool-text-dim">
              {orderbook.note}
            </div>
          )}

          {/* Asks (sell) — orange/red */}
          <div className="space-y-0.5 mb-2 max-h-48 overflow-y-auto">
            {asks.length > 0 ? (
              asks
                .slice(0, 8)
                .reverse()
                .map((a, i) => (
                  <div
                    key={`ask-${i}`}
                    className="flex justify-between text-xs font-mono relative py-0.5"
                  >
                    <div
                      className="absolute inset-0 bg-orange-500/10 rounded"
                      style={{
                        width: `${Math.min((a.size / maxSize) * 100, 100)}%`,
                        right: 0,
                        left: "auto",
                      }}
                    />
                    <span className="text-orange-400 relative z-10 px-1">
                      {fmtPrice(a.price)}
                    </span>
                    <span className="text-mempool-text relative z-10 px-1">
                      {fmtSize(a.size)}
                    </span>
                  </div>
                ))
            ) : (
              <p className="text-mempool-text-dim text-xs text-center py-4">
                No sell orders
              </p>
            )}
          </div>

          {/* Mid / Spread divider */}
          <div className="text-center py-2 border-y border-mempool-border my-2">
            <span className="text-lg font-bold text-mempool-text font-mono">
              {bids.length && asks.length
                ? fmtPrice((bids[0].price + asks[0].price) / 2)
                : "—"}
            </span>
            {bids.length && asks.length && (
              <span className="text-xs text-mempool-text-dim ml-2">
                Spread: {fmtPrice(asks[0].price - bids[0].price)}
              </span>
            )}
          </div>

          {/* Bids (buy) — green */}
          <div className="space-y-0.5 max-h-48 overflow-y-auto">
            {bids.length > 0 ? (
              bids.slice(0, 8).map((b, i) => (
                <div
                  key={`bid-${i}`}
                  className="flex justify-between text-xs font-mono relative py-0.5"
                >
                  <div
                    className="absolute inset-0 bg-green-500/10 rounded"
                    style={{
                      width: `${Math.min((b.size / maxSize) * 100, 100)}%`,
                      right: 0,
                      left: "auto",
                    }}
                  />
                  <span className="text-green-400 relative z-10 px-1">
                    {fmtPrice(b.price)}
                  </span>
                  <span className="text-mempool-text relative z-10 px-1">
                    {fmtSize(b.size)}
                  </span>
                </div>
              ))
            ) : (
              <p className="text-mempool-text-dim text-xs text-center py-4">
                No buy orders
              </p>
            )}
          </div>
        </div>

        {/* Recent Trades */}
        <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
          <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider mb-3">
            Recent Trades
          </h2>

          {tradesMissing && (
            <div className="p-4 rounded border border-amber-500/30 bg-amber-500/10 text-amber-200 text-xs">
              Trading engine attached — no trades yet
            </div>
          )}

          {trades && trades.length > 0 ? (
            <div className="space-y-0.5 max-h-96 overflow-y-auto">
              <div className="flex justify-between text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">
                <span>Price</span>
                <span>Amount</span>
                <span>Time</span>
              </div>
              {trades.map((t, i) => (
                <div
                  key={i}
                  className="flex justify-between text-xs font-mono py-0.5"
                >
                  <span
                    className={
                      t.side === "buy" ? "text-green-400" : "text-orange-400"
                    }
                  >
                    {fmtPrice(t.price)}
                  </span>
                  <span className="text-mempool-text">{fmtSize(t.amount)}</span>
                  <span className="text-mempool-text-dim">
                    {new Date(t.timestamp).toLocaleTimeString()}
                  </span>
                </div>
              ))}
            </div>
          ) : (
            !tradesMissing && (
              <div className="p-8 text-center text-mempool-text-dim text-sm">
                No trades yet for {pair}.
              </div>
            )
          )}
        </div>
      </div>

      <div className="mt-6 text-xs text-mempool-text-dim">
        <p>
          <span className="font-semibold text-mempool-text">Refresh:</span>{" "}
          auto every 3s.
        </p>
      </div>
    </div>
  );
}
