import { useEffect, useMemo, useState } from "react";
import OmniBusRpcClient, {
  OrderbookLevel,
  PairInfo,
  TradeFill,
} from "../../api/rpc-client";
import { PlaceOrderForm } from "./PlaceOrderForm";
import { UserOrdersPanel } from "./UserOrdersPanel";
import { ApiKeysPanel } from "./ApiKeysPanel";
import { BalancesPanel } from "./BalancesPanel";
import { IdentityPanel } from "./IdentityPanel";
import { KycPanel } from "./KycPanel";
import { TraderModeToggle, useTraderMode } from "./TraderModeToggle";
import { GridPanel } from "./GridPanel";

const rpc = new OmniBusRpcClient();

const SAT_PER_OMNI = 1_000_000_000;
const MICRO_PER_USD = 1_000_000;

type Pair = { id: number; base: string; quote: string; label: string };

const FALLBACK_PAIRS: Pair[] = [
  { id: 0, base: "OMNI", quote: "USDC", label: "OMNI/USDC" },
  { id: 2, base: "LCX",  quote: "USDC", label: "LCX/USDC" },
  { id: 3, base: "ETH",  quote: "USDC", label: "ETH/USDC" },
  { id: 5, base: "OMNI", quote: "LCX",  label: "OMNI/LCX" },
  { id: 6, base: "OMNI", quote: "ETH",  label: "OMNI/ETH" },
];

type Tab = "trade" | "grid" | "account";
type AccountTab = "balances" | "identity" | "kyc" | "apikeys";

