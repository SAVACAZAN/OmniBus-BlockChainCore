/**
 * SubscriptionPage.tsx — Recurring payment subscriptions.
 *
 * Allows users to create, view, and cancel on-chain subscriptions.
 * The chain processes subscriptions automatically every `interval` blocks.
 *
 * RPCs:
 *   sub_create       — create a recurring payment
 *   sub_cancel       — cancel by sub_id
 *   getsubscriptions — list subs by address (emitted + received)
 *
 * Signing: secp256k1 + SHA256d, canonical message
 *   SUB_CREATE_V1\n{from}\n{to}\n{amount}\n{interval}\n{max_payments}\n{nonce}
 *   SUB_CANCEL_V1\n{from}\n{sub_id}\n{nonce}
 */

import { useState, useEffect, useCallback } from "react";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsNewBlockEvent } from "../../types";
import OmniBusRpcClient from "../../api/rpc-client";
import { AddressLabel } from "../common/AddressLabel";
import { useWallet } from "../../api/use-wallet";
import { bytesToHex, hexToBytes, signMessage } from "../../api/exchange-sign";
import { satToOmni, SAT_PER_OMNI, midTrunc } from "../../utils/fmt";

const rpc = new OmniBusRpcClient();

// ── Types ──────────────────────────────────────────────────────────────────

interface Subscription {
  id: number;
  from: string;
  to: string;
  amount: number;        // satoshis
  interval: number;      // blocks between payments
  max_payments: number;  // 0 = unlimited
  payments_made: number;
  next_block: number;
  active: boolean;
  note?: string;
  created_at_block?: number;
}

interface GetSubscriptionsResp {
  subscriptions?: Subscription[];
  emitted?: Subscription[];
  received?: Subscription[];
}

type SubTab = "mine" | "create" | "incoming";

// ── Helpers ────────────────────────────────────────────────────────────────

function fmtOmni(sat: number): string {
  return satToOmni(sat, 4);
}


