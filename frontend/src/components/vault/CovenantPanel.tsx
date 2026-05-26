/**
 * CovenantPanel.tsx — Destination whitelist (covenant) manager.
 *
 * A covenant restricts an address to only send funds to pre-approved
 * destination addresses. Once a covenant is active, any TX from that
 * address to an unlisted destination is rejected by the node.
 *
 * RPCs used:
 *   covenant_create  { address, whitelist, max_per_tx_sat?, expires_block?, label }
 *   covenant_list    {}
 *   covenant_get     { address }
 *   covenant_remove  { address }
 */

import { useCallback, useEffect, useState } from "react";
import { Shield, Trash2, ChevronDown, ChevronRight, Plus, X, RefreshCw, AlertTriangle } from "lucide-react";
import { OmniBusRpcClient } from "../../api/rpc-client";
import { SAT_PER_OMNI, midTrunc } from "../../utils/fmt";
import { AddressLabel } from "../common/AddressLabel";
import { useWallet } from "../../api/use-wallet";

const rpc = new OmniBusRpcClient();


interface CovenantEntry {
  address: string;
  label: string;
  whitelist: string[];
  max_per_tx_sat?: number;
  expires_block?: number;
  created_block?: number;
}

export function CovenantPanel() {
  const wallet = useWallet();
  const [covenants, setCovenants] = useState<CovenantEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [removeAddr, setRemoveAddr] = useState<string | null>(null);
  const [liveMap, setLiveMap] = useState<Record<string, CovenantEntry>>({});

  // Create form state
  const [formAddr, setFormAddr] = useState("");
  const [formLabel, setFormLabel] = useState("");
  const [formWhitelist, setFormWhitelist] = useState<string[]>([""]);
  const [formMaxPerTx, setFormMaxPerTx] = useState("");
  const [formExpires, setFormExpires] = useState("");
  const [createBusy, setCreateBusy] = useState(false);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast(null), 5000);
  };

  // Auto-fill address from connected wallet
  useEffect(() => {
    if (wallet && !formAddr) setFormAddr(wallet.address);
  }, [wallet, formAddr]);

  const refresh = useCallback(async () => {
    setLoading(true);
    setErr(null);
    try {
      const result = await rpc.request_raw("covenant_list", [{}]) as
        { covenants?: CovenantEntry[] } | null;
      setCovenants(result?.covenants ?? []);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void refresh(); }, [refresh]);

  const handleCreate = async () => {
    const addr = formAddr.trim();
    const whitelist = formWhitelist.map((s) => s.trim()).filter(Boolean);
    if (!addr || whitelist.length === 0) {
      showToast("Address and at least one whitelist entry required.");
      return;
    }
    setCreateBusy(true);
    try {
      const payload: Record<string, unknown> = {
        address: addr,
        whitelist,
        label: formLabel.trim(),
      };
      if (formMaxPerTx) payload.max_per_tx_sat = Math.floor(parseFloat(formMaxPerTx) * SAT_PER_OMNI);
      if (formExpires) payload.expires_block = parseInt(formExpires, 10);

      await rpc.request_raw("covenant_create", [payload]);
      showToast(`Covenant created for ${midTrunc(addr)}`);
      setFormAddr(wallet?.address ?? "");
      setFormLabel("");
      setFormWhitelist([""]);
      setFormMaxPerTx("");
      setFormExpires("");
      await refresh();
    } catch (e) {
      showToast(`Create failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setCreateBusy(false);
    }
  };

  const handleFetchLive = async (address: string) => {
    try {
      const r = await rpc.request_raw("covenant_get", [{ address }]) as CovenantEntry | null;
      if (r) setLiveMap((prev) => ({ ...prev, [address]: r }));
    } catch { /* ignore */ }
  };

  const handleRemove = async (address: string) => {
    try {
      await rpc.request_raw("covenant_remove", [{ address }]);
      setRemoveAddr(null);
      showToast(`Covenant removed for ${midTrunc(address)}`);
      await refresh();
    } catch (e) {
      showToast(`Remove failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  };

  const toggleExpanded = (addr: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(addr)) next.delete(addr);
      else next.add(addr);
      return next;
    });
  };

  const addWhitelistRow = () => setFormWhitelist((prev) => [...prev, ""]);
  const updateWhitelistRow = (idx: number, val: string) =>
    setFormWhitelist((prev) => prev.map((v, i) => (i === idx ? val : v)));
  const removeWhitelistRow = (idx: number) =>
    setFormWhitelist((prev) => prev.filter((_, i) => i !== idx));

  return (
    <div className="space-y-5">
      {/* Info box */}
      <div className="bg-mempool-blue/5 border border-mempool-blue/20 rounded p-3 text-xs text-mempool-text-dim leading-relaxed">
        <Shield className="inline w-3.5 h-3.5 mr-1 text-mempool-blue -mt-0.5" />
        Covenants restrict an address to only send OMNI to pre-approved destinations.
        Any transaction to an unlisted address is rejected by the node — ideal for treasury
        addresses or exchange hot wallets.
      </div>

      {/* Create form */}
      <div className="bg-mempool-bg border border-mempool-border rounded p-4 space-y-4">
        <h3 className="text-[10px] uppercase tracking-wider text-mempool-text-dim font-medium">
          Create covenant
        </h3>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="space-y-1">
            <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
              Address to restrict
            </label>
            <input
              type="text"
              value={formAddr}
              onChange={(e) => setFormAddr(e.target.value)}
              placeholder="ob1q…"
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
              placeholder="e.g. Treasury cold"
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
            />
          </div>
        </div>

        {/* Whitelist */}
        <div className="space-y-2">
          <div className="flex items-center justify-between">
            <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
              Allowed destinations (whitelist)
            </label>
            <button
              type="button"
              onClick={addWhitelistRow}
              className="flex items-center gap-1 px-2 py-1 text-[10px] rounded border border-mempool-blue/30 text-mempool-blue hover:bg-mempool-blue/10"
            >
              <Plus className="w-3 h-3" />
              Add
            </button>
          </div>
          {formWhitelist.map((entry, idx) => (
            <div key={idx} className="flex gap-2">
              <input
                type="text"
                value={entry}
                onChange={(e) => updateWhitelistRow(idx, e.target.value)}
                placeholder={`Allowed address ${idx + 1}`}
                className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
              />
              {formWhitelist.length > 1 && (
                <button
                  type="button"
                  onClick={() => removeWhitelistRow(idx)}
                  className="px-2 py-1 text-mempool-orange hover:text-mempool-orange/70"
                >
                  <X className="w-3.5 h-3.5" />
                </button>
              )}
            </div>
          ))}
        </div>

        {/* Optional fields */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="space-y-1">
            <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
              Max per TX (OMNI, optional)
            </label>
            <input
              type="number"
              min="0"
              step="0.0001"
              value={formMaxPerTx}
              onChange={(e) => setFormMaxPerTx(e.target.value)}
              placeholder="Unlimited"
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
            />
          </div>
          <div className="space-y-1">
            <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
              Expires block (optional)
            </label>
            <input
              type="number"
              min="0"
              value={formExpires}
              onChange={(e) => setFormExpires(e.target.value)}
              placeholder="Never"
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
            />
          </div>
        </div>

        <button
          onClick={() => void handleCreate()}
          disabled={createBusy}
          className="w-full px-4 py-2.5 rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25 disabled:opacity-40 text-xs font-medium uppercase tracking-wider"
        >
          {createBusy ? "Creating…" : "Create Covenant"}
        </button>
      </div>

      {/* List */}
      <div className="flex items-center gap-2">
        <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Active covenants ({covenants.length})
        </span>
        <div className="flex-1 h-px bg-mempool-border" />
        {covenants.length > 0 && (
          <button
            onClick={() => {
              const rows = [
                ["address", "label", "whitelist_count", "whitelist", "max_per_tx_omni", "expires_block", "created_block"].join(","),
                ...covenants.map((c) => [
                  `"${c.address}"`,
                  `"${c.label}"`,
                  c.whitelist.length,
                  `"${c.whitelist.join("|")}"`,
                  c.max_per_tx_sat !== undefined ? (c.max_per_tx_sat / SAT_PER_OMNI).toFixed(4) : "",
                  c.expires_block ?? "",
                  c.created_block ?? "",
                ].join(",")),
              ].join("\n");
              const blob = new Blob([rows], { type: "text/csv" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url; a.download = "omnibus-covenants.csv";
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
      {!err && covenants.length === 0 && (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          No covenants yet. Create one above to restrict an address.
        </p>
      )}

      {covenants.length > 0 && (
        <div className="space-y-2">
          {covenants.map((c) => {
            const isOpen = expanded.has(c.address);
            return (
              <div key={c.address} className="bg-mempool-bg border border-mempool-border rounded">
                {/* Row header */}
                <button
                  className="w-full flex flex-wrap items-center gap-x-3 gap-y-1 p-3 text-left hover:bg-mempool-bg-light transition-colors"
                  onClick={() => toggleExpanded(c.address)}
                >
                  {isOpen ? (
                    <ChevronDown className="w-3.5 h-3.5 text-mempool-text-dim flex-shrink-0" />
                  ) : (
                    <ChevronRight className="w-3.5 h-3.5 text-mempool-text-dim flex-shrink-0" />
                  )}
                  <span className="font-mono text-xs text-mempool-blue">
                    <AddressLabel address={c.address} showEmoji truncate={{ left: 8, right: 6 }} />
                  </span>
                  <span className="text-xs text-mempool-text">{c.label || <span className="italic text-mempool-text-dim">—</span>}</span>
                  <span className="text-[10px] text-mempool-text-dim">
                    {c.whitelist.length} allowed dest{c.whitelist.length !== 1 ? "s" : ""}
                  </span>
                  {c.expires_block && (
                    <span className="text-[10px] text-mempool-orange">
                      expires @ {c.expires_block.toLocaleString()}
                    </span>
                  )}
                  <div className="flex-1" />
                  <button
                    onClick={(e) => { e.stopPropagation(); setRemoveAddr(c.address); }}
                    className="flex items-center gap-1 px-2 py-1 text-[10px] rounded border border-mempool-orange/30 text-mempool-orange hover:bg-mempool-orange/10"
                  >
                    <Trash2 className="w-3 h-3" />
                    Remove
                  </button>
                </button>

                {/* Expanded whitelist */}
                {isOpen && (
                  <div className="px-4 pb-3 border-t border-mempool-border/40 space-y-1 pt-2">
                    <div className="flex items-center justify-between mb-2">
                      <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
                        Whitelist{liveMap[c.address] ? " (live)" : ""}
                      </div>
                      {!liveMap[c.address] && (
                        <button
                          onClick={() => void handleFetchLive(c.address)}
                          className="text-[10px] text-mempool-blue hover:underline"
                        >
                          Fetch live
                        </button>
                      )}
                    </div>
                    {(liveMap[c.address]?.whitelist ?? c.whitelist).map((addr) => (
                      <div key={addr} className="font-mono text-xs text-mempool-text bg-mempool-bg-elev rounded px-2 py-1 break-all">
                        {addr}
                      </div>
                    ))}
                    {(liveMap[c.address]?.max_per_tx_sat ?? c.max_per_tx_sat) ? (
                      <div className="text-[10px] text-mempool-text-dim pt-1">
                        Max per TX: {((liveMap[c.address]?.max_per_tx_sat ?? c.max_per_tx_sat ?? 0) / SAT_PER_OMNI).toFixed(4)} OMNI
                      </div>
                    ) : null}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      {/* Warning */}
      <div className="flex items-start gap-2 bg-mempool-orange/5 border border-mempool-orange/20 rounded p-3 text-[10px] text-mempool-text-dim">
        <AlertTriangle className="w-3.5 h-3.5 text-mempool-orange flex-shrink-0 mt-0.5" />
        <span>
          Removing a covenant immediately lifts the restriction. Ensure the address is secure
          before removing, or the funds become unrestricted.
        </span>
      </div>

      {/* Remove confirmation */}
      {removeAddr && (
        <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4">
          <div className="bg-mempool-bg-elev border border-mempool-border rounded-lg w-full max-w-md mx-4 p-4 sm:p-5 space-y-4">
            <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
              Remove covenant?
            </h3>
            <p className="text-xs text-mempool-text-dim font-mono break-all">{removeAddr}</p>
            <p className="text-xs text-mempool-text-dim">
              This immediately removes all destination restrictions for this address.
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
