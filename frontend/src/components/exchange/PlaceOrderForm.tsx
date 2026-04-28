import { useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import { signPlaceOrderPayload } from "../../api/exchange-sign";
import { getUnlocked, nextNonce, subscribeWallet } from "../../api/wallet-keystore";
import { useEffect } from "react";
import { useTraderMode } from "./TraderModeToggle";

const rpc = new OmniBusRpcClient();

interface Props {
  pairId: number;
  pairLabel: string;
  /// Called after a successful place so parent can refresh user orders.
  onPlaced?: () => void;
}

const SAT_PER_OMNI = 1_000_000_000;
const MICRO_PER_USD = 1_000_000;

/**
 * BUY/SELL form. Inputs are human-friendly (OMNI + USD); we convert to
 * the chain's u64 native units (SAT, micro-USD) before signing.
 */
export function PlaceOrderForm({ pairId, pairLabel, onPlaced }: Props) {
  const [, force] = useState(0);
  useEffect(() => subscribeWallet(() => force((n) => n + 1)), []);
  const [traderMode] = useTraderMode();

  const [side, setSide] = useState<"buy" | "sell">("buy");
  const [priceStr, setPriceStr] = useState("");
  const [amountStr, setAmountStr] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const u = getUnlocked();

  const submit = async () => {
    setMsg(null);
    setErr(null);
    if (!u) {
      setErr("Unlock the wallet first");
      return;
    }
    const priceUsd = Number(priceStr);
    const amountOmni = Number(amountStr);
    if (!Number.isFinite(priceUsd) || priceUsd <= 0) {
      setErr("Price must be > 0");
      return;
    }
    if (!Number.isFinite(amountOmni) || amountOmni <= 0) {
      setErr("Amount must be > 0");
      return;
    }
    const priceMicroUsd = Math.round(priceUsd * MICRO_PER_USD);
    const amountSat = Math.round(amountOmni * SAT_PER_OMNI);
    const nonce = nextNonce();
    const { signature, publicKey } = signPlaceOrderPayload({
      privateKeyHex: u.privateKey,
      trader: u.address,
      side,
      pairId,
      priceMicroUsd,
      amountSat,
      nonce,
    });
    setBusy(true);
    try {
      const res = await rpc.exchangePlaceOrder({
        trader: u.address,
        side,
        pairId,
        price: priceMicroUsd,
        amount: amountSat,
        nonce,
        signature,
        publicKey,
      });
      setMsg(
        `${res.status.toUpperCase()} — order #${res.orderId}, filled ${
          res.filled / SAT_PER_OMNI
        } / ${res.amount / SAT_PER_OMNI} OMNI`,
      );
      setPriceStr("");
      setAmountStr("");
      onPlaced?.();
    } catch (e: any) {
      setErr(e?.message || "Place failed");
    } finally {
      setBusy(false);
    }
  };

  const notional = (() => {
    const p = Number(priceStr);
    const a = Number(amountStr);
    if (!Number.isFinite(p) || !Number.isFinite(a) || p <= 0 || a <= 0) return 0;
    return p * a;
  })();

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
      <div className="flex items-center justify-between mb-3">
        <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          Place order — {pairLabel}
        </h3>
        <span
          className={`px-2 py-0.5 rounded text-[10px] font-semibold ${
            traderMode === "real"
              ? "bg-mempool-green/20 text-mempool-green"
              : "bg-yellow-500/20 text-yellow-300"
          }`}
        >
          {traderMode === "real" ? "💰 Real" : "🎮 Paper"}
        </span>
      </div>

      {/* Side toggle */}
      <div className="grid grid-cols-2 gap-1 mb-3 bg-mempool-bg rounded p-0.5">
        <button
          onClick={() => setSide("buy")}
          className={`py-1.5 text-xs font-semibold rounded transition-colors ${
            side === "buy"
              ? "bg-green-500/30 text-green-200"
              : "text-mempool-text-dim hover:text-mempool-text"
          }`}
        >
          BUY
        </button>
        <button
          onClick={() => setSide("sell")}
          className={`py-1.5 text-xs font-semibold rounded transition-colors ${
            side === "sell"
              ? "bg-orange-500/30 text-orange-200"
              : "text-mempool-text-dim hover:text-mempool-text"
          }`}
        >
          SELL
        </button>
      </div>

      <label className="block text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">
        Price (USD)
      </label>
      <input
        type="number"
        step="any"
        value={priceStr}
        onChange={(e) => setPriceStr(e.target.value)}
        placeholder="0.10"
        className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text font-mono text-sm mb-3 focus:outline-none focus:border-mempool-blue"
      />

      <label className="block text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">
        Amount (OMNI)
      </label>
      <input
        type="number"
        step="any"
        value={amountStr}
        onChange={(e) => setAmountStr(e.target.value)}
        placeholder="100"
        className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text font-mono text-sm mb-3 focus:outline-none focus:border-mempool-blue"
      />

      <div className="flex justify-between text-[11px] text-mempool-text-dim mb-3">
        <span>Notional</span>
        <span className="font-mono text-mempool-text">
          ${notional > 0 && notional < 0.01
            ? notional.toFixed(6)
            : notional.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 })}
        </span>
      </div>

      <button
        onClick={submit}
        disabled={busy || !u}
        className={`w-full py-2 text-sm font-semibold rounded transition-colors ${
          side === "buy"
            ? "bg-green-500/80 hover:bg-green-500 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
            : "bg-orange-500/80 hover:bg-orange-500 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
        }`}
      >
        {busy ? "Signing & sending…" : !u ? "Unlock wallet first" : `Place ${side.toUpperCase()}`}
      </button>

      {msg && (
        <div className="mt-3 p-2 rounded bg-green-500/10 border border-green-500/30 text-[11px] text-green-200">
          {msg}
        </div>
      )}
      {err && (
        <div className="mt-3 p-2 rounded bg-red-500/10 border border-red-500/30 text-[11px] text-red-300">
          {err}
        </div>
      )}
    </div>
  );
}
