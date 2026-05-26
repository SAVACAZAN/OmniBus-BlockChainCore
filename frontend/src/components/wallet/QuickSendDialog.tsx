/**
 * QuickSendDialog.tsx — modal for sending OMNI without leaving the dashboard.
 *
 * Mirrors the Send card on WalletPage but trimmed to the essentials so users
 * can fire off a payment in 3 fields. Reuses the same RPC + signing path:
 *   - Recipient: ob1q… address OR <name>.<tld> (auto-resolved via ns_resolveforsend)
 *   - Amount: OMNI float, with Max button
 *   - Fee selector: low / normal / fast (mapped from estimateFee)
 *
 * Submit pipeline:
 *   1) Resolve name (if applicable)
 *   2) Fetch current nonce + fee estimate
 *   3) Sign with ECDSA via the keystore singleton (sendTransaction RPC)
 *   4) Show TX hash + confirmation tracker
 */

import { useEffect, useState } from "react";
import { useWallet } from "../../api/use-wallet";
import OmniBusRpcClient from "../../api/rpc-client";
import { useGlobalBalance } from "../../api/use-global-balance";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { FeeEstimate, WsTxConfirmedEvent } from "../../types";
import { SAT_PER_OMNI } from "../../utils/fmt";

const rpc = new OmniBusRpcClient();

type FeeTier = "low" | "normal" | "fast";

const NAME_REGEX = /^[a-z][a-z0-9_]{2,24}\.(omnibus|arbitraje|quantum|bank|gov|mil|fin|edu|org|dev)$/i;

