import React, { useEffect, useState } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import OmniBusRpcClient from "../../api/rpc-client";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import { DashboardPlasma } from "../effects/DashboardPlasma";
import { useIsPlasmaActive } from "../effects/PlasmaSlotContext";
import { SAT_PER_OMNI } from "../../utils/fmt";

interface StatCardProps {
  label: string;
  value: string | number;
  sub?: React.ReactNode;
  color?: string;
}

function StatCard({ label, value, sub, color = "text-mempool-text", slotIndex }: StatCardProps & { slotIndex?: number }) {
  const isActive = useIsPlasmaActive(slotIndex ?? -1);
  return (
    <div className="relative bg-mempool-bg-elev rounded-lg p-4 border border-mempool-border backdrop-blur-sm" style={{ overflow: "visible" }}>
      {slotIndex !== undefined && isActive && (
        <div
          className="absolute top-1/2 right-0 -translate-y-1/2 pointer-events-none"
          style={{ zIndex: 0, opacity: 0.7, width: "65%", height: "100%", marginRight: "-10%" }}
        >
          <DashboardPlasma />
        </div>
      )}
      <div className="relative" style={{ zIndex: 10 }}>
        <p className="text-xs text-mempool-text-dim uppercase tracking-wider mb-1">
          {label}
        </p>
        <p className={`text-xl font-mono font-bold ${color}`}>
          {typeof value === "number" ? value.toLocaleString() : value}
        </p>
        {sub && (
          typeof sub === "string"
            ? <p className="text-xs text-mempool-text-dim mt-1">{sub}</p>
            : <div className="mt-1">{sub}</div>
        )}
      </div>
    </div>
  );
}

function fmtBlockAge(ts: number | null): string {
  if (!ts) return "—";
  const secs = Math.floor(Date.now() / 1000 - ts);
  if (secs < 0) return "now";
  if (secs < 60) return `${secs}s ago`;
  const m = Math.floor(secs / 60);
  const s = secs % 60;
  return `${m}m ${s}s ago`;
}

export function StatsBar() {
  const { state } = useBlockchain();
  const [, setTick] = useState(0);
  const [totalMined, setTotalMined] = useState<string | null>(null);
  // Optimistic mempool delta — increments on every `new_tx` WS event and
  // resets when the next block lands (mempool size is authoritative again).
  // Skips the 500ms WS throttle by using ws-bus directly so users see TX
  // arrival the instant the node accepts it.
  const [pendingDelta, setPendingDelta] = useState(0);

  // 1s ticker so "Xs ago" on the Block Height card stays fresh.
  useEffect(() => {
    const id = setInterval(() => setTick((n) => n + 1), 1000);
    return () => clearInterval(id);
  }, []);

  useEffect(() => {
    const off1 = wsSubscribe("new_tx", () => setPendingDelta((n) => n + 1));
    const off2 = wsSubscribe("new_block", () => setPendingDelta(0));
    return () => { off1(); off2(); };
  }, []);

  // Fetch total mined every time block count changes (cheap on server side —
  // it's a single sum loop). This is the canonical "Total Mined Network"
  // shown on the public explorer in place of any per-wallet balance.
  useEffect(() => {
    const client = new OmniBusRpcClient();
    let cancelled = false;
    client.request_raw("omnibus_gettotalmined", []).then((r) => {
      if (cancelled) return;
      if (r?.totalMinedOMNI) setTotalMined(r.totalMinedOMNI);
    }).catch(() => {});
    return () => { cancelled = true; };
  }, [state.blockCount]);

  const rewardPerBlock = state.networkInfo?.blockRewardSAT
    ? (state.networkInfo.blockRewardSAT / SAT_PER_OMNI).toFixed(8)
    : "0.00833333";

  // Trim trailing zeros from "X.000000000" -> "X" or "X.123" (4 dp max).
  const formatOMNI = (raw: string | null) => {
    if (!raw) return "...";
    const [int, frac = ""] = raw.split(".");
    const trimmed = frac.replace(/0+$/, "").slice(0, 4);
    return trimmed.length > 0 ? `${int}.${trimmed}` : int;
  };

  return (
    <div className="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-5 gap-3">
      <StatCard
        label="Block Height"
        value={state.blockCount}
        sub={<span className="font-mono text-[10px] text-mempool-text-dim">{fmtBlockAge(state.lastBlockTimestamp)}</span>}
        color="text-mempool-blue"
        slotIndex={0}
      />
      <StatCard
        label="Mempool"
        value={state.mempoolSize + pendingDelta}
        sub={
          pendingDelta > 0
            ? `+${pendingDelta} just received`
            : state.mempoolStats
            ? `${(state.mempoolStats.bytes / 1024).toFixed(1)} KB`
            : "pending TXs"
        }
        color={
          (state.mempoolSize + pendingDelta) > 0
            ? "text-mempool-orange"
            : "text-mempool-text"
        }
        slotIndex={1}
      />
      <StatCard
        label="Difficulty"
        slotIndex={2}
        value={state.difficulty}
        sub="PoW leading zeros"
      />
      <StatCard
        label="Total Mined"
        slotIndex={3}
        value={`${formatOMNI(totalMined)} OMNI`}
        sub={(() => {
          const omni = totalMined ? parseFloat(totalMined) : 0;
          const pct = omni > 0 ? Math.min(100, (omni / 21_000_000) * 100) : 0;
          return (
            <div className="mt-1">
              <div className="w-full h-1 bg-mempool-bg rounded-full overflow-hidden">
                <div
                  className="h-full bg-mempool-green rounded-full transition-all"
                  style={{ width: `${pct}%` }}
                />
              </div>
              <p className="text-[9px] text-mempool-text-dim mt-0.5">
                {pct < 0.001 ? "<0.001" : pct.toFixed(4)}% of 21M cap
              </p>
            </div>
          );
        })()}
        color="text-mempool-green"
      />
      <StatCard
        label="Reward/Block"
        slotIndex={4}
        value={`${rewardPerBlock} OMNI`}
        sub="halving every 126M blocks"
        color="text-mempool-purple"
      />
    </div>
  );
}
