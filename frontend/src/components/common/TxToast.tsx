/**
 * TxToast — global wallet TX notifications.
 *
 * Subscribes to ws-bus events and shows brief bottom-right toasts:
 *   new_tx   → "TX sent" when the connected wallet sends a TX to mempool
 *   tx_confirmed → "TX confirmed" for recently-seen txids
 *
 * Mounted once at the App root. No props needed — reads wallet state
 * directly from the keystore singleton and tracks recent txids internally.
 */

import { useEffect, useRef, useState } from "react";
import { subscribe as wsSubscribe } from "../../api/clients/ws-bus";
import { getUnlocked, subscribeWallet } from "../../api/wallet/wallet-keystore";
import type { WsNewTxEvent, WsTxConfirmedEvent } from "../../types";
import { satToOmni } from "../../utils/fmt";

interface Toast {
  id: number;
  kind: "sent" | "confirmed";
  txid: string;
  amount?: number;   // satoshis
  height?: number;
}

let nextId = 1;

export function TxToast() {
  const [toasts, setToasts] = useState<Toast[]>([]);
  // Track recent txids sent from this wallet (last 20) to match confirmations.
  const recentTxids = useRef<string[]>([]);
  // Mirror wallet address without a full render loop — just a ref.
  const walletAddr = useRef<string | null>(null);

  // Keep walletAddr ref in sync whenever the keystore changes.
  useEffect(() => {
    walletAddr.current = getUnlocked()?.address ?? null;
    return subscribeWallet(() => {
      walletAddr.current = getUnlocked()?.address ?? null;
      // Clear tracked txids when wallet changes to avoid cross-wallet false positives.
      recentTxids.current = [];
    });
  }, []);

  const addToast = (t: Omit<Toast, "id">) => {
    const id = nextId++;
    setToasts((prev) => [...prev, { ...t, id }]);
    window.setTimeout(() => {
      setToasts((prev) => prev.filter((x) => x.id !== id));
    }, 5000);
  };

  useEffect(() => {
    const unsubTx = wsSubscribe<WsNewTxEvent>("new_tx", (ev) => {
      if (!walletAddr.current || ev.from !== walletAddr.current) return;
      // Track txid for confirmation matching.
      recentTxids.current = [ev.txid, ...recentTxids.current].slice(0, 20);
      addToast({ kind: "sent", txid: ev.txid, amount: ev.amount_sat });
    });

    const unsubConf = wsSubscribe<WsTxConfirmedEvent>("tx_confirmed", (ev) => {
      if (!recentTxids.current.includes(ev.hash)) return;
      recentTxids.current = recentTxids.current.filter((id) => id !== ev.hash);
      addToast({ kind: "confirmed", txid: ev.hash, height: ev.blockHeight });
    });

    return () => { unsubTx(); unsubConf(); };
  }, []);

  if (toasts.length === 0) return null;

  return (
    <div className="fixed bottom-20 sm:bottom-6 left-4 z-[99] flex flex-col gap-2 pointer-events-none">
      {toasts.map((t) => (
        <div
          key={t.id}
          className="pointer-events-auto flex items-start gap-2 bg-mempool-bg-elev border border-mempool-border rounded-lg shadow-2xl p-3 max-w-xs backdrop-blur-md animate-fade-in"
        >
          <span className={`text-base leading-none flex-shrink-0 ${t.kind === "sent" ? "text-mempool-orange" : "text-mempool-green"}`}>
            {t.kind === "sent" ? "⬆" : "✓"}
          </span>
          <div className="min-w-0">
            <div className="text-xs font-semibold text-mempool-text">
              {t.kind === "sent" ? "TX sent to mempool" : `TX confirmed — block #${t.height?.toLocaleString()}`}
            </div>
            {t.kind === "sent" && t.amount !== undefined && (
              <div className="text-[11px] text-mempool-text-dim">
                {satToOmni(t.amount)} OMNI
              </div>
            )}
            <button
              className="text-[10px] font-mono text-mempool-blue hover:underline truncate block max-w-full"
              onClick={() => { window.location.hash = `#/tx/${t.txid}`; }}
            >
              {t.txid.slice(0, 16)}…
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}
