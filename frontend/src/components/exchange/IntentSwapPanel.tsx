/**
 * IntentSwapPanel.tsx — UI for intent_* RPC methods (atomic intent swaps).
 *
 * Intent swaps are a maker/taker atomic swap mechanism on OmniBus:
 *   - Maker calls intent_post  (TX type 0x40) to publish an intent
 *   - Taker calls intent_fill_commit (TX type 0x41) to lock a bond and claim filling rights
 *   - Settlement via swap_proveSettle (0x42), timeout reclaim via intent_timeout (0x43)
 *
 * RPC params (from rpc_server.zig):
 *   intent_post         { swap_id, taker_chain, expiry_block, maker_amount_sat, taker_min_sat? }
 *   intent_fill_commit  { intent_id, bond_locked_sat }
 *   intent_timeout      { intent_id, slashed_bond_sat?, swap_id? }
 *   swap_listOpen       {}  → array of open swaps (swap_id, order_id, state, maker_chain, taker_chain, timeout_block)
 *
 * Chain enum for taker_chain (rpc_server.zig line 8682): 0=omnibus, 1=btc, 2=eth, 3=base, 4=liberty
 * Note: intent_post uses 0..3 (max 3), swap_open uses 1..4.
 */

import { useState, useEffect, useCallback } from "react";
import { useBlockHeight } from "../../api/use-block-height";
import {
  RefreshCw,
  ArrowLeftRight,
  Plus,
  List,
  Globe,
  Clock,
  CheckCircle,
  XCircle,
  AlertCircle,
} from "lucide-react";
import { rpc } from "../../api/rpc-client";
import { SAT_PER_OMNI, midTrunc, fmtInt } from "../../utils/fmt";
import { useWallet } from "../../api/use-wallet";
import { signMessage } from "../../api/exchange-sign";

// exchange-sign.ts initializes noble's HMAC-SHA256 as a side-effect on import.


// ── Types ──────────────────────────────────────────────────────────────────────

type SubTab = "my-intents" | "market" | "post" | "fill";

/** Shape returned by swap_listOpen */
interface SwapEntry {
  swap_id: string;
  order_id: number;
  state: string;
  maker_chain: string;
  taker_chain: string;
  timeout_block: number;
}

/** Shape of a locally-posted intent (we persist in sessionStorage for "My Intents") */
interface LocalIntent {
  intent_id: string;
  swap_id: string;
  expiry_block: number;
  taker_chain: number;
  maker_amount_sat: number;
  taker_min_sat: number;
  tx_hash: string;
  posted_at: number; // block height when posted
  status: "open" | "filled" | "settled" | "timeout" | "cancelled";
}

// ── Constants ─────────────────────────────────────────────────────────────────

const TAKER_CHAIN_OPTIONS: { label: string; value: number }[] = [
  { label: "OmniBus", value: 0 },
  { label: "Bitcoin", value: 1 },
  { label: "Ethereum", value: 2 },
  { label: "Base", value: 3 },
];

const LOCAL_INTENTS_KEY = "omnibus_local_intents_v1";

// ── Helpers ──────────────────────────────────────────────────────────────────

function loadLocalIntents(): LocalIntent[] {
  try {
    const raw = sessionStorage.getItem(LOCAL_INTENTS_KEY);
    if (!raw) return [];
    return JSON.parse(raw) as LocalIntent[];
  } catch {
    return [];
  }
}

function saveLocalIntents(intents: LocalIntent[]): void {
  try {
    sessionStorage.setItem(LOCAL_INTENTS_KEY, JSON.stringify(intents));
  } catch {
    // quota exceeded — ignore
  }
}

function satToDisplay(sat: number): string {
  return (sat / SAT_PER_OMNI).toFixed(4);
}

function displayToSat(s: string): number {
  return Math.round(parseFloat(s) * SAT_PER_OMNI);
}

function genNonce(): number {
  return Math.floor(Math.random() * 2_000_000_000);
}

