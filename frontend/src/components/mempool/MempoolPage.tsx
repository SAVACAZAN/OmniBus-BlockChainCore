import { useState, useEffect, useMemo, useRef } from "react";
import { rpc } from "../../api/rpc-client";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsNewTxEvent } from "../../types";
import { AddressLabel } from "../common/AddressLabel";
import { KindBadge, SchemeTag } from "../common/TxBadges";
import { satToOmni, midTrunc, fmtDuration } from "../../utils/fmt";
import {
  ResponsiveContainer,
  BarChart,
  Bar,
  XAxis,
  YAxis,
  Tooltip,
  Cell,
} from "recharts";


interface MempoolTx {
  txid: string;
  from: string;
  to: string;
  amount: number;
  fee: number;
  timestamp?: number;
  scheme?: string;
  nonce?: number;
  kind?: string;
}


interface Stats {
  size: number;
  maxTx: number;
  bytes: number;
  maxBytes: number;
}

interface FeeEstimate {
  feeSAT: number;
  minFeeSAT: number;
  burnPct: number;
}

// Fee buckets in SAT
const FEE_BUCKETS = [
  { label: "< 1k", min: 0, max: 1_000 },
  { label: "1k–10k", min: 1_000, max: 10_000 },
  { label: "10k–100k", min: 10_000, max: 100_000 },
  { label: "100k–1M", min: 100_000, max: 1_000_000 },
  { label: "> 1M", min: 1_000_000, max: Infinity },
];

const BUCKET_COLORS = ["#3b82f6", "#10b981", "#f59e0b", "#f97316", "#ef4444"];