export function ExchangePage() {
  const [tab, setTab] = useState<Tab>("trade");
  const [accountTab, setAccountTab] = useState<AccountTab>("balances");
  const [traderMode] = useTraderMode();
  const [pairs, setPairs] = useState<Pair[]>(FALLBACK_PAIRS);
  const [pairId, setPairId] = useState<number>(0);
  const [bids, setBids] = useState<OrderbookLevel[]>([]);
  const [asks, setAsks] = useState<OrderbookLevel[]>([]);
  const [bestBid, setBestBid] = useState(0);
  const [bestAsk, setBestAsk] = useState(0);
  const [trades, setTrades] = useState<TradeFill[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshNonce, setRefreshNonce] = useState(0);
  const [methodMissing, setMethodMissing] = useState(false);
  const [pairInfo, setPairInfo] = useState<PairInfo | null>(null);
  const walletAddress: string = (typeof localStorage !== "undefined" && localStorage.getItem("omnibus.wallet_address")) ?? "";

  // Pull pair list once. Falls back to a hardcoded list if the node is too old.
  useEffect(() => {
    let cancelled = false;
    rpc.exchangeListPairs().then((list) => {
      if (!cancelled && list.length > 0) {
        // Filter out BTC pairs (reserved, no liquidity yet)
        setPairs(list.filter((p) => p.id !== 1 && p.id !== 4));
      }
    });
    return () => { cancelled = true; };
  }, []);

  // Fetch pair chain info (maker/taker chains) on pair change
  useEffect(() => {
    let cancelled = false;
    setPairInfo(null);
    rpc.exchangePairInfo(pairId).then((info) => {
      if (!cancelled) setPairInfo(info);
    });
    return () => { cancelled = true; };
  }, [pairId]);

  // Poll orderbook + trades. Mode-aware — switches engine on toggle.
  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      try {
        const [ob, tr] = await Promise.all([
          rpc.exchangeGetOrderbook({ pairId, depth: 25, mode: traderMode }),
          rpc.exchangeGetTrades({ pairId, limit: 50, mode: traderMode }),
        ]);
        if (cancelled) return;
        if (ob) {
          setBids(ob.bids);
          setAsks(ob.asks);
          setBestBid(ob.bestBid);
          setBestAsk(ob.bestAsk);
          setMethodMissing(false);
        }
        setTrades(tr);
        setLoading(false);
      } catch (e: any) {
        if (!cancelled) {
          if ((e?.message || "").includes("Method not found")) {
            setMethodMissing(true);
          }
          setLoading(false);
        }
      }
    };
    refresh();
    const id = setInterval(refresh, 3000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [pairId, refreshNonce, traderMode]);

  const activePair = useMemo(
    () => pairs.find((p) => p.id === pairId) ?? pairs[0],
    [pairs, pairId],
  );
  const pairLabel = activePair?.label ?? "?";

  const maxAmount = Math.max(
    1,
    ...bids.map((b) => b.remaining),
    ...asks.map((a) => a.remaining),
  );

  const fmtPrice = (p: number) => (p / MICRO_PER_USD).toFixed(4);
  const fmtAmount = (a: number) => (a / SAT_PER_OMNI).toFixed(4);

  const mid = bestBid && bestAsk ? (bestBid + bestAsk) / 2 : 0;
  const spread = bestBid && bestAsk ? bestAsk - bestBid : 0;

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-4">
      <div>
        <h1 className="text-2xl font-bold text-mempool-text">OmniBus Exchange</h1>
        <p className="text-mempool-text-dim text-xs mt-1">
          On-chain matching engine. Orders are signed client-side with your
          wallet's secp256k1 key — never leaves the browser. Connect once via
          the wallet button in the header — Names / Faucet / Reputation /
          Exchange all share the same session.
        </p>
      </div>

      {methodMissing && (
        <div className="p-3 rounded-lg border border-amber-500/40 bg-amber-500/10 text-amber-200 text-xs">
          This node does not expose <code>exchange_*</code> RPC. Rebuild &
          restart the node with the matching engine enabled.
        </div>
      )}

      {/* Top-level tabs */}
      <div className="flex gap-1 border-b border-mempool-border">
        {([
          { id: "trade", label: "Trade" },
          { id: "grid",  label: "Grid" },
          { id: "account", label: "Account" },
        ] as { id: Tab; label: string }[]).map((t) => (
          <button
            key={t.id}
            onClick={() => setTab(t.id)}
            className={`px-4 py-2 text-xs uppercase tracking-wider transition-colors ${
              tab === t.id
                ? "border-b-2 border-mempool-blue text-mempool-text font-semibold"
                : "text-mempool-text-dim hover:text-mempool-text"
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {tab === "account" && (
        <div className="space-y-4">
          {/* Account sub-tabs (Balances | Identity | KYC | API Keys) */}
          <div className="flex flex-wrap gap-1 bg-mempool-bg-elev rounded-lg p-1">
            {([
              { id: "balances", label: "💰 Balances" },
              { id: "identity", label: "👤 Identity" },
              { id: "kyc",      label: "🛡 KYC" },
              { id: "apikeys",  label: "🔑 API Keys" },
            ] as const).map((it) => (
              <button
                key={it.id}
                onClick={() => setAccountTab(it.id)}
                className={`px-4 py-1.5 text-xs rounded transition-colors ${
                  accountTab === it.id
                    ? "bg-mempool-blue text-white font-semibold"
                    : "text-mempool-text-dim hover:text-mempool-text hover:bg-mempool-bg/40"
                }`}
              >
                {it.label}
              </button>
            ))}
          </div>

          <div className="max-w-3xl">
            {accountTab === "balances" && <BalancesPanel />}
            {accountTab === "identity" && <IdentityPanel />}
            {accountTab === "kyc"      && <KycPanel />}
            {accountTab === "apikeys"  && <ApiKeysPanel />}
          </div>
        </div>
      )}

      {tab === "grid" && (
        <GridPanel pairs={pairs} walletAddress={walletAddress} />
      )}

      {tab === "trade" && (
      <>
      {/* Real/Paper trader mode toggle — top of Trade so users always see */}
      <TraderModeToggle />

      {/* Pair selector */}
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Pair
        </span>
        {pairs.map((p) => (
          <button
            key={p.id}
            onClick={() => setPairId(p.id)}
            className={`px-3 py-1.5 text-xs rounded transition-colors ${
              p.id === pairId
                ? "bg-mempool-blue text-white font-semibold"
                : "bg-mempool-bg-elev text-mempool-text-dim hover:text-mempool-text"
            }`}
          >
            {p.label}
          </button>
        ))}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-12 gap-4">
        {/* Orderbook */}
        <div className="lg:col-span-6 rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
          <div className="flex items-center justify-between mb-2">
            <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
              Order book — {pairLabel}
            </h2>
            <span className="text-[11px] text-mempool-text-dim font-mono">
              {bids.length}b / {asks.length}a
            </span>
          </div>
          {pairInfo && (
            <div className="flex flex-wrap gap-2 mb-3">
              <div className="flex items-center gap-1">
                <span className="text-[9px] uppercase tracking-wider text-mempool-text-dim">Maker:</span>
                {pairInfo.maker_chains.map((c) => (
                  <span key={c.chain} className="px-1.5 py-0.5 bg-blue-500/20 text-blue-300 rounded text-[9px] font-mono">{c.chain}</span>
                ))}
              </div>
              <div className="flex items-center gap-1">
                <span className="text-[9px] uppercase tracking-wider text-mempool-text-dim">Taker:</span>
                {pairInfo.taker_chains.map((c) => (
                  <span key={c.chain} className="px-1.5 py-0.5 bg-orange-500/20 text-orange-300 rounded text-[9px] font-mono">{c.chain}</span>
                ))}
              </div>
            </div>
          )}

          {loading && bids.length === 0 && asks.length === 0 ? (
            <div className="p-8 text-center text-mempool-text-dim text-sm">Loading…</div>
          ) : (
            <>
              <div className="space-y-0.5 mb-2 max-h-56 overflow-y-auto">
                {asks.length === 0 ? (
                  <p className="text-mempool-text-dim text-xs text-center py-3">No sell orders</p>
                ) : (
                  asks.slice(0, 10).reverse().map((a) => (
                    <div
                      key={`ask-${a.orderId}`}
                      className="flex justify-between text-xs font-mono relative py-0.5"
                    >
                      <div
                        className="absolute inset-y-0 right-0 bg-orange-500/10 rounded"
                        style={{ width: `${Math.min((a.remaining / maxAmount) * 100, 100)}%` }}
                      />
                      <span className="text-orange-400 relative z-10 px-1">{fmtPrice(a.price)}</span>
                      <span className="text-mempool-text relative z-10 px-1">{fmtAmount(a.remaining)}</span>
                    </div>
                  ))
                )}
              </div>

              <div className="text-center py-2 border-y border-mempool-border my-2">
                {mid > 0 ? (
                  <>
                    <span className="text-lg font-bold text-mempool-text font-mono">
                      ${(mid / MICRO_PER_USD).toFixed(4)}
                    </span>
                    <span className="text-xs text-mempool-text-dim ml-2">
                      Spread ${(spread / MICRO_PER_USD).toFixed(4)}
                    </span>
                  </>
                ) : (
                  <span className="text-xs text-mempool-text-dim">No mid — empty book</span>
                )}
              </div>

              <div className="space-y-0.5 max-h-56 overflow-y-auto">
                {bids.length === 0 ? (
                  <p className="text-mempool-text-dim text-xs text-center py-3">No buy orders</p>
                ) : (
                  bids.slice(0, 10).map((b) => (
                    <div
                      key={`bid-${b.orderId}`}
                      className="flex justify-between text-xs font-mono relative py-0.5"
                    >
                      <div
                        className="absolute inset-y-0 right-0 bg-green-500/10 rounded"
                        style={{ width: `${Math.min((b.remaining / maxAmount) * 100, 100)}%` }}
                      />
                      <span className="text-green-400 relative z-10 px-1">{fmtPrice(b.price)}</span>
                      <span className="text-mempool-text relative z-10 px-1">{fmtAmount(b.remaining)}</span>
                    </div>
                  ))
                )}
              </div>
            </>
          )}
        </div>

        {/* Place order */}
        <div className="lg:col-span-3">
          <PlaceOrderForm
            pairId={pairId}
            pairLabel={pairLabel}
            onPlaced={() => setRefreshNonce((n) => n + 1)}
          />
        </div>

        {/* Trades */}
        <div className="lg:col-span-3 rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
          <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider mb-3">
            Recent trades
          </h2>
          {trades.length === 0 ? (
            <div className="p-6 text-center text-mempool-text-dim text-xs">No trades yet.</div>
          ) : (
            <div className="space-y-0.5 max-h-96 overflow-y-auto">
              <div className="grid grid-cols-3 text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">
                <span>Price</span>
                <span className="text-right">Size</span>
                <span className="text-right">Time</span>
              </div>
              {trades.filter((t) => t.pairId === pairId).map((t) => (
                <div key={t.fillId} className="grid grid-cols-3 text-xs font-mono py-0.5">
                  <span className="text-mempool-text">{fmtPrice(t.price)}</span>
                  <span className="text-right text-mempool-text">{fmtAmount(t.amount)}</span>
                  <span className="text-right text-mempool-text-dim">
                    {new Date(t.ts).toLocaleTimeString()}
                  </span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      <UserOrdersPanel pairId={pairId} refreshKey={refreshNonce} />

      <div className="text-[11px] text-mempool-text-dim">
        Poll: 3s · Prices in {activePair?.quote ?? "USDC"} (oracle) · Amounts in {activePair?.base ?? "base"} (1 unit = 10⁹ SAT) · Matching on-chain in Zig
      </div>
      </>
      )}
    </div>
  );
}
