import { useBlockchain } from "../../stores/useBlockchainStore";

export function MinerTable() {
  const { state } = useBlockchain();

  if (state.miners.length === 0) {
    return (
      <div className="bg-mempool-card rounded-lg border border-mempool-border p-6 text-center text-sm text-mempool-text-dim">
        No miners registered yet.
      </div>
    );
  }

  const totalBlocks = state.miners.reduce((s, m) => s + (m.blocksMined || 0), 0);

  return (
    <div className="bg-mempool-card rounded-lg border border-mempool-border overflow-hidden">
      <div className="px-4 py-3 border-b border-mempool-border">
        <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
          Miners ({state.miners.length})
        </h3>
      </div>
      <div className="overflow-x-auto">
        <table className="w-full text-xs">
          <thead>
            <tr className="text-mempool-text-dim border-b border-mempool-border/50">
              <th className="px-4 py-2 text-left font-medium">Address</th>
              <th className="px-4 py-2 text-right font-medium">Blocks</th>
              <th className="px-4 py-2 text-right font-medium">Share</th>
              <th className="px-4 py-2 text-right font-medium">Reward (SAT)</th>
              <th className="px-4 py-2 text-right font-medium">Balance (SAT)</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-mempool-border/30">
            {state.miners.map((miner) => {
              const pct = totalBlocks > 0
                ? ((miner.blocksMined / totalBlocks) * 100).toFixed(1)
                : "0.0";
              return (
                <tr key={miner.miner} className="hover:bg-mempool-bg-light/50 transition-colors">
                  <td className="px-4 py-2 font-mono text-mempool-blue truncate max-w-[200px]">
                    {miner.miner}
                  </td>
                  <td className="px-4 py-2 text-right font-mono text-mempool-text">
                    {miner.blocksMined}
                  </td>
                  <td className="px-4 py-2 text-right">
                    <div className="flex items-center justify-end gap-2">
                      <div className="w-16 h-1.5 bg-mempool-bg rounded-full overflow-hidden">
                        <div
                          className="h-full bg-mempool-purple rounded-full"
                          style={{ width: `${pct}%` }}
                        />
                      </div>
                      <span className="text-mempool-text-dim w-10 text-right">
                        {pct}%
                      </span>
                    </div>
                  </td>
                  <td className="px-4 py-2 text-right font-mono text-mempool-green">
                    {(miner.totalRewardSAT || 0).toLocaleString()}
                  </td>
                  <td className="px-4 py-2 text-right font-mono text-mempool-text">
                    {(miner.currentBalanceSAT || 0).toLocaleString()}
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
