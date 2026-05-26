import { useEffect, useState } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import OmniBusRpcClient from "../../api/rpc-client";
import { AddressLabel } from "../common/AddressLabel";

const rpc = new OmniBusRpcClient();
const SAT = 1_000_000_000;

interface MinerRow {
  address: string;
  blocksMined: number;
  totalRewardSAT: number;
  currentBalanceSAT: number;
  lastBlockHeight?: number;
}

function fmtOmni(sat: number): string {
  const omni = sat / SAT;
  return omni >= 1
    ? omni.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 4 })
    : omni.toFixed(6);
}

export function MinerTable() {
  const { state } = useBlockchain();
  const [rpcMiners, setRpcMiners] = useState<MinerRow[]>([]);

  useEffect(() => {
    let cancelled = false;
    const load = async () => {
      try {
        const r: any = await rpc.request_raw("getminerstats", []);
        if (cancelled) return;
        if (Array.isArray(r?.miners)) {
          setRpcMiners(r.miners.map((m: any): MinerRow => ({
            address: m.miner || "",
            blocksMined: m.blocksMined || 0,
            totalRewardSAT: m.totalRewardSAT || 0,
            currentBalanceSAT: m.currentBalanceSAT || 0,
            lastBlockHeight: m.lastBlockHeight ?? undefined,
          })));
        }
      } catch {}
    };
    load();
    const id = setInterval(load, 8000);
    return () => { cancelled = true; clearInterval(id); };
  }, [state.blockCount]);

  // Merge: prefer RPC data (richer), fall back to store
  const miners: MinerRow[] =
    rpcMiners.length > 0
      ? rpcMiners
      : state.miners.map((m) => ({
          address: m.miner,
          blocksMined: m.blocksMined,
          totalRewardSAT: m.totalRewardSAT,
          currentBalanceSAT: m.currentBalanceSAT,
        }));

  if (miners.length === 0) {
    return (
      <div className="bg-mempool-bg-elev rounded-lg border border-mempool-border p-6 text-center text-sm text-mempool-text-dim backdrop-blur-sm">
        No miners registered yet. Start mining to appear here.
      </div>
    );
  }

  const totalBlocks = miners.reduce((s, m) => s + m.blocksMined, 0);

  return (
    <div className="bg-mempool-bg-elev rounded-lg border border-mempool-border overflow-hidden backdrop-blur-sm">
      <div className="px-4 py-3 border-b border-mempool-border flex items-center justify-between">
        <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
          Miners ({miners.length})
        </h3>
        {totalBlocks > 0 && (
          <span className="text-[10px] text-mempool-text-dim">
            {totalBlocks.toLocaleString()} blocks total
          </span>
        )}
      </div>
      <div className="overflow-x-auto">
        <table className="w-full text-xs min-w-[520px]">
          <thead>
            <tr className="text-mempool-text-dim border-b border-mempool-border/50 text-left">
              <th className="px-4 py-2 font-medium">#</th>
              <th className="px-4 py-2 font-medium">Address</th>
              <th className="px-4 py-2 font-medium text-right">Blocks</th>
              <th className="px-4 py-2 font-medium text-right">Share</th>
              <th className="px-4 py-2 font-medium text-right">Total Reward</th>
              <th className="px-4 py-2 font-medium text-right">Balance</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-mempool-border/30">
            {[...miners]
              .sort((a, b) => b.blocksMined - a.blocksMined)
              .map((miner, idx) => {
                const pct = totalBlocks > 0
                  ? (miner.blocksMined / totalBlocks) * 100
                  : 0;
                const barColor =
                  pct > 50 ? "bg-red-400" :
                  pct > 33 ? "bg-orange-400" :
                  pct > 10 ? "bg-mempool-blue" :
                  "bg-mempool-purple";
                return (
                  <tr
                    key={miner.address}
                    className="hover:bg-mempool-bg-light/50 transition-colors cursor-pointer"
                    onClick={() => {
                      if (miner.address) window.location.hash = `#/address/${miner.address}`;
                    }}
                  >
                    <td className="px-4 py-2.5 text-mempool-text-dim font-mono">{idx + 1}</td>
                    <td className="px-4 py-2.5 font-mono text-mempool-blue hover:underline truncate max-w-[200px]">
                      <AddressLabel address={miner.address} showEmoji truncate={{ left: 10, right: 6 }} />
                    </td>
                    <td className="px-4 py-2.5 text-right font-mono text-mempool-text">
                      {miner.blocksMined.toLocaleString()}
                    </td>
                    <td className="px-4 py-2.5 text-right">
                      <div className="flex items-center justify-end gap-2">
                        <div className="w-16 h-1.5 bg-mempool-bg rounded-full overflow-hidden flex-shrink-0">
                          <div className={`h-full rounded-full ${barColor}`} style={{ width: `${pct}%` }} />
                        </div>
                        <span className="text-mempool-text-dim w-10 text-right font-mono">
                          {pct.toFixed(1)}%
                        </span>
                      </div>
                    </td>
                    <td className="px-4 py-2.5 text-right font-mono text-mempool-green">
                      {fmtOmni(miner.totalRewardSAT)} OMNI
                    </td>
                    <td className="px-4 py-2.5 text-right font-mono text-mempool-text">
                      {fmtOmni(miner.currentBalanceSAT)} OMNI
                    </td>
                  </tr>
                );
              })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
