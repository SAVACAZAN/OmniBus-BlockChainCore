/**
 * TimelockPanel.tsx — CLTV timelock vaults.
 *
 * A timelock vault locks OMNI until a specific block height. The owner can
 * spend it only after the unlock block is reached. Useful for vesting, delayed
 * payments, or self-custody cold storage with a time-based unlock.
 *
 * RPCs used:
 *   timelock_create  { owner, dest, amount_sat, unlock_block }
 *   timelock_list    { owner? }
 *   timelock_spend   { vault_id }
 *   timelock_status  { vault_id }
 */

import { useCallback, useEffect, useState } from "react";
import { Lock, Unlock, RefreshCw, AlertTriangle } from "lucide-react";
import { OmniBusRpcClient } from "../../api/rpc-client";
import { SAT_PER_OMNI } from "../../utils/fmt";
import { useWallet } from "../../api/use-wallet";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsNewBlockEvent } from "../../types";

const rpc = new OmniBusRpcClient();


const BLOCKS_PER_DAY = 86_400; // 1s blocks

function fmtOmni(sat: number): string {
  return (sat / SAT_PER_OMNI).toFixed(4);
}
function shortAddr(addr: string): string {
  if (addr.length <= 16) return addr;
  return `${addr.slice(0, 8)}…${addr.slice(-6)}`;
}
function shortId(id: string): string {
  if (id.length <= 12) return id;
  return `${id.slice(0, 8)}…`;
}

type VaultState = "locked" | "unlocked" | "spent";

interface TimelockVault {
  vault_id: string;
  owner: string;
  dest: string;
  amount_sat: number;
  unlock_block: number;
  created_block: number;
  state: VaultState;
}

function stateBadge(state: VaultState): string {
  switch (state) {
    case "locked":   return "bg-mempool-orange/15 text-mempool-orange border-mempool-orange/40";
    case "unlocked": return "bg-mempool-green/15 text-mempool-green border-mempool-green/40";
    case "spent":    return "bg-mempool-border/30 text-mempool-text-dim border-mempool-border";
  }
}
function stateIcon(state: VaultState): string {
  switch (state) {
    case "locked":   return "🔒";
    case "unlocked": return "🔓";
    case "spent":    return "✅";
  }
}

