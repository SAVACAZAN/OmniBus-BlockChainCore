/**
 * TreasuryPanel.tsx — Auto-distribute treasury manager.
 *
 * A treasury address auto-distributes incoming OMNI to a set of destination
 * addresses by percentage once the balance exceeds a trigger threshold.
 * Useful for protocol fee distribution, DAO payouts, or salary splits.
 *
 * RPCs used:
 *   treasury_create     { address, destinations, trigger_sat, label }
 *   treasury_list       {}
 *   treasury_distribute { treasury_id }
 *   treasury_status     { treasury_id }
 */

import { useCallback, useEffect, useState } from "react";
import { Wallet, Plus, X, RefreshCw, Play, AlertTriangle } from "lucide-react";
import { rpc } from "../../api/rpc-client";
import { SAT_PER_OMNI, satToOmni, midTrunc } from "../../utils/fmt";
import { useWallet } from "../../api/use-wallet";



interface TreasuryDest {
  address: string;
  percent: number;
  label: string;
}

interface TreasuryEntry {
  treasury_id: string;
  address: string;
  label: string;
  balance_sat: number;
  trigger_sat: number;
  destinations: TreasuryDest[];
  last_distribute_block?: number;
  last_distribute_ts?: number;
}

interface DistributeModalProps {
  entry: TreasuryEntry;
  onClose: () => void;
  onConfirm: () => Promise<void>;
}

function DistributeModal({ entry, onClose, onConfirm }: DistributeModalProps) {
  const [busy, setBusy] = useState(false);

  const handleConfirm = async () => {
    setBusy(true);
    try {
      await onConfirm();
      onClose();
    } finally {
      setBusy(false);
    }
  };

  const perDest = entry.destinations.map((d) => ({
    ...d,
    amount_sat: Math.floor(entry.balance_sat * (d.percent / 100)),
  }));

  return (
    <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4">
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-lg w-full max-w-lg mx-4 p-4 sm:p-5 space-y-4">
        <div className="flex items-center gap-2">
          <Play className="w-4 h-4 text-mempool-green" />
          <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
            Distribute treasury
          </h3>
        </div>

        <div className="text-[10px] font-mono text-mempool-text-dim">
          From: <span className="text-mempool-text break-all">{entry.address}</span>
        </div>

        <div className="text-xs text-mempool-text-dim">
          Current balance: <span className="text-mempool-text font-mono">{satToOmni(entry.balance_sat, 4)} OMNI</span>
        </div>

        <div className="space-y-2">
          <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Split</div>
          {perDest.map((d) => (
            <div key={d.address} className="flex items-center justify-between text-xs font-mono bg-mempool-bg rounded px-3 py-2">
              <div>
                <span className="text-mempool-text-dim">{d.label || midTrunc(d.address)}</span>
                <span className="text-mempool-text-dim ml-2">{d.percent}%</span>
              </div>
              <span className="text-mempool-green">+{satToOmni(d.amount_sat, 4)} OMNI</span>
            </div>
          ))}
        </div>

        <div className="flex justify-end gap-2 pt-2">
          <button
            onClick={onClose}
            className="px-3 py-2.5 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-text"
          >
            Cancel
          </button>
          <button
            onClick={() => void handleConfirm()}
            disabled={busy}
            className="px-3 py-2.5 text-xs rounded bg-mempool-green/20 text-mempool-green border border-mempool-green/40 hover:bg-mempool-green/30 disabled:opacity-50"
          >
            {busy ? "Distributing…" : "Confirm distribute"}
          </button>
        </div>
      </div>
    </div>
  );
}

