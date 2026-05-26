import { useEffect, useState } from "react";
import { rpc } from "../../api/rpc-client";
import type { AddressHistoryEntry } from "../../types";
import { AddressLabel } from "../common/AddressLabel";
import { CopyButton } from "../common/CopyButton";
import { useNameForAddress } from "../../api/use-names";
import { KindBadge, SchemeTag } from "../common/TxBadges";
import { fmtSat, midTrunc, fmtAge, SAT_PER_OMNI } from "../../utils/fmt";
import {
  ResponsiveContainer,
  BarChart,
  Bar,
  XAxis,
  YAxis,
  Tooltip,
  Legend,
} from "recharts";


function StatCard({ label, value, sub, color }: {
  label: string;
  value: string;
  sub?: string;
  color: "blue" | "green" | "orange" | "dim";
}) {
  const cls = { blue: "text-mempool-blue", green: "text-green-400", orange: "text-orange-400", dim: "text-mempool-text-dim" }[color];
  return (
    <div className="text-center">
      <div className={`text-sm font-mono font-semibold ${cls}`}>{value}</div>
      {sub && <div className="text-[10px] text-mempool-text-dim mt-0.5">{sub}</div>}
      <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mt-0.5">{label}</div>
    </div>
  );
}

const PAGE_SIZE = 20;
type FilterType = "all" | "received" | "sent";

interface Props {
  addr: string;
  onNavigate: (h: string) => void;
}

interface DailyEntry {
  dayIndex: number;
  blockStart: number;
  blockEnd: number;
  txCount: number;
  sent: number;
  received: number;
  miningReward: number;
  // computed client-side
  dateLabel?: string;
}
interface NonceInfo { nonce: number; chainNonce: number; pendingCount: number; }