export function TimelockPanel() {
  const wallet = useWallet();
  const [blockHeight, setBlockHeight] = useState(0);
  const [vaults, setVaults] = useState<TimelockVault[]>([]);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [spendBusy, setSpendBusy] = useState<string | null>(null);
  const [statusMap, setStatusMap] = useState<Record<string, { blocks_remaining: number }>>({});

  // Create form
  const [dest, setDest] = useState("");
  const [amountStr, setAmountStr] = useState("");
  const [unlockBlock, setUnlockBlock] = useState("");
  const [createBusy, setCreateBusy] = useState(false);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast(null), 6000);
  };

  // Fetch block height — live via WS, 60 s fallback poll.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const h = await rpc.getBlockCount();
        if (!cancelled) setBlockHeight(h);
      } catch { /* ignore */ }
    })();
    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", (ev) => {
      setBlockHeight(ev.height);
    });
    const id = setInterval(async () => {
      try {
        const h = await rpc.getBlockCount();
        if (!cancelled) setBlockHeight(h);
      } catch { /* ignore */ }
    }, 60_000);
    return () => { cancelled = true; clearInterval(id); unsub(); };
  }, []);

  const refresh = useCallback(async () => {
    setLoading(true);
    setErr(null);
    try {
      const owner = wallet?.address;
      const result = await rpc.request_raw("timelock_list", [
        owner ? { owner } : {},
      ]) as { vaults?: TimelockVault[] } | null;
      setVaults(result?.vaults ?? []);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [wallet]);

  useEffect(() => { void refresh(); }, [refresh]);

  const handleCreate = async () => {
    if (!wallet) { showToast("Connect wallet first"); return; }
    const amountSat = Math.floor((parseFloat(amountStr) || 0) * SAT_PER_OMNI);
    const unlock = parseInt(unlockBlock, 10);
    if (!dest.trim() || amountSat <= 0 || isNaN(unlock) || unlock <= blockHeight) {
      showToast("Fill all fields. Unlock block must be in the future.");
      return;
    }
    setCreateBusy(true);
    try {
      const result = await rpc.request_raw("timelock_create", [{
        owner: wallet.address,
        dest: dest.trim(),
        amount_sat: amountSat,
        unlock_block: unlock,
      }]) as { vault_id?: string } | null;
      showToast(`Vault created: ${result?.vault_id ?? "—"}`);
      setDest(""); setAmountStr(""); setUnlockBlock("");
      await refresh();
    } catch (e) {
      showToast(`Create failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setCreateBusy(false);
    }
  };

  const handleStatus = async (vaultId: string) => {
    try {
      const r = await rpc.request_raw("timelock_status", [{ vault_id: vaultId }]) as
        { blocks_remaining?: number } | null;
      if (r) setStatusMap((prev) => ({ ...prev, [vaultId]: { blocks_remaining: r.blocks_remaining ?? 0 } }));
    } catch { /* ignore */ }
  };

  const handleSpend = async (vaultId: string) => {
    setSpendBusy(vaultId);
    try {
      await rpc.request_raw("timelock_spend", [{ vault_id: vaultId }]);
      showToast(`Vault ${shortId(vaultId)} spent`);
      await refresh();
    } catch (e) {
      showToast(`Spend failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setSpendBusy(null);
    }
  };

  // Days estimate helper
  const unlockNum = parseInt(unlockBlock, 10);
  const blocksFromNow = isNaN(unlockNum) ? 0 : Math.max(0, unlockNum - blockHeight);
  const daysFromNow = (blocksFromNow / BLOCKS_PER_DAY).toFixed(1);

  return (
    <div className="space-y-5">
      {/* Info box */}
      <div className="bg-mempool-blue/5 border border-mempool-blue/20 rounded p-3 text-xs text-mempool-text-dim leading-relaxed">
        <Lock className="inline w-3.5 h-3.5 mr-1 text-mempool-blue -mt-0.5" />
        Timelock vaults (CLTV) lock OMNI until a specific block height is reached.
        Only the owner can spend after the unlock block — useful for vesting schedules or
        time-delayed self-custody.
      </div>

      {/* Create form */}
      <div className="bg-mempool-bg border border-mempool-border rounded p-4 space-y-3">
        <h3 className="text-[10px] uppercase tracking-wider text-mempool-text-dim font-medium">
          Create vault
        </h3>

        {!wallet && (
          <p className="text-xs text-mempool-orange font-mono bg-mempool-orange/10 border border-mempool-orange/30 rounded px-3 py-2">
            Connect wallet to create a timelock vault.
          </p>
        )}

        {wallet && (
          <div className="text-[10px] font-mono text-mempool-text-dim">
            Owner: <span className="text-mempool-text">{wallet.address}</span>
          </div>
        )}

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="space-y-1">
            <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
              Destination address
            </label>
            <input
              type="text"
              value={dest}
              onChange={(e) => setDest(e.target.value)}
              placeholder="ob1q…"
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
            />
          </div>
          <div className="space-y-1">
            <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
              Amount (OMNI)
            </label>
            <input
              type="number"
              min="0"
              step="0.0001"
              value={amountStr}
              onChange={(e) => setAmountStr(e.target.value)}
              placeholder="0.0000"
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
            />
          </div>
        </div>

        <div className="space-y-1">
          <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
            Unlock block
          </label>
          <input
            type="number"
            min={blockHeight + 1}
            value={unlockBlock}
            onChange={(e) => setUnlockBlock(e.target.value)}
            placeholder={`Current: ${blockHeight}`}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
          {unlockBlock && !isNaN(unlockNum) && (
            <p className="text-[10px] text-mempool-text-dim font-mono">
              ~{daysFromNow} days from now ({blocksFromNow.toLocaleString()} blocks)
            </p>
          )}
        </div>

        <button
          onClick={() => void handleCreate()}
          disabled={createBusy || !wallet}
          className="w-full px-4 py-2.5 rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25 disabled:opacity-40 text-xs font-medium uppercase tracking-wider"
        >
          {createBusy ? "Creating…" : "Create Vault"}
        </button>
      </div>

      {/* Vaults list */}
      <div className="flex items-center gap-2">
        <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Vaults ({vaults.length})
        </span>
        <div className="flex-1 h-px bg-mempool-border" />
        {vaults.length > 0 && (
          <button
            onClick={() => {
              const rows = [
                ["vault_id", "owner", "dest", "amount_omni", "unlock_block", "created_block", "state"].join(","),
                ...vaults.map((v) => [
                  `"${v.vault_id}"`,
                  `"${v.owner}"`,
                  `"${v.dest}"`,
                  (v.amount_sat / SAT_PER_OMNI).toFixed(4),
                  v.unlock_block,
                  v.created_block,
                  v.state,
                ].join(",")),
              ].join("\n");
              const blob = new Blob([rows], { type: "text/csv" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url; a.download = "omnibus-timelock-vaults.csv";
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
      {!err && vaults.length === 0 && (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          No timelock vaults yet. Create one above.
        </p>
      )}

      {vaults.length > 0 && (
        <div className="space-y-2">
          {vaults.map((v) => {
            const blocksLeft = Math.max(0, v.unlock_block - blockHeight);
            const daysLeft = (blocksLeft / BLOCKS_PER_DAY).toFixed(1);
            const canSpend = v.state === "unlocked";

            return (
              <div key={v.vault_id} className="bg-mempool-bg border border-mempool-border rounded p-3">
                <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
                  <span className="font-mono text-[10px] text-mempool-text-dim">
                    #{shortId(v.vault_id)}
                  </span>
                  <span className={`text-[10px] uppercase tracking-wider px-2 py-0.5 rounded border font-medium ${stateBadge(v.state)}`}>
                    {stateIcon(v.state)} {v.state}
                  </span>
                  <span className="font-mono text-sm text-mempool-text">
                    {fmtOmni(v.amount_sat)} <span className="text-xs text-mempool-text-dim">OMNI</span>
                  </span>
                  <span className="text-xs text-mempool-text-dim font-mono">
                    dest: {shortAddr(v.dest)}
                  </span>
                  <div className="flex-1" />
                  <button
                    onClick={() => void handleStatus(v.vault_id)}
                    className="px-2 py-1 text-[10px] rounded border border-mempool-border/40 text-mempool-text-dim hover:border-mempool-blue/40 hover:text-mempool-blue"
                    title="Fetch live status"
                  >
                    {statusMap[v.vault_id] !== undefined
                      ? `${statusMap[v.vault_id].blocks_remaining.toLocaleString()} blk left`
                      : "Status"}
                  </button>
                  {v.state !== "spent" && (
                    <button
                      onClick={() => void handleSpend(v.vault_id)}
                      disabled={!canSpend || spendBusy === v.vault_id}
                      className={`px-3 py-1 text-xs rounded border font-medium ${
                        canSpend
                          ? "border-mempool-green/40 text-mempool-green hover:bg-mempool-green/10"
                          : "border-mempool-border/40 text-mempool-text-dim opacity-40 cursor-not-allowed"
                      } disabled:opacity-40`}
                    >
                      {spendBusy === v.vault_id ? "Spending…" : "Spend"}
                    </button>
                  )}
                </div>
                <div className="mt-2 text-[11px] font-mono text-mempool-text-dim flex flex-wrap gap-x-4 gap-y-1">
                  <span>created @ {v.created_block}</span>
                  <span>unlock @ block {v.unlock_block.toLocaleString()}</span>
                  {v.state === "locked" && (
                    <span className="text-mempool-orange">
                      {blocksLeft.toLocaleString()} blk remaining (~{daysLeft}d)
                    </span>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      )}

      {/* Security note */}
      <div className="flex items-start gap-2 bg-mempool-orange/5 border border-mempool-orange/20 rounded p-3 text-[10px] text-mempool-text-dim">
        <AlertTriangle className="w-3.5 h-3.5 text-mempool-orange flex-shrink-0 mt-0.5" />
        <span>
          Timelock is enforced by the node. Once funds are locked, they cannot be spent until
          the unlock block even by the owner. Double-check the block height before confirming.
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