export function TreasuryPanel() {
  const wallet = useWallet();
  const [treasuries, setTreasuries] = useState<TreasuryEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [distributeTarget, setDistributeTarget] = useState<TreasuryEntry | null>(null);
  const [statusMap, setStatusMap] = useState<Record<string, { pending_distribute_sat: number; total_distributed_sat: number; balance_sat: number }>>({});

  // Create form
  const [formAddress, setFormAddress] = useState("");
  const [formLabel, setFormLabel] = useState("");
  const [formTrigger, setFormTrigger] = useState("");
  const [formDests, setFormDests] = useState<TreasuryDest[]>([
    { address: "", percent: 100, label: "" },
  ]);
  const [createBusy, setCreateBusy] = useState(false);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast(null), 6000);
  };

  const refresh = useCallback(async () => {
    setLoading(true);
    setErr(null);
    try {
      const result = await rpc.request_raw("treasury_list", [{}]) as
        { treasuries?: TreasuryEntry[] } | null;
      setTreasuries(result?.treasuries ?? []);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void refresh(); }, [refresh]);

  const percentTotal = formDests.reduce((acc, d) => acc + (d.percent || 0), 0);
  const percentValid = Math.abs(percentTotal - 100) < 0.01;

  const addDestRow = () =>
    setFormDests((prev) => [...prev, { address: "", percent: 0, label: "" }]);
  const updateDest = (idx: number, field: keyof TreasuryDest, val: string | number) =>
    setFormDests((prev) => prev.map((d, i) => i === idx ? { ...d, [field]: val } : d));
  const removeDest = (idx: number) =>
    setFormDests((prev) => prev.filter((_, i) => i !== idx));

  const handleCreate = async () => {
    const addr = formAddress.trim();
    const dests = formDests.filter((d) => d.address.trim());
    if (!addr || dests.length === 0 || !percentValid) {
      showToast("Fill all fields. Percentages must sum to 100%.");
      return;
    }
    const triggerSat = Math.floor((parseFloat(formTrigger) || 0) * SAT_PER_OMNI);
    setCreateBusy(true);
    try {
      await rpc.request_raw("treasury_create", [{
        address: addr,
        label: formLabel.trim(),
        destinations: dests.map((d) => ({
          address: d.address.trim(),
          percent: d.percent,
          label: d.label.trim(),
        })),
        trigger_sat: triggerSat,
      }]);
      showToast(`Treasury created for ${midTrunc(addr)}`);
      setFormAddress("");
      setFormLabel("");
      setFormTrigger("");
      setFormDests([{ address: "", percent: 100, label: "" }]);
      await refresh();
    } catch (e) {
      showToast(`Create failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setCreateBusy(false);
    }
  };

  const handleStatus = async (tid: string) => {
    try {
      const r = await rpc.request_raw("treasury_status", [{ treasury_id: tid }]) as
        { pending_distribute_sat?: number; total_distributed_sat?: number; balance_sat?: number } | null;
      if (r) setStatusMap((prev) => ({ ...prev, [tid]: {
        pending_distribute_sat: r.pending_distribute_sat ?? 0,
        total_distributed_sat: r.total_distributed_sat ?? 0,
        balance_sat: r.balance_sat ?? 0,
      } }));
    } catch { /* ignore */ }
  };

  const handleDistribute = async (entry: TreasuryEntry) => {
    try {
      await rpc.request_raw("treasury_distribute", [{ treasury_id: entry.treasury_id }]);
      showToast(`Distributed treasury ${entry.label || midTrunc(entry.address)}`);
      await refresh();
    } catch (e) {
      showToast(`Distribute failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  };

  return (
    <div className="space-y-5">
      {/* Info box */}
      <div className="bg-mempool-blue/5 border border-mempool-blue/20 rounded p-3 text-xs text-mempool-text-dim leading-relaxed">
        <Wallet className="inline w-3.5 h-3.5 mr-1 text-mempool-blue -mt-0.5" />
        Treasury addresses automatically distribute OMNI to a set of destinations by percentage
        when the balance exceeds a configurable trigger amount. Ideal for protocol fees, DAO
        payouts, or multi-party splits.
      </div>

      {/* Create form */}
      <div className="bg-mempool-bg border border-mempool-border rounded p-4 space-y-4">
        <h3 className="text-[10px] uppercase tracking-wider text-mempool-text-dim font-medium">
          Create treasury
        </h3>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="space-y-1">
            <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
              Treasury address
            </label>
            <input
              type="text"
              value={formAddress}
              onChange={(e) => setFormAddress(e.target.value)}
              placeholder={wallet?.address ?? "ob1q…"}
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
            />
          </div>
          <div className="space-y-1">
            <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
              Label
            </label>
            <input
              type="text"
              value={formLabel}
              onChange={(e) => setFormLabel(e.target.value)}
              placeholder="e.g. Protocol fees"
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
            />
          </div>
        </div>

        <div className="space-y-1">
          <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
            Trigger amount (OMNI) — distribute when balance exceeds this
          </label>
          <input
            type="number"
            min="0"
            step="0.0001"
            value={formTrigger}
            onChange={(e) => setFormTrigger(e.target.value)}
            placeholder="0.0000 (manual only)"
            className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
        </div>

        {/* Destinations */}
        <div className="space-y-2">
          <div className="flex items-center justify-between">
            <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
              Destinations — total: {percentTotal.toFixed(1)}%
              {!percentValid && (
                <span className="ml-2 text-mempool-orange">must sum to 100%</span>
              )}
              {percentValid && (
                <span className="ml-2 text-mempool-green">OK</span>
              )}
            </label>
            <button
              type="button"
              onClick={addDestRow}
              className="flex items-center gap-1 px-2 py-1 text-[10px] rounded border border-mempool-blue/30 text-mempool-blue hover:bg-mempool-blue/10"
            >
              <Plus className="w-3 h-3" />
              Add row
            </button>
          </div>
          {formDests.map((d, idx) => (
            <div key={idx} className="flex flex-col sm:flex-row gap-2">
              <input
                type="text"
                value={d.address}
                onChange={(e) => updateDest(idx, "address", e.target.value)}
                placeholder="ob1q… address"
                className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
              />
              <input
                type="text"
                value={d.label}
                onChange={(e) => updateDest(idx, "label", e.target.value)}
                placeholder="Label"
                className="w-full sm:w-28 bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
              />
              <div className="flex items-center gap-1 w-full sm:w-24">
                <input
                  type="number"
                  min="0"
                  max="100"
                  step="0.1"
                  value={d.percent}
                  onChange={(e) => updateDest(idx, "percent", parseFloat(e.target.value) || 0)}
                  className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text focus:outline-none focus:border-mempool-blue"
                />
                <span className="text-xs text-mempool-text-dim">%</span>
              </div>
              {formDests.length > 1 && (
                <button
                  type="button"
                  onClick={() => removeDest(idx)}
                  className="px-2 py-1 text-mempool-orange hover:text-mempool-orange/70 flex-shrink-0"
                >
                  <X className="w-3.5 h-3.5" />
                </button>
              )}
            </div>
          ))}
        </div>

        <button
          onClick={() => void handleCreate()}
          disabled={createBusy || !percentValid}
          className="w-full px-4 py-2.5 rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25 disabled:opacity-40 text-xs font-medium uppercase tracking-wider"
        >
          {createBusy ? "Creating…" : "Create Treasury"}
        </button>
      </div>

      {/* List */}
      <div className="flex items-center gap-2">
        <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Treasuries ({treasuries.length})
        </span>
        <div className="flex-1 h-px bg-mempool-border" />
        {treasuries.length > 0 && (
          <button
            onClick={() => {
              const rows = [
                ["treasury_id", "address", "label", "balance_omni", "trigger_omni", "destinations", "last_distribute_block"].join(","),
                ...treasuries.map((t) => [
                  `"${t.treasury_id}"`,
                  `"${t.address}"`,
                  `"${t.label}"`,
                  (t.balance_sat / SAT_PER_OMNI).toFixed(4),
                  (t.trigger_sat / SAT_PER_OMNI).toFixed(4),
                  t.destinations.length,
                  t.last_distribute_block ?? "",
                ].join(",")),
              ].join("\n");
              const blob = new Blob([rows], { type: "text/csv" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url; a.download = "omnibus-treasuries.csv";
              a.click(); URL.revokeObjectURL(url);
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
      {!err && treasuries.length === 0 && (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          No treasuries yet. Create one above.
        </p>
      )}

      {treasuries.length > 0 && (
        <div className="space-y-2">
          {treasuries.map((t) => {
            const belowTrigger = t.balance_sat < t.trigger_sat;
            return (
              <div key={t.treasury_id} className="bg-mempool-bg border border-mempool-border rounded p-3">
                <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
                  <span className="text-xs text-mempool-text font-medium">
                    {t.label || midTrunc(t.address)}
                  </span>
                  <span className="font-mono text-[10px] text-mempool-text-dim">
                    {midTrunc(t.address)}
                  </span>
                  <div className="flex-1" />
                  <button
                    onClick={() => void handleStatus(t.treasury_id)}
                    className="flex items-center gap-1 px-2 py-1 text-xs rounded border border-mempool-border/40 text-mempool-text-dim hover:border-mempool-blue/40 hover:text-mempool-blue"
                  >
                    Status
                  </button>
                  <button
                    onClick={() => setDistributeTarget(t)}
                    className="flex items-center gap-1 px-3 py-1 text-xs rounded border border-mempool-green/40 text-mempool-green hover:bg-mempool-green/10"
                  >
                    <Play className="w-3 h-3" />
                    Distribute Now
                  </button>
                </div>

                <div className="mt-2 grid grid-cols-2 sm:grid-cols-4 gap-2 text-[11px] font-mono text-mempool-text-dim">
                  <div>
                    <div className="text-[9px] uppercase tracking-wider">Balance</div>
                    <div className="text-mempool-text">{satToOmni(t.balance_sat, 4)} OMNI</div>
                  </div>
                  <div>
                    <div className="text-[9px] uppercase tracking-wider">Trigger</div>
                    <div className={belowTrigger ? "text-mempool-orange" : "text-mempool-green"}>
                      {satToOmni(t.trigger_sat, 4)} OMNI
                    </div>
                  </div>
                  <div>
                    <div className="text-[9px] uppercase tracking-wider">Destinations</div>
                    <div className="text-mempool-text">{t.destinations.length}</div>
                  </div>
                  <div>
                    <div className="text-[9px] uppercase tracking-wider">Last distribute</div>
                    <div className="text-mempool-text">
                      {t.last_distribute_block ? `@ ${t.last_distribute_block}` : "never"}
                    </div>
                  </div>
                </div>

                {/* Live status from treasury_status RPC */}
                {statusMap[t.treasury_id] && (
                  <div className="mt-2 grid grid-cols-3 gap-2 text-[11px] font-mono">
                    <div>
                      <div className="text-[9px] uppercase tracking-wider text-mempool-text-dim">Live balance</div>
                      <div className="text-mempool-blue">{satToOmni(statusMap[t.treasury_id].balance_sat, 4)} OMNI</div>
                    </div>
                    <div>
                      <div className="text-[9px] uppercase tracking-wider text-mempool-text-dim">Pending dist.</div>
                      <div className={statusMap[t.treasury_id].pending_distribute_sat > 0 ? "text-mempool-green" : "text-mempool-text-dim"}>
                        {satToOmni(statusMap[t.treasury_id].pending_distribute_sat, 4)} OMNI
                      </div>
                    </div>
                    <div>
                      <div className="text-[9px] uppercase tracking-wider text-mempool-text-dim">Total distrib.</div>
                      <div className="text-mempool-text">{satToOmni(statusMap[t.treasury_id].total_distributed_sat, 4)} OMNI</div>
                    </div>
                  </div>
                )}

                {/* Destinations mini-list */}
                <div className="mt-2 flex flex-wrap gap-1">
                  {t.destinations.map((d) => (
                    <span key={d.address} className="text-[9px] font-mono bg-mempool-bg-elev border border-mempool-border rounded px-2 py-0.5 text-mempool-text-dim">
                      {d.label || midTrunc(d.address)} {d.percent}%
                    </span>
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      )}

      {/* Distribute modal */}
      {distributeTarget && (
        <DistributeModal
          entry={distributeTarget}
          onClose={() => setDistributeTarget(null)}
          onConfirm={() => handleDistribute(distributeTarget)}
        />
      )}

      {/* Warning */}
      <div className="flex items-start gap-2 bg-mempool-orange/5 border border-mempool-orange/20 rounded p-3 text-[10px] text-mempool-text-dim">
        <AlertTriangle className="w-3.5 h-3.5 text-mempool-orange flex-shrink-0 mt-0.5" />
        <span>
          "Distribute Now" sends the entire current balance split by the configured percentages.
          Ensure the balance and percentages are correct before confirming.
        </span>
      </div>

      {toast && (
        <div className="fixed bottom-4 right-4 bg-mempool-bg-elev border border-mempool-border rounded px-4 py-2 text-xs text-mempool-text font-mono shadow-lg z-50">
          {toast}
        </div>
      )}
    </div>
  );
}
