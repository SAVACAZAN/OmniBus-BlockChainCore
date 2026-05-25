import { useState, useEffect } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import { OmniBusRpcClient } from "../../api/rpc-client";
import type { BlockData } from "../../types";
import {
  ResponsiveContainer,
  LineChart,
  Line,
  XAxis,
  YAxis,
  Tooltip,
} from "recharts";

const rpc = new OmniBusRpcClient();

function midTrunc(s: string | undefined | null, head = 8, tail = 6): string {
  if (!s) return "—";
  if (s.length <= head + tail + 2) return s;
  return `${s.slice(0, head)}**${s.slice(-tail)}`;
}

type BlockWithDiff = BlockData & { difficulty?: number };

export function BlocksPage() {
  const { state } = useBlockchain();
  const [blocks, setBlocks] = useState<BlockWithDiff[]>([]);
  const [loading, setLoading] = useState(true);
  const [page, setPage] = useState(0);
  const PAGE_SIZE = 20;

  useEffect(() => {
    loadBlocks();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [page]);

  useEffect(() => {
    if (page !== 0) return;
    const id = setInterval(() => loadBlocks(), 5000);
    return () => clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [page]);

  const loadBlocks = async () => {
    setLoading(true);
    try {
      let height = state.blockCount;
      try {
        const live: any = await rpc.getBlockCount();
        const liveCount = typeof live === "object" && live ? live.blockCount : live;
        if (typeof liveCount === "number" && liveCount > 0) height = liveCount;
      } catch { /* fall back */ }

      const start = Math.max(0, height - 1 - page * PAGE_SIZE);
      const end = Math.max(0, start - PAGE_SIZE);
      const indices: number[] = [];
      for (let i = start; i > end && i >= 0; i--) indices.push(i);

      const results: (BlockWithDiff | null)[] = [];
      const BATCH = 4;
      for (let i = 0; i < indices.length; i += BATCH) {
        const slice = indices.slice(i, i + BATCH);
        const batch = await Promise.all(
          slice.map((idx) => rpc.getBlock(idx).catch(() => null))
        );
        results.push(...batch);
      }
      setBlocks(results.filter(Boolean) as BlockWithDiff[]);
    } catch {}
    setLoading(false);
  };

  const maxPage = Math.max(0, Math.floor((state.blockCount - 1) / PAGE_SIZE));

  // Chart data: last 20 blocks (oldest→newest for correct left-to-right render)
  const chartData = [...blocks]
    .reverse()
    .map((b) => ({
      h: b.height,
      d: b.difficulty ?? b.nonce ?? 0,
    }));

  const hasDifficulty = chartData.some((c) => c.d > 0);

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-4">
      {/* Title + pagination */}
      <div className="flex items-center justify-between flex-wrap gap-2">
        <h2 className="text-lg font-bold text-mempool-text">
          Blocks{" "}
          <span className="text-mempool-text-dim font-normal text-sm">
            ({state.blockCount.toLocaleString()} total)
          </span>
        </h2>
        <div className="flex items-center gap-2">
          <button
            onClick={() => setPage(Math.min(page + 1, maxPage))}
            disabled={page >= maxPage}
            className="px-3 py-1 text-xs bg-mempool-bg-elev border border-mempool-border rounded hover:bg-mempool-bg-light disabled:opacity-30 text-mempool-text-dim transition-colors"
          >
            Older
          </button>
          <span className="text-xs text-mempool-text-dim">Page {page + 1}</span>
          <button
            onClick={() => setPage(Math.max(0, page - 1))}
            disabled={page <= 0}
            className="px-3 py-1 text-xs bg-mempool-bg-elev border border-mempool-border rounded hover:bg-mempool-bg-light disabled:opacity-30 text-mempool-text-dim transition-colors"
          >
            Newer
          </button>
        </div>
      </div>

      {/* Difficulty / nonce sparkline chart */}
      {hasDifficulty && (
        <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
          <div className="flex items-center justify-between mb-2">
            <span className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim">
              Difficulty (last {chartData.length} blocks)
            </span>
          </div>
          <ResponsiveContainer width="100%" height={80}>
            <LineChart data={chartData} margin={{ top: 4, right: 8, left: 0, bottom: 0 }}>
              <XAxis dataKey="h" hide />
              <YAxis hide domain={["auto", "auto"]} />
              <Tooltip
                contentStyle={{
                  background: "var(--color-mempool-bg-elev, #1a1b1e)",
                  border: "1px solid var(--color-mempool-border, #2d2f36)",
                  borderRadius: "6px",
                  fontSize: "11px",
                  color: "#c9d1d9",
                }}
                labelFormatter={(v) => `Block #${v}`}
                formatter={(v: any) => [v.toLocaleString(), "Difficulty"]}
              />
              <Line
                type="monotone"
                dataKey="d"
                stroke="#3b82f6"
                strokeWidth={1.5}
                dot={false}
                activeDot={{ r: 3, fill: "#3b82f6" }}
              />
            </LineChart>
          </ResponsiveContainer>
        </div>
      )}

      {/* Blocks table */}
      <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border overflow-x-auto">
        <table className="w-full text-xs min-w-[480px]">
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
              <tr>
                <td colSpan={6} className="px-4 py-8 text-center text-mempool-text-dim">
                  Loading…
                </td>
              </tr>
            ) : blocks.length === 0 ? (
              <tr>
                <td colSpan={6} className="px-4 py-8 text-center text-mempool-text-dim">
                  No blocks
                </td>
              </tr>
            ) : (
              blocks.map((b) => (
                <tr
                  key={`block-${b.height}`}
                  className="hover:bg-mempool-bg-light/50 transition-colors cursor-pointer"
                  onClick={() => { window.location.hash = `#/block/${b.height}`; }}
                  title={`Open block #${b.height}`}
                >
                  <td className="px-4 py-2.5 font-mono text-mempool-blue font-bold whitespace-nowrap">
                    #{b.height.toLocaleString()}
                  </td>
                  <td className="px-4 py-2.5 font-mono text-mempool-text whitespace-nowrap" title={b.hash}>
                    {midTrunc(b.hash, 8, 6)}
                  </td>
                  <td
                    className="px-4 py-2.5 font-mono text-mempool-text-dim whitespace-nowrap hover:text-mempool-blue transition-colors"
                    title={b.miner}
                    onClick={(e) => {
                      if (b.miner) {
                        e.stopPropagation();
                        window.location.hash = `#/address/${b.miner}`;
                      }
                    }}
                  >
                    {midTrunc(b.miner, 8, 6)}
                  </td>
                  <td className="px-4 py-2.5 text-right font-mono text-mempool-text whitespace-nowrap">
                    {(b.txCount || 0) + 1}
                  </td>
                  <td className="px-4 py-2.5 text-right font-mono text-mempool-green whitespace-nowrap">
                    {((b.rewardSAT || 0) / 1e9).toFixed(8)}
                  </td>
                  <td className="px-4 py-2.5 text-right text-mempool-text-dim whitespace-nowrap">
                    {b.timestamp
                      ? new Date(b.timestamp * 1000).toLocaleTimeString()
                      : "—"}
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
