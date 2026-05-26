import { useEffect, useState } from "react";
import { OmniBusRpcClient } from "../../api/rpc-client";
import type { AddressHistoryEntry } from "../../types";

const rpc = new OmniBusRpcClient();
const SAT = 1e9;

function fmtSat(sat: number) {
  return (sat / SAT).toFixed(8) + " OMNI";
}
function midTrunc(s: string | undefined | null, h = 12, t = 10): string {
  if (!s) return "—";
  if (s.length <= h + t + 3) return s;
  return s.slice(0, h) + "…" + s.slice(-t);
}

function CopyBtn({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      className="flex-shrink-0 text-mempool-text-dim hover:text-mempool-blue transition-colors"
      onClick={() => { navigator.clipboard.writeText(text); setCopied(true); setTimeout(() => setCopied(false), 1500); }}
    >
      {copied ? "✓" : "⧉"}
    </button>
  );
}

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

export function AddressPage({ addr, onNavigate }: Props) {
  const [history, setHistory] = useState<AddressHistoryEntry[]>([]);
  const [chainBalance, setChainBalance] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");
  const [filter, setFilter] = useState<FilterType>("all");
  const [page, setPage] = useState(0);

  useEffect(() => {
    setLoading(true);
    setErr("");
    setPage(0);
    setChainBalance(null);
    Promise.all([
      rpc.getAddressHistory(addr),
      rpc.getAddressBalance(addr),
    ])
      .then(([histData, balData]) => {
        const txs: AddressHistoryEntry[] = Array.isArray(histData)
          ? histData
          : histData?.transactions || histData?.history || [];
        setHistory(txs);
        if (balData?.balance !== undefined) {
          setChainBalance(balData.balance);
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
          <div className="flex items-start gap-2">
            <span className="font-mono text-sm text-mempool-text break-all">{addr}</span>
            <CopyBtn text={addr} />
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
      </div>

      {/* Transactions */}
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
        {/* Header + filter */}
        <div className="flex items-center justify-between mb-3 flex-wrap gap-2">
          <h2 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim">
            Transactions ({filtered.length})
          </h2>
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
                        {midTrunc(counterparty, 10, 8)}
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
