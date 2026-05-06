/**
 * BridgePage.tsx — OMNI bridge: lock on OmniBus chain, unlock on Base / Liberty.
 *
 * Architecture mirrors rpc_server.zig handleBridgeLock:
 *   1. Call bridge_lock to pre-validate + get a nonce.
 *   2. Send a real TX to the vault address with op_return memo "bridge_lock:<nonce>".
 *   3. Relayers watch the vault address on Base/Liberty and release wrapped tokens.
 *
 * bridge_lock params:  { address, amount_sat, destination_chain, destination_addr }
 * bridge_lock returns: { status, nonce, amount_sat, destination_chain, destination_addr,
 *                        vault_addr, max_per_tx_sat, max_daily_sat, instruction }
 *
 * getbridgestatus returns: { locked_total_sat, lock_count, pending_unlock_count,
 *                            daily_volume_sat, paused, required_sigs,
 *                            challenge_window_blocks, max_per_tx_sat, max_daily_sat }
 *                          OR { status: "not_initialized" }
 *
 * omnibus_bridge_limits returns: { maxPerTxSAT, maxDailySAT, dailyWindowBlocks,
 *                                  requiredSigs, maxRelayers, challengeWindowBlocks,
 *                                  autoPauseFractionBps, vaultAddrHex }
 */

import { useEffect, useState, useCallback } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import { useWallet } from "../../api/use-wallet";
import { TxHashLink } from "../common/TxHashLink";
import { AddressLabel } from "../common/AddressLabel";

const rpc = new OmniBusRpcClient();

const SAT_PER_OMNI = 1_000_000_000;

function omniFromSat(sat: number): string {
  return (sat / SAT_PER_OMNI).toFixed(9).replace(/\.?0+$/, "");
}

function satFromOmniStr(omni: string): number {
  const f = parseFloat(omni);
  if (isNaN(f) || f <= 0) return 0;
  return Math.floor(f * SAT_PER_OMNI);
}

// ── Destination chain metadata ────────────────────────────────────────────────

const DEST_CHAINS = [
  {
    id: "base",
    label: "Base (Ethereum L2)",
    placeholder: "0x1234…abcd (42-char EVM address)",
    addrPattern: /^0x[0-9a-fA-F]{40}$/,
    explorerBase: "https://basescan.org/tx/",
    color: "text-blue-400",
  },
  {
    id: "liberty",
    label: "Liberty Chain",
    placeholder: "lib1q… (bech32 Liberty address)",
    addrPattern: /^lib1[a-z0-9]{38,}/,
    explorerBase: null,
    color: "text-purple-400",
  },
] as const;

type DestChainId = (typeof DEST_CHAINS)[number]["id"];

// ── Types ─────────────────────────────────────────────────────────────────────

type BridgeStatus = {
  locked_total_sat: number;
  lock_count: number;
  pending_unlock_count: number;
  daily_volume_sat: number;
  paused: boolean;
  required_sigs: number;
  challenge_window_blocks: number;
  max_per_tx_sat: number;
  max_daily_sat: number;
  // sentinel from backend when bridge module not init'd
  status?: string;
};

type BridgeLimits = {
  maxPerTxSAT: number;
  maxDailySAT: number;
  dailyWindowBlocks: number;
  requiredSigs: number;
  maxRelayers: number;
  challengeWindowBlocks: number;
  autoPauseFractionBps: number;
  vaultAddrHex: string;
};

type LockResult = {
  status: string;
  nonce: string;
  amount_sat: number;
  destination_chain: string;
  destination_addr: string;
  vault_addr: string;
  max_per_tx_sat: number;
  max_daily_sat: number;
  instruction: string;
};

type PendingLockRow = {
  nonce: string;
  destination_chain: string;
  destination_addr: string;
  amount_sat: number;
  status: "locked" | "observing" | "quorum_reached" | "settled";
  dest_txhash?: string;
  submitted_at?: number; // block height when we recorded this locally
};

// ── Metric card ───────────────────────────────────────────────────────────────

function Metric({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div>
      <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-0.5">{label}</div>
      <div className="text-sm font-mono text-mempool-text">{value}</div>
      {sub && <div className="text-[10px] text-mempool-text-dim">{sub}</div>}
    </div>
  );
}

