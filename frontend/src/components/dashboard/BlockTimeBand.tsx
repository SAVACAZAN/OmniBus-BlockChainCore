import { useEffect, useState } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import { rpc } from "../../api/rpc-client";


function Sparkline({ values, width = 200, height = 32 }: {
  values: number[];
  width?: number;
  height?: number;
}) {
  if (values.length < 2) return null;
  const mn = Math.min(...values);
  const mx = Math.max(...values);
  const range = mx - mn || 1;
  const pad = 2;
  const w = width - pad * 2;
  const h = height - pad * 2;

  const pts = values.map((v, i) => {
    const x = pad + (i / (values.length - 1)) * w;
    const y = pad + h - ((v - mn) / range) * h;
    return `${x},${y}`;
  });

  // Color the line based on latest block time relative to target (1s)
  const latest = values[values.length - 1];
  const stroke = latest <= 2 ? "#22c55e" : latest <= 10 ? "#f59e0b" : "#ef4444";

  return (
    <svg width={width} height={height} className="overflow-visible">
      <polyline
        points={pts.join(" ")}
        fill="none"
        stroke={stroke}
        strokeWidth="1.5"
        strokeLinejoin="round"
        strokeLinecap="round"
        opacity="0.85"
      />
      {/* Latest dot */}
      {(() => {
        const [lx, ly] = pts[pts.length - 1].split(",").map(Number);
        return <circle cx={lx} cy={ly} r="2.5" fill={stroke} />;
      })()}
    </svg>
  );
}

export function BlockTimeBand() {
  const { state } = useBlockchain();
  const [times, setTimes] = useState<number[]>([]);

  useEffect(() => {
    let cancelled = false;
    const load = async () => {
      try {
        const from = Math.max(0, state.blockCount - 25);
        const count = Math.min(25, state.blockCount - from);
        if (count < 2) return;
        const resp: any = await rpc.getBlocks(from, count);
        if (cancelled) return;
        const blks: any[] = (Array.isArray(resp) ? resp : (resp?.blocks ?? []))
          .filter((b: any) => b.timestamp > 0)
          .sort((a: any, b: any) => a.height - b.height);
        const ts: number[] = [];
        for (let i = 1; i < blks.length; i++) {
          const dt = blks[i].timestamp - blks[i - 1].timestamp;
          if (dt > 0 && dt < 600) ts.push(dt);
        }
        if (!cancelled) setTimes(ts);
      } catch {
        // RPC unavailable — show nothing
      }
    };
    void load();
    return () => { cancelled = true; };
  }, [state.blockCount]);

  if (times.length < 3) return null;

  const avg = times.reduce((s, v) => s + v, 0) / times.length;
  const mn  = Math.min(...times);
  const mx  = Math.max(...times);

  const healthColor =
    avg <= 2 ? "text-green-400" :
    avg <= 10 ? "text-yellow-400" :
    "text-red-400";

  const healthLabel =
    avg <= 2  ? "healthy" :
    avg <= 10 ? "slow" :
    "stalled";

  return (
    <div className="flex items-center gap-4 px-4 py-2 rounded-lg border border-mempool-border bg-mempool-bg-elev text-xs">
      <div className="flex items-center gap-1.5 flex-shrink-0">
        <span
          className={`w-2 h-2 rounded-full ${
            avg <= 2 ? "bg-green-400 animate-pulse" :
            avg <= 10 ? "bg-yellow-400" : "bg-red-400"
          }`}
        />
        <span className="text-mempool-text-dim uppercase tracking-wider text-[10px]">Block time</span>
        <span className={`font-mono font-semibold ${healthColor}`}>{healthLabel}</span>
      </div>

      <Sparkline values={times} width={120} height={28} />

      <div className="flex items-center gap-3 text-[10px] text-mempool-text-dim ml-auto flex-shrink-0">
        <span>avg <span className="font-mono text-mempool-text">{avg.toFixed(1)}s</span></span>
        <span>min <span className="font-mono text-green-400">{mn}s</span></span>
        <span>max <span className="font-mono text-red-400">{mx}s</span></span>
        <span className="text-mempool-text-dim">last {times.length} blocks</span>
      </div>
    </div>
  );
}
