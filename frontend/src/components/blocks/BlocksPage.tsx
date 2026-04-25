import { useState, useEffect } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import { BlockDetail } from "./BlockDetail";
import OmniBusRpcClient from "../../api/rpc-client";
import type { BlockData } from "../../types";

const rpc = new OmniBusRpcClient();

// Trunchiaza hash/adresa la mijloc cu '**' (gen 0000abcd**1234ef).
// Pastreaza primele `head` si ultimele `tail` caractere.
function midTrunc(s: string | undefined | null, head = 8, tail = 6): string {
  if (!s) return "—";
  if (s.length <= head + tail + 2) return s;
  return `${s.slice(0, head)}**${s.slice(-tail)}`;
}

export function BlocksPage() {
  const { state } = useBlockchain();
  const [blocks, setBlocks] = useState<BlockData[]>([]);
  const [selectedBlock, setSelectedBlock] = useState<BlockData | null>(null);
  const [loading, setLoading] = useState(true);
  const [page, setPage] = useState(0);
  const PAGE_SIZE = 20;

  // Reload only when paging — not on every blockCount tick (would cause
  // 1 reload per mined block = annoying flicker on Testnet/Regtest where
  // blocks come at 1/s or faster).
  useEffect(() => {
    loadBlocks();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [page]);

  // For new blocks: only reload page 0 (the "latest" view), and only every
  // 5 seconds even if 5 blocks were mined. Older pages don't change.
  useEffect(() => {
    if (page !== 0) return;
    const id = setInterval(() => loadBlocks(), 5000);
    return () => clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [page]);

  const loadBlocks = async () => {
    setLoading(true);
    try {
      const height = state.blockCount;
      const start = Math.max(0, height - 1 - page * PAGE_SIZE);
      const end = Math.max(0, start - PAGE_SIZE);
      // Batch by 4 to avoid overloading the RPC backend (MAX_CONCURRENT=4
      // in rpc_server.zig). Sequential batches >> 20 parallel requests
      // that get refused with ECONNRESET / 502 Bad Gateway through Nginx.
      const indices: number[] = [];
      for (let i = start; i > end && i >= 0; i--) indices.push(i);
      const results: (BlockData | null)[] = [];
      const BATCH = 4;
      for (let i = 0; i < indices.length; i += BATCH) {
        const slice = indices.slice(i, i + BATCH);
        const batch = await Promise.all(
          slice.map((idx) => rpc.getBlock(idx).catch(() => null))
        );
        results.push(...batch);
      }
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
                <tr key={`block-${b.height}`} className="hover:bg-mempool-bg-light/50 transition-colors cursor-pointer" onClick={() => setSelectedBlock(b)}>
                  <td className="px-4 py-2.5 font-mono text-mempool-blue font-bold whitespace-nowrap">
                    #{b.height}
                  </td>
                  <td className="px-4 py-2.5 font-mono text-mempool-text whitespace-nowrap" title={b.hash}>
                    {midTrunc(b.hash, 8, 6)}
                  </td>
                  <td className="px-4 py-2.5 font-mono text-mempool-text-dim whitespace-nowrap" title={b.miner}>
                    {midTrunc(b.miner, 8, 6)}
                  </td>
                  <td className="px-4 py-2.5 text-right font-mono text-mempool-text whitespace-nowrap">
                    {b.txCount + 1}
                  </td>
                  <td className="px-4 py-2.5 text-right font-mono text-mempool-green whitespace-nowrap">
                    {((b.rewardSAT || 0) / 1e9).toFixed(4)}
                  </td>
                  <td className="px-4 py-2.5 text-right text-mempool-text-dim whitespace-nowrap">
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
