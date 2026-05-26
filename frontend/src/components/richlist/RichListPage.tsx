import { useEffect, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import { AddressLabel } from "../common/AddressLabel";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsNewBlockEvent } from "../../types";

const rpc = new OmniBusRpcClient();
const SAT_PER_OMNI = 1_000_000_000;

type Role = "validator" | "miner" | "agent" | "user";

type RichEntry = {
  rank: number;
  address: string;
  balance: number;
  isValidator: boolean;
  blocksMined: number;
  txCount: number;
  received: number;
  sent: number;
  firstHeight: number;
  lastHeight: number;
  roles?: string[]; // new field, optional for backward compat
  stake?: number;   // staked SAT
};

type RichListResp = {
  entries: RichEntry[];
  total: number;
  shown: number;
  totalSupply: number;
};

type ChainMetrics = {
  height: number;
  tipHash: string;
  totalSupply: number;
  addressesWithBalance: number;
  validators: number;
  validatorSetSize: number;
  minValidatorBalance: number;
  mempoolSize: number;
  peerCount: number;
  currentBlockReward: number;
  satPerOmni: number;
  latestBlockTxCount?: number;
  latestBlockFees?: number;
  latestBlockTimestamp?: number;
};

// Derive role list with backward-compat fallback when entry.roles is missing.
function deriveRoles(e: RichEntry): Role[] {
  if (e.roles && e.roles.length > 0) {
    const out: Role[] = [];
    for (const r of e.roles) {
      if (r === "validator" || r === "miner" || r === "agent" || r === "user") {
        if (!out.includes(r)) out.push(r);
      }
    }
    if (out.length > 0) return out;
  }
  const fallback: Role[] = [];
  if (e.blocksMined > 0) fallback.push("miner");
  if (e.isValidator === true) fallback.push("validator");
  if (fallback.length === 0) fallback.push("user");
  return fallback;
}

// ── Wealth Concentration ───────────────────────────────────────────────────

type ConcentrationSlot = { label: string; pct: number; color: string };

function buildConcentration(entries: RichEntry[], totalSupply: number): ConcentrationSlot[] {
  if (!totalSupply || entries.length === 0) return [];
  const pct = (n: number) => +((n / totalSupply) * 100).toFixed(2);
  const sumRange = (from: number, to: number) =>
    entries.slice(from, to).reduce((s, e) => s + e.balance, 0);
  const top1   = pct(sumRange(0, 1));
  const top5   = pct(sumRange(0, Math.min(5,  entries.length)));
  const top10  = pct(sumRange(0, Math.min(10, entries.length)));
  const top50  = pct(sumRange(0, Math.min(50, entries.length)));
  return [
    { label: "Top 1",    pct: top1,            color: "#f97316" },
    { label: "Top 5",    pct: top5  - top1,    color: "#eab308" },
    { label: "Top 10",   pct: top10 - top5,    color: "#22c55e" },
    { label: "Top 50",   pct: top50 - top10,   color: "#3b82f6" },
    { label: "Others",   pct: 100   - top50,   color: "#4b5563" },
  ].filter((s) => s.pct > 0);
}

function nakamotoCoefficient(entries: RichEntry[], totalSupply: number): number {
  let cumulative = 0;
  for (let i = 0; i < entries.length; i++) {
    cumulative += entries[i].balance;
    if (cumulative / totalSupply > 0.5) return i + 1;
  }
  return entries.length;
}

