import { useEffect, useState } from "react";
import OmniBusRpcClient, { UserOrder } from "../../api/rpc-client";
import { signCancelOrderPayload } from "../../api/exchange-sign";
import { getUnlocked, nextNonce, subscribeWallet } from "../../api/wallet-keystore";
import { useTraderMode } from "./TraderModeToggle";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsOrderbookUpdateEvent } from "../../types";
import { SAT_PER_OMNI, MICRO_PER_USD } from "../../utils/fmt";

const rpc = new OmniBusRpcClient();

interface Props {
  pairId: number;
  refreshKey?: number;
}

/**
 * Lists active orders for the unlocked address (filtered by current pair).
 * Each row has a Cancel button which signs `EXCHANGE_CANCEL_V1` and posts.
 */
export function UserOrdersPanel({ pairId, refreshKey }: Props) {
  const [, force] = useState(0);
  useEffect(() => subscribeWallet(() => force((n) => n + 1)), []);
  const [traderMode] = useTraderMode();

  const [orders, setOrders] = useState<UserOrder[]>([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<number | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const u = getUnlocked();

  useEffect(() => {
    if (!u) {
      setOrders([]);
      setLoading(false);
      return;
    }
    let cancelled = false;
    const refresh = async () => {
      try {
        const list = await rpc.exchangeGetUserOrders({ trader: u.address, pairId, mode: traderMode });
        if (!cancelled) { setOrders(list); setLoading(false); }
      } catch {
        if (!cancelled) setLoading(false);
      }
    };
    void refresh();
    // Live: orderbook_update fires whenever this pair's book changes.
    const unsub = wsSubscribe<WsOrderbookUpdateEvent>("orderbook_update", (ev) => {
      if (ev.pair_id === pairId) void refresh();
    });
    // Fallback poll at 15 s in case WS is not connected.
    const id = setInterval(refresh, 15_000);
    return () => {
      cancelled = true;
      clearInterval(id);
      unsub();
    };
  }, [u?.address, pairId, refreshKey, traderMode]);

  const cancel = async (orderId: number) => {
    if (!u) return;
    setErr(null);
    setBusyId(orderId);
    try {
      const nonce = nextNonce();
      const { signature, publicKey } = signCancelOrderPayload({
        privateKeyHex: u.privateKey,
        orderId,
        trader: u.address,
        nonce,
      });
      await rpc.exchangeCancelOrder({
        orderId,
        trader: u.address,
        nonce,
        signature,
        publicKey,
        mode: traderMode,
      });
      // Optimistic remove; refresh will re-sync.
      setOrders((prev) => prev.filter((o) => o.orderId !== orderId));
    } catch (e: any) {
      setErr(e?.message || "Cancel failed");
    } finally {
      setBusyId(null);
    }
  };

  if (!u) {
    return (
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
        <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider mb-2">
          My orders
        </h3>
        <p className="text-xs text-mempool-text-dim">Unlock wallet to see your orders.</p>
      </div>
    );
  }

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
      <div className="flex items-center justify-between mb-2">
        <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          My orders
        </h3>
        {orders.length > 0 && (
          <button
            onClick={() => {
              const rows = [
                ["order_id","side","price_usd","remaining_omni","status"].join(","),
                ...orders.map((o) => [
                  o.orderId,
                  o.side,
                  (o.price / MICRO_PER_USD).toFixed(6),
                  (o.remaining / SAT_PER_OMNI).toFixed(8),
                  o.status,
                ].join(",")),
              ].join("\n");
              const blob = new Blob([rows], { type: "text/csv" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url; a.download = "omnibus-my-orders.csv";
              a.click(); URL.revokeObjectURL(url);
            }}
            className="px-2 py-1 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue"
          >
            ⬇ CSV
          </button>
        )}
      </div>
      {loading ? (
        <p className="text-xs text-mempool-text-dim">Loading…</p>
      ) : orders.length === 0 ? (
        <p className="text-xs text-mempool-text-dim">No active orders for this pair.</p>
      ) : (
        <div className="space-y-1 max-h-72 overflow-y-auto">
          <div className="grid grid-cols-12 gap-1 text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1 px-1">
            <span className="col-span-2">Side</span>
            <span className="col-span-3 text-right">Price</span>
            <span className="col-span-3 text-right">Remaining</span>
            <span className="col-span-2 text-right">Status</span>
            <span className="col-span-2 text-right">Action</span>
          </div>
          {orders.map((o) => (
            <div
              key={o.orderId}
              className="grid grid-cols-12 gap-1 text-xs font-mono py-1 px-1 rounded hover:bg-mempool-bg/40"
            >
              <span
                className={`col-span-2 ${
                  o.side.toLowerCase().includes("buy")
                    ? "text-green-400"
                    : "text-orange-400"
                }`}
              >
                {o.side}
              </span>
              <span className="col-span-3 text-right text-mempool-text">
                ${(o.price / MICRO_PER_USD).toFixed(4)}
              </span>
              <span className="col-span-3 text-right text-mempool-text">
                {(o.remaining / SAT_PER_OMNI).toFixed(4)}
              </span>
              <span className="col-span-2 text-right text-mempool-text-dim">
                {o.status}
              </span>
              <span className="col-span-2 text-right">
                <button
                  onClick={() => cancel(o.orderId)}
                  disabled={busyId === o.orderId}
                  className="px-2 py-0.5 rounded text-[10px] bg-red-500/20 hover:bg-red-500/40 disabled:opacity-40 text-red-200"
                >
                  {busyId === o.orderId ? "…" : "Cancel"}
                </button>
              </span>
            </div>
          ))}
          {/* Summary row */}
          {(() => {
            const buys = orders.filter((o) => o.side.toLowerCase().includes("buy"));
            const sells = orders.filter((o) => !o.side.toLowerCase().includes("buy"));
            const lockedQuote = buys.reduce((s, o) => s + (o.price / MICRO_PER_USD) * (o.remaining / SAT_PER_OMNI), 0);
            const lockedBase = sells.reduce((s, o) => s + o.remaining / SAT_PER_OMNI, 0);
            return (
              <div className="mt-1 pt-1 border-t border-mempool-border/40 flex flex-wrap gap-x-3 text-[9px] font-mono text-mempool-text-dim px-1">
                {buys.length > 0 && (
                  <span>Buys ({buys.length}): <span className="text-green-400">${lockedQuote.toFixed(2)} locked</span></span>
                )}
                {sells.length > 0 && (
                  <span>Sells ({sells.length}): <span className="text-orange-400">{lockedBase.toFixed(4)} base locked</span></span>
                )}
              </div>
            );
          })()}
        </div>
      )}
      {err && (
        <div className="mt-2 p-2 rounded bg-red-500/10 border border-red-500/30 text-[11px] text-red-300">
          {err}
        </div>
      )}
    </div>
  );
}