export function QuickSendDialog({ onClose }: { onClose: () => void }) {
  const wallet = useWallet();
  const [to, setTo] = useState("");
  const [amount, setAmount] = useState("");
  const [tier, setTier] = useState<FeeTier>("normal");
  const [feeEstimate, setFeeEstimate] = useState<FeeEstimate | null>(null);
  // Use the global atomic snapshot — Send must reflect AVAILABLE (= wallet -
  // staked - in_orders), not raw wallet balance. Previous version called
  // getBalance() which returned wallet total and let users overdraft into
  // their staked / locked-in-orders funds → chain rejected the TX after
  // sign, leaving the user confused.
  const globalBal = useGlobalBalance();
  const isLive = globalBal.address === wallet?.address && globalBal.fetched_at > 0;
  const balanceSat = isLive ? globalBal.available_sat : 0;
  const stakedSat = isLive ? globalBal.staked_sat : 0;
  const inOrdersSat = isLive ? globalBal.in_orders_sat : 0;
  const [resolvedAddress, setResolvedAddress] = useState<string>("");
  const [submitting, setSubmitting] = useState(false);
  const [result, setResult] = useState<{ ok: boolean; msg: string; txid?: string } | null>(null);
  const [confirmations, setConfirmations] = useState<number | null>(null);

  // Fee tier → effective fee (sat/byte). low = min, normal = median, fast = ~2x median.
  const effectiveFee = (() => {
    if (!feeEstimate) return 1;
    if (tier === "low")  return feeEstimate.minFee || feeEstimate.medianFee || 1;
    if (tier === "fast") return Math.max(1, Math.ceil((feeEstimate.medianFee || 1) * 2));
    return feeEstimate.medianFee || 1;
  })();

  // Esc closes the dialog.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  // Fetch fee estimate once on mount. Balance comes from useGlobalBalance,
  // which polls every 8 s and broadcasts to all subscribers (Wallet / Stake
  // / Header pill all stay in sync with this dialog).
  useEffect(() => {
    (async () => {
      try {
        const fee = await rpc.estimateFee();
        if (fee) setFeeEstimate(fee);
      } catch {}
    })();
  }, []);

  // Resolve name → address whenever the input looks like a name. Debounced
  // implicitly by React's render loop — typing fast just re-fires the effect
  // which is cheap (single RPC).
  useEffect(() => {
    const trimmed = to.trim().toLowerCase();
    if (!trimmed) { setResolvedAddress(""); return; }
    if (!NAME_REGEX.test(trimmed)) {
      // Looks like an address already (or not yet a complete name) — accept as-is.
      setResolvedAddress(trimmed.startsWith("ob") ? trimmed : "");
      return;
    }
    const [n, t] = trimmed.split(".");
    let cancelled = false;
    (async () => {
      try {
        const r: any = await rpc.request_raw("ns_resolveforsend", [n, t]);
        if (cancelled) return;
        if (r?.found) {
          setResolvedAddress(r.route_address || r.primary_address || "");
        } else {
          setResolvedAddress("");
        }
      } catch {
        if (!cancelled) setResolvedAddress("");
      }
    })();
    return () => { cancelled = true; };
  }, [to]);

  // Track confirmations after sending via WS event (instant) + polling fallback.
  useEffect(() => {
    if (!result?.txid) return;
    const txid = result.txid;
    // WebSocket: fires immediately when the block is found.
    const unsub = wsSubscribe<WsTxConfirmedEvent>("tx_confirmed", (ev) => {
      if (ev.hash === txid) setConfirmations(ev.blockHeight);
    });
    // Polling fallback: catches the case where WS is disconnected or the TX
    // was already confirmed before the dialog opened.
    let cancelled = false;
    const tick = async () => {
      try {
        const r: any = await rpc.request_raw("gettransaction", [txid]);
        if (cancelled) return;
        if (typeof r?.confirmations === "number") setConfirmations(r.confirmations);
      } catch {}
    };
    tick();
    const id = setInterval(tick, 5_000);
    return () => { cancelled = true; clearInterval(id); unsub(); };
  }, [result?.txid]);

  const onMax = () => {
    if (balanceSat <= 0) return;
    // Reserve a token amount for the fee — 1 sat min, otherwise 1k sat for headroom.
    const reserve = Math.max(1_000, effectiveFee * 200);
    const spendable = Math.max(0, balanceSat - reserve);
    setAmount((spendable / SAT_PER_OMNI).toFixed(9).replace(/\.?0+$/, ""));
  };

  const onSubmit = async () => {
    if (!wallet) return;
    setResult(null);
    setSubmitting(true);
    try {
      const finalAddr = resolvedAddress || to.trim();
      if (!finalAddr.startsWith("ob")) throw new Error("Invalid recipient address");
      const amountSat = Math.floor(parseFloat(amount || "0") * SAT_PER_OMNI);
      if (!amountSat || amountSat <= 0) throw new Error("Amount must be > 0");
      if (amountSat > balanceSat) throw new Error("Insufficient balance");

      // sendTransaction RPC handles signing on the chain server using the
      // unlocked wallet's privkey via the same keystore singleton — UI
      // does not transmit the privkey itself.
      const txResult: any = await rpc.sendTransaction(finalAddr, amountSat);
      const txid = typeof txResult === "object" ? txResult?.txid : txResult;
      setResult({ ok: true, msg: "Transaction sent", txid: (txid || "").toString() });
    } catch (e: any) {
      setResult({ ok: false, msg: e?.message || "Send failed" });
    } finally {
      setSubmitting(false);
    }
  };

  if (!wallet) {
    return (
      <Modal onClose={onClose}>
        <div className="text-sm text-mempool-text-dim">
          Connect your wallet first to send OMNI.
        </div>
      </Modal>
    );
  }

  return (
    <Modal onClose={onClose}>
      <div className="space-y-4">
        <div className="flex items-center justify-between">
          <h2 className="text-base font-bold text-mempool-text">Quick send OMNI</h2>
          <button onClick={onClose} className="text-mempool-text-dim hover:text-mempool-text">✕</button>
        </div>

        <div className="bg-mempool-bg rounded-lg border border-mempool-border p-3 text-xs">
          <div className="flex justify-between">
            <span className="text-mempool-text-dim">From</span>
            <span className="font-mono text-mempool-blue text-[11px] break-all max-w-[60%] text-right">
              {wallet.address}
            </span>
          </div>
          <div className="flex justify-between mt-1">
            <span className="text-mempool-text-dim">Available</span>
            <span className="font-mono text-mempool-green">
              {(balanceSat / SAT_PER_OMNI).toFixed(4)} OMNI
            </span>
          </div>
          {(stakedSat > 0 || inOrdersSat > 0) && (
            <div className="text-[10px] text-mempool-text-dim/70 mt-1 space-y-0.5">
              {stakedSat > 0 && (
                <div className="flex justify-between">
                  <span>· staked (locked)</span>
                  <span className="font-mono">{(stakedSat / SAT_PER_OMNI).toFixed(4)}</span>
                </div>
              )}
              {inOrdersSat > 0 && (
                <div className="flex justify-between">
                  <span>· in open orders</span>
                  <span className="font-mono">{(inOrdersSat / SAT_PER_OMNI).toFixed(4)}</span>
                </div>
              )}
            </div>
          )}
        </div>

        <div>
          <label className="text-[10px] text-mempool-text-dim uppercase tracking-wider">
            Recipient (address or name.tld)
          </label>
          <input
            type="text"
            placeholder="ob1q… or savacazan.omnibus"
            value={to}
            onChange={(e) => setTo(e.target.value)}
            className="w-full bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm font-mono text-mempool-text mt-1 focus:outline-none focus:border-mempool-blue"
            autoFocus
          />
          {resolvedAddress && resolvedAddress !== to.trim() && (
            <div className="mt-1 text-[11px] text-mempool-text-dim">
              → <span className="font-mono text-mempool-blue">{resolvedAddress}</span>
            </div>
          )}
        </div>

        <div>
          <div className="flex items-center justify-between">
            <label className="text-[10px] text-mempool-text-dim uppercase tracking-wider">
              Amount (OMNI)
            </label>
            <button
              onClick={onMax}
              className="text-[10px] text-mempool-blue hover:text-mempool-text"
            >
              Max
            </button>
          </div>
          <input
            type="text"
            inputMode="decimal"
            placeholder="0.0"
            value={amount}
            onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))}
            className="w-full bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm font-mono text-mempool-text mt-1 focus:outline-none focus:border-mempool-blue"
          />
        </div>

        <div>
          <label className="text-[10px] text-mempool-text-dim uppercase tracking-wider">
            Fee
          </label>
          <div className="grid grid-cols-3 gap-1.5 mt-1">
            {(["low", "normal", "fast"] as FeeTier[]).map((t) => (
              <button
                key={t}
                onClick={() => setTier(t)}
                className={`py-2 text-xs rounded-lg border transition-colors ${
                  tier === t
                    ? "bg-mempool-blue/20 border-mempool-blue text-mempool-blue font-semibold"
                    : "bg-mempool-bg border-mempool-border text-mempool-text-dim hover:text-mempool-text"
                }`}
              >
                <div className="capitalize">{t}</div>
                <div className="text-[10px] opacity-70">
                  {feeEstimate
                    ? t === "low"
                      ? (feeEstimate.minFee || feeEstimate.medianFee || 1)
                      : t === "fast"
                      ? Math.max(1, Math.ceil((feeEstimate.medianFee || 1) * 2))
                      : (feeEstimate.medianFee || 1)
                    : "—"}
                  {" sat/B"}
                </div>
              </button>
            ))}
          </div>
        </div>

        {result && (
          <div className={`text-xs rounded px-3 py-2 ${
            result.ok
              ? "text-mempool-green bg-mempool-green/10 border border-mempool-green/30"
              : "text-red-400 bg-red-500/10 border border-red-500/30"
          }`}>
            <div>{result.msg}</div>
            {result.txid && (
              <div className="mt-1 font-mono text-[10px] break-all">
                TX: {result.txid}
                {confirmations !== null && (
                  <span className="ml-2 text-mempool-text-dim">
                    · {confirmations} confirmation{confirmations === 1 ? "" : "s"}
                  </span>
                )}
              </div>
            )}
          </div>
        )}

        {!result?.ok && (
          <button
            onClick={onSubmit}
            disabled={submitting || !to.trim() || !amount}
            className="w-full bg-mempool-blue hover:bg-mempool-blue/80 disabled:bg-mempool-bg-light disabled:text-mempool-text-dim text-white font-semibold rounded-lg px-4 py-2.5 text-sm transition-colors"
          >
            {submitting ? "Signing & sending…" : "Send"}
          </button>
        )}

        {result?.ok && (
          <button
            onClick={onClose}
            className="w-full bg-mempool-bg border border-mempool-border text-mempool-text-dim hover:text-mempool-text rounded-lg px-4 py-2 text-sm"
          >
            Close
          </button>
        )}
      </div>
    </Modal>
  );
}

function Modal({ onClose, children }: { onClose: () => void; children: React.ReactNode }) {
  return (
    <div
      className="fixed inset-0 z-[60] flex items-center justify-center bg-black/60 backdrop-blur-sm p-4"
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
    >
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl shadow-2xl max-w-md w-full p-5">
        {children}
      </div>
    </div>
  );
}