export function MempoolPage() {
  const [txs, setTxs] = useState<MempoolTx[]>([]);
  const [stats, setStats] = useState<Stats | null>(null);
  const [feeEst, setFeeEst] = useState<FeeEstimate | null>(null);
  const [loading, setLoading] = useState(true);
  const [fetchErr, setFetchErr] = useState<string | null>(null);
  const [filter, setFilter] = useState("");
  const [page, setPage] = useState(0);
  const [sortCol, setSortCol] = useState<"amount" | "fee" | "age" | null>("fee");
  const [sortDir, setSortDir] = useState<"asc" | "desc">("desc");
  const PAGE_SIZE = 25;

  const toggleSort = (col: "amount" | "fee" | "age") => {
    if (sortCol === col) {
      setSortDir((d) => (d === "desc" ? "asc" : "desc"));
    } else {
      setSortCol(col);
      setSortDir("desc");
    }
    setPage(0);
  };
  // Keep a live feed of incoming TXs (from WS) prepended to the list
  const wsBuffer = useRef<MempoolTx[]>([]);

  const fetchMempool = async () => {
    setFetchErr(null);
    try {
      const [mempoolData, statsData, feeData, pendingData] = await Promise.allSettled([
        rpc.getMempoolTransactions(),
        rpc.getMempoolStats(),
        rpc.estimateFee(),
        rpc.getPendingTxs(200),
      ]);

      if (pendingData.status === "fulfilled" && pendingData.value?.transactions?.length) {
        // Use rich pending TX list (has scheme/nonce) when available
        const mapped: MempoolTx[] = pendingData.value.transactions.map((tx: any) => ({
          txid: tx.txid || "",
          from: tx.from || "",
          to: tx.to || "",
          amount: tx.amount || 0,
          fee: tx.fee || 0,
          timestamp: tx.timestamp,
          scheme: tx.scheme,
          nonce: tx.nonce,
          kind: tx.kind,
        }));
        const existing = new Set(mapped.map((t) => t.txid));
        const merged = [
          ...wsBuffer.current.filter((t) => !existing.has(t.txid)),
          ...mapped,
        ];
        setTxs(merged.slice(0, 500));
      } else if (mempoolData.status === "fulfilled" && mempoolData.value) {
        const val: any = mempoolData.value;
        const raw = Array.isArray(val) ? val : val?.transactions || [];
        const mapped: MempoolTx[] = raw.map((tx: any) => ({
          txid: tx.txid || tx.id || "",
          from: tx.from || "",
          to: tx.to || "",
          amount: tx.amount || 0,
          fee: tx.fee || 0,
          timestamp: tx.timestamp,
        }));
        const existing = new Set(mapped.map((t) => t.txid));
        const merged = [
          ...wsBuffer.current.filter((t) => !existing.has(t.txid)),
          ...mapped,
        ];
        setTxs(merged.slice(0, 500));
      }

      if (statsData.status === "fulfilled" && statsData.value) {
        const s = statsData.value;
        setStats({
          size: s.size ?? s.count ?? 0,
          maxTx: s.maxTx ?? s.max_tx ?? 5000,
          bytes: s.bytes ?? 0,
          maxBytes: s.maxBytes ?? s.max_bytes ?? 10_000_000,
        });
      }

      if (feeData.status === "fulfilled" && feeData.value) {
        const f = feeData.value;
        setFeeEst({
          feeSAT: f.feeSAT ?? f.fee_sat ?? 1000,
          minFeeSAT: f.minFeeSAT ?? f.min_fee_sat ?? 500,
          burnPct: f.burnPct ?? f.burn_pct ?? 0,
        });
      }
    } catch (e: any) {
      setFetchErr(e?.message || "Failed to load mempool");
    }
    setLoading(false);
  };

  useEffect(() => {
    fetchMempool();
    // new_tx WS (below) prepends TXs live — this poll only refreshes fee estimates.
    const id = setInterval(() => { void fetchMempool(); }, 30_000);
    return () => clearInterval(id);
  }, []);

  // Live WS feed — prepend new TXs instantly
  useEffect(() => {
    return wsSubscribe<WsNewTxEvent>("new_tx", (ev) => {
      const entry: MempoolTx = {
        txid: ev.txid,
        from: ev.from,
        to: "",
        amount: ev.amount_sat,
        fee: 0,
        timestamp: Math.floor(Date.now() / 1000),
      };
      wsBuffer.current = [entry, ...wsBuffer.current].slice(0, 100);
      setTxs((prev) => {
        if (prev.some((t) => t.txid === ev.txid)) return prev;
        return [entry, ...prev].slice(0, 500);
      });
    });
  }, []);

  // Fee distribution chart data
  const feeChart = useMemo(() => FEE_BUCKETS.map((b, i) => ({
    label: b.label,
    count: txs.filter((t) => t.fee >= b.min && t.fee < b.max).length,
    color: BUCKET_COLORS[i],
  })), [txs]);

  const avgFee = useMemo(() =>
    txs.length === 0 ? 0 : Math.round(txs.reduce((s, t) => s + t.fee, 0) / txs.length),
  [txs]);

  // Filter + sort + paginate (memoized to avoid re-runs on unrelated state changes)
  const filtered = useMemo(() => filter
    ? txs.filter(
        (t) =>
          t.txid.includes(filter) ||
          t.from.includes(filter) ||
          t.to.includes(filter)
      )
    : txs, [txs, filter]);

  const sorted = useMemo(() => sortCol
    ? [...filtered].sort((a, b) => {
        let va = 0; let vb = 0;
        if (sortCol === "fee")    { va = a.fee;       vb = b.fee; }
        if (sortCol === "amount") { va = a.amount;    vb = b.amount; }
        if (sortCol === "age")    { va = a.timestamp ?? 0; vb = b.timestamp ?? 0; }
        return sortDir === "desc" ? vb - va : va - vb;
      })
    : filtered, [filtered, sortCol, sortDir]);

  const totalPages = Math.ceil(sorted.length / PAGE_SIZE);
  const pageTxs = sorted.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);

  const capacityPct = stats
    ? Math.min(100, Math.round((stats.size / stats.maxTx) * 100))
    : 0;

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-4">
      <h2 className="text-lg font-bold text-mempool-text">
        Mempool{" "}
        <span className="text-mempool-text-dim font-normal text-sm">
          (live pending transactions)
        </span>
      </h2>

      {/* Stats cards */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <StatCard
          label="Pending TXs"
          value={loading ? "…" : txs.length.toLocaleString()}
          sub={stats ? `max ${stats.maxTx.toLocaleString()}` : undefined}
          color="blue"
        />
        <StatCard
          label="Capacity"
          value={loading ? "…" : `${capacityPct}%`}
          sub={
            <div className="w-full h-1 bg-mempool-bg rounded-full mt-1 overflow-hidden">
              <div
                className={`h-full rounded-full transition-all ${
                  capacityPct > 80
                    ? "bg-red-400"
                    : capacityPct > 50
                    ? "bg-orange-400"
                    : "bg-green-400"
                }`}
                style={{ width: `${capacityPct}%` }}
              />
            </div>
          }
          color={capacityPct > 80 ? "red" : capacityPct > 50 ? "orange" : "green"}
        />
        <StatCard
          label="Bytes Used"
          value={
            loading || !stats
              ? "…"
              : stats.bytes > 1_000_000
              ? `${(stats.bytes / 1_000_000).toFixed(1)} MB`
              : `${(stats.bytes / 1000).toFixed(1)} KB`
          }
          sub={stats ? `/ ${(stats.maxBytes / 1_000_000).toFixed(0)} MB` : undefined}
          color="dim"
        />
        <StatCard
          label="Avg Fee"
          value={
            loading || txs.length === 0
              ? "—"
              : `${avgFee.toLocaleString()} SAT`
          }
          color="orange"
        />
      </div>

      {/* Fee Estimator */}
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
        <h3 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim mb-3">
          Fee Estimator
          {feeEst && feeEst.burnPct > 0 && (
            <span className="ml-2 text-orange-400 normal-case font-normal text-[10px]">
              🔥 {feeEst.burnPct}% burned
            </span>
          )}
        </h3>
        <div className="grid grid-cols-3 gap-3">
          {[
            { label: "Fast", sub: "next 1-2 blocks", sat: feeEst ? Math.round(feeEst.feeSAT * 2) : null, color: "text-red-400", dot: "bg-red-400" },
            { label: "Normal", sub: "3-6 blocks", sat: feeEst?.feeSAT ?? null, color: "text-orange-400", dot: "bg-orange-400" },
            { label: "Economy", sub: "7+ blocks", sat: feeEst?.minFeeSAT ?? null, color: "text-green-400", dot: "bg-green-400" },
          ].map((tier) => (
            <div key={tier.label} className="bg-mempool-bg border border-mempool-border rounded-lg p-3 flex flex-col gap-1">
              <div className="flex items-center gap-1.5">
                <span className={`w-1.5 h-1.5 rounded-full ${tier.dot}`} />
                <span className="text-[10px] font-semibold uppercase tracking-wider text-mempool-text-dim">{tier.label}</span>
              </div>
              <div className={`text-base font-mono font-bold ${tier.color}`}>
                {tier.sat === null ? (
                  <span className="animate-pulse text-mempool-text-dim">…</span>
                ) : (
                  tier.sat.toLocaleString()
                )}
                {tier.sat !== null && <span className="text-[10px] text-mempool-text-dim font-normal ml-1">SAT</span>}
              </div>
              <div className="text-[10px] text-mempool-text-dim">{tier.sub}</div>
            </div>
          ))}
        </div>
        {feeEst && (
          <div className="mt-2 text-[10px] text-mempool-text-dim">
            Median mempool fee: <span className="text-mempool-text font-mono">{feeEst.feeSAT.toLocaleString()} SAT</span>
            {" · "}
            Min accepted: <span className="text-mempool-text font-mono">{feeEst.minFeeSAT.toLocaleString()} SAT</span>
          </div>
        )}
      </div>

      {/* Fee distribution chart */}
      {txs.length > 0 && (
        <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
          <h3 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim mb-3">
            Fee Distribution (SAT)
          </h3>
          <ResponsiveContainer width="100%" height={100}>
            <BarChart data={feeChart} margin={{ top: 4, right: 8, bottom: 0, left: 0 }}>
              <XAxis dataKey="label" tick={{ fontSize: 10, fill: "#6b7280" }} />
              <YAxis hide />
              <Tooltip
                contentStyle={{
                  background: "#1a1b1e",
                  border: "1px solid #2d2f36",
                  borderRadius: "6px",
                  fontSize: "11px",
                  color: "#c9d1d9",
                }}
                formatter={(v: number) => [`${v} TXs`, "Count"]}
              />
              <Bar dataKey="count" radius={[3, 3, 0, 0]}>
                {feeChart.map((entry, i) => (
                  <Cell key={i} fill={entry.color} />
                ))}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        </div>
      )}

      {/* TX table */}
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl overflow-hidden">
        {/* Search */}
        <div className="px-4 py-3 border-b border-mempool-border flex items-center gap-3">
          <h3 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim whitespace-nowrap">
            Pending ({sorted.length})
          </h3>
          <input
            type="text"
            value={filter}
            onChange={(e) => { setFilter(e.target.value); setPage(0); }}
            placeholder="Filter by hash / address…"
            className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-1 text-xs text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue transition-colors"
          />
          {filter && (
            <button onClick={() => setFilter("")} className="text-xs text-mempool-text-dim hover:text-mempool-text">
              ✕
            </button>
          )}
          {sorted.length > 0 && (
            <button
              onClick={() => {
                const rows = [
                  ["txid", "from", "to", "amount_omni", "fee_sat", "kind", "scheme", "age_s"].join(","),
                  ...sorted.map((t) => [
                    `"${t.txid}"`,
                    `"${t.from}"`,
                    `"${t.to}"`,
                    satToOmni(t.amount),
                    t.fee,
                    t.kind ?? "transfer",
                    t.scheme ?? "",
                    t.timestamp ? Math.floor(Date.now() / 1000) - t.timestamp : "",
                  ].join(",")),
                ].join("\n");
                const blob = new Blob([rows], { type: "text/csv" });
                const url = URL.createObjectURL(blob);
                const a = document.createElement("a");
                a.href = url; a.download = "omnibus-mempool.csv";
                a.click(); URL.revokeObjectURL(url);
              }}
              className="px-2 py-1 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue font-mono whitespace-nowrap"
            >
              ⬇ CSV
            </button>
          )}
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-xs min-w-[560px]">
            <thead>
              <tr className="text-mempool-text-dim border-b border-mempool-border text-left">
                <th className="px-4 py-2.5 font-medium">TX Hash</th>
                <th className="px-4 py-2.5 font-medium">From</th>
                <th className="px-4 py-2.5 font-medium">To</th>
                <th
                  className="px-4 py-2.5 font-medium text-right cursor-pointer select-none hover:text-mempool-blue transition-colors"
                  onClick={() => toggleSort("amount")}
                >
                  Amount (OMNI) {sortCol === "amount" ? (sortDir === "desc" ? "↓" : "↑") : "↕"}
                </th>
                <th
                  className="px-4 py-2.5 font-medium text-right cursor-pointer select-none hover:text-mempool-blue transition-colors"
                  onClick={() => toggleSort("fee")}
                >
                  Fee (SAT) {sortCol === "fee" ? (sortDir === "desc" ? "↓" : "↑") : "↕"}
                </th>
                <th className="px-4 py-2.5 font-medium">Scheme</th>
                <th
                  className="px-4 py-2.5 font-medium text-right cursor-pointer select-none hover:text-mempool-blue transition-colors"
                  onClick={() => toggleSort("age")}
                >
                  Age {sortCol === "age" ? (sortDir === "desc" ? "↓" : "↑") : "↕"}
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-mempool-border/30">
              {loading ? (
                <tr>
                  <td colSpan={7} className="px-4 py-8 text-center text-mempool-text-dim animate-pulse">
                    Loading mempool…
                  </td>
                </tr>
              ) : fetchErr ? (
                <tr>
                  <td colSpan={7} className="px-4 py-8 text-center text-red-400 text-xs font-mono">
                    {fetchErr}
                  </td>
                </tr>
              ) : pageTxs.length === 0 ? (
                <tr>
                  <td colSpan={7} className="px-4 py-8 text-center text-mempool-text-dim">
                    {filter ? "No matching transactions" : "Mempool is empty"}
                  </td>
                </tr>
              ) : (
                pageTxs.map((tx) => (
                  <tr key={tx.txid} className="hover:bg-mempool-bg-light/40 transition-colors">
                    <td className="px-4 py-2.5">
                      <button
                        onClick={() => { window.location.hash = `#/tx/${tx.txid}`; }}
                        className="font-mono text-mempool-blue hover:underline"
                      >
                        {midTrunc(tx.txid, 10, 8)}
                      </button>
                    </td>
                    <td className="px-4 py-2.5 font-mono text-mempool-text-dim">
                      {tx.from ? (
                        <button
                          onClick={() => { window.location.hash = `#/address/${tx.from}`; }}
                          className="hover:text-mempool-blue hover:underline transition-colors"
                        >
                          <AddressLabel address={tx.from} showEmoji truncate={{ left: 8, right: 6 }} />
                        </button>
                      ) : "—"}
                    </td>
                    <td className="px-4 py-2.5 font-mono text-mempool-text-dim">
                      {tx.to ? (
                        <button
                          onClick={() => { window.location.hash = `#/address/${tx.to}`; }}
                          className="hover:text-mempool-blue hover:underline transition-colors"
                        >
                          <AddressLabel address={tx.to} showEmoji truncate={{ left: 8, right: 6 }} />
                        </button>
                      ) : "—"}
                    </td>
                    <td className="px-4 py-2.5 text-right font-mono text-mempool-text">
                      {satToOmni(tx.amount)}
                    </td>
                    <td className="px-4 py-2.5 text-right font-mono">
                      <FeeTag fee={tx.fee} />
                    </td>
                    <td className="px-4 py-2.5">
                      <div className="flex items-center gap-1">
                        <KindBadge kind={tx.kind} />
                        {tx.scheme ? <SchemeTag scheme={tx.scheme} /> : <span className="text-mempool-text-dim">—</span>}
                      </div>
                    </td>
                    <td className="px-4 py-2.5 text-right text-mempool-text-dim">
                      {tx.timestamp ? fmtDuration(tx.timestamp) : "—"}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>

        {/* Pagination */}
        {totalPages > 1 && (
          <div className="flex items-center justify-between px-4 py-3 border-t border-mempool-border text-xs">
            <button
              disabled={page === 0}
              onClick={() => setPage((p) => p - 1)}
              className="px-3 py-1.5 rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
            >
              ← Prev
            </button>
            <span className="text-mempool-text-dim">
              {page * PAGE_SIZE + 1}–{Math.min((page + 1) * PAGE_SIZE, sorted.length)} of {sorted.length}
            </span>
            <button
              disabled={(page + 1) * PAGE_SIZE >= sorted.length}
              onClick={() => setPage((p) => p + 1)}
              className="px-3 py-1.5 rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
            >
              Next →
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

function FeeTag({ fee }: { fee: number }) {
  if (fee === 0) return <span className="text-mempool-text-dim">—</span>;
  if (fee < 1_000) return <span className="text-blue-400">{fee.toLocaleString()}</span>;
  if (fee < 100_000) return <span className="text-green-400">{fee.toLocaleString()}</span>;
  if (fee < 1_000_000) return <span className="text-orange-400">{fee.toLocaleString()}</span>;
  return <span className="text-red-400">{fee.toLocaleString()}</span>;
}

function StatCard({
  label,
  value,
  sub,
  color,
}: {
  label: string;
  value: string;
  sub?: React.ReactNode;
  color: "blue" | "green" | "orange" | "red" | "dim";
}) {
  const cls = {
    blue: "text-mempool-blue",
    green: "text-green-400",
    orange: "text-orange-400",
    red: "text-red-400",
    dim: "text-mempool-text",
  }[color];
  return (
    <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-3">
      <div className={`text-lg font-mono font-bold ${cls}`}>{value}</div>
      {typeof sub === "string" ? (
        <div className="text-[10px] text-mempool-text-dim mt-0.5">{sub}</div>
      ) : (
        sub
      )}
      <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mt-1">{label}</div>
    </div>
  );
}
