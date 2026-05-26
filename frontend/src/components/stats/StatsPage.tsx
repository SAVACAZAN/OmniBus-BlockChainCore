import { useState, useEffect, useCallback, useRef } from "react";
import { OmniBusRpcClient } from "../../api/rpc-client";
import {
  ResponsiveContainer,
  LineChart,
  Line,
  ReferenceLine,
  BarChart,
  Bar,
  XAxis,
  YAxis,
  Tooltip,
  CartesianGrid,
} from "recharts";

const rpc = new OmniBusRpcClient();
const SAT = 1e9;

interface BlockStat {
  height: number;
  timestamp: number;
  txCount: number;
  rewardSAT: number;
  difficulty: number;
  blockTime: number; // seconds from prev block
  feesEstimate: number; // SAT — rough estimate
}

interface NetworkStats {
  avgBlockTime: number;
  estimatedHashrate: string;
  totalTxLast100: number;
  avgFeeLast100: number;
  latestDifficulty: number;
  blocksAnalyzed: number;
}

function computeStats(blocks: any[]): { stats: NetworkStats; series: BlockStat[] } {
  if (blocks.length < 2) {
    return {
      stats: {
        avgBlockTime: 0,
        estimatedHashrate: "—",
        totalTxLast100: 0,
        avgFeeLast100: 0,
        latestDifficulty: 0,
        blocksAnalyzed: blocks.length,
      },
      series: [],
    };
  }

  const sorted = [...blocks].sort((a, b) => a.height - b.height);

  let totalBlockTime = 0;
  let btCount = 0;
  let totalTx = 0;
  const series: BlockStat[] = [];

  for (let i = 0; i < sorted.length; i++) {
    const b = sorted[i];
    let blockTime = 0;
    if (i > 0) {
      blockTime = (sorted[i].timestamp || 0) - (sorted[i - 1].timestamp || 0);
      if (blockTime > 0 && blockTime < 3600) {
        totalBlockTime += blockTime;
        btCount++;
      }
    }
    totalTx += b.txCount || 0;
    series.push({
      height: b.height,
      timestamp: b.timestamp || 0,
      txCount: b.txCount || 0,
      rewardSAT: b.rewardSAT || 0,
      difficulty: b.difficulty || 0,
      blockTime: i > 0 ? blockTime : 0,
      feesEstimate: 0,
    });
  }

  const avgBlockTime = btCount > 0 ? Math.round(totalBlockTime / btCount) : 0;
  const latestDifficulty = sorted[sorted.length - 1]?.difficulty || 0;

  // Rough hashrate estimate: H/s ≈ difficulty × 2^32 / blockTime
  let hashrate = "—";
  if (avgBlockTime > 0 && latestDifficulty > 0) {
    const hs = (latestDifficulty * Math.pow(2, 32)) / avgBlockTime;
    if (hs >= 1e15) hashrate = `${(hs / 1e15).toFixed(2)} PH/s`;
    else if (hs >= 1e12) hashrate = `${(hs / 1e12).toFixed(2)} TH/s`;
    else if (hs >= 1e9) hashrate = `${(hs / 1e9).toFixed(2)} GH/s`;
    else if (hs >= 1e6) hashrate = `${(hs / 1e6).toFixed(2)} MH/s`;
    else if (hs >= 1e3) hashrate = `${(hs / 1e3).toFixed(2)} KH/s`;
    else hashrate = `${Math.round(hs)} H/s`;
  }

  return {
    stats: {
      avgBlockTime,
      estimatedHashrate: hashrate,
      totalTxLast100: totalTx,
      avgFeeLast100: 0,
      latestDifficulty,
      blocksAnalyzed: sorted.length,
    },
    series: series.slice(-50), // show last 50 in charts
  };
}

const TOOLTIP_STYLE = {
  background: "#1a1b1e",
  border: "1px solid #2d2f36",
  borderRadius: "6px",
  fontSize: "11px",
  color: "#c9d1d9",
};

const AUTO_REFRESH_MS = 30_000;