/** Generates a random 32-byte hex string (swap_id) */
function genSwapId(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function shortHex(h: string): string {
  if (h.length <= 12) return h;
  return midTrunc(h, 8, 4);
}


// ── Status badge ─────────────────────────────────────────────────────────────

type IntentStatus =
  | "open"
  | "pending"
  | "filled"
  | "settled"
  | "expired"
  | "cancelled"
  | string;

function StatusBadge({ status }: { status: IntentStatus }) {
  const map: Record<string, string> = {
    open: "bg-mempool-blue/20 text-mempool-blue border border-mempool-blue/40",
    pending:
      "bg-yellow-500/20 text-yellow-400 border border-yellow-500/40",
    filled:
      "bg-green-500/20 text-green-400 border border-green-500/40",
    settled: "bg-gray-500/20 text-gray-400 border border-gray-500/40",
    both_locked:
      "bg-green-500/20 text-green-400 border border-green-500/40",
    expired:
      "bg-yellow-500/20 text-yellow-400 border border-yellow-500/40",
    timeout:
      "bg-yellow-500/20 text-yellow-400 border border-yellow-500/40",
    cancelled:
      "bg-red-500/20 text-red-400 border border-red-500/40",
  };
  const cls =
    map[status] ??
    "bg-gray-500/20 text-gray-400 border border-gray-500/40";
  return (
    <span
      className={`inline-block px-2 py-0.5 rounded text-[10px] font-semibold uppercase tracking-wider ${cls}`}
    >
      {status}
    </span>
  );
}

// ── My Intents sub-tab ────────────────────────────────────────────────────────

function MyIntentsTab() {
  const wallet = useWallet();
  const [intents, setIntents] = useState<LocalIntent[]>([]);
  const blockHeight = useBlockHeight();
  const [busy, setBusy] = useState<string | null>(null);
  const [feedback, setFeedback] = useState<{
    id: string;
    msg: string;
    ok: boolean;
  } | null>(null);

  useEffect(() => {
    setIntents(loadLocalIntents());
  }, []);

  const refresh = useCallback(() => {
    setIntents(loadLocalIntents());
  }, []);

  const markStatus = (intent_id: string, status: LocalIntent["status"]) => {
    const updated = loadLocalIntents().map((i) =>
      i.intent_id === intent_id ? { ...i, status } : i
    );
    saveLocalIntents(updated);
    setIntents(updated);
  };

  const handleTimeout = async (intent: LocalIntent) => {
    if (!wallet) return;
    setBusy(intent.intent_id);
    setFeedback(null);
    try {
      const result = await rpc.request_raw("intent_timeout", [
        {
          intent_id: intent.intent_id,
          swap_id: intent.swap_id,
          slashed_bond_sat: 0,
        },
      ]);
      markStatus(intent.intent_id, "timeout");
      setFeedback({
        id: intent.intent_id,
        msg: `Timeout TX: ${result?.tx_hash ?? "submitted"}`,
        ok: true,
      });
    } catch (err) {
      setFeedback({
        id: intent.intent_id,
        msg: String(err),
        ok: false,
      });
    } finally {
      setBusy(null);
    }
  };

  if (!wallet) {
    return (
      <div className="text-mempool-text-dim text-sm text-center py-8">
        Connect wallet to view your intents.
      </div>
    );
  }

  if (intents.length === 0) {
    return (
      <div className="text-mempool-text-dim text-sm text-center py-8">
        No posted intents found. Use the &ldquo;Post Intent&rdquo; tab to create one.
      </div>
    );
  }

  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between mb-2">
        <span className="text-xs text-mempool-text-dim">
          Block height: {fmtInt(blockHeight)}
        </span>
        <button
          onClick={refresh}
          className="flex items-center gap-1 text-xs text-mempool-blue hover:opacity-80"
        >
          <RefreshCw className="w-3 h-3" />
          Refresh
        </button>
      </div>

      {intents.map((intent) => {
        const isExpired = blockHeight > 0 && blockHeight >= intent.expiry_block;
        const canTimeout = isExpired && intent.status === "open";
        const isBusy = busy === intent.intent_id;

        return (
          <div
            key={intent.intent_id}
            className="bg-mempool-bg rounded-lg border border-mempool-border p-3 space-y-1.5"
          >
            <div className="flex items-start justify-between gap-2">
              <div className="min-w-0">
                <p className="text-xs font-mono text-mempool-text truncate">
                  {shortHex(intent.intent_id)}
                </p>
                <p className="text-[10px] text-mempool-text-dim font-mono">
                  swap: {shortHex(intent.swap_id)}
                </p>
              </div>
              <StatusBadge status={isExpired && intent.status === "open" ? "expired" : intent.status} />
            </div>

            <div className="grid grid-cols-3 gap-2 text-xs">
              <div>
                <p className="text-mempool-text-dim text-[10px]">Amount</p>
                <p className="text-mempool-text font-mono">
                  {satToDisplay(intent.maker_amount_sat)} OMNI
                </p>
              </div>
              <div>
                <p className="text-mempool-text-dim text-[10px]">Min taker</p>
                <p className="text-mempool-text font-mono">
                  {satToDisplay(intent.taker_min_sat)} OMNI
                </p>
              </div>
              <div>
                <p className="text-mempool-text-dim text-[10px]">Expiry block</p>
                <p className={`font-mono ${isExpired ? "text-yellow-400" : "text-mempool-text"}`}>
                  {fmtInt(intent.expiry_block)}
                </p>
              </div>
            </div>

            <div className="text-[10px] text-mempool-text-dim font-mono">
              TX: {shortHex(intent.tx_hash)}
            </div>

            {feedback?.id === intent.intent_id && (
              <p
                className={`text-xs ${feedback.ok ? "text-green-400" : "text-red-400"} break-all`}
              >
                {feedback.msg}
              </p>
            )}

            {canTimeout && (
              <button
                disabled={isBusy}
                onClick={() => handleTimeout(intent)}
                className="w-full mt-1 bg-yellow-500/20 text-yellow-400 border border-yellow-500/40 px-3 py-1.5 rounded text-xs font-semibold hover:bg-yellow-500/30 disabled:opacity-50"
              >
                {isBusy ? "Submitting…" : "Reclaim (Timeout)"}
              </button>
            )}
          </div>
        );
      })}
    </div>
  );
}

