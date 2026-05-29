import { useState, useEffect, useCallback, useRef, useMemo } from "react";
import { rpc } from "../../api/clients/rpc-client";
import { SAT_PER_OMNI } from "../../utils/fmt";
import { subscribe as wsSubscribe } from "../../api/clients/ws-bus";
import type { WsNewBlockEvent } from "../../types/index";
import {
  ResponsiveContainer,
  LineChart,
  Line,
  ReferenceLine,
  BarChart,
  Bar,
  PieChart,
  Pie,
  Cell,
  XAxis,
  YAxis,
  Tooltip,
  CartesianGrid,
} from "recharts";


function HalvingCountdown({ height, halvingInterval, currentBlockReward, avgBlockTime }: {
  height: number; halvingInterval: number; currentBlockReward: number; avgBlockTime: number;
}) {
  const effectiveBT = avgBlockTime > 0 ? avgBlockTime : 10;
  const era = Math.floor(height / halvingInterval);
  const nextHalvingBlock = (era + 1) * halvingInterval;
  const blocksLeft = nextHalvingBlock - height;
  const secondsLeft = blocksLeft * effectiveBT;
  const daysLeft = secondsLeft / 86400;
  const currentReward = (currentBlockReward / SAT_PER_OMNI).toFixed(8);
  const nextReward = (currentBlockReward / SAT_PER_OMNI / 2).toFixed(8);
  const pct = ((height % halvingInterval) / halvingInterval) * 100;
  const halvingDate = new Date(Date.now() + secondsLeft * 1000);
  return (
    <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
      <h3 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim mb-3">
        Halving Countdown — Era {era + 1}
      </h3>
      <div className="flex flex-col sm:flex-row items-start sm:items-center gap-4">
        <div className="flex-1 w-full">
          <div className="flex justify-between text-xs text-mempool-text-dim mb-1">
            <span>Block #{(era * halvingInterval).toLocaleString()}</span>
            <span>Next halving: #{nextHalvingBlock.toLocaleString()}</span>
          </div>
          <div className="w-full h-3 bg-mempool-bg rounded-full overflow-hidden">
            <div
              className="h-full rounded-full bg-gradient-to-r from-orange-500 to-orange-300 transition-all"
              style={{ width: `${pct.toFixed(2)}%` }}
            />
          </div>
          <div className="flex justify-between text-[10px] text-mempool-text-dim mt-1">
            <span>{pct.toFixed(1)}% through era</span>
            <span>{blocksLeft.toLocaleString()} blocks remaining</span>
          </div>
        </div>
        <div className="flex flex-col gap-1 text-xs text-right sm:min-w-[160px]">
          <div className="text-2xl font-mono font-bold text-orange-400">
            {daysLeft >= 1
              ? `~${daysLeft.toFixed(0)}d`
              : daysLeft >= 1/24
              ? `~${Math.ceil(daysLeft * 24)}h`
              : `~${Math.ceil(secondsLeft / 60)}m`}
          </div>
          <div className="text-mempool-text-dim">
            {halvingDate.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" })}
          </div>
          <div className="flex items-center gap-2 justify-end mt-1">
            <span className="text-mempool-text-dim">
              {currentReward} → <span className="text-orange-400">{nextReward} OMNI</span>
            </span>
          </div>
        </div>
      </div>
    </div>
  );
}

interface BlockStat {
  height: number;
  timestamp: number;
  txCount: number;
  rewardSAT: number;
  difficulty: number;
  blockTime: number; // seconds from prev block
  feesEstimate: number; // SAT_PER_OMNI — rough estimate
}

interface NetworkStats {
  avgBlockTime: number;
  estimatedHashrate: string;
  totalTxLast100: number;
  avgFeeLast100: number;
  latestDifficulty: number;
  blocksAnalyzed: number;
}

interface ChainMetrics {
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
  halvingInterval?: number;
  latestBlockTxCount?: number;
  latestBlockFees?: number;
  latestBlockTimestamp?: number;
}

interface RichEntry {
  address: string;
  balance: number;
}

interface SupplyDistSlice {
  name: string;
  value: number;
  color: string;
}

interface SchemeStatEntry {
  scheme: string;
  count: number;
  pct: number; // × 100, so 9950 = 99.50%
}

interface SchemeStats {
  totalTxs: number;
  blocks: number;
  schemes: SchemeStatEntry[];
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
  let totalFees = 0;
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
    totalFees += b.totalFees || 0;
    series.push({
      height: b.height,
      timestamp: b.timestamp || 0,
      txCount: b.txCount || 0,
      rewardSAT: b.rewardSAT || 0,
      difficulty: b.difficulty || 0,
      blockTime: i > 0 ? blockTime : 0,
      feesEstimate: b.totalFees || 0,
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

  const avgFeeLast100 = totalTx > 0 ? Math.round(totalFees / totalTx) : 0;

  return {
    stats: {
      avgBlockTime,
      estimatedHashrate: hashrate,
      totalTxLast100: totalTx,
      avgFeeLast100,
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
  const [chainMetrics, setChainMetrics] = useState<ChainMetrics | null>(null);
  const [supplyDist, setSupplyDist] = useState<SupplyDistSlice[] | null>(null);
  const [schemeStats, setSchemeStats] = useState<SchemeStats | null>(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");
  const [lastRefresh, setLastRefresh] = useState(0);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setErr("");
    try {
      const [tipRaw, metricsRaw, richRaw, schemeRaw] = await Promise.all([
        rpc.getBlockCount(),
        rpc.getChainMetrics().catch(() => null) as Promise<ChainMetrics | null>,
        rpc.getRichList(100).catch(() => null) as Promise<{ entries?: RichEntry[]; totalSupply?: number; total?: number } | null>,
        rpc.getSchemeStats(100).catch(() => null) as Promise<SchemeStats | null>,
      ]);
      if (schemeRaw?.schemes && schemeRaw.schemes.length > 0) setSchemeStats(schemeRaw);
      const tipObj = tipRaw as unknown as { blockCount?: number } | number;
      const tip: number = typeof tipObj === "number" ? tipObj : (tipObj?.blockCount ?? 0);
      if (metricsRaw) setChainMetrics(metricsRaw);

      // Build supply distribution from richlist
      if (richRaw?.entries && richRaw.entries.length > 0) {
        const entries = richRaw.entries;
        const total = metricsRaw?.totalSupply ?? entries.reduce((s, e) => s + e.balance, 0);
        if (total > 0) {
          const top1 = entries.slice(0, 1).reduce((s, e) => s + e.balance, 0);
          const top10 = entries.slice(0, 10).reduce((s, e) => s + e.balance, 0);
          const top50 = entries.slice(0, 50).reduce((s, e) => s + e.balance, 0);
          const top100 = entries.slice(0, 100).reduce((s, e) => s + e.balance, 0);
          setSupplyDist([
            { name: "Top 1",    value: Math.round((top1 / total) * 10000) / 100,               color: "#ef4444" },
            { name: "Top 2-10", value: Math.round(((top10 - top1) / total) * 10000) / 100,     color: "#f97316" },
            { name: "Top 11-50",value: Math.round(((top50 - top10) / total) * 10000) / 100,    color: "#eab308" },
            { name: "51-100",   value: Math.round(((top100 - top50) / total) * 10000) / 100,   color: "#22c55e" },
            { name: "Others",   value: Math.round(((total - top100) / total) * 10000) / 100,   color: "#3b82f6" },
          ]);
        }
      }

      if (!tip || tip < 1) { setLoading(false); return; }

      // Fetch last 100 blocks — single batch call, fallback to parallel individual calls
      const count = Math.min(100, tip);
      const from = Math.max(0, tip - count);
      let blocks: import("../../types").BlockData[] = [];
      try {
        blocks = await rpc.getBlocks(from, count);
      } catch {
        const start = tip - 1;
        const end = Math.max(0, start - count);
        const indices: number[] = [];
        for (let i = start; i >= end; i--) indices.push(i);
        const CONCURRENCY = 20;
        for (let i = 0; i < indices.length; i += CONCURRENCY) {
          const slice = indices.slice(i, i + CONCURRENCY);
          const batch = await Promise.all(
            slice.map((idx) => rpc.getBlock(idx).catch(() => null))
          );
          blocks.push(...batch.filter(Boolean));
        }
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
    // Refresh immediately on new block; fall back to 30s poll.
    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", () => { void load(); });
    timerRef.current = setInterval(() => void load(), AUTO_REFRESH_MS);
    return () => { if (timerRef.current) clearInterval(timerRef.current); unsub(); };
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

  const hasDifficulty = useMemo(() => series.some((s) => s.difficulty > 0), [series]);
  const hasBlockTime = useMemo(() => series.some((s) => s.blockTime > 0), [series]);
  const hasFeesEstimate = useMemo(() => series.some((s) => s.feesEstimate > 0), [series]);

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
          {series.length > 0 && (
            <button
              onClick={() => {
                const rows = [
                  ["height", "timestamp", "tx_count", "reward_omni", "difficulty", "block_time_s", "fees_est_omni"].join(","),
                  ...series.map((b) => [
                    b.height,
                    b.timestamp,
                    b.txCount,
                    (b.rewardSAT / SAT_PER_OMNI).toFixed(8),
                    b.difficulty,
                    b.blockTime,
                    (b.feesEstimate / SAT_PER_OMNI).toFixed(8),
                  ].join(",")),
                ].join("\n");
                const blob = new Blob([rows], { type: "text/csv" });
                const url = URL.createObjectURL(blob);
                const a = document.createElement("a");
                a.href = url; a.download = "omnibus-block-stats.csv";
                a.click(); URL.revokeObjectURL(url);
              }}
              className="flex items-center gap-1.5 px-3 py-1.5 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue font-mono"
            >
              ⬇ CSV
            </button>
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
          {netStats.avgFeeLast100 > 0 && (
            <StatCard
              label="Avg Fee / TX"
              value={`${(netStats.avgFeeLast100 / SAT_PER_OMNI).toFixed(8)} OMNI`}
              sub={`${netStats.avgFeeLast100.toLocaleString()} sat`}
              color="green"
            />
          )}
        </div>
      )}

      {/* Chain Overview */}
      {chainMetrics && (
        <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
          <h3 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim mb-3">
            Chain Overview
          </h3>
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
            <StatCard
              label="Total Supply"
              value={`${((chainMetrics.totalSupply ?? 0) / SAT_PER_OMNI).toLocaleString(undefined, { maximumFractionDigits: 2 })} OMNI`}
              sub={`of 21,000,000 max`}
              color="orange"
            />
            <StatCard
              label="Active Addresses"
              value={(chainMetrics.addressesWithBalance ?? 0).toLocaleString()}
              color="blue"
            />
            <StatCard
              label="Validators"
              value={`${chainMetrics.validators ?? 0} / ${chainMetrics.validatorSetSize ?? 0}`}
              sub={`min ${((chainMetrics.minValidatorBalance ?? 0) / SAT_PER_OMNI).toFixed(0)} OMNI`}
              color="green"
            />
            <StatCard
              label="Block Reward"
              value={`${((chainMetrics.currentBlockReward ?? 0) / SAT_PER_OMNI).toFixed(2)} OMNI`}
              sub={`mempool: ${chainMetrics.mempoolSize ?? 0} TX`}
              color="dim"
            />
            {(chainMetrics.latestBlockTxCount ?? 0) > 0 && (
              <StatCard
                label="Latest Block TXs"
                value={(chainMetrics.latestBlockTxCount ?? 0).toLocaleString()}
                sub={chainMetrics.latestBlockTimestamp ? new Date(chainMetrics.latestBlockTimestamp * 1000).toLocaleTimeString() : undefined}
                color="blue"
              />
            )}
            {(chainMetrics.latestBlockFees ?? 0) > 0 && (
              <StatCard
                label="Latest Block Fees"
                value={`${((chainMetrics.latestBlockFees ?? 0) / SAT_PER_OMNI).toFixed(8)} OMNI`}
                sub={`${(chainMetrics.latestBlockFees ?? 0).toLocaleString()} sat`}
                color="green"
              />
            )}
          </div>
          {chainMetrics.peerCount > 0 && (
            <div className="mt-2 text-[10px] text-mempool-text-dim font-mono">
              {chainMetrics.peerCount} peer{chainMetrics.peerCount !== 1 ? "s" : ""} connected
              {chainMetrics.tipHash ? ` · tip ${chainMetrics.tipHash.slice(0, 16)}…` : ""}
            </div>
          )}
        </div>
      )}

      {/* Supply Distribution */}
      {supplyDist && supplyDist.some((s) => s.value > 0) && (
        <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
          <h3 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim mb-3">
            Supply Distribution (top 100 addresses)
          </h3>
          <div className="flex flex-col sm:flex-row items-center gap-4">
            <ResponsiveContainer width={160} height={160}>
              <PieChart>
                <Pie data={supplyDist} dataKey="value" cx="50%" cy="50%"
                  innerRadius={40} outerRadius={70} strokeWidth={1} stroke="#0d0e12">
                  {supplyDist.map((entry, i) => (
                    <Cell key={i} fill={entry.color} />
                  ))}
                </Pie>
                <Tooltip
                  contentStyle={TOOLTIP_STYLE}
                  formatter={(v: number) => [`${v.toFixed(2)}%`, "of supply"]}
                />
              </PieChart>
            </ResponsiveContainer>
            <div className="flex flex-col gap-1.5 text-xs flex-1">
              {supplyDist.map((s) => (
                <div key={s.name} className="flex items-center gap-2">
                  <div className="w-2.5 h-2.5 rounded-sm flex-shrink-0" style={{ background: s.color }} />
                  <span className="text-mempool-text-dim w-20 flex-shrink-0">{s.name}</span>
                  <div className="flex-1 bg-mempool-bg rounded-full h-1.5 overflow-hidden">
                    <div className="h-full rounded-full" style={{ width: `${Math.min(s.value, 100)}%`, background: s.color }} />
                  </div>
                  <span className="font-mono text-mempool-text w-12 text-right">{s.value.toFixed(2)}%</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      )}

      {/* Halving Countdown */}
      {chainMetrics && chainMetrics.height > 0 && (
        <HalvingCountdown
          height={chainMetrics.height}
          halvingInterval={chainMetrics.halvingInterval ?? 210_000}
          currentBlockReward={chainMetrics.currentBlockReward}
          avgBlockTime={netStats?.avgBlockTime ?? 10}
        />
      )}

      {/* Signing Scheme Distribution */}
      {schemeStats && schemeStats.schemes.length > 0 && (
        <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
          <h3 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim mb-1">
            Signing Scheme Distribution
          </h3>
          <p className="text-[10px] text-mempool-text-dim mb-3">
            {schemeStats.totalTxs.toLocaleString()} TXs across {schemeStats.blocks.toLocaleString()} blocks
          </p>
          <div className="space-y-2">
            {schemeStats.schemes.map((s) => {
              const pctFloat = s.pct / 100;
              const isPQ = s.scheme.includes("ML-DSA") || s.scheme.includes("Falcon") || s.scheme.includes("SLH-DSA") || s.scheme.includes("Hybrid");
              const isSoulbound = s.scheme.includes("soulbound");
              const barColor = isSoulbound ? "#a855f7" : isPQ ? "#3b82f6" : "#22c55e";
              return (
                <div key={s.scheme} className="flex items-center gap-2 text-xs">
                  <span className="text-mempool-text-dim w-44 flex-shrink-0 truncate" title={s.scheme}>{s.scheme}</span>
                  <div className="flex-1 bg-mempool-bg rounded-full h-2 overflow-hidden">
                    <div className="h-full rounded-full transition-all" style={{ width: `${Math.min(pctFloat, 100)}%`, background: barColor }} />
                  </div>
                  <span className="font-mono text-mempool-text w-14 text-right flex-shrink-0">
                    {pctFloat.toFixed(2)}% <span className="text-mempool-text-dim">({s.count})</span>
                  </span>
                </div>
              );
            })}
          </div>
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
                formatter={(v: number) => [`${v}s`, "Block Time"]}
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
                formatter={(v: number) => [Number(v).toLocaleString(), "Difficulty"]}
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
              formatter={(v: number) => [v, "TXs"]}
            />
            <Bar dataKey="txCount" fill="#10b981" radius={[2, 2, 0, 0]} maxBarSize={16} />
          </BarChart>
        </ResponsiveContainer>
      </div>

      {/* Fees per block chart */}
      {hasFeesEstimate && (
        <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
          <h3 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim mb-3">
            Fees per Block (sat)
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
              <YAxis tick={{ fontSize: 10, fill: "#6b7280" }} width={42}
                tickFormatter={(v) => v >= SAT_PER_OMNI ? `${(v/SAT_PER_OMNI).toFixed(2)}` : v >= 1e6 ? `${(v/1e6).toFixed(0)}M` : v.toLocaleString()} />
              <Tooltip
                contentStyle={TOOLTIP_STYLE}
                labelFormatter={(v) => `Block #${v}`}
                formatter={(v: number) => [`${(v/SAT_PER_OMNI).toFixed(8)} OMNI (${Number(v).toLocaleString()} sat)`, "Fees"]}
              />
              <Bar dataKey="feesEstimate" fill="#a855f7" radius={[2, 2, 0, 0]} maxBarSize={16} />
            </BarChart>
          </ResponsiveContainer>
        </div>
      )}

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
              tickFormatter={(v) => (v / SAT_PER_OMNI).toFixed(0)}
            />
            <Tooltip
              contentStyle={TOOLTIP_STYLE}
              labelFormatter={(v) => `Block #${v}`}
              formatter={(v: number) => [`${(v / SAT_PER_OMNI).toFixed(8)} OMNI`, "Reward"]}
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

const STAT_CARD_COLOR: Record<string, string> = {
  blue:   "text-mempool-blue",
  green:  "text-green-400",
  orange: "text-orange-400",
  dim:    "text-mempool-text",
};

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
  const cls = STAT_CARD_COLOR[color];
  return (
    <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-3">
      <div className={`text-base font-mono font-bold ${cls}`}>{value}</div>
      {sub && <div className="text-[10px] text-mempool-text-dim mt-0.5">{sub}</div>}
      <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mt-1">{label}</div>
    </div>
  );
}
