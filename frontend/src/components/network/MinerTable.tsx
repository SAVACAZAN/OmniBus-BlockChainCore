import { useEffect, useState } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import OmniBusRpcClient from "../../api/rpc-client";
import { AddressLabel } from "../common/AddressLabel";
import { SAT_PER_OMNI } from "../../utils/fmt";

const rpc = new OmniBusRpcClient();

interface MinerRow {
  address: string;
  blocksMined: number;
  totalRewardSAT: number;
  currentBalanceSAT: number;
  lastBlockHeight?: number;
}

function fmtOmni(sat: number): string {
  const omni = sat / SAT_PER_OMNI;
  return omni >= 1
    ? omni.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 4 })
    : omni.toFixed(6);
}

export function MinerTable() {
  const { state } = useBlockchain();
  const [rpcMiners, setRpcMiners] = useState<MinerRow[]>([]);
  const [addrSearch, setAddrSearch] = useState("");

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
    // state.blockCount is WS-driven — re-runs on every new block automatically.
    return () => { cancelled = true; };
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
      <div className="px-4 py-3 border-b border-mempool-border flex flex-wrap items-center gap-3">
        <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider shrink-0">
          Miners ({miners.length})
        </h3>
        <input
          type="text"
          placeholder="Filter by address…"
          value={addrSearch}
          onChange={(e) => setAddrSearch(e.target.value)}
          className="flex-1 min-w-[140px] max-w-xs bg-mempool-bg border border-mempool-border rounded px-3 py-1 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
        />
        <div className="flex items-center gap-3 ml-auto">
          {totalBlocks > 0 && (
            <span className="text-[10px] text-mempool-text-dim">
              {totalBlocks.toLocaleString()} blocks total
            </span>
          )}
          <button
            onClick={() => {
              const rows = [
                ["rank","address","blocks_mined","share_pct","total_reward_omni","balance_omni","last_block"].join(","),
                ...[...miners].sort((a, b) => b.blocksMined - a.blocksMined).map((m, idx) => {
                  const pct = totalBlocks > 0 ? (m.blocksMined / totalBlocks * 100).toFixed(2) : "0";
                  return [
                    idx + 1,
                    `"${m.address}"`,
                    m.blocksMined,
                    pct,
                    fmtOmni(m.totalRewardSAT),
                    fmtOmni(m.currentBalanceSAT),
                    m.lastBlockHeight ?? "",
                  ].join(",");
                }),
              ].join("\n");
              const blob = new Blob([rows], { type: "text/csv" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url; a.download = "omnibus-miners.csv";
              a.click(); URL.revokeObjectURL(url);
            }}
            className="px-2 py-1 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue"
          >
            ⬇ CSV
          </button>
        </div>
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
              .filter((m) => !addrSearch.trim() || m.address.toLowerCase().includes(addrSearch.trim().toLowerCase()))
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
            {addrSearch.trim() && miners.filter((m) => m.address.toLowerCase().includes(addrSearch.trim().toLowerCase())).length === 0 && (
              <tr>
                <td colSpan={6} className="px-4 py-4 text-center text-xs text-mempool-text-dim">
                  No miners match "{addrSearch}"
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