function ConcentrationBar({ entries, totalSupply }: { entries: RichEntry[]; totalSupply: number }) {
  const slots = buildConcentration(entries, totalSupply);
  if (slots.length === 0) return null;
  const coeff = nakamotoCoefficient(entries, totalSupply);

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 mb-6">
      <div className="flex items-center justify-between mb-3 flex-wrap gap-2">
        <h3 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim">
          Wealth Concentration
        </h3>
        <div className="flex items-center gap-1.5 text-xs">
          <span className="text-mempool-text-dim">Nakamoto coefficient:</span>
          <span
            className={`font-mono font-bold ${
              coeff <= 3 ? "text-red-400" : coeff <= 10 ? "text-orange-400" : "text-green-400"
            }`}
            title={`${coeff} address${coeff !== 1 ? "es" : ""} needed to control >50% of supply`}
          >
            {coeff}
          </span>
          <span className="text-mempool-text-dim text-[10px]">addr → 51%</span>
        </div>
      </div>

      {/* Stacked bar */}
      <div className="flex rounded-full overflow-hidden h-5 mb-3" title="Supply concentration by address group">
        {slots.map((s) => (
          <div
            key={s.label}
            style={{ width: `${s.pct}%`, backgroundColor: s.color, minWidth: s.pct > 0.5 ? "4px" : "0" }}
            title={`${s.label}: ${s.pct.toFixed(2)}%`}
            className="transition-all"
          />
        ))}
      </div>

      {/* Legend */}
      <div className="flex flex-wrap gap-x-4 gap-y-1">
        {slots.map((s) => (
          <div key={s.label} className="flex items-center gap-1.5 text-[11px]">
            <span className="w-2.5 h-2.5 rounded-sm inline-block flex-shrink-0" style={{ backgroundColor: s.color }} />
            <span className="text-mempool-text-dim">{s.label}</span>
            <span className="font-mono text-mempool-text">{s.pct.toFixed(2)}%</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// ───────────────────────────────────────────────────────────────────────────

export function RichListPage() {
  const [list, setList] = useState<RichListResp | null>(null);
  const [metrics, setMetrics] = useState<ChainMetrics | null>(null);
  const [loading, setLoading] = useState(true);
  const [limit, setLimit] = useState(100);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState("");

  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      try {
        const [rl, m] = await Promise.all([
          rpc.request_raw("getrichlist", [limit]) as Promise<RichListResp>,
          rpc.request_raw("getchainmetrics", []) as Promise<ChainMetrics>,
        ]);
        if (!cancelled) {
          setList(rl);
          setMetrics(m);
          setError(null);
        }
      } catch (e: any) {
        if (!cancelled) setError(e?.message || "RPC error");
      } finally {
        if (!cancelled) setLoading(false);
      }
    };
    refresh();
    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", () => { void refresh(); });
    const id = setInterval(refresh, 60_000);
    return () => {
      cancelled = true;
      clearInterval(id);
      unsub();
    };
  }, [limit]);

  const omniFmt = (sat: number) => (sat / SAT_PER_OMNI).toFixed(8);

  // Per-role counts derived from current entries.
  let validatorCount = 0;
  let minerCount = 0;
  let agentCount = 0;
  let userCount = 0;
  if (list) {
    for (const e of list.entries) {
      const roles = deriveRoles(e);
      if (roles.includes("validator")) validatorCount++;
      if (roles.includes("miner")) minerCount++;
      if (roles.includes("agent")) agentCount++;
      if (roles.includes("user")) userCount++;
    }
  }

  const exportCsv = () => {
    if (!list) return;
    const rows = [
      ["rank", "address", "balance_omni", "share_pct", "blocks_mined", "tx_count", "received_omni", "sent_omni", "roles"].join(","),
      ...list.entries.map((e) => {
        const sharePct = list.totalSupply > 0 ? ((e.balance / list.totalSupply) * 100).toFixed(4) : "0";
        const roles = deriveRoles(e).join("|");
        return [
          e.rank,
          `"${e.address}"`,
          (e.balance / SAT_PER_OMNI).toFixed(8),
          sharePct,
          e.blocksMined,
          e.txCount ?? 0,
          ((e.received ?? 0) / SAT_PER_OMNI).toFixed(8),
          ((e.sent ?? 0) / SAT_PER_OMNI).toFixed(8),
          `"${roles}"`,
        ].join(",");
      }),
    ].join("\n");
    const blob = new Blob([rows], { type: "text/csv" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url; a.download = `omnibus-richlist-top${list.shown}.csv`;
    a.click(); URL.revokeObjectURL(url);
  };

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      <h1 className="text-2xl font-bold text-mempool-text mb-2">Rich List</h1>
      <p className="text-mempool-text-dim text-sm mb-6">
        All addresses with a positive balance, sorted descending. Roles are
        determined per address: validator (stake ≥ 100 OMNI), miner (mined ≥ 1
        block), agent (registered via op_return), user (default).
      </p>

      {/* Metrics row */}
      {metrics && (
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
          <Metric label="Height" value={metrics.height.toLocaleString()} />
          <Metric label="Total supply" value={`${omniFmt(metrics.totalSupply)} OMNI`} />
          <Metric label="Addresses" value={metrics.addressesWithBalance.toLocaleString()} />
          <Metric label="Validators" value={validatorCount.toLocaleString()} />
          <Metric label="Miners" value={minerCount.toLocaleString()} />
          <Metric label="Agents" value={agentCount.toLocaleString()} />
          <Metric label="Users" value={userCount.toLocaleString()} />
          <Metric label="Mempool" value={metrics.mempoolSize.toString()} />
          <Metric label="Peers" value={metrics.peerCount.toString()} />
          <Metric label="Block reward" value={`${omniFmt(metrics.currentBlockReward)} OMNI`} />
          <Metric label="Min validator" value={`${omniFmt(metrics.minValidatorBalance)} OMNI`} />
        </div>
      )}

      {/* Wealth concentration bar */}
      {list && list.entries.length > 0 && list.totalSupply > 0 && (
        <ConcentrationBar entries={list.entries} totalSupply={list.totalSupply} />
      )}

      {/* Filter + limit selector */}
      <div className="flex flex-wrap items-center gap-2 mb-4">
        <input
          type="text"
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          placeholder="Filter by address…"
          className="flex-1 min-w-[180px] bg-mempool-bg border border-mempool-border rounded px-3 py-1.5 text-xs text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue transition-colors"
        />
        {filter && (
          <button onClick={() => setFilter("")} className="text-xs text-mempool-text-dim hover:text-mempool-text">✕</button>
        )}
        <span className="text-xs text-mempool-text-dim">Show:</span>
        {[50, 100, 250, 500].map((n) => (
          <button
            key={n}
            onClick={() => setLimit(n)}
            className={`px-2 py-1 text-xs rounded transition-colors ${
              limit === n
                ? "bg-mempool-blue text-white"
                : "bg-mempool-bg-elev text-mempool-text-dim hover:text-mempool-text"
            }`}
          >
            top {n}
          </button>
        ))}
        {list && (
          <span className="ml-auto text-xs text-mempool-text-dim">
            {filter
              ? `${list.entries.filter((e) => e.address.includes(filter)).length} matched`
              : `showing ${list.shown} of ${list.total}`}
          </span>
        )}
        {list && list.entries.length > 0 && (
          <button
            onClick={exportCsv}
            className="text-[10px] px-2 py-1 bg-mempool-bg-elev border border-mempool-border rounded text-mempool-text-dim hover:text-mempool-text transition-colors font-mono"
          >
            ⬇ CSV
          </button>
        )}
      </div>

      {/* Table */}
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-hidden">
        {loading && !list && (
          <div className="p-8 text-center text-mempool-text-dim text-sm">Loading rich list…</div>
        )}
        {error && (
          <div className="p-4 text-red-400 text-sm">RPC error: {error}</div>
        )}
        {list && list.entries.length === 0 && (
          <div className="p-8 text-center text-mempool-text-dim text-sm">
            No addresses with balance yet — chain is fresh.
          </div>
        )}
        {list && list.entries.length > 0 && (
          <div className="overflow-x-auto">
          <table className="w-full text-sm min-w-[640px]">
            <thead>
              <tr className="border-b border-mempool-border bg-mempool-bg/50">
                <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-12">#</th>
                <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Address</th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Balance</th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-20">Share</th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-24">Mined</th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-16">TXs</th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Received</th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Sent</th>
                <th className="text-center px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-40">Roles</th>
              </tr>
            </thead>
            <tbody>
              {(filter ? list.entries.filter((e) => e.address.includes(filter)) : list.entries).map((e) => {
                const sharePct = list.totalSupply > 0
                  ? ((e.balance / list.totalSupply) * 100).toFixed(2)
                  : "0.00";
                const roles = deriveRoles(e);
                return (
                  <tr key={e.address} className="border-b border-mempool-border/40 hover:bg-mempool-bg/30">
                    <td className="px-3 py-2 text-mempool-text-dim font-mono text-xs">{e.rank}</td>
                    <td className="px-3 py-2 font-mono text-xs">
                      <button
                        onClick={() => { window.location.hash = `#/address/${e.address}`; }}
                        className="text-mempool-blue hover:underline truncate max-w-[180px] inline-block align-middle"
                        title={e.address}
                      >
                        <AddressLabel address={e.address} showEmoji
                          truncate={{ left: 10, right: 6 }} />
                      </button>
                    </td>
                    <td className="px-3 py-2 text-right font-mono text-mempool-text">
                      {omniFmt(e.balance)} OMNI
                    </td>
                    <td className="px-3 py-2 text-right text-xs text-mempool-text-dim">{sharePct}%</td>
                    <td className="px-3 py-2 text-right text-xs text-mempool-text">
                      {e.blocksMined.toLocaleString()}
                    </td>
                    <td className="px-3 py-2 text-right text-xs text-mempool-text">
                      {(e.txCount ?? 0).toLocaleString()}
                    </td>
                    <td className="px-3 py-2 text-right font-mono text-xs text-green-300">
                      {omniFmt(e.received ?? 0)}
                    </td>
                    <td className="px-3 py-2 text-right font-mono text-xs text-red-300">
                      {omniFmt(e.sent ?? 0)}
                    </td>
                    <td className="px-3 py-2">
                      <RoleBadges roles={roles} stake={e.stake} omniFmt={omniFmt} />
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          </div>
        )}
      </div>

      <div className="mt-6 text-xs text-mempool-text-dim">
        <p>
          <span className="font-semibold text-mempool-text">Roles:</span> are
          determined per address: validator (stake ≥ 100 OMNI), miner (mined ≥ 1
          block), agent (registered via op_return), user (default).
        </p>
        <p className="mt-2">
          <span className="font-semibold text-mempool-text">Refresh:</span> auto every 8s.
        </p>
      </div>
    </div>
  );
}

function RoleBadges({
  roles,
  stake,
  omniFmt,
}: {
  roles: Role[];
  stake?: number;
  omniFmt: (sat: number) => string;
}) {
  const badgeBase =
    "inline-block px-1.5 py-0.5 text-[10px] uppercase tracking-wider rounded border font-mono";
  const styles: Record<Role, string> = {
    validator: "bg-green-900/40 text-green-300 border-green-600/40",
    miner: "bg-orange-900/40 text-orange-300 border-orange-600/40",
    agent: "bg-blue-900/40 text-blue-300 border-blue-600/40",
    user: "bg-gray-800 text-gray-400 border-gray-700",
  };
  return (
    <div className="flex flex-wrap items-center justify-center gap-[2px]">
      {roles.map((r) => {
        const title =
          r === "validator" && stake && stake > 0
            ? `stake: ${omniFmt(stake)} OMNI`
            : undefined;
        return (
          <span key={r} className={`${badgeBase} ${styles[r]}`} title={title}>
            {r}
          </span>
        );
      })}
    </div>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-3">
      <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">{label}</div>
      <div className="text-sm font-mono text-mempool-text">{value}</div>
    </div>
  );
}