function signSubCreate(args: {
  privateKeyHex: string;
  from: string;
  to: string;
  amountSat: number;
  intervalBlocks: number;
  maxPeriods: number;
  nonce: number;
}): { signature: string; publicKey: string } {
  const msg =
    `SUB_CREATE_V1\n${args.from}\n${args.to}\n${args.amountSat}\n` +
    `${args.intervalBlocks}\n${args.maxPeriods}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

function signSubCancel(args: {
  privateKeyHex: string;
  from: string;
  subId: number;
  nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `SUB_CANCEL_V1\n${args.from}\n${args.subId}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

async function fetchNonce(address: string): Promise<number> {
  try {
    const res: unknown = await rpc.request_raw("getnonce", [address]);
    const r = res as { nonce?: number } | number | null;
    if (typeof r === "number") return r;
    if (r && typeof r === "object" && "nonce" in r) return r.nonce ?? 0;
  } catch { /* ignore */ }
  return 0;
}

// ── Component ──────────────────────────────────────────────────────────────

export function SubscriptionPage() {
  const wallet = useWallet();
  const [tab, setTab] = useState<SubTab>("mine");

  // ── Tab 1: My Subscriptions ───────────────────────────────────────────
  const [mySubs, setMySubs] = useState<Subscription[]>([]);
  const [loadingSubs, setLoadingSubs] = useState(false);
  const [cancelResult, setCancelResult] = useState<{ id: number; ok: boolean; msg: string } | null>(null);
  const [cancelling, setCancelling] = useState<number | null>(null);

  // ── Tab 2: Create ─────────────────────────────────────────────────────
  const [createTo, setCreateTo] = useState("");
  const [createAmount, setCreateAmount] = useState("");
  const [createInterval, setCreateInterval] = useState("100");
  const [createMax, setCreateMax] = useState("0");
  const [createNote, setCreateNote] = useState("");
  const [creating, setCreating] = useState(false);
  const [createResult, setCreateResult] = useState<{ ok: boolean; msg: string; subId?: number } | null>(null);

  // ── Tab 3: Incoming ───────────────────────────────────────────────────
  const [incomingAddr, setIncomingAddr] = useState("");
  const [incomingSubs, setIncomingSubs] = useState<Subscription[]>([]);
  const [loadingIncoming, setLoadingIncoming] = useState(false);

  // ── Fetch my subscriptions ─────────────────────────────────────────────
  const loadMySubs = useCallback(async () => {
    if (!wallet?.address) return;
    setLoadingSubs(true);
    try {
      const res: unknown = await rpc.request_raw("getsubscriptions", [{ address: wallet.address }]);
      const r = res as GetSubscriptionsResp | Subscription[] | null;
      if (Array.isArray(r)) {
        setMySubs(r);
      } else if (r && typeof r === "object") {
        const resp = r as GetSubscriptionsResp;
        // Backend may return emitted+received or a flat subscriptions array.
        const all = [
          ...(resp.subscriptions ?? []),
          ...(resp.emitted ?? []),
        ];
        setMySubs(all);
      }
    } catch { /* node may not have this yet */ }
    setLoadingSubs(false);
  }, [wallet?.address]);

  useEffect(() => {
    if (tab === "mine") void loadMySubs();
    // Subscriptions fire per-block — refresh "mine" tab on every new block.
    if (tab !== "mine") return;
    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", () => { void loadMySubs(); });
    return unsub;
  }, [tab, loadMySubs]);

  // ── Auto-fill incoming address from wallet ────────────────────────────
  useEffect(() => {
    if (wallet?.address && !incomingAddr) {
      setIncomingAddr(wallet.address);
    }
  }, [wallet?.address, incomingAddr]);

  // ── Cancel subscription ───────────────────────────────────────────────
  const handleCancel = async (sub: Subscription) => {
    if (!wallet) return;
    setCancelling(sub.id);
    setCancelResult(null);
    try {
      const nonce = await fetchNonce(wallet.address);
      const { signature, publicKey } = signSubCancel({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        subId: sub.id,
        nonce,
      });
      const res: unknown = await rpc.request_raw("sub_cancel", [{
        from: wallet.address,
        sub_id: sub.id,
        signature,
        public_key: publicKey,
        nonce,
      }]);
      const r = res as { status?: string; txid?: string } | null;
      if (r?.status === "queued" || r?.txid) {
        setCancelResult({ id: sub.id, ok: true, msg: `Sub #${sub.id} cancelled` });
        // Optimistic remove.
        setMySubs((prev) => prev.filter((s) => s.id !== sub.id));
      } else {
        setCancelResult({ id: sub.id, ok: false, msg: "Cancel returned unexpected result" });
      }
    } catch (err: unknown) {
      const e = err as Error;
      setCancelResult({ id: sub.id, ok: false, msg: e.message || "Cancel failed" });
    } finally {
      setCancelling(null);
    }
  };

  // ── Create subscription ───────────────────────────────────────────────
  const handleCreate = async () => {
    if (!wallet) return;
    const toAddr = createTo.trim();
    if (!/^ob/.test(toAddr)) {
      setCreateResult({ ok: false, msg: "Service address must start with 'ob'" });
      return;
    }
    const amountSat = Math.floor(parseFloat(createAmount || "0") * SAT_PER_OMNI);
    if (amountSat <= 0) {
      setCreateResult({ ok: false, msg: "Amount per period must be > 0" });
      return;
    }
    const intervalBlocks = parseInt(createInterval || "100", 10);
    if (intervalBlocks <= 0) {
      setCreateResult({ ok: false, msg: "Interval must be > 0 blocks" });
      return;
    }
    const maxPeriods = parseInt(createMax || "0", 10);

    setCreating(true);
    setCreateResult(null);
    try {
      const nonce = await fetchNonce(wallet.address);
      const { signature, publicKey } = signSubCreate({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        to: toAddr,
        amountSat,
        intervalBlocks,
        maxPeriods,
        nonce,
      });
      const res: unknown = await rpc.request_raw("sub_create", [{
        from: wallet.address,
        to: toAddr,
        amount: amountSat,
        interval: intervalBlocks,
        max_payments: maxPeriods,
        note: createNote.trim(),
        signature,
        public_key: publicKey,
        nonce,
      }]);
      const r = res as { status?: string; sub_id?: number; next_block?: number; txid?: string } | null;
      if (r?.status === "queued" || r?.txid) {
        setCreateResult({
          ok: true,
          msg: `Subscription created${r.sub_id !== undefined ? ` (sub #${r.sub_id})` : ""}${r.next_block ? `. First payment at block ${r.next_block}` : ""}`,
          subId: r.sub_id,
        });
        // Reset form.
        setCreateTo("");
        setCreateAmount("");
        setCreateInterval("100");
        setCreateMax("0");
        setCreateNote("");
      } else {
        setCreateResult({ ok: false, msg: "Unexpected response from chain" });
      }
    } catch (err: unknown) {
      const e = err as Error;
      setCreateResult({ ok: false, msg: e.message || "Failed to create subscription" });
    } finally {
      setCreating(false);
    }
  };

  // ── Load incoming subs ────────────────────────────────────────────────
  const loadIncoming = async () => {
    const addr = incomingAddr.trim();
    if (!addr) return;
    setLoadingIncoming(true);
    try {
      const res: unknown = await rpc.request_raw("getsubscriptions", [{ address: addr }]);
      const r = res as GetSubscriptionsResp | Subscription[] | null;
      let all: Subscription[] = [];
      if (Array.isArray(r)) {
        all = r;
      } else if (r && typeof r === "object") {
        const resp = r as GetSubscriptionsResp;
        all = [
          ...(resp.received ?? []),
          ...(resp.subscriptions ?? []),
        ];
      }
      // Filter to only subscriptions targeting this address.
      setIncomingSubs(all.filter((s) => s.to === addr));
    } catch { /* ignore */ }
    setLoadingIncoming(false);
  };

  // ── Locked guard ──────────────────────────────────────────────────────
  if (!wallet) {
    return (
      <div className="max-w-2xl mx-auto px-4 py-12">
        <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-6 text-center space-y-3">
          <div className="w-12 h-12 mx-auto rounded-full bg-mempool-bg flex items-center justify-center">
            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" className="text-mempool-blue">
              <rect x="3" y="11" width="18" height="11" rx="2" stroke="currentColor" strokeWidth="2" />
              <path d="M7 11V7a5 5 0 0110 0v4" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
            </svg>
          </div>
          <h2 className="text-xl font-bold text-mempool-text">Wallet locked</h2>
          <p className="text-sm text-mempool-text-dim">
            Connect your wallet to manage subscriptions.
          </p>
        </div>
      </div>
    );
  }

  // ── Render ────────────────────────────────────────────────────────────
  return (
    <div className="max-w-3xl mx-auto px-4 py-6 space-y-4">
      {/* Header */}
      <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4">
        <div className="flex items-start justify-between">
          <div>
            <h1 className="text-mempool-text font-bold text-xl">Subscriptions</h1>
            <p className="text-mempool-text-dim text-sm mt-0.5">
              Recurring on-chain payments — executed automatically every N blocks.
            </p>
          </div>
          <div className="text-right text-xs text-mempool-text-dim">
            <p>Connected as</p>
            <p className="font-mono text-mempool-blue">
              <AddressLabel address={wallet.address} showEmoji truncate={{ left: 8, right: 6 }} />
            </p>
          </div>
        </div>
      </div>

      {/* Sub-tabs */}
      <div className="flex gap-1 bg-mempool-bg-elev rounded-xl border border-mempool-border p-1">
        {(["mine", "create", "incoming"] as SubTab[]).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`flex-1 py-2 text-sm font-medium rounded-lg transition-colors ${
              tab === t
                ? "bg-mempool-blue text-white"
                : "text-mempool-text-dim hover:text-mempool-text"
            }`}
          >
            {t === "mine" ? "My Subscriptions" : t === "create" ? "Create" : "Incoming"}
          </button>
        ))}
      </div>

      {/* ── Tab 1: My Subscriptions ─────────────────────────────────── */}
      {tab === "mine" && (
        <div className="space-y-3">
          {cancelResult && (
            <div
              className={`rounded-lg px-4 py-3 text-sm border ${
                cancelResult.ok
                  ? "bg-green-500/10 border-green-500/30 text-green-300"
                  : "bg-red-500/10 border-red-500/30 text-red-300"
              }`}
            >
              {cancelResult.msg}
            </div>
          )}

          {loadingSubs && (
            <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-6 text-center">
              <p className="text-mempool-text-dim text-sm animate-pulse">Loading subscriptions…</p>
            </div>
          )}

          {!loadingSubs && mySubs.length === 0 && (
            <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-6 text-center space-y-2">
              <p className="text-mempool-text-dim text-sm">No active subscriptions found.</p>
              <button
                onClick={() => setTab("create")}
                className="text-mempool-blue text-sm hover:underline"
              >
                Create your first subscription
              </button>
            </div>
          )}

          {!loadingSubs && mySubs.map((sub) => (
            <SubscriptionCard
              key={sub.id}
              sub={sub}
              myAddress={wallet.address}
              cancelling={cancelling === sub.id}
              onCancel={handleCancel}
            />
          ))}

          <div className="flex gap-2">
            {mySubs.length > 0 && (
              <button
                onClick={() => {
                  const rows = [
                    ["id","from","to","amount_omni","interval_blocks","max_payments","payments_made","next_block","active","note"].join(","),
                    ...mySubs.map((s) => [
                      s.id,
                      `"${s.from}"`,
                      `"${s.to}"`,
                      fmtOmni(s.amount),
                      s.interval,
                      s.max_payments,
                      s.payments_made,
                      s.next_block,
                      s.active ? "true" : "false",
                      `"${(s.note ?? "").replace(/"/g, '""')}"`,
                    ].join(",")),
                  ].join("\n");
                  const blob = new Blob([rows], { type: "text/csv" });
                  const url = URL.createObjectURL(blob);
                  const a = document.createElement("a");
                  a.href = url; a.download = "omnibus-subscriptions.csv";
                  a.click(); URL.revokeObjectURL(url);
                }}
                className="flex-1 py-2 text-sm text-mempool-text-dim border border-mempool-border rounded-lg hover:border-mempool-blue hover:text-mempool-blue transition-colors"
              >
                ⬇ CSV
              </button>
            )}
            <button
              onClick={loadMySubs}
              disabled={loadingSubs}
              className="flex-1 py-2 text-sm text-mempool-text-dim border border-mempool-border rounded-lg hover:border-mempool-blue hover:text-mempool-blue transition-colors disabled:opacity-50"
            >
              Refresh
            </button>
          </div>
        </div>
      )}

      {/* ── Tab 2: Create ───────────────────────────────────────────── */}
      {tab === "create" && (
        <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4 space-y-4">
          <h3 className="text-mempool-text font-semibold">New Subscription</h3>

          {/* Service address */}
          <div className="space-y-1">
            <label className="text-xs text-mempool-text-dim">Service address (recipient)</label>
            <input
              type="text"
              value={createTo}
              onChange={(e) => setCreateTo(e.target.value)}
              placeholder="ob1q…"
              className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text w-full focus:outline-none focus:border-mempool-blue"
            />
            {createTo && !/^ob/.test(createTo.trim()) && (
              <p className="text-red-400 text-xs">Address must start with 'ob'</p>
            )}
          </div>

          {/* Amount per period */}
          <div className="space-y-1">
            <label className="text-xs text-mempool-text-dim">Amount per period (OMNI)</label>
            <input
              type="number"
              value={createAmount}
              onChange={(e) => setCreateAmount(e.target.value)}
              placeholder="0.0001"
              min="0"
              step="0.0001"
              className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text w-full focus:outline-none focus:border-mempool-blue"
            />
            {createAmount && (
              <p className="text-xs text-mempool-text-dim">
                = {Math.floor(parseFloat(createAmount || "0") * SAT_PER_OMNI).toLocaleString()} sat
              </p>
            )}
          </div>

          {/* Interval blocks */}
          <div className="space-y-1">
            <label className="text-xs text-mempool-text-dim">
              Interval (blocks between payments)
            </label>
            <div className="flex gap-2">
              <input
                type="number"
                value={createInterval}
                onChange={(e) => setCreateInterval(e.target.value)}
                min="1"
                className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text flex-1 focus:outline-none focus:border-mempool-blue"
              />
              <div className="flex gap-1">
                {[
                  { label: "1h",  blocks: 3600 },
                  { label: "1d",  blocks: 86400 },
                  { label: "30d", blocks: 2592000 },
                ].map((p) => (
                  <button
                    key={p.label}
                    onClick={() => setCreateInterval(String(p.blocks))}
                    className="px-2 py-1 text-xs text-mempool-text-dim border border-mempool-border rounded-lg hover:border-mempool-blue hover:text-mempool-blue transition-colors"
                  >
                    {p.label}
                  </button>
                ))}
              </div>
            </div>
            <p className="text-xs text-mempool-text-dim">
              At 1 block/s: {parseInt(createInterval || "0", 10)} blocks ≈{" "}
              {(parseInt(createInterval || "0", 10) / 86400).toFixed(2)} days
            </p>
          </div>

          {/* Max periods */}
          <div className="space-y-1">
            <label className="text-xs text-mempool-text-dim">
              Max periods (0 = unlimited)
            </label>
            <input
              type="number"
              value={createMax}
              onChange={(e) => setCreateMax(e.target.value)}
              min="0"
              className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text w-full focus:outline-none focus:border-mempool-blue"
            />
            {parseInt(createMax || "0", 10) > 0 && createAmount && (
              <p className="text-xs text-mempool-text-dim">
                Total max:{" "}
                {fmtOmni(
                  Math.floor(parseFloat(createAmount || "0") * SAT_PER_OMNI) *
                    parseInt(createMax, 10),
                )}{" "}
                OMNI
              </p>
            )}
          </div>

          {/* Note */}
          <div className="space-y-1">
            <label className="text-xs text-mempool-text-dim">Note (optional)</label>
            <input
              type="text"
              value={createNote}
              onChange={(e) => setCreateNote(e.target.value)}
              placeholder="e.g. Netflix, Hosting, etc."
              maxLength={64}
              className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text w-full focus:outline-none focus:border-mempool-blue"
            />
          </div>

          {/* Summary */}
          {createTo && createAmount && createInterval && (
            <div className="bg-mempool-bg rounded-lg px-4 py-3 text-xs space-y-1">
              <p className="text-mempool-text-dim font-semibold mb-1">Summary</p>
              <p className="text-mempool-text">
                Pay{" "}
                <span className="text-mempool-blue font-mono">
                  {parseFloat(createAmount || "0").toFixed(4)} OMNI
                </span>{" "}
                to{" "}
                <span className="font-mono text-mempool-text">
                  <AddressLabel address={createTo} showEmoji truncate={{ left: 8, right: 6 }} />
                </span>
              </p>
              <p className="text-mempool-text">
                Every{" "}
                <span className="text-mempool-blue">
                  {parseInt(createInterval, 10).toLocaleString()} blocks
                </span>
                {parseInt(createMax, 10) > 0
                  ? `, up to ${parseInt(createMax, 10)} times`
                  : " indefinitely"}
              </p>
            </div>
          )}

          {createResult && (
            <div
              className={`rounded-lg px-4 py-3 text-sm border ${
                createResult.ok
                  ? "bg-green-500/10 border-green-500/30 text-green-300"
                  : "bg-red-500/10 border-red-500/30 text-red-300"
              }`}
            >
              {createResult.msg}
            </div>
          )}

          <button
            onClick={handleCreate}
            disabled={creating || !createTo || !createAmount}
            className="bg-mempool-blue text-white px-4 py-2 rounded-lg text-sm font-semibold hover:opacity-90 disabled:opacity-50 w-full"
          >
            {creating ? "Creating…" : "Create Subscription"}
          </button>
        </div>
      )}

      {/* ── Tab 3: Incoming ─────────────────────────────────────────── */}
      {tab === "incoming" && (
        <div className="space-y-3">
          <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4 space-y-3">
            <h3 className="text-mempool-text font-semibold">Service Provider View</h3>
            <p className="text-mempool-text-dim text-xs">
              Enter an address to see which subscribers are sending recurring payments to it.
            </p>

            <div className="flex gap-2">
              <input
                type="text"
                value={incomingAddr}
                onChange={(e) => setIncomingAddr(e.target.value)}
                placeholder="ob1q… service address"
                className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text flex-1 focus:outline-none focus:border-mempool-blue"
              />
              <button
                onClick={loadIncoming}
                disabled={loadingIncoming || !incomingAddr.trim()}
                className="bg-mempool-blue text-white px-4 py-2 rounded-lg text-sm font-semibold hover:opacity-90 disabled:opacity-50"
              >
                {loadingIncoming ? "…" : "Search"}
              </button>
            </div>
          </div>

          {incomingSubs.length > 0 && (
            <div className="space-y-2">
              <p className="text-mempool-text-dim text-xs px-1">
                {incomingSubs.length} subscription{incomingSubs.length !== 1 ? "s" : ""} targeting this address
              </p>
              {incomingSubs.map((sub) => (
                <SubscriptionCard
                  key={sub.id}
                  sub={sub}
                  myAddress={wallet.address}
                  cancelling={false}
                  onCancel={() => {}}
                  readOnly
                />
              ))}
            </div>
          )}

          {!loadingIncoming && incomingSubs.length === 0 && incomingAddr && (
            <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4 text-center">
              <p className="text-mempool-text-dim text-sm">No subscriptions found for this address.</p>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// ── Sub-component: subscription card ──────────────────────────────────────

interface SubscriptionCardProps {
  sub: Subscription;
  myAddress: string;
  cancelling: boolean;
  onCancel: (sub: Subscription) => void;
  readOnly?: boolean;
}

function SubscriptionCard({
  sub,
  myAddress,
  cancelling,
  onCancel,
  readOnly = false,
}: SubscriptionCardProps) {
  const isOwner = sub.from === myAddress;
  const intervalDays = (sub.interval / 86400).toFixed(2);

  return (
    <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4">
      <div className="flex items-start justify-between gap-3">
        {/* Left: info */}
        <div className="space-y-1 min-w-0 flex-1">
          <div className="flex items-center gap-2 flex-wrap">
            <span className="text-sm font-semibold text-mempool-text">
              Sub #{sub.id}
            </span>
            {sub.note && (
              <span className="text-xs text-mempool-text-dim bg-mempool-bg rounded px-2 py-0.5">
                {sub.note}
              </span>
            )}
            <span
              className={`text-xs px-2 py-0.5 rounded font-medium ${
                sub.active
                  ? "bg-green-500/20 text-green-400"
                  : "bg-gray-500/20 text-gray-400"
              }`}
            >
              {sub.active ? "active" : "inactive"}
            </span>
          </div>

          <div className="grid grid-cols-2 gap-x-4 gap-y-1 text-xs text-mempool-text-dim mt-2">
            <div>
              <span className="opacity-70">From </span>
              <button onClick={() => { window.location.hash = `#/address/${sub.from}`; }} className="font-mono text-mempool-text hover:text-mempool-blue hover:underline">
              <AddressLabel address={sub.from} showEmoji truncate={{ left: 8, right: 6 }} />
            </button>
              {isOwner && <span className="ml-1 text-mempool-blue">(you)</span>}
            </div>
            <div>
              <span className="opacity-70">To </span>
              <button onClick={() => { window.location.hash = `#/address/${sub.to}`; }} className="font-mono text-mempool-text hover:text-mempool-blue hover:underline">
                <AddressLabel address={sub.to} showEmoji truncate={{ left: 8, right: 6 }} />
              </button>
            </div>
            <div>
              <span className="opacity-70">Per period </span>
              <span className="text-mempool-blue font-semibold">{fmtOmni(sub.amount)} OMNI</span>
            </div>
            <div>
              <span className="opacity-70">Interval </span>
              <span className="text-mempool-text">
                {sub.interval.toLocaleString()} blk (~{intervalDays}d)
              </span>
            </div>
            <div>
              <span className="opacity-70">Next block </span>
              <span className="text-mempool-text">{sub.next_block.toLocaleString()}</span>
            </div>
            <div>
              <span className="opacity-70">Payments </span>
              <span className="text-mempool-text">
                {sub.payments_made}
                {sub.max_payments > 0 ? ` / ${sub.max_payments}` : " (unlimited)"}
              </span>
            </div>
          </div>
        </div>

        {/* Right: cancel button */}
        {!readOnly && isOwner && sub.active && (
          <button
            onClick={() => onCancel(sub)}
            disabled={cancelling}
            className="flex-shrink-0 px-3 py-1.5 text-xs text-red-400 border border-red-400/30 rounded-lg hover:bg-red-400/10 transition-colors disabled:opacity-50"
          >
            {cancelling ? "…" : "Cancel"}
          </button>
        )}
      </div>
    </div>
  );
}