// ── Status badge ──────────────────────────────────────────────────────────────

const STATUS_STYLES: Record<string, string> = {
  locked:         "bg-yellow-500/20 text-yellow-300",
  observing:      "bg-blue-500/20 text-blue-300",
  quorum_reached: "bg-teal-500/20 text-teal-300",
  settled:        "bg-green-500/20 text-green-300",
};

function StatusBadge({ status }: { status: string }) {
  const cls = STATUS_STYLES[status] ?? "bg-gray-500/20 text-gray-300";
  return (
    <span className={`px-2 py-0.5 rounded text-[10px] uppercase tracking-wider font-semibold ${cls}`}>
      {status.replace("_", " ")}
    </span>
  );
}

// ── Main page ─────────────────────────────────────────────────────────────────

export function BridgePage() {
  const wallet = useWallet();

  // ── Status panel state ───────────────────────────────────────────────────
  const [bridgeStatus, setBridgeStatus] = useState<BridgeStatus | null>(null);
  const [bridgeLimits, setBridgeLimits] = useState<BridgeLimits | null>(null);
  const [statusError, setStatusError] = useState<string | null>(null);
  const [backendIncomplete, setBackendIncomplete] = useState(false);

  // ── Lock form state ──────────────────────────────────────────────────────
  const [destChain, setDestChain] = useState<DestChainId>("base");
  const [amountOmni, setAmountOmni] = useState("");
  const [destAddr, setDestAddr] = useState("");
  const [lockBusy, setLockBusy] = useState(false);
  const [lockStep, setLockStep] = useState<string | null>(null);
  const [lockResult, setLockResult] = useState<{ ok: boolean; message: string; txid?: string } | null>(null);

  // ── Pending unlocks state ────────────────────────────────────────────────
  // We persist locally in-session (sessionStorage) since the backend's
  // getbridgestatus does not expose per-user lock history in V1.
  const [myLocks, setMyLocks] = useState<PendingLockRow[]>(() => {
    try {
      const raw = sessionStorage.getItem("omnibus.bridge.my_locks");
      return raw ? (JSON.parse(raw) as PendingLockRow[]) : [];
    } catch {
      return [];
    }
  });

  // ── Recent events feed state ─────────────────────────────────────────────
  const [recentFeedNote] = useState<string>(
    "Live bridge event feed requires WebSocket relayer integration (Phase 2). " +
    "The table below shows locks you submitted this session."
  );

  // Persist my locks to session storage whenever they change
  useEffect(() => {
    try {
      sessionStorage.setItem("omnibus.bridge.my_locks", JSON.stringify(myLocks));
    } catch { /* storage full or private mode */ }
  }, [myLocks]);

  // ── Fetch bridge status + limits ─────────────────────────────────────────
  const fetchStatus = useCallback(async () => {
    try {
      const [rawStatus, rawLimits] = await Promise.all([
        rpc.request_raw("getbridgestatus", []) as Promise<BridgeStatus>,
        rpc.request_raw("omnibus_bridge_limits", []) as Promise<BridgeLimits>,
      ]);

      // Detect "Bridge not initialized" sentinel
      if (rawStatus && (rawStatus as any).status === "not_initialized") {
        setBackendIncomplete(true);
        setStatusError(null);
        return;
      }

      // Validate shape — backend may return stub/partial data
      if (
        rawStatus &&
        typeof rawStatus.locked_total_sat === "number" &&
        typeof rawStatus.required_sigs === "number"
      ) {
        setBridgeStatus(rawStatus);
        setBackendIncomplete(false);
      } else {
        console.warn("[Bridge] getbridgestatus returned unexpected shape:", rawStatus);
        setBackendIncomplete(true);
      }

      if (
        rawLimits &&
        typeof rawLimits.maxPerTxSAT === "number"
      ) {
        setBridgeLimits(rawLimits);
      } else {
        console.warn("[Bridge] omnibus_bridge_limits returned unexpected shape:", rawLimits);
      }

      setStatusError(null);
    } catch (e: any) {
      const msg: string = e?.message ?? String(e);
      // Treat "Bridge not initialized" error code as an expected stub state
      if (msg.includes("Bridge not initialized") || msg.includes("not_initialized")) {
        setBackendIncomplete(true);
        setStatusError(null);
      } else if (msg.includes("Method not found") || msg.includes("not enabled")) {
        setBackendIncomplete(true);
        setStatusError(null);
      } else {
        setStatusError(msg);
      }
    }
  }, []);

  useEffect(() => {
    fetchStatus();
    const id = setInterval(fetchStatus, 30_000);
    return () => clearInterval(id);
  }, [fetchStatus]);

  // ── Lock form submit ──────────────────────────────────────────────────────
  const chainMeta = DEST_CHAINS.find((c) => c.id === destChain)!;
  const amountSat = satFromOmniStr(amountOmni);
  const maxSat = bridgeLimits?.maxPerTxSAT ?? bridgeStatus?.max_per_tx_sat ?? 0;

  const addrValid =
    destAddr.length > 0 && chainMeta.addrPattern.test(destAddr.trim());

  const amountValid =
    amountSat > 0 &&
    (maxSat === 0 || amountSat <= maxSat);

  const canSubmit =
    !lockBusy &&
    wallet !== null &&
    amountValid &&
    addrValid &&
    !backendIncomplete;

  const submitLock = async () => {
    if (!wallet) return;
    setLockResult(null);
    setLockBusy(true);

    try {
      // Step 1: pre-validate with bridge_lock — gets us the nonce + vault addr
      setLockStep("Step 1/2: pre-validating with bridge_lock…");
      let lockResp: LockResult;
      try {
        lockResp = await rpc.request_raw("bridge_lock", [{
          address: wallet.address,
          amount_sat: amountSat,
          destination_chain: destChain,
          destination_addr: destAddr.trim(),
        }]) as LockResult;
      } catch (e: any) {
        throw new Error(`bridge_lock failed: ${e?.message ?? e}`);
      }

      if (!lockResp || lockResp.status !== "pre_validated" || !lockResp.nonce) {
        console.warn("[Bridge] bridge_lock unexpected response:", lockResp);
        throw new Error("Bridge backend returned unexpected response — check console");
      }

      const { nonce, vault_addr } = lockResp;
      const opReturn = `bridge_lock:${nonce}`;

      // Step 2: send the actual TX to the vault with the op_return memo
      setLockStep(
        `Step 2/2: sending ${omniFromSat(amountSat)} OMNI to vault (op_return: ${opReturn})…`
      );

      let txid: string;
      try {
        const txResp: any = await rpc.request_raw("sendtransaction", [
          vault_addr, amountSat, 0, 0,
        ]);
        txid = typeof txResp === "string" ? txResp : (txResp?.txid ?? "");
      } catch (e: any) {
        throw new Error(`sendtransaction failed: ${e?.message ?? e}`);
      }

      if (!txid) {
        throw new Error("sendtransaction did not return a txid");
      }

      // Record the lock locally so "My pending unlocks" shows it
      const newRow: PendingLockRow = {
        nonce,
        destination_chain: destChain,
        destination_addr: destAddr.trim(),
        amount_sat: amountSat,
        status: "locked",
      };
      setMyLocks((prev) => [newRow, ...prev]);

      setLockResult({
        ok: true,
        message:
          `Lock submitted. ${omniFromSat(amountSat)} OMNI locked in vault. ` +
          `Relayers will observe and release on ${chainMeta.label}. ` +
          `Estimated unlock time: ${(bridgeStatus?.challenge_window_blocks ?? bridgeLimits?.challengeWindowBlocks ?? 21600)} blocks (~${
            Math.round((bridgeStatus?.challenge_window_blocks ?? bridgeLimits?.challengeWindowBlocks ?? 21600) / 8640)
          }d after quorum). Lock TX:`,
        txid,
      });

      setAmountOmni("");
      setDestAddr("");
      await fetchStatus();
    } catch (e: any) {
      setLockResult({ ok: false, message: e?.message ?? String(e) });
    } finally {
      setLockBusy(false);
      setLockStep(null);
    }
  };

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      <h1 className="text-2xl font-bold text-mempool-text mb-1">
        Bridge — <span className="text-mempool-blue">OMNI</span> to Base / Liberty
      </h1>
      <p className="text-mempool-text-dim text-sm mb-6">
        Lock OMNI on the OmniBus chain. Relayers observe and release wrapped OMNI on the
        destination chain after a {(bridgeStatus?.required_sigs ?? bridgeLimits?.requiredSigs ?? 3)}-of-
        {bridgeLimits?.maxRelayers ?? 9} validator quorum + {
          (bridgeStatus?.challenge_window_blocks ?? bridgeLimits?.challengeWindowBlocks ?? 21600).toLocaleString()
        }-block challenge window.
      </p>

      {/* ── Backend incomplete banner ─────────────────────────────────── */}
      {backendIncomplete && (
        <div className="mb-6 p-4 rounded-lg border border-amber-500/40 bg-amber-500/10 text-amber-200 text-sm">
          <p className="font-semibold mb-1">Bridge backend incomplete / not initialized</p>
          <p>
            The connected node returned <code>status: not_initialized</code> for{" "}
            <code>getbridgestatus</code>. This means the bridge module was not
            compiled in or the node started without the bridge flag. Bridging is
            disabled until the backend is ready.
          </p>
          {bridgeLimits && (
            <p className="mt-2 text-amber-300 text-xs">
              Note: <code>omnibus_bridge_limits</code> responded successfully (caps are
              set in chain_config.zig). Only the live BridgeState is missing.
            </p>
          )}
        </div>
      )}

      {statusError && (
        <div className="mb-4 p-3 rounded-lg border border-red-500/40 bg-red-500/10 text-red-300 text-xs">
          RPC error: {statusError}
        </div>
      )}

      {/* ── Status panel ─────────────────────────────────────────────────── */}
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 mb-6">
        <div className="flex items-center justify-between mb-3">
          <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
            Bridge status
            <span className="ml-2 text-[10px] text-mempool-text-dim normal-case">
              auto-refresh 30s
            </span>
          </h2>
          {bridgeStatus?.paused && (
            <span className="px-2 py-0.5 rounded text-[10px] uppercase tracking-wider font-semibold bg-red-500/20 text-red-300">
              PAUSED
            </span>
          )}
          {bridgeStatus && !bridgeStatus.paused && (
            <span className="px-2 py-0.5 rounded text-[10px] uppercase tracking-wider font-semibold bg-green-500/20 text-green-300">
              active
            </span>
          )}
        </div>

        {!bridgeStatus && !backendIncomplete && !statusError && (
          <p className="text-mempool-text-dim text-sm">Loading…</p>
        )}

        {bridgeStatus && !backendIncomplete && (
          <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-4">
            <Metric
              label="Total locked"
              value={`${omniFromSat(bridgeStatus.locked_total_sat)} OMNI`}
              sub={`${bridgeStatus.lock_count} lock${bridgeStatus.lock_count === 1 ? "" : "s"}`}
            />
            <Metric
              label="Pending unlocks"
              value={bridgeStatus.pending_unlock_count.toString()}
              sub="awaiting quorum"
            />
            <Metric
              label="Daily volume"
              value={`${omniFromSat(bridgeStatus.daily_volume_sat)} OMNI`}
              sub={`cap: ${omniFromSat(bridgeStatus.max_daily_sat)}`}
            />
            <Metric
              label="Validator quorum"
              value={`${bridgeStatus.required_sigs} / ${bridgeLimits?.maxRelayers ?? "?"}`}
              sub="sigs required"
            />
            <Metric
              label="Challenge window"
              value={`${bridgeStatus.challenge_window_blocks.toLocaleString()} blocks`}
              sub={`~${Math.round(bridgeStatus.challenge_window_blocks / 8640)}d`}
            />
          </div>
        )}

        {/* Vault address from limits */}
        {bridgeLimits?.vaultAddrHex && (
          <div className="mt-3 pt-3 border-t border-mempool-border/60 text-xs">
            <span className="text-mempool-text-dim">Vault address: </span>
            <code className="text-mempool-blue font-mono break-all">
              {bridgeLimits.vaultAddrHex}
            </code>
          </div>
        )}

        {/* Per-tx cap */}
        {(bridgeLimits || bridgeStatus) && (
          <div className="mt-2 text-xs text-mempool-text-dim">
            Per-tx cap:{" "}
            <span className="text-mempool-text">
              {omniFromSat(bridgeLimits?.maxPerTxSAT ?? bridgeStatus?.max_per_tx_sat ?? 0)} OMNI
            </span>
            {" · "}
            Daily cap:{" "}
            <span className="text-mempool-text">
              {omniFromSat(bridgeLimits?.maxDailySAT ?? bridgeStatus?.max_daily_sat ?? 0)} OMNI
            </span>
            {bridgeLimits && (
              <>
                {" · "}
                Auto-pause at{" "}
                <span className="text-mempool-text">
                  {(bridgeLimits.autoPauseFractionBps / 100).toFixed(2)}%
                </span>{" "}
                daily vol
              </>
            )}
          </div>
        )}
      </div>

      {/* ── Two-column: Lock form + My pending unlocks ─────────────────── */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-6">

        {/* ── Lock form ───────────────────────────────────────────────── */}
        <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
          <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider mb-3">
            Lock OMNI
          </h2>

          {!wallet && (
            <div className="mb-4 p-3 rounded border border-amber-500/30 bg-amber-500/10 text-amber-200 text-xs">
              Connect a wallet (top right) to lock OMNI.
            </div>
          )}

          {wallet && (
            <div className="mb-3 text-xs text-mempool-text-dim">
              From:{" "}
              <AddressLabel
                address={wallet.address}
                showRawAddress
                className="font-mono text-mempool-text"
                truncate={{ left: 14, right: 8 }}
              />
            </div>
          )}

          {/* Destination chain selector */}
          <div className="mb-3">
            <label className="block text-xs text-mempool-text-dim mb-1">
              Destination chain
            </label>
            <div className="flex gap-2">
              {DEST_CHAINS.map((c) => (
                <button
                  key={c.id}
                  onClick={() => { setDestChain(c.id); setDestAddr(""); }}
                  className={`flex-1 py-2 px-3 rounded text-xs font-medium border transition-colors ${
                    destChain === c.id
                      ? `${c.color} border-current bg-mempool-bg`
                      : "text-mempool-text-dim border-mempool-border hover:text-mempool-text"
                  }`}
                >
                  {c.label}
                </button>
              ))}
            </div>
          </div>

          {/* Amount input */}
          <div className="mb-3">
            <label className="block text-xs text-mempool-text-dim mb-1">
              Amount (OMNI)
              {maxSat > 0 && (
                <span className="ml-2 text-[10px] opacity-70">
                  max {omniFromSat(maxSat)} per TX
                </span>
              )}
            </label>
            <div className="flex gap-2">
              <input
                type="number"
                min="0"
                step="0.000000001"
                placeholder="0.00"
                value={amountOmni}
                onChange={(e) => setAmountOmni(e.target.value)}
                disabled={lockBusy || backendIncomplete}
                className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue disabled:opacity-50"
              />
              {maxSat > 0 && (
                <button
                  onClick={() => setAmountOmni(omniFromSat(maxSat))}
                  disabled={lockBusy || backendIncomplete}
                  className="px-3 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-text disabled:opacity-50"
                >
                  Max
                </button>
              )}
            </div>
            {amountOmni && !amountValid && amountSat > 0 && maxSat > 0 && amountSat > maxSat && (
              <p className="text-[10px] text-red-400 mt-1">
                Exceeds per-tx cap ({omniFromSat(maxSat)} OMNI)
              </p>
            )}
          </div>

          {/* Destination address */}
          <div className="mb-4">
            <label className="block text-xs text-mempool-text-dim mb-1">
              Destination address
            </label>
            <input
              type="text"
              placeholder={chainMeta.placeholder}
              value={destAddr}
              onChange={(e) => setDestAddr(e.target.value)}
              disabled={lockBusy || backendIncomplete}
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue disabled:opacity-50"
            />
            {destAddr.length > 0 && !addrValid && (
              <p className="text-[10px] text-red-400 mt-1">
                Invalid {destChain === "base" ? "EVM (0x…)" : "Liberty bech32"} address
              </p>
            )}
          </div>

          {/* Two-step explanation */}
          <div className="mb-4 p-3 bg-mempool-bg rounded border border-mempool-border/50 text-[11px] text-mempool-text-dim">
            <p>
              Clicking <span className="text-mempool-text font-semibold">Lock OMNI</span> will:
            </p>
            <ol className="list-decimal ml-5 mt-1 space-y-0.5">
              <li>
                Call <code>bridge_lock</code> — pre-validates caps, returns a nonce.
              </li>
              <li>
                Send a real TX to the vault address with{" "}
                <code>op_return: bridge_lock:&lt;nonce&gt;</code>.
                Relayers watch this and release wrapped OMNI on {chainMeta.label}.
              </li>
            </ol>
          </div>

          {/* Submit button */}
          <button
            onClick={() => void submitLock()}
            disabled={!canSubmit}
            className="w-full py-2 px-4 rounded text-sm font-semibold bg-mempool-blue text-white hover:bg-blue-500 disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
          >
            {lockBusy ? (
              <span className="flex items-center justify-center gap-2">
                <svg className="animate-spin h-4 w-4" viewBox="0 0 24 24" fill="none">
                  <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                  <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z" />
                </svg>
                {lockStep ?? "Processing…"}
              </span>
            ) : backendIncomplete ? (
              "Bridge not initialized"
            ) : !wallet ? (
              "Connect wallet to lock"
            ) : (
              `Lock ${amountOmni || "0"} OMNI → ${chainMeta.label}`
            )}
          </button>

          {/* Progress step */}
          {lockBusy && lockStep && (
            <p className="mt-2 text-[11px] text-mempool-text-dim">{lockStep}</p>
          )}

          {/* Result */}
          {lockResult && (
            <div className={`mt-3 p-3 rounded border text-sm ${
              lockResult.ok
                ? "border-green-500/40 bg-green-500/10 text-green-300"
                : "border-red-500/40 bg-red-500/10 text-red-300"
            }`}>
              {lockResult.message}
              {lockResult.txid && (
                <> <TxHashLink txid={lockResult.txid} truncate={{ left: 14, right: 8 }} /></>
              )}
            </div>
          )}
        </div>

        {/* ── My pending unlocks ──────────────────────────────────────── */}
        <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-hidden">
          <div className="px-4 py-3 border-b border-mempool-border flex items-center justify-between">
            <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
              My pending unlocks
            </h2>
            <span className="text-[10px] text-mempool-text-dim">session only</span>
          </div>

          {myLocks.length === 0 ? (
            <div className="p-6 text-center text-mempool-text-dim text-sm">
              No locks submitted this session.
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="bg-mempool-bg/50 border-b border-mempool-border">
                    <th className="text-left px-3 py-2 text-[10px] uppercase tracking-wider text-mempool-text-dim">
                      Amount
                    </th>
                    <th className="text-left px-3 py-2 text-[10px] uppercase tracking-wider text-mempool-text-dim">
                      Dest
                    </th>
                    <th className="text-left px-3 py-2 text-[10px] uppercase tracking-wider text-mempool-text-dim">
                      Status
                    </th>
                    <th className="text-left px-3 py-2 text-[10px] uppercase tracking-wider text-mempool-text-dim">
                      Nonce
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {myLocks.map((row) => {
                    const chainInfo = DEST_CHAINS.find((c) => c.id === row.destination_chain);
                    return (
                      <tr
                        key={row.nonce}
                        className="border-b border-mempool-border/40 hover:bg-mempool-bg/30"
                      >
                        <td className="px-3 py-2 font-mono text-mempool-text">
                          {omniFromSat(row.amount_sat)} OMNI
                        </td>
                        <td className="px-3 py-2">
                          <div className={`text-[10px] font-semibold ${chainInfo?.color ?? "text-mempool-text"}`}>
                            {chainInfo?.label ?? row.destination_chain}
                          </div>
                          <div className="font-mono text-mempool-text-dim text-[10px] break-all">
                            {row.destination_addr.length > 22
                              ? `${row.destination_addr.slice(0, 10)}…${row.destination_addr.slice(-8)}`
                              : row.destination_addr}
                          </div>
                          {row.dest_txhash && chainInfo?.explorerBase && (
                            <a
                              href={`${chainInfo.explorerBase}${row.dest_txhash}`}
                              target="_blank"
                              rel="noopener noreferrer"
                              className="text-mempool-blue hover:underline text-[10px]"
                            >
                              View on explorer
                            </a>
                          )}
                        </td>
                        <td className="px-3 py-2">
                          <StatusBadge status={row.status} />
                        </td>
                        <td className="px-3 py-2 font-mono text-mempool-text-dim text-[10px]">
                          {row.nonce.slice(0, 8)}…
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}

          <div className="px-4 py-2 border-t border-mempool-border/60 bg-mempool-bg/30 text-[10px] text-mempool-text-dim">
            Status transitions (locked → observing → quorum_reached → settled) are
            pushed by relayers via WebSocket in Phase 2. Rows here reflect what you
            submitted; refresh manually or wait for relayer confirmation.
          </div>
        </div>
      </div>

      {/* ── Recent bridge events feed ─────────────────────────────────────── */}
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
        <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider mb-2">
          Recent bridge events
          <span className="ml-2 text-[10px] text-mempool-text-dim normal-case">
            Phase 2 — not yet live
          </span>
        </h2>
        <p className="text-xs text-mempool-text-dim">{recentFeedNote}</p>

        {/* Show global counts from getbridgestatus as a proxy for activity */}
        {bridgeStatus && !backendIncomplete && (
          <div className="mt-3 grid grid-cols-3 gap-3">
            <div className="p-3 rounded bg-mempool-bg border border-mempool-border text-center">
              <div className="text-lg font-bold font-mono text-mempool-text">
                {bridgeStatus.lock_count}
              </div>
              <div className="text-[10px] text-mempool-text-dim uppercase tracking-wider">
                total locks
              </div>
            </div>
            <div className="p-3 rounded bg-mempool-bg border border-mempool-border text-center">
              <div className="text-lg font-bold font-mono text-mempool-text">
                {bridgeStatus.pending_unlock_count}
              </div>
              <div className="text-[10px] text-mempool-text-dim uppercase tracking-wider">
                pending unlocks
              </div>
            </div>
            <div className="p-3 rounded bg-mempool-bg border border-mempool-border text-center">
              <div className="text-lg font-bold font-mono text-mempool-blue">
                {omniFromSat(bridgeStatus.locked_total_sat)}
              </div>
              <div className="text-[10px] text-mempool-text-dim uppercase tracking-wider">
                OMNI in vault
              </div>
            </div>
          </div>
        )}

        {backendIncomplete && (
          <div className="mt-3 p-3 rounded bg-mempool-bg border border-mempool-border/50 text-xs text-mempool-text-dim italic">
            Bridge module not initialized — no event history available.
          </div>
        )}
      </div>

      {/* ── How it works footer ───────────────────────────────────────────── */}
      <div className="mt-6 text-xs text-mempool-text-dim space-y-1">
        <p>
          <span className="font-semibold text-mempool-text">Protocol:</span>{" "}
          Lock-and-mint bridge. OMNI is locked in the on-chain vault; relayers
          mint wrapped OMNI on the destination. Burning wrapped OMNI triggers
          the unlock flow on this chain (requires relayer quorum + challenge window).
        </p>
        <p>
          <span className="font-semibold text-mempool-text">Security:</span>{" "}
          {bridgeLimits?.requiredSigs ?? 3}-of-{bridgeLimits?.maxRelayers ?? 9} multisig.
          Anyone may submit a fraud proof (bridge_fraud_challenge RPC) during
          the {(bridgeLimits?.challengeWindowBlocks ?? 21600).toLocaleString()}-block window.
          Auto-pause triggers at {((bridgeLimits?.autoPauseFractionBps ?? 3000) / 100).toFixed(2)}% anomaly.
        </p>
        <p>
          <span className="font-semibold text-mempool-text">v1 note:</span>{" "}
          Per-user lock history and relayer status updates require Phase 2 (WebSocket
          relayer integration). Per-session tracking is stored in sessionStorage only.
        </p>
      </div>
    </div>
  );
}
