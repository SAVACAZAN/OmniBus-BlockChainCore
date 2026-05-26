/**
 * ColdWalletPanel.tsx — Watch-only cold wallet address management.
 *
 * Cold wallet addresses are tracked locally (no private key ever loaded).
 * You see incoming TX history and balance for each watched address, but
 * cannot spend from them. Useful for hardware wallets, paper wallets, or
 * multi-sig cold storage kept air-gapped.
 *
 * RPCs used:
 *   coldwallet_add    { address, label }
 *   coldwallet_list   {}
 *   coldwallet_remove { address }
 *   coldwallet_history { address, limit }
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { Eye, Trash2, Clock, RefreshCw, X, Plus } from "lucide-react";
import { OmniBusRpcClient } from "../../api/rpc-client";
import { SAT_PER_OMNI, satToOmni, midTrunc } from "../../utils/fmt";
import { AddressLabel } from "../common/AddressLabel";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsNewBlockEvent } from "../../types/index";

const rpc = new OmniBusRpcClient();


const REFRESH_INTERVAL_MS = 30_000;

interface ColdWalletEntry {
  address: string;
  label: string;
  balance_sat: number;
  added_at?: number;
}

interface ColdWalletTx {
  txid: string;
  amount_sat: number;
  block_height: number | null;
  direction: "received" | "sent";
  ts?: number;
}

interface HistoryModalProps {
  entry: ColdWalletEntry;
  onClose: () => void;
}

function HistoryModal({ entry, onClose }: HistoryModalProps) {
  const [txs, setTxs] = useState<ColdWalletTx[] | null>(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const load = async () => {
      try {
        const result = await rpc.request_raw("coldwallet_history", [
          { address: entry.address, limit: 50 },
        ]) as { transactions?: ColdWalletTx[] } | null;
        if (!cancelled) setTxs(result?.transactions ?? []);
      } catch (e) {
        if (!cancelled) setErr(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    };
    void load();
    return () => { cancelled = true; };
  }, [entry.address]);

  return (
    <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4">
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-lg w-full max-w-lg mx-4 p-4 sm:p-5 space-y-4 max-h-[80vh] flex flex-col">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <Clock className="w-4 h-4 text-mempool-blue" />
            <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
              History — {entry.label || midTrunc(entry.address)}
            </h3>
          </div>
          <button
            onClick={onClose}
            className="text-mempool-text-dim hover:text-mempool-text"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        <p className="text-[10px] font-mono text-mempool-text-dim break-all">{entry.address}</p>

        <div className="flex-1 overflow-y-auto">
          {loading && (
            <p className="text-xs text-mempool-text-dim font-mono py-4 text-center">Loading…</p>
          )}
          {err && (
            <p className="text-xs text-mempool-orange font-mono">{err}</p>
          )}
          {!loading && !err && txs && txs.length === 0 && (
            <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
              No transactions found for this address.
            </p>
          )}
          {txs && txs.length > 0 && (
            <table className="w-full text-xs font-mono">
              <thead>
                <tr className="text-left text-mempool-text-dim uppercase tracking-wider">
                  <th className="py-1.5 pr-2">Block</th>
                  <th className="py-1.5 pr-2">TXID</th>
                  <th className="py-1.5 text-right">Amount</th>
                </tr>
              </thead>
              <tbody>
                {txs.map((tx, i) => (
                  <tr key={tx.txid + i} className="border-t border-mempool-border/40">
                    <td className="py-1.5 pr-2 text-mempool-text-dim">
                      {tx.block_height === null ? "pending" : tx.block_height}
                    </td>
                    <td className="py-1.5 pr-2 text-mempool-blue">
                      {midTrunc(tx.txid, 10, 6)}
                    </td>
                    <td className={`py-1.5 text-right ${tx.direction === "received" ? "text-mempool-green" : "text-mempool-orange"}`}>
                      {tx.direction === "received" ? "+" : "−"}{satToOmni(tx.amount_sat, 4)} OMNI
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>

        <button
          onClick={onClose}
          className="px-4 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-text"
        >
          Close
        </button>
      </div>
    </div>
  );
}

export function ColdWalletPanel() {
  const [addresses, setAddresses] = useState<ColdWalletEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);

  // Add form
  const [addAddress, setAddAddress] = useState("");
  const [addLabel, setAddLabel] = useState("");
  const [addBusy, setAddBusy] = useState(false);

  // History modal
  const [historyEntry, setHistoryEntry] = useState<ColdWalletEntry | null>(null);

  // Remove confirmation
  const [removeAddr, setRemoveAddr] = useState<string | null>(null);

  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast(null), 5000);
  };

  const refresh = useCallback(async () => {
    setLoading(true);
    setErr(null);
    try {
      const result = await rpc.request_raw("coldwallet_list", [{}]) as
        { addresses?: ColdWalletEntry[] } | null;
      setAddresses(result?.addresses ?? []);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", () => { void refresh(); });
    timerRef.current = setInterval(() => void refresh(), REFRESH_INTERVAL_MS);
    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
      unsub();
    };
  }, [refresh]);

  const handleAdd = async () => {
    const addr = addAddress.trim();
    if (!addr) return;
    setAddBusy(true);
    try {
      await rpc.request_raw("coldwallet_add", [{ address: addr, label: addLabel.trim() }]);
      setAddAddress("");
      setAddLabel("");
      showToast(`Watching address ${midTrunc(addr)}`);
      await refresh();
    } catch (e) {
      showToast(`Add failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setAddBusy(false);
    }
  };

  const handleRemove = async (address: string) => {
    try {
      await rpc.request_raw("coldwallet_remove", [{ address }]);
      setRemoveAddr(null);
      showToast(`Removed ${midTrunc(address)}`);
      await refresh();
    } catch (e) {
      showToast(`Remove failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  };

  return (
    <div className="space-y-5">
      {/* Info box */}
      <div className="bg-mempool-blue/5 border border-mempool-blue/20 rounded p-3 text-xs text-mempool-text-dim leading-relaxed">
        <Eye className="inline w-3.5 h-3.5 mr-1 text-mempool-blue -mt-0.5" />
        Watch-only addresses let you monitor cold wallet balances and incoming transactions without
        loading a private key. Funds cannot be spent from this interface.
      </div>

      {/* Add form */}
      <div className="bg-mempool-bg border border-mempool-border rounded p-4 space-y-3">
        <h3 className="text-[10px] uppercase tracking-wider text-mempool-text-dim font-medium">
          Add watch address
        </h3>
        <div className="flex flex-col sm:flex-row gap-2">
          <input
            type="text"
            value={addAddress}
            onChange={(e) => setAddAddress(e.target.value)}
            placeholder="ob1q… address"
            className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
          <input
            type="text"
            value={addLabel}
            onChange={(e) => setAddLabel(e.target.value)}
            placeholder="Label (optional)"
            className="w-full sm:w-40 bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
          <button
            onClick={() => void handleAdd()}
            disabled={addBusy || !addAddress.trim()}
            className="flex items-center gap-1.5 px-4 py-2 text-xs rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25 disabled:opacity-40 whitespace-nowrap"
          >
            <Plus className="w-3.5 h-3.5" />
            {addBusy ? "Adding…" : "Add Watch"}
          </button>
        </div>
      </div>

      {/* Header row */}
      <div className="flex items-center gap-2">
        <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Watched addresses ({addresses.length})
        </span>
        <div className="flex-1 h-px bg-mempool-border" />
        {addresses.length > 0 && (
          <button
            onClick={() => {
              const rows = [
                ["address", "label", "balance_omni"].join(","),
                ...addresses.map((a) => [
                  `"${a.address}"`,
                  `"${a.label}"`,
                  (a.balance_sat / SAT_PER_OMNI).toFixed(4),
                ].join(",")),
              ].join("\n");
              const blob = new Blob([rows], { type: "text/csv" });
              const url = URL.createObjectURL(blob);
              const el = document.createElement("a");
              el.href = url; el.download = "omnibus-cold-wallets.csv";
              el.click(); URL.revokeObjectURL(url);
            }}
            className="flex items-center gap-1.5 px-3 py-1 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-text font-mono"
          >
            ⬇ CSV
          </button>
        )}
        <button
          onClick={() => void refresh()}
          disabled={loading}
          className="flex items-center gap-1.5 px-3 py-1 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-50"
        >
          <RefreshCw className={`w-3 h-3 ${loading ? "animate-spin" : ""}`} />
          Refresh
        </button>
      </div>

      {err && <p className="text-xs text-mempool-orange font-mono">{err}</p>}

      {!err && addresses.length === 0 && (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          No watched addresses yet. Add a cold wallet address above.
        </p>
      )}

      {/* Table */}
      {addresses.length > 0 && (
        <div className="overflow-x-auto -mx-3 sm:mx-0">
          <table className="w-full min-w-[480px] text-xs font-mono">
            <thead className="sticky top-0 bg-mempool-bg-elev">
              <tr className="text-left text-mempool-text-dim uppercase tracking-wider">
                <th className="py-2 px-2 font-medium">Address</th>
                <th className="py-2 px-2 font-medium">Label</th>
                <th className="py-2 px-2 font-medium text-right">Balance (OMNI)</th>
                <th className="py-2 px-2 font-medium text-center">Actions</th>
              </tr>
            </thead>
            <tbody>
              {addresses.map((entry) => (
                <tr key={entry.address} className="border-t border-mempool-border/40 hover:bg-mempool-bg/50">
                  <td className="py-2 px-2 text-mempool-blue" title={entry.address}>
                    <button onClick={() => { window.location.hash = `#/address/${entry.address}`; }} className="hover:underline">
                      <AddressLabel address={entry.address} showEmoji truncate={{ left: 8, right: 6 }} />
                    </button>
                  </td>
                  <td className="py-2 px-2 text-mempool-text-dim">
                    {entry.label || <span className="italic opacity-50">—</span>}
                  </td>
                  <td className="py-2 px-2 text-right text-mempool-text">
                    {satToOmni(entry.balance_sat ?? 0, 4)}
                  </td>
                  <td className="py-2 px-2">
                    <div className="flex items-center justify-center gap-2">
                      <button
                        onClick={() => setHistoryEntry(entry)}
                        className="flex items-center gap-1 px-2 py-1 text-[10px] rounded border border-mempool-blue/30 text-mempool-blue hover:bg-mempool-blue/10"
                      >
                        <Clock className="w-3 h-3" />
                        History
                      </button>
                      <button
                        onClick={() => setRemoveAddr(entry.address)}
                        className="flex items-center gap-1 px-2 py-1 text-[10px] rounded border border-mempool-orange/30 text-mempool-orange hover:bg-mempool-orange/10"
                      >
                        <Trash2 className="w-3 h-3" />
                        Remove
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* History modal */}
      {historyEntry && (
        <HistoryModal entry={historyEntry} onClose={() => setHistoryEntry(null)} />
      )}

      {/* Remove confirmation modal */}
      {removeAddr && (
        <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4">
          <div className="bg-mempool-bg-elev border border-mempool-border rounded-lg w-full max-w-md mx-4 p-4 sm:p-5 space-y-4">
            <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
              Remove watch address?
            </h3>
            <p className="text-xs text-mempool-text-dim font-mono break-all">{removeAddr}</p>
            <p className="text-xs text-mempool-text-dim">
              This only removes it from the watch list. No funds are affected.
            </p>
            <div className="flex justify-end gap-2">
              <button
                onClick={() => setRemoveAddr(null)}
                className="px-3 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-text"
              >
                Cancel
              </button>
              <button
                onClick={() => void handleRemove(removeAddr)}
                className="px-3 py-2 text-xs rounded bg-mempool-orange/20 text-mempool-orange border border-mempool-orange/40 hover:bg-mempool-orange/30"
              >
                Remove
              </button>
            </div>
          </div>
        </div>
      )}

      {toast && (
        <div className="fixed bottom-4 right-4 bg-mempool-bg-elev border border-mempool-border rounded px-4 py-2 text-xs text-mempool-text font-mono shadow-lg z-50">
          {toast}
        </div>
      )}
    </div>
  );
}
