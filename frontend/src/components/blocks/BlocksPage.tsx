import { useState, useEffect } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import { BlockDetail } from "./BlockDetail";
import OmniBusRpcClient from "../../api/rpc-client";
import type { BlockData } from "../../types";

const rpc = new OmniBusRpcClient("/api");

export function BlocksPage() {
  const { state } = useBlockchain();
  const [blocks, setBlocks] = useState<BlockData[]>([]);
  const [selectedBlock, setSelectedBlock] = useState<BlockData | null>(null);
  const [loading, setLoading] = useState(true);
  const [page, setPage] = useState(0);
  const PAGE_SIZE = 20;

  useEffect(() => {
    loadBlocks();
  }, [page, state.blockCount]);

  const loadBlocks = async () => {
    setLoading(true);
    try {
      const height = state.blockCount;
      const start = Math.max(0, height - 1 - page * PAGE_SIZE);
      const end = Math.max(0, start - PAGE_SIZE);
      const promises = [];
      for (let i = start; i > end && i >= 0; i--) {
        promises.push(rpc.getBlock(i).catch(() => null));
      }
      const results = await Promise.all(promises);
      setBlocks(results.filter(Boolean) as BlockData[]);
    } catch {}
    setLoading(false);
  };

  const maxPage = Math.max(0, Math.floor((state.blockCount - 1) / PAGE_SIZE));

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-4">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-bold text-mempool-text">
          Blocks <span className="text-mempool-text-dim font-normal text-sm">({state.blockCount} total)</span>
        </h2>
        <div className="flex items-center gap-2">
          <button
            onClick={() => setPage(Math.min(page + 1, maxPage))}
            disabled={page >= maxPage}
            className="px-3 py-1 text-xs bg-mempool-card border border-mempool-border rounded hover:bg-mempool-bg-light disabled:opacity-30 text-mempool-text-dim"
          >
            Older
          </button>
          <span className="text-xs text-mempool-text-dim">Page {page + 1}</span>
          <button
            onClick={() => setPage(Math.max(0, page - 1))}
            disabled={page <= 0}
            className="px-3 py-1 text-xs bg-mempool-card border border-mempool-border rounded hover:bg-mempool-bg-light disabled:opacity-30 text-mempool-text-dim"
          >
            Newer
          </button>
        </div>
      </div>

      <div className="bg-mempool-card rounded-xl border border-mempool-border overflow-hidden">
        <table className="w-full text-xs">
          <thead>
            <tr className="text-mempool-text-dim border-b border-mempool-border text-left">
              <th className="px-4 py-3 font-medium">Height</th>
              <th className="px-4 py-3 font-medium">Hash</th>
              <th className="px-4 py-3 font-medium">Miner</th>
              <th className="px-4 py-3 font-medium text-right">TXs</th>
              <th className="px-4 py-3 font-medium text-right">Reward</th>
              <th className="px-4 py-3 font-medium text-right">Time</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-mempool-border/30">
            {loading ? (
              <tr><td colSpan={6} className="px-4 py-8 text-center text-mempool-text-dim">Loading...</td></tr>
            ) : blocks.length === 0 ? (
              <tr><td colSpan={6} className="px-4 py-8 text-center text-mempool-text-dim">No blocks</td></tr>
            ) : (
              blocks.map((b) => (
                <tr key={b.height} className="hover:bg-mempool-bg-light/50 transition-colors cursor-pointer" onClick={() => setSelectedBlock(b)}>
                  <td className="px-4 py-2.5 font-mono text-mempool-blue font-bold">
                    #{b.height}
                  </td>
                  <td className="px-4 py-2.5 font-mono text-mempool-text truncate max-w-[180px]">
                    {b.hash?.slice(0, 20)}...
                  </td>
                  <td className="px-4 py-2.5 font-mono text-mempool-text-dim truncate max-w-[150px]">
                    {b.miner?.slice(0, 18)}...
                  </td>
                  <td className="px-4 py-2.5 text-right font-mono text-mempool-text">
                    {b.txCount + 1}
                  </td>
                  <td className="px-4 py-2.5 text-right font-mono text-mempool-green">
                    {((b.rewardSAT || 0) / 1e9).toFixed(4)}
                  </td>
                  <td className="px-4 py-2.5 text-right text-mempool-text-dim">
                    {b.timestamp ? new Date(b.timestamp * 1000).toLocaleTimeString() : "—"}
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      {/* Block Detail Modal */}
      {selectedBlock && (
        <BlockDetail block={selectedBlock} onClose={() => setSelectedBlock(null)} />
      )}
    </div>
  );
}