export function AddressPage({ addr, onNavigate }: Props) {
  const [history, setHistory] = useState<AddressHistoryEntry[]>([]);
  const [chainBalance, setChainBalance] = useState<number | null>(null);
  const [dailyActivity, setDailyActivity] = useState<DailyEntry[]>([]);
  const [nonceInfo, setNonceInfo] = useState<NonceInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");
  const [filter, setFilter] = useState<FilterType>("all");
  const [page, setPage] = useState(0);
  const ens = useNameForAddress(addr);

  useEffect(() => {
    setLoading(true);
    setErr("");
    setPage(0);
    setChainBalance(null);
    setDailyActivity([]);
    setNonceInfo(null);
    Promise.all([
      rpc.getAddressHistory(addr),
      rpc.getAddressBalance(addr),
      rpc.request_raw("getdailyactivity", [addr, 30]).catch(() => null) as Promise<{ daily?: DailyEntry[]; tipTimestamp?: number; tipHeight?: number; blocksPerDay?: number } | null>,
      rpc.getNonce(addr).catch(() => null) as Promise<NonceInfo | null>,
    ])
      .then(([histData, balData, dailyData, nonceData]) => {
        const txs: AddressHistoryEntry[] = Array.isArray(histData)
          ? histData
          : histData?.transactions || histData?.history || [];
        setHistory(txs);
        if (balData?.balance !== undefined) {
          setChainBalance(balData.balance);
        }
        if (dailyData?.daily && dailyData.daily.length > 0) {
          // Compute real dates: tipTimestamp (unix s) + tipHeight + blocksPerDay
          const tipTs: number = dailyData.tipTimestamp ?? 0;
          const tipH: number = dailyData.tipHeight ?? 0;
          const bpd: number = dailyData.blocksPerDay ?? 86400;
          const withDates = dailyData.daily.map((d: DailyEntry) => {
            let dateLabel = `D${d.dayIndex}`;
            if (tipTs > 0 && bpd > 0) {
              const blocksFromTip = tipH - (d.blockStart || 0);
              const secsFromTip = (blocksFromTip / bpd) * 86400;
              const ts = tipTs - secsFromTip;
              if (ts > 0) {
                const dt = new Date(ts * 1000);
                dateLabel = `${dt.getMonth() + 1}/${dt.getDate()}`;
              }
            }
            return { ...d, dateLabel };
          });
          const active = withDates.filter((d: DailyEntry) =>
            d.txCount > 0 || d.sent > 0 || d.received > 0 || d.miningReward > 0
          );
          setDailyActivity(active.slice(-30));
        }
        if (nonceData && (nonceData as NonceInfo).nonce !== undefined) {
          setNonceInfo(nonceData as NonceInfo);
        }
      })
      .catch((e) => setErr(e.message))
      .finally(() => setLoading(false));
  }, [addr]);

  const received = history.filter((t) => t.direction === "received");
  const sent = history.filter((t) => t.direction === "sent");
  const totalReceived = received.reduce((s, t) => s + t.amount, 0);
  const totalSent = sent.reduce((s, t) => s + t.amount, 0);
  const totalFees = sent.reduce((s, t) => s + (t.fee || 0), 0);
  // Prefer chain-reported balance; fall back to computed
  const balance = chainBalance !== null ? chainBalance : Math.max(0, totalReceived - totalSent);

  const filtered = filter === "all" ? history : filter === "received" ? received : sent;
  const totalPages = Math.ceil(filtered.length / PAGE_SIZE);
  const pageTxs = filtered.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);

  if (loading) {
    return (
      <div className="max-w-7xl mx-auto px-4 py-8 text-mempool-text-dim animate-pulse text-sm">
        Loading address…
      </div>
    );
  }

  if (err) {
    return (
      <div className="max-w-7xl mx-auto px-4 py-8 space-y-4">
        <button onClick={() => onNavigate("#/blocks")} className="text-mempool-blue hover:underline text-sm">
          ← Explorer
        </button>
        <p className="text-red-400">{err}</p>
      </div>
    );
  }

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-4">
      {/* Breadcrumb */}
      <div className="flex items-center gap-2 text-sm flex-wrap">
        <button onClick={() => onNavigate("#/blocks")} className="text-mempool-blue hover:underline">
          ← Explorer
        </button>
        <span className="text-mempool-text-dim">/</span>
        <span className="text-mempool-text font-medium">Address</span>
      </div>

      {/* Address + stats card */}
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-5">
        {/* Address */}
        <div className="mb-4">
          <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">Address</div>
          {ens && (
            <div className="flex items-center gap-2 mb-1">
              <AddressLabel address={addr} showEmoji showCategory
                className="text-base font-semibold" />
            </div>
          )}
          <div className="flex items-start gap-2">
            <span className="font-mono text-sm text-mempool-text break-all">{addr}</span>
            <CopyButton text={addr} />
          </div>
        </div>

        {/* Stats */}
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-4 pt-4 border-t border-mempool-border">
          <StatCard
            label="Balance"
            value={fmtSat(balance)}
            color="blue"
            sub={chainBalance !== null ? "on-chain" : "computed"}
          />
          <StatCard label="Received" value={fmtSat(totalReceived)} sub={`${received.length} tx`} color="green" />
          <StatCard label="Sent" value={fmtSat(totalSent)} sub={`${sent.length} tx`} color="orange" />
          <StatCard label="Fees Paid" value={fmtSat(totalFees)} color="dim" />
        </div>

        {/* Nonce row */}
        {nonceInfo && (
          <div className="flex flex-wrap gap-4 pt-3 mt-1 border-t border-mempool-border/50 text-xs text-mempool-text-dim">
            <span>Next nonce: <span className="font-mono text-mempool-text">{nonceInfo.nonce}</span></span>
            <span>Chain nonce: <span className="font-mono text-mempool-text">{nonceInfo.chainNonce}</span></span>
            {nonceInfo.pendingCount > 0 && (
              <span className="text-yellow-400 font-medium">{nonceInfo.pendingCount} pending TX{nonceInfo.pendingCount !== 1 ? "s" : ""}</span>
            )}
          </div>
        )}
      </div>

      {/* 30-day activity chart */}
      {dailyActivity.length > 0 && (
        <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
          <h3 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim mb-3">
            Activity (last {dailyActivity.length} active days)
          </h3>
          <ResponsiveContainer width="100%" height={110}>
            <BarChart data={dailyActivity} margin={{ top: 4, right: 8, bottom: 0, left: 0 }}>
              <XAxis dataKey="dateLabel" tick={{ fontSize: 9, fill: "#6b7280" }}
                interval="preserveStartEnd" />
              <YAxis hide />
              <Tooltip
                contentStyle={{ background: "#1a1b1e", border: "1px solid #2d2f36", borderRadius: "6px", fontSize: "11px", color: "#c9d1d9" }}
                labelFormatter={(v) => `${v}`}
                formatter={(val: number, name: string) => [
                  `${(val / SAT_PER_OMNI).toFixed(4)} OMNI`,
                  name === "received" ? "Received" : name === "sent" ? "Sent" : "Mining",
                ]}
              />
              <Legend iconType="square" wrapperStyle={{ fontSize: "10px" }} />
              <Bar dataKey="received" fill="#22c55e" radius={[2, 2, 0, 0]} maxBarSize={14} stackId="a" name="received" />
              <Bar dataKey="sent" fill="#f97316" radius={[2, 2, 0, 0]} maxBarSize={14} stackId="b" name="sent" />
              {dailyActivity.some(d => d.miningReward > 0) && (
                <Bar dataKey="miningReward" fill="#eab308" radius={[2, 2, 0, 0]} maxBarSize={14} stackId="c" name="mining" />
              )}
            </BarChart>
          </ResponsiveContainer>
        </div>
      )}

      {/* Transactions */}
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
        {/* Header + filter */}
        <div className="flex items-center justify-between mb-3 flex-wrap gap-2">
          <h2 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim">
            Transactions ({filtered.length})
          </h2>
          <div className="flex items-center gap-2">
            <div className="flex gap-1">
              {(["all", "received", "sent"] as FilterType[]).map((f) => (
                <button
                  key={f}
                  onClick={() => { setFilter(f); setPage(0); }}
                  className={`text-xs px-2.5 py-1 rounded-full transition-colors ${
                    filter === f
                      ? "bg-mempool-blue text-white"
                      : "text-mempool-text-dim hover:text-mempool-text border border-mempool-border"
                  }`}
                >
                  {f.charAt(0).toUpperCase() + f.slice(1)}
                </button>
              ))}
            </div>
            {history.length > 0 && (
              <button
                onClick={() => {
                  const rows = [
                    ["txid", "direction", "amount_omni", "fee_omni", "from", "to", "block_height", "confirmations", "status", "kind", "timestamp"].join(","),
                    ...history.map((tx) => [
                      tx.txid,
                      tx.direction ?? "",
                      (tx.amount / SAT_PER_OMNI).toFixed(8),
                      (tx.fee / SAT_PER_OMNI).toFixed(8),
                      tx.from,
                      tx.to,
                      tx.blockHeight ?? "",
                      tx.confirmations,
                      tx.status,
                      tx.kind ?? "",
                      tx.timestamp ? new Date(tx.timestamp > 1e12 ? tx.timestamp : tx.timestamp * 1000).toISOString() : "",
                    ].join(",")),
                  ].join("\n");
                  const blob = new Blob([rows], { type: "text/csv" });
                  const url = URL.createObjectURL(blob);
                  const a = document.createElement("a");
                  a.href = url;
                  a.download = `omnibus-${addr.slice(0, 12)}-txs.csv`;
                  a.click();
                  URL.revokeObjectURL(url);
                }}
                className="text-[10px] px-2.5 py-1 rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue transition-colors font-mono"
                title="Download transaction history as CSV"
              >
                ⬇ CSV
              </button>
            )}
          </div>
        </div>

        {/* TX list */}
        {pageTxs.length === 0 ? (
          <div className="text-mempool-text-dim text-sm py-6 text-center">No transactions found</div>
        ) : (
          <div className="space-y-2">
            {pageTxs.map((tx) => {
              const counterparty = tx.direction === "received" ? tx.from : tx.to;
              return (
                <div key={tx.txid} className="bg-mempool-bg-light border border-mempool-border/40 rounded-lg p-3 text-xs space-y-1.5">
                  <div className="flex items-center justify-between gap-2 flex-wrap">
                    <button onClick={() => onNavigate(`#/tx/${tx.txid}`)}
                      className="font-mono text-mempool-blue hover:underline truncate max-w-[200px] sm:max-w-xs">
                      {midTrunc(tx.txid, 14, 12)}
                    </button>
                    <div className="flex items-center gap-2 flex-shrink-0">
                      <span className={`font-mono font-medium ${tx.direction === "received" ? "text-green-400" : "text-orange-400"}`}>
                        {tx.direction === "received" ? "+" : "−"}{fmtSat(tx.amount)}
                      </span>
                      <span className={`px-1.5 py-0.5 rounded text-[10px] font-medium ${
                        tx.status === "confirmed"
                          ? "bg-green-400/10 text-green-400"
                          : "bg-yellow-400/10 text-yellow-400"
                      }`}>{tx.status}</span>
                    </div>
                  </div>

                  <div className="flex flex-wrap gap-x-4 gap-y-0.5 text-mempool-text-dim">
                    <span>
                      {tx.direction === "received" ? "From" : "To"}:{" "}
                      <button onClick={() => onNavigate(`#/address/${counterparty}`)}
                        className="text-mempool-blue hover:underline font-mono">
                        <AddressLabel address={counterparty ?? ""}
                          truncate={{ left: 10, right: 8 }} showEmoji />
                      </button>
                    </span>
                    {tx.blockHeight >= 0 && (
                      <span>
                        Block:{" "}
                        <button onClick={() => onNavigate(`#/block/${tx.blockHeight}`)}
                          className="text-mempool-blue hover:underline font-mono">
                          #{tx.blockHeight.toLocaleString()}
                        </button>
                      </span>
                    )}
                    <span>{tx.confirmations} conf</span>
                    {tx.fee > 0 && <span>Fee: {fmtSat(tx.fee)}</span>}
                    {tx.kind && tx.kind !== "transfer" && <KindBadge kind={tx.kind} memo={tx.memo} />}
                    {tx.scheme && <SchemeTag scheme={tx.scheme} />}
                    {tx.timestamp && tx.timestamp > 0 && (
                      <span className="text-mempool-text-dim" title={new Date(tx.timestamp > 1e12 ? tx.timestamp : tx.timestamp * 1000).toLocaleString()}>
                        {fmtAge(tx.timestamp)}
                      </span>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        )}

        {/* Pagination */}
        {totalPages > 1 && (
          <div className="flex items-center justify-between mt-4 pt-4 border-t border-mempool-border text-xs">
            <button
              disabled={page === 0}
              onClick={() => setPage((p) => p - 1)}
              className="px-3 py-1.5 rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
            >
              ← Newer
            </button>
            <span className="text-mempool-text-dim">
              {page * PAGE_SIZE + 1}–{Math.min((page + 1) * PAGE_SIZE, filtered.length)} of {filtered.length}
            </span>
            <button
              disabled={(page + 1) * PAGE_SIZE >= filtered.length}
              onClick={() => setPage((p) => p + 1)}
              className="px-3 py-1.5 rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
            >
              Older →
            </button>
          </div>
        )}
      </div>

      <AddressLabelsPanel addr={addr} />
      <UtxoPanel addr={addr} onNavigate={onNavigate} />
    </div>
  );
}

function AddressLabelsPanel({ addr }: { addr: string }) {
  const [labels, setLabels] = useState<string[]>([]);
  const [newLabel, setNewLabel] = useState("");
  const [loading, setLoading] = useState(false);
  const [applying, setApplying] = useState(false);
  const [removing, setRemoving] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const loadLabels = async () => {
    setLoading(true);
    try {
      const r = (await rpc.request_raw("getlabels", [addr])) as string[] | { labels?: string[] };
      setLabels(Array.isArray(r) ? r : (r?.labels ?? []));
    } catch {
      setLabels([]);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (addr) loadLabels();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [addr]);

  const applyLabel = async () => {
    if (!newLabel.trim()) return;
    setApplying(true);
    setErr(null);
    try {
      await rpc.request_raw("applylabel", [addr, newLabel.trim()]);
      setNewLabel("");
      await loadLabels();
    } catch (e: any) {
      setErr(e?.message ?? String(e));
    } finally {
      setApplying(false);
    }
  };

  const removeLabel = async (label: string) => {
    setRemoving(label);
    setErr(null);
    try {
      await rpc.request_raw("removelabel", [addr, label]);
      await loadLabels();
    } catch (e: any) {
      setErr(e?.message ?? String(e));
    } finally {
      setRemoving(null);
    }
  };

  return (
    <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4 space-y-3">
      <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
        On-chain Labels
      </h3>
      {loading ? (
        <p className="text-xs text-mempool-text-dim animate-pulse">Loading labels…</p>
      ) : (
        <div className="flex flex-wrap gap-1.5">
          {labels.map((l) => (
            <span key={l} className="inline-flex items-center gap-1 px-2 py-0.5 rounded bg-mempool-blue/10 text-mempool-blue border border-mempool-blue/20 text-[11px] font-mono">
              {l}
              <button
                onClick={() => removeLabel(l)}
                disabled={removing === l}
                className="text-mempool-text-dim hover:text-red-400 ml-0.5 text-[10px] leading-none"
              >
                {removing === l ? "…" : "×"}
              </button>
            </span>
          ))}
          {labels.length === 0 && (
            <span className="text-[11px] text-mempool-text-dim">No labels yet.</span>
          )}
        </div>
      )}
      <div className="flex gap-2">
        <input
          value={newLabel}
          onChange={(e) => setNewLabel(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && applyLabel()}
          className="flex-1 bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs text-mempool-text"
          placeholder="Add label…"
        />
        <button
          onClick={applyLabel}
          disabled={applying || !newLabel.trim()}
          className="px-3 py-1.5 text-xs bg-mempool-blue/20 hover:bg-mempool-blue/30 text-mempool-blue border border-mempool-blue/30 rounded disabled:opacity-50 whitespace-nowrap"
        >
          {applying ? "…" : "Apply"}
        </button>
      </div>
      {err && <p className="text-[11px] text-red-400">{err}</p>}
    </div>
  );
}

// ── UTXO panel ──────────────────────────────────────────────────────────────

interface Utxo {
  tx_hash: string;
  output_index: number;
  amount: number;
  block_height: number;
  is_coinbase: boolean;
}

function UtxoPanel({ addr, onNavigate }: { addr: string; onNavigate: (h: string) => void }) {
  const [utxos, setUtxos] = useState<Utxo[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [expanded, setExpanded] = useState(false);

  useEffect(() => {
    setLoading(true);
    rpc.request_raw("listunspent", [addr])
      .then((r: any) => {
        if (Array.isArray(r?.utxos)) {
          setUtxos(r.utxos);
          setTotal(r.total ?? 0);
        }
      })
      .catch(() => {})
      .finally(() => setLoading(false));
  }, [addr]);

  if (!loading && utxos.length === 0) return null;

  return (
    <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4 space-y-3">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
          UTXOs ({loading ? "…" : utxos.length})
          {total > 0 && (
            <span className="ml-2 font-mono text-xs text-mempool-blue normal-case">
              {fmtSat(total)}
            </span>
          )}
        </h3>
        {utxos.length > 5 && (
          <button
            onClick={() => setExpanded((v) => !v)}
            className="text-xs text-mempool-text-dim hover:text-mempool-text"
          >
            {expanded ? "Show less" : `Show all ${utxos.length}`}
          </button>
        )}
      </div>
      {loading ? (
        <p className="text-xs text-mempool-text-dim animate-pulse">Loading UTXOs…</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-xs min-w-[420px]">
            <thead className="text-mempool-text-dim border-b border-mempool-border">
              <tr>
                <th className="text-left pb-2 pr-3">TX Hash</th>
                <th className="text-right pb-2 pr-3">Vout</th>
                <th className="text-right pb-2 pr-3">Amount</th>
                <th className="text-right pb-2 pr-3">Block</th>
                <th className="text-left pb-2">Type</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-mempool-border/30">
              {(expanded ? utxos : utxos.slice(0, 5)).map((u) => (
                <tr key={`${u.tx_hash}:${u.output_index}`} className="hover:bg-mempool-bg-light/30">
                  <td className="py-1.5 pr-3 font-mono text-mempool-blue">
                    <button
                      onClick={() => onNavigate(`#/tx/${u.tx_hash}`)}
                      className="hover:underline"
                      title={u.tx_hash}
                    >
                      {midTrunc(u.tx_hash, 10, 8)}
                    </button>
                  </td>
                  <td className="py-1.5 pr-3 text-right font-mono text-mempool-text-dim">{u.output_index}</td>
                  <td className="py-1.5 pr-3 text-right font-mono text-green-400">{fmtSat(u.amount)}</td>
                  <td className="py-1.5 pr-3 text-right font-mono">
                    <button
                      onClick={() => onNavigate(`#/block/${u.block_height}`)}
                      className="text-mempool-blue hover:underline"
                    >
                      #{u.block_height.toLocaleString()}
                    </button>
                  </td>
                  <td className="py-1.5">
                    {u.is_coinbase ? (
                      <span className="px-1.5 py-0.5 rounded bg-yellow-500/20 text-yellow-300 text-[9px] uppercase">coinbase</span>
                    ) : (
                      <span className="px-1.5 py-0.5 rounded bg-gray-700/40 text-gray-400 text-[9px] uppercase">utxo</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