export function StatsPage() {
  const [series, setSeries] = useState<BlockStat[]>([]);
  const [netStats, setNetStats] = useState<NetworkStats | null>(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");
  const [lastRefresh, setLastRefresh] = useState(0);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setErr("");
    try {
      const tipRaw = await rpc.getBlockCount();
      const tip: number =
        typeof tipRaw === "object" && tipRaw
          ? (tipRaw as any).blockCount ?? (tipRaw as any)
          : tipRaw;
      if (!tip || tip < 1) { setLoading(false); return; }

      // Fetch last 100 blocks — all in parallel (20 concurrent RPCs max)
      const count = Math.min(100, tip);
      const start = tip - 1;
      const end = Math.max(0, start - count);
      const indices: number[] = [];
      for (let i = start; i >= end; i--) indices.push(i);

      const CONCURRENCY = 20;
      const blocks: any[] = [];
      for (let i = 0; i < indices.length; i += CONCURRENCY) {
        const slice = indices.slice(i, i + CONCURRENCY);
        const batch = await Promise.all(
          slice.map((idx) => rpc.getBlock(idx).catch(() => null))
        );
        blocks.push(...batch.filter(Boolean));
      }

      const { stats, series: s } = computeStats(blocks);
      setNetStats(stats);
      setSeries(s);
      setLastRefresh(Date.now());
    } catch (e: any) {
      setErr(e.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
    timerRef.current = setInterval(() => void load(), AUTO_REFRESH_MS);
    return () => { if (timerRef.current) clearInterval(timerRef.current); };
  }, [load]);

  if (loading) {
    return (
      <div className="max-w-7xl mx-auto px-4 py-8 text-mempool-text-dim animate-pulse text-sm">
        Loading statistics (last 100 blocks)…
      </div>
    );
  }

  if (err) {
    return (
      <div className="max-w-7xl mx-auto px-4 py-8">
        <p className="text-red-400">{err}</p>
      </div>
    );
  }

  const hasDifficulty = series.some((s) => s.difficulty > 0);
  const hasBlockTime = series.some((s) => s.blockTime > 0);

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-4">
      <div className="flex items-center justify-between flex-wrap gap-2">
        <h2 className="text-lg font-bold text-mempool-text">
          Network Statistics{" "}
          <span className="text-mempool-text-dim font-normal text-sm">
            (last {netStats?.blocksAnalyzed ?? 0} blocks)
          </span>
        </h2>
        <div className="flex items-center gap-3">
          {lastRefresh > 0 && (
            <span className="text-[10px] text-mempool-text-dim font-mono">
              updated {new Date(lastRefresh).toLocaleTimeString()}
            </span>
          )}
          <button
            onClick={() => void load()}
            disabled={loading}
            className="flex items-center gap-1.5 px-3 py-1.5 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-40 transition-colors"
          >
            <svg className={`w-3 h-3 ${loading ? "animate-spin" : ""}`} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M21 12a9 9 0 0 0-9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" />
              <path d="M3 3v5h5" />
              <path d="M3 12a9 9 0 0 0 9 9 9.75 9.75 0 0 0 6.74-2.74L21 16" />
              <path d="M16 21h5v-5" />
            </svg>
            Refresh
          </button>
        </div>
      </div>

      {/* Summary cards */}
      {netStats && (
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <StatCard
            label="Avg Block Time"
            value={netStats.avgBlockTime > 0 ? `${netStats.avgBlockTime}s` : "—"}
            sub={netStats.avgBlockTime > 0 ? `target: 10s` : undefined}
            color={
              netStats.avgBlockTime <= 0
                ? "dim"
                : netStats.avgBlockTime < 8
                ? "orange"
                : netStats.avgBlockTime > 15
                ? "orange"
                : "green"
            }
          />
          <StatCard
            label="Est. Hashrate"
            value={netStats.estimatedHashrate}
            color="blue"
          />
          <StatCard
            label="TXs (last 100 blocks)"
            value={netStats.totalTxLast100.toLocaleString()}
            color="dim"
          />
          <StatCard
            label="Latest Difficulty"
            value={
              netStats.latestDifficulty > 0
                ? netStats.latestDifficulty.toLocaleString()
                : "—"
            }
            color="dim"
          />
        </div>
      )}

      {/* Block time chart */}
      {hasBlockTime && (
        <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
          <h3 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim mb-3">
            Block Time (seconds)
          </h3>
          <ResponsiveContainer width="100%" height={140}>
            <LineChart data={series} margin={{ top: 4, right: 8, bottom: 0, left: 0 }}>
              <CartesianGrid strokeDasharray="3 3" stroke="#2d2f36" />
              <XAxis
                dataKey="height"
                tick={{ fontSize: 10, fill: "#6b7280" }}
                tickFormatter={(v) => `#${v}`}
                interval="preserveStartEnd"
              />
              <YAxis tick={{ fontSize: 10, fill: "#6b7280" }} width={32} />
              <Tooltip
                contentStyle={TOOLTIP_STYLE}
                labelFormatter={(v) => `Block #${v}`}
                formatter={(v: any) => [`${v}s`, "Block Time"]}
              />
              {/* Target line at 10s */}
              <ReferenceLine y={10} stroke="#f97316" strokeDasharray="4 4" strokeWidth={1}
                label={{ value: "10s target", position: "right", fill: "#f97316", fontSize: 9 }} />
              <Line
                type="monotone"
                dataKey="blockTime"
                stroke="#3b82f6"
                strokeWidth={1.5}
                dot={false}
                activeDot={{ r: 3 }}
              />
            </LineChart>
          </ResponsiveContainer>
        </div>
      )}

      {/* Difficulty chart */}
      {hasDifficulty && (
        <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
          <h3 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim mb-3">
            Difficulty
          </h3>
          <ResponsiveContainer width="100%" height={120}>
            <LineChart data={series} margin={{ top: 4, right: 8, bottom: 0, left: 0 }}>
              <CartesianGrid strokeDasharray="3 3" stroke="#2d2f36" />
              <XAxis
                dataKey="height"
                tick={{ fontSize: 10, fill: "#6b7280" }}
                tickFormatter={(v) => `#${v}`}
                interval="preserveStartEnd"
              />
              <YAxis tick={{ fontSize: 10, fill: "#6b7280" }} width={42} tickFormatter={(v) => v.toLocaleString()} />
              <Tooltip
                contentStyle={TOOLTIP_STYLE}
                labelFormatter={(v) => `Block #${v}`}
                formatter={(v: any) => [Number(v).toLocaleString(), "Difficulty"]}
              />
              <Line
                type="monotone"
                dataKey="difficulty"
                stroke="#f59e0b"
                strokeWidth={1.5}
                dot={false}
                activeDot={{ r: 3 }}
              />
            </LineChart>
          </ResponsiveContainer>
        </div>
      )}

      {/* TX count per block */}
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
        <h3 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim mb-3">
          Transactions per Block
        </h3>
        <ResponsiveContainer width="100%" height={120}>
          <BarChart data={series} margin={{ top: 4, right: 8, bottom: 0, left: 0 }}>
            <CartesianGrid strokeDasharray="3 3" stroke="#2d2f36" />
            <XAxis
              dataKey="height"
              tick={{ fontSize: 10, fill: "#6b7280" }}
              tickFormatter={(v) => `#${v}`}
              interval="preserveStartEnd"
            />
            <YAxis tick={{ fontSize: 10, fill: "#6b7280" }} width={28} />
            <Tooltip
              contentStyle={TOOLTIP_STYLE}
              labelFormatter={(v) => `Block #${v}`}
              formatter={(v: any) => [v, "TXs"]}
            />
            <Bar dataKey="txCount" fill="#10b981" radius={[2, 2, 0, 0]} maxBarSize={16} />
          </BarChart>
        </ResponsiveContainer>
      </div>

      {/* Block reward chart */}
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
        <h3 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim mb-3">
          Block Reward (OMNI)
        </h3>
        <ResponsiveContainer width="100%" height={100}>
          <LineChart data={series} margin={{ top: 4, right: 8, bottom: 0, left: 0 }}>
            <CartesianGrid strokeDasharray="3 3" stroke="#2d2f36" />
            <XAxis
              dataKey="height"
              tick={{ fontSize: 10, fill: "#6b7280" }}
              tickFormatter={(v) => `#${v}`}
              interval="preserveStartEnd"
            />
            <YAxis
              tick={{ fontSize: 10, fill: "#6b7280" }}
              width={42}
              tickFormatter={(v) => (v / SAT).toFixed(0)}
            />
            <Tooltip
              contentStyle={TOOLTIP_STYLE}
              labelFormatter={(v) => `Block #${v}`}
              formatter={(v: any) => [`${(v / SAT).toFixed(8)} OMNI`, "Reward"]}
            />
            <Line
              type="monotone"
              dataKey="rewardSAT"
              stroke="#f97316"
              strokeWidth={1.5}
              dot={false}
              activeDot={{ r: 3 }}
            />
          </LineChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}

function StatCard({
  label,
  value,
  sub,
  color,
}: {
  label: string;
  value: string;
  sub?: string;
  color: "blue" | "green" | "orange" | "dim";
}) {
  const cls = {
    blue: "text-mempool-blue",
    green: "text-green-400",
    orange: "text-orange-400",
    dim: "text-mempool-text",
  }[color];
  return (
    <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-3">
      <div className={`text-base font-mono font-bold ${cls}`}>{value}</div>
      {sub && <div className="text-[10px] text-mempool-text-dim mt-0.5">{sub}</div>}
      <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mt-1">{label}</div>
    </div>
  );
}
