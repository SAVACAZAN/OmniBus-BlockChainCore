import { useEffect, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import { AddressDetail } from "./AddressDetail";
import { AddressLabel } from "../common/AddressLabel";

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

export function RichListPage() {
  const [list, setList] = useState<RichListResp | null>(null);
  const [metrics, setMetrics] = useState<ChainMetrics | null>(null);
  const [loading, setLoading] = useState(true);
  const [limit, setLimit] = useState(100);
  const [error, setError] = useState<string | null>(null);
  const [selectedAddress, setSelectedAddress] = useState<string | null>(null);
  const [filter, setFilter] = useState("");

  if (selectedAddress) {
    return (
      <AddressDetail
        address={selectedAddress}
        onBack={() => setSelectedAddress(null)}
      />
    );
  }

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
    const id = setInterval(refresh, 8000);
    return () => {
      cancelled = true;
      clearInterval(id);
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
                        onClick={() => setSelectedAddress(e.address)}
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