// ── Market sub-tab ────────────────────────────────────────────────────────────

function MarketTab() {
  const wallet = useWallet();
  const [swaps, setSwaps] = useState<SwapEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [feedback, setFeedback] = useState<{
    id: string;
    msg: string;
    ok: boolean;
  } | null>(null);
  const [bondInput, setBondInput] = useState<Record<string, string>>({});

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await rpc.request_raw("swap_listOpen", []);
      setSwaps(Array.isArray(result) ? result : []);
    } catch (err) {
      setError(String(err));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const handleFill = async (swap: SwapEntry) => {
    if (!wallet) return;
    const bondSatStr = bondInput[swap.swap_id];
    const bondSat = bondSatStr ? displayToSat(bondSatStr) : 0;
    if (!bondSat || bondSat <= 0) {
      setFeedback({ id: swap.swap_id, msg: "Enter bond amount (OMNI)", ok: false });
      return;
    }

    // intent_id is not always known from swap_listOpen;
    // the taker signs and submits with the swap_id as intent_id fallback.
    // The chain accepts any 64-hex intent_id — use swap_id as the intent_id here.
    const intentId = swap.swap_id;
    const nonce = genNonce();
    const msg = `INTENT_FILL_V1\n${wallet.address}\n${intentId}\n${nonce}`;

    setBusy(swap.swap_id);
    setFeedback(null);
    try {
      const sig = signMessage(wallet.privateKey, msg);
      const result = await rpc.request_raw("intent_fill_commit", [
        {
          intent_id: intentId,
          bond_locked_sat: bondSat,
          signature: sig.signature,
          public_key: sig.publicKey,
          nonce,
        },
      ]);
      setFeedback({
        id: swap.swap_id,
        msg: `Fill TX: ${result?.tx_hash ?? "submitted"}`,
        ok: true,
      });
      // Reload after fill
      await load();
    } catch (err) {
      setFeedback({ id: swap.swap_id, msg: String(err), ok: false });
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between mb-2">
        <span className="text-xs text-mempool-text-dim">
          {swaps.length} open swap{swaps.length !== 1 ? "s" : ""}
        </span>
        <div className="flex items-center gap-2">
          {swaps.length > 0 && (
            <button
              onClick={() => {
                const rows = [
                  ["swap_id","order_id","state","maker_chain","taker_chain","timeout_block"].join(","),
                  ...swaps.map((s) => [
                    `"${s.swap_id}"`,
                    s.order_id,
                    s.state,
                    s.maker_chain,
                    s.taker_chain,
                    s.timeout_block,
                  ].join(",")),
                ].join("\n");
                const blob = new Blob([rows], { type: "text/csv" });
                const url = URL.createObjectURL(blob);
                const a = document.createElement("a");
                a.href = url; a.download = "omnibus-intent-swaps.csv";
                a.click(); URL.revokeObjectURL(url);
              }}
              className="px-2 py-1 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue"
            >
              ⬇ CSV
            </button>
          )}
          <button
            onClick={load}
            disabled={loading}
            className="flex items-center gap-1 text-xs text-mempool-blue hover:opacity-80 disabled:opacity-50"
          >
            <RefreshCw className={`w-3 h-3 ${loading ? "animate-spin" : ""}`} />
            Refresh
          </button>
        </div>
      </div>

      {error && (
        <p className="text-red-400 text-xs">{error}</p>
      )}

      {loading && swaps.length === 0 && (
        <div className="text-mempool-text-dim text-xs text-center py-8 animate-pulse">
          Loading open swaps…
        </div>
      )}
      {!loading && swaps.length === 0 && !error && (
        <div className="text-mempool-text-dim text-sm text-center py-8">
          No open swaps available.
        </div>
      )}

      {swaps.map((swap) => {
        const isBusy = busy === swap.swap_id;
        return (
          <div
            key={swap.swap_id}
            className="bg-mempool-bg rounded-lg border border-mempool-border p-3 space-y-2"
          >
            <div className="flex items-start justify-between gap-2">
              <p className="text-xs font-mono text-mempool-text truncate">
                {shortHex(swap.swap_id)}
              </p>
              <StatusBadge status={swap.state} />
            </div>

            <div className="grid grid-cols-3 gap-2 text-xs">
              <div>
                <p className="text-mempool-text-dim text-[10px]">Order ID</p>
                <p className="text-mempool-text font-mono">{swap.order_id}</p>
              </div>
              <div>
                <p className="text-mempool-text-dim text-[10px]">Maker chain</p>
                <p className="text-mempool-text capitalize">{swap.maker_chain}</p>
              </div>
              <div>
                <p className="text-mempool-text-dim text-[10px]">Taker chain</p>
                <p className="text-mempool-text capitalize">{swap.taker_chain}</p>
              </div>
            </div>

            <p className="text-[10px] text-mempool-text-dim">
              Timeout block: {fmtInt(swap.timeout_block)}
            </p>

            {feedback?.id === swap.swap_id && (
              <p
                className={`text-xs ${feedback.ok ? "text-green-400" : "text-red-400"} break-all`}
              >
                {feedback.msg}
              </p>
            )}

            {wallet && (
              <div className="flex gap-2 items-center">
                <input
                  type="number"
                  min="0"
                  step="0.0001"
                  placeholder="Bond (OMNI)"
                  value={bondInput[swap.swap_id] ?? ""}
                  onChange={(e) =>
                    setBondInput((prev) => ({
                      ...prev,
                      [swap.swap_id]: e.target.value,
                    }))
                  }
                  className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-1.5 text-xs text-mempool-text w-32 focus:outline-none focus:border-mempool-blue"
                />
                <button
                  disabled={isBusy}
                  onClick={() => handleFill(swap)}
                  className="bg-mempool-blue text-white px-3 py-1.5 rounded-lg text-xs font-semibold hover:opacity-90 disabled:opacity-50"
                >
                  {isBusy ? "Filling…" : "Fill Intent"}
                </button>
              </div>
            )}

            {!wallet && (
              <p className="text-xs text-mempool-text-dim italic">
                Connect wallet to fill this swap.
              </p>
            )}
          </div>
        );
      })}
    </div>
  );
}

// ── Post Intent sub-tab ───────────────────────────────────────────────────────

function PostIntentTab() {
  const wallet = useWallet();
  const [takerChain, setTakerChain] = useState(0);
  const [makerAmount, setMakerAmount] = useState("");
  const [takerMin, setTakerMin] = useState("");
  const [expiryBlocks, setExpiryBlocks] = useState("100");
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<{
    ok: boolean;
    msg: string;
    intentId?: string;
    txHash?: string;
  } | null>(null);

  const handlePost = async () => {
    if (!wallet) return;
    const makerSat = displayToSat(makerAmount);
    const takerMinSat = takerMin ? displayToSat(takerMin) : 0;
    const expiry = parseInt(expiryBlocks, 10);

    if (!makerSat || makerSat <= 0) {
      setResult({ ok: false, msg: "Enter a valid maker amount." });
      return;
    }
    if (!expiry || expiry <= 0 || expiry > 0xffffffff) {
      setResult({ ok: false, msg: "Enter a valid expiry (1 – 4294967295 blocks)." });
      return;
    }

    const swapId = genSwapId();
    const nonce = genNonce();

    // Signing message for intent_post
    const msg = `INTENT_POST_V1\n${wallet.address}\n${swapId}\n${takerChain}\n${makerSat}\n${takerMinSat}\n${expiry}\n${nonce}`;

    setBusy(true);
    setResult(null);
    try {
      const sig = signMessage(wallet.privateKey, msg);

      const resp = await rpc.request_raw("intent_post", [
        {
          swap_id: swapId,
          taker_chain: takerChain,
          expiry_block: expiry,
          maker_amount_sat: makerSat,
          taker_min_sat: takerMinSat,
          signature: sig.signature,
          public_key: sig.publicKey,
          nonce,
        },
      ]);

      // Persist locally
      const intentRecord: LocalIntent = {
        intent_id: resp?.intent_id ?? swapId,
        swap_id: resp?.swap_id ?? swapId,
        expiry_block: resp?.expiry_block ?? expiry,
        taker_chain: takerChain,
        maker_amount_sat: makerSat,
        taker_min_sat: takerMinSat,
        tx_hash: resp?.tx_hash ?? "",
        posted_at: 0,
        status: "open",
      };
      const existing = loadLocalIntents();
      saveLocalIntents([intentRecord, ...existing]);

      setResult({
        ok: true,
        msg: "Intent posted successfully.",
        intentId: intentRecord.intent_id,
        txHash: intentRecord.tx_hash,
      });

      // Reset form
      setMakerAmount("");
      setTakerMin("");
      setExpiryBlocks("100");
    } catch (err) {
      setResult({ ok: false, msg: String(err) });
    } finally {
      setBusy(false);
    }
  };

  if (!wallet) {
    return (
      <div className="text-mempool-text-dim text-sm text-center py-8">
        Connect wallet to post an intent.
      </div>
    );
  }

  return (
    <div className="space-y-4 max-w-md">
      <div className="bg-mempool-bg rounded-lg border border-mempool-border p-3 space-y-3">
        <p className="text-xs text-mempool-text-dim">
          From: <span className="font-mono text-mempool-text">{wallet.address}</span>
        </p>

        {/* Taker chain */}
        <div>
          <label className="block text-xs text-mempool-text-dim mb-1">
            Taker chain (who fills the other side)
          </label>
          <select
            value={takerChain}
            onChange={(e) => setTakerChain(parseInt(e.target.value, 10))}
            className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text w-full focus:outline-none focus:border-mempool-blue"
          >
            {TAKER_CHAIN_OPTIONS.map((opt) => (
              <option key={opt.value} value={opt.value}>
                {opt.label}
              </option>
            ))}
          </select>
        </div>

        {/* Maker amount */}
        <div>
          <label className="block text-xs text-mempool-text-dim mb-1">
            Maker amount (OMNI)
          </label>
          <input
            type="number"
            min="0"
            step="0.0001"
            placeholder="e.g. 10.0"
            value={makerAmount}
            onChange={(e) => setMakerAmount(e.target.value)}
            className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text w-full focus:outline-none focus:border-mempool-blue"
          />
          {makerAmount && !isNaN(parseFloat(makerAmount)) && (
            <p className="text-[10px] text-mempool-text-dim mt-0.5">
              = {fmtInt(displayToSat(makerAmount))} sat
            </p>
          )}
        </div>

        {/* Taker min (optional) */}
        <div>
          <label className="block text-xs text-mempool-text-dim mb-1">
            Taker minimum (OMNI) — optional
          </label>
          <input
            type="number"
            min="0"
            step="0.0001"
            placeholder="0 = accept any"
            value={takerMin}
            onChange={(e) => setTakerMin(e.target.value)}
            className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text w-full focus:outline-none focus:border-mempool-blue"
          />
        </div>

        {/* Expiry */}
        <div>
          <label className="block text-xs text-mempool-text-dim mb-1">
            Expiry (blocks from now)
          </label>
          <input
            type="number"
            min="1"
            max="4294967295"
            step="1"
            value={expiryBlocks}
            onChange={(e) => setExpiryBlocks(e.target.value)}
            className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text w-full focus:outline-none focus:border-mempool-blue"
          />
          <p className="text-[10px] text-mempool-text-dim mt-0.5">
            ~{(parseInt(expiryBlocks, 10) || 0)} blocks at 1 s/block ≈{" "}
            {Math.round(((parseInt(expiryBlocks, 10) || 0) / 60))} min
          </p>
        </div>

        {result && (
          <div
            className={`rounded-lg p-2 text-xs ${
              result.ok
                ? "bg-green-500/10 text-green-400 border border-green-500/30"
                : "bg-red-500/10 text-red-400 border border-red-500/30"
            }`}
          >
            <p className="font-semibold mb-1">{result.msg}</p>
            {result.intentId && (
              <p className="font-mono break-all">
                Intent ID: {result.intentId}
              </p>
            )}
            {result.txHash && (
              <p className="font-mono break-all">TX: {result.txHash}</p>
            )}
          </div>
        )}

        <button
          disabled={busy}
          onClick={handlePost}
          className="w-full bg-mempool-blue text-white px-4 py-2 rounded-lg text-sm font-semibold hover:opacity-90 disabled:opacity-50 flex items-center justify-center gap-2"
        >
          <Plus className="w-4 h-4" />
          {busy ? "Posting…" : "Post Intent"}
        </button>
      </div>

      <div className="bg-mempool-bg rounded-lg border border-mempool-border p-3 text-xs text-mempool-text-dim space-y-1">
        <p className="font-semibold text-mempool-text">How it works</p>
        <p>1. You post an intent (TX 0x40) locking <em>maker_amount_sat</em> OMNI to swap.</p>
        <p>2. A taker commits a bond via <em>intent_fill_commit</em> (TX 0x41).</p>
        <p>3. Settlement via hash/preimage (TX 0x42). Both sides atomic.</p>
        <p>4. If no taker fills before expiry, reclaim via &ldquo;Timeout&rdquo; in My Intents.</p>
      </div>
    </div>
  );
}

// ── Fill Intent sub-tab ───────────────────────────────────────────────────────

function FillIntentTab() {
  const wallet = useWallet();
  const [intentId, setIntentId] = useState("");
  const [bondAmount, setBondAmount] = useState("");
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<{
    ok: boolean;
    msg: string;
    txHash?: string;
    bondLockedSat?: number;
  } | null>(null);

  const handleFill = async () => {
    if (!wallet) return;

    const trimmedId = intentId.trim();
    if (trimmedId.length !== 64 || !/^[0-9a-fA-F]+$/.test(trimmedId)) {
      setResult({ ok: false, msg: "Intent ID must be 64 hex characters." });
      return;
    }

    const bondSat = displayToSat(bondAmount);
    if (!bondSat || bondSat <= 0) {
      setResult({ ok: false, msg: "Enter a valid bond amount > 0." });
      return;
    }

    const nonce = genNonce();
    const msg = `INTENT_FILL_V1\n${wallet.address}\n${trimmedId}\n${nonce}`;

    setBusy(true);
    setResult(null);
    try {
      const sig = signMessage(wallet.privateKey, msg);

      const resp = await rpc.request_raw("intent_fill_commit", [
        {
          intent_id: trimmedId,
          bond_locked_sat: bondSat,
          signature: sig.signature,
          public_key: sig.publicKey,
          nonce,
        },
      ]);

      setResult({
        ok: true,
        msg: "Fill committed successfully.",
        txHash: resp?.tx_hash,
        bondLockedSat: resp?.bond_locked_sat,
      });
      setIntentId("");
      setBondAmount("");
    } catch (err) {
      setResult({ ok: false, msg: String(err) });
    } finally {
      setBusy(false);
    }
  };

  const handleSettle = async () => {
    if (!wallet) return;

    const trimmedId = intentId.trim();
    if (trimmedId.length !== 64 || !/^[0-9a-fA-F]+$/.test(trimmedId)) {
      setResult({ ok: false, msg: "Intent ID must be 64 hex characters." });
      return;
    }

    setBusy(true);
    setResult(null);
    try {
      // intent_settle delegates to swap_proveSettle (0x42)
      // Minimal params: swap_id = intent_id, preimage can be omitted for on-chain probe
      const resp = await rpc.request_raw("intent_settle", [
        {
          swap_id: trimmedId,
        },
      ]);

      setResult({
        ok: true,
        msg: "Settle TX submitted.",
        txHash: resp?.tx_hash,
      });
    } catch (err) {
      setResult({ ok: false, msg: String(err) });
    } finally {
      setBusy(false);
    }
  };

  if (!wallet) {
    return (
      <div className="text-mempool-text-dim text-sm text-center py-8">
        Connect wallet to fill an intent.
      </div>
    );
  }

  return (
    <div className="space-y-4 max-w-md">
      <div className="bg-mempool-bg rounded-lg border border-mempool-border p-3 space-y-3">
        <p className="text-xs text-mempool-text-dim">
          From: <span className="font-mono text-mempool-text">{wallet.address}</span>
        </p>

        {/* Intent ID */}
        <div>
          <label className="block text-xs text-mempool-text-dim mb-1">
            Intent ID (64 hex chars)
          </label>
          <input
            type="text"
            placeholder="e.g. a1b2c3d4…"
            value={intentId}
            onChange={(e) => setIntentId(e.target.value.trim())}
            className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text w-full focus:outline-none focus:border-mempool-blue font-mono"
            maxLength={64}
          />
          {intentId.length > 0 && intentId.length !== 64 && (
            <p className="text-[10px] text-yellow-400 mt-0.5">
              {intentId.length}/64 chars
            </p>
          )}
        </div>

        {/* Bond amount */}
        <div>
          <label className="block text-xs text-mempool-text-dim mb-1">
            Bond amount (OMNI) — locked until settlement or slash
          </label>
          <input
            type="number"
            min="0"
            step="0.0001"
            placeholder="e.g. 1.0"
            value={bondAmount}
            onChange={(e) => setBondAmount(e.target.value)}
            className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text w-full focus:outline-none focus:border-mempool-blue"
          />
          {bondAmount && !isNaN(parseFloat(bondAmount)) && (
            <p className="text-[10px] text-mempool-text-dim mt-0.5">
              = {fmtInt(displayToSat(bondAmount))} sat
            </p>
          )}
        </div>

        {result && (
          <div
            className={`rounded-lg p-2 text-xs ${
              result.ok
                ? "bg-green-500/10 text-green-400 border border-green-500/30"
                : "bg-red-500/10 text-red-400 border border-red-500/30"
            }`}
          >
            <p className="font-semibold mb-1">{result.msg}</p>
            {result.txHash && (
              <p className="font-mono break-all">TX: {result.txHash}</p>
            )}
            {result.bondLockedSat !== undefined && (
              <p>Bond locked: {satToDisplay(result.bondLockedSat)} OMNI</p>
            )}
          </div>
        )}

        <div className="flex gap-2">
          <button
            disabled={busy}
            onClick={handleFill}
            className="flex-1 bg-mempool-blue text-white px-4 py-2 rounded-lg text-sm font-semibold hover:opacity-90 disabled:opacity-50 flex items-center justify-center gap-2"
          >
            <ArrowLeftRight className="w-4 h-4" />
            {busy ? "Submitting…" : "Fill Commit"}
          </button>
          <button
            disabled={busy}
            onClick={handleSettle}
            className="flex-1 bg-green-600/80 text-white px-4 py-2 rounded-lg text-sm font-semibold hover:opacity-90 disabled:opacity-50 flex items-center justify-center gap-2"
          >
            <CheckCircle className="w-4 h-4" />
            {busy ? "Submitting…" : "Settle"}
          </button>
        </div>
      </div>

      <div className="bg-mempool-bg rounded-lg border border-mempool-border p-3 text-xs text-mempool-text-dim space-y-1">
        <p className="font-semibold text-mempool-text">Fill Commit vs Settle</p>
        <p>
          <strong className="text-mempool-text">Fill Commit</strong> — lock a bond on OmniBus and claim the right to fill the maker&apos;s intent. You must then fulfil the swap on the taker chain.
        </p>
        <p>
          <strong className="text-mempool-text">Settle</strong> — prove the cross-chain fill is done (submits TX 0x42 via <em>intent_settle</em>). Use after the HTLC on the taker chain is funded.
        </p>
      </div>
    </div>
  );
}

// ── Main panel ────────────────────────────────────────────────────────────────

const TABS: { id: SubTab; label: string; Icon: React.FC<{ className?: string }> }[] = [
  { id: "my-intents", label: "My Intents", Icon: List },
  { id: "market",     label: "Market",     Icon: Globe },
  { id: "post",       label: "Post Intent", Icon: Plus },
  { id: "fill",       label: "Fill Intent", Icon: ArrowLeftRight },
];

export function IntentSwapPanel() {
  const [tab, setTab] = useState<SubTab>("market");
  const blockHeight = useBlockHeight();

  return (
    <section className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4">
      {/* Header */}
      <div className="flex items-center gap-2 sm:gap-3 mb-4">
        <ArrowLeftRight className="w-5 h-5 text-mempool-blue flex-shrink-0" />
        <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          Intent Swaps
        </h2>
        <div className="flex-1 h-px bg-mempool-border" />
        <div className="flex items-center gap-1 text-[10px] text-mempool-text-dim font-mono whitespace-nowrap">
          <Clock className="w-3 h-3" />
          block {fmtInt(blockHeight)}
        </div>
      </div>

      {/* Info banner */}
      <div className="flex items-start gap-2 bg-mempool-blue/5 border border-mempool-blue/20 rounded-lg px-3 py-2 mb-4">
        <AlertCircle className="w-4 h-4 text-mempool-blue flex-shrink-0 mt-0.5" />
        <p className="text-[11px] text-mempool-text-dim leading-relaxed">
          Intent swaps are atomic cross-chain swaps. Maker posts an intent (TX 0x40),
          taker commits a bond (TX 0x41), both settle atomically (TX 0x42).
          Expired unfilled intents can be reclaimed via timeout (TX 0x43).
        </p>
      </div>

      {/* Sub-tab bar */}
      <div className="flex gap-1 border-b border-mempool-border mb-4 overflow-x-auto scrollbar-none">
        {TABS.map(({ id, label, Icon }) => {
          const active = tab === id;
          return (
            <button
              key={id}
              onClick={() => setTab(id)}
              className={
                "relative flex-shrink-0 px-3 sm:px-4 py-2.5 text-xs font-medium uppercase tracking-wider transition-colors whitespace-nowrap " +
                (active
                  ? "text-mempool-blue"
                  : "text-mempool-text-dim hover:text-mempool-text")
              }
            >
              <span className="flex items-center gap-1.5">
                <Icon className="w-3 h-3" />
                {label}
              </span>
              {active && (
                <span className="absolute bottom-0 left-0 right-0 h-[2px] bg-mempool-blue rounded-t" />
              )}
            </button>
          );
        })}
      </div>

      {/* Content */}
      <div>
        {tab === "my-intents" && <MyIntentsTab />}
        {tab === "market"     && <MarketTab />}
        {tab === "post"       && <PostIntentTab />}
        {tab === "fill"       && <FillIntentTab />}
      </div>

      {/* Footer legend */}
      <div className="mt-6 pt-3 border-t border-mempool-border flex flex-wrap gap-3 text-[10px] text-mempool-text-dim">
        {(
          [
            { status: "open",     desc: "Pending taker" },
            { status: "filled",   desc: "Bond locked" },
            { status: "settled",  desc: "Complete" },
            { status: "expired",  desc: "Past expiry" },
            { status: "cancelled",desc: "Cancelled" },
          ] as { status: IntentStatus; desc: string }[]
        ).map(({ status, desc }) => (
          <span key={status} className="flex items-center gap-1">
            <StatusBadge status={status} />
            <span>{desc}</span>
          </span>
        ))}
        <span className="flex items-center gap-1 ml-auto">
          <XCircle className="w-3 h-3 text-mempool-text-dim" />
          TX types: 0x40 post · 0x41 fill · 0x42 settle · 0x43 timeout
        </span>
      </div>
    </section>
  );
}
