/**
 * DailyAuditPage.tsx — daily transparency audit for the connected wallet.
 *
 * Pulls last N days of activity straight from chain RPC (`getdailyactivity`)
 * and the current reputation snapshot (`getreputation`), then renders a
 * Bitcoin-Core-style table where every row is one day.
 *
 * Design rules:
 *   - 100 % chain-derived values. We never cache totals across renders — every
 *     refresh re-fetches `getdailyactivity` so the UI matches chain state byte
 *     for byte. The user explicitly requested "no stale cached values".
 *   - Reputation snapshot at top is a single sample (current cups). Per-day
 *     reputation deltas would require historical snapshots which the chain
 *     doesn't expose yet — we surface only the *current* cups so the user can
 *     correlate with the daily TX log below it.
 *   - Sortable columns + CSV export. CSV is built client-side from the same
 *     in-memory rows the table renders so they're always identical.
 *   - All amounts are SAT on the wire; `fmtOmni` divides by SAT_PER_OMNI for display.
 *   - No `any` for known shapes. Only `unknown` when narrowing RPC responses
 *     because `request_raw` returns `unknown` by design.
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  ClipboardList,
  Download,
  RefreshCw,
  AlertTriangle,
  ArrowUpDown,
} from "lucide-react";
import { OmniBusRpcClient } from "../../api/rpc-client";
import { SAT_PER_OMNI, fmtOmni } from "../../utils/fmt";
import { useWallet } from "../../api/use-wallet";

const rpc = new OmniBusRpcClient();


// ── Types matching backend `getdailyactivity` response ───────────────────

interface DailyEntry {
  dayIndex: number;
  blockStart: number;
  blockEnd: number;
  txCount: number;
  sent: number;
  received: number;
  miningReward: number;
  feesBurned: number;
  stakeChange: number; // signed (positive = stake added that day, negative = unstaked)
}

interface DailyActivityResp {
  address: string;
  days: number;
  blocksPerDay: number;
  blockTimeMs: number;
  tipHeight: number;
  tipTimestamp: number; // unix seconds (i64 from chain)
  daily: DailyEntry[];
}

interface ReputationCups {
  love: string;
  food: string;
  rent: string;
  vacation: string;
}
interface ReputationResp {
  address: string;
  cups: ReputationCups;
  total: number;
  tier: string;
}

// ── Sort + render helpers ────────────────────────────────────────────────

type SortKey =
  | "date"
  | "txCount"
  | "sent"
  | "received"
  | "miningReward"
  | "feesBurned"
  | "stakeChange";
type SortDir = "asc" | "desc";

const intFmt = new Intl.NumberFormat("en-US");

/** Convert tip block timestamp + day-window math to a real ISO date string. */
function dayDate(d: DailyEntry, resp: DailyActivityResp | null): string {
  if (!resp) return `day-${d.dayIndex}`;
  // Each day-bucket starts at d.blockStart. We anchor at tipTimestamp/tipHeight
  // and walk back at block_time_ms granularity.
  const blockTimeS = resp.blockTimeMs / 1000;
  const deltaBlocks = resp.tipHeight > d.blockStart ? resp.tipHeight - d.blockStart : 0;
  const ts = resp.tipTimestamp - deltaBlocks * blockTimeS;
  if (!Number.isFinite(ts) || ts <= 0) return `day-${d.dayIndex}`;
  const dt = new Date(ts * 1000);
  // YYYY-MM-DD (no time component — one row = one day)
  const y = dt.getUTCFullYear();
  const m = String(dt.getUTCMonth() + 1).padStart(2, "0");
  const day = String(dt.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function csvEscape(v: string | number): string {
  const s = String(v);
  if (/[",\n\r]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
  return s;
}

// ── Component ────────────────────────────────────────────────────────────

export function DailyAuditPage() {
  const wallet = useWallet();
  const [addrInput, setAddrInput] = useState<string>("");
  const effectiveAddress = wallet?.address ?? addrInput.trim();

  const [days, setDays] = useState<number>(30);
  const [resp, setResp] = useState<DailyActivityResp | null>(null);
  const [rep, setRep] = useState<ReputationResp | null>(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [sortKey, setSortKey] = useState<SortKey>("date");
  const [sortDir, setSortDir] = useState<SortDir>("desc");

  const refresh = useCallback(async () => {
    if (!effectiveAddress) {
      setResp(null);
      setRep(null);
      return;
    }
    setLoading(true);
    setErr(null);
    try {
      // Fire both in parallel — they hit independent chain subsystems
      // (address_tx_index vs reputation manager) so there's no benefit to
      // serializing.
      const [dailyRaw, repRaw] = await Promise.all([
        rpc.request_raw("getdailyactivity", [{ address: effectiveAddress, days }]),
        rpc.request_raw("getreputation", [effectiveAddress]),
      ]);
      const daily = dailyRaw as DailyActivityResp | null;
      const reputation = repRaw as ReputationResp | null;
      setResp(daily);
      setRep(reputation);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
      setResp(null);
      setRep(null);
    } finally {
      setLoading(false);
    }
  }, [effectiveAddress, days]);

  useEffect(() => { void refresh(); }, [refresh]);

  // Aggregated totals across the visible window — chain-derived, recomputed
  // on every render rather than cached, to obey the "100 % chain reality" rule.
  const totals = useMemo(() => {
    const rows = resp?.daily ?? [];
    const t = {
      txCount: 0,
      sent: 0,
      received: 0,
      miningReward: 0,
      feesBurned: 0,
      stakeChange: 0,
    };
    for (const d of rows) {
      t.txCount += d.txCount;
      t.sent += d.sent;
      t.received += d.received;
      t.miningReward += d.miningReward;
      t.feesBurned += d.feesBurned;
      t.stakeChange += d.stakeChange;
    }
    return t;
  }, [resp]);

  const sortedRows = useMemo(() => {
    const rows = (resp?.daily ?? []).slice();
    rows.sort((a, b) => {
      let va: number;
      let vb: number;
      switch (sortKey) {
        case "date":
          // Higher dayIndex = more recent (later block range)
          va = a.dayIndex; vb = b.dayIndex; break;
        case "txCount":
          va = a.txCount; vb = b.txCount; break;
        case "sent":
          va = a.sent; vb = b.sent; break;
        case "received":
          va = a.received; vb = b.received; break;
        case "miningReward":
          va = a.miningReward; vb = b.miningReward; break;
        case "feesBurned":
          va = a.feesBurned; vb = b.feesBurned; break;
        case "stakeChange":
          va = a.stakeChange; vb = b.stakeChange; break;
      }
      const diff = va - vb;
      return sortDir === "asc" ? diff : -diff;
    });
    return rows;
  }, [resp, sortKey, sortDir]);

  const toggleSort = (key: SortKey) => {
    if (sortKey === key) {
      setSortDir(d => (d === "asc" ? "desc" : "asc"));
    } else {
      setSortKey(key);
      setSortDir("desc");
    }
  };

  const exportCsv = () => {
    if (!resp) return;
    const header = [
      "date",
      "blockStart",
      "blockEnd",
      "txCount",
      "sentOmni",
      "receivedOmni",
      "miningRewardOmni",
      "feesBurnedOmni",
      "stakeChangeOmni",
    ];
    const lines: string[] = [header.join(",")];
    for (const d of sortedRows) {
      lines.push([
        csvEscape(dayDate(d, resp)),
        d.blockStart,
        d.blockEnd,
        d.txCount,
        (d.sent / SAT_PER_OMNI).toFixed(4),
        (d.received / SAT_PER_OMNI).toFixed(4),
        (d.miningReward / SAT_PER_OMNI).toFixed(4),
        (d.feesBurned / SAT_PER_OMNI).toFixed(4),
        (d.stakeChange / SAT_PER_OMNI).toFixed(4),
      ].map(csvEscape).join(","));
    }
    const today = new Date().toISOString().slice(0, 10);
    const blob = new Blob([lines.join("\n")], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `daily-audit-${today}.csv`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  return (
    <section className="bg-mempool-bg-elev rounded-lg p-3 sm:p-4 border border-mempool-border backdrop-blur-sm">
      <div className="flex items-center gap-2 sm:gap-3 mb-4">
        <ClipboardList className="w-5 h-5 text-mempool-blue flex-shrink-0" />
        <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          Daily Audit
        </h2>
        <div className="flex-1 h-px bg-mempool-border" />
        <span className="text-[10px] sm:text-xs text-mempool-text-dim font-mono whitespace-nowrap">
          {resp ? `tip ${intFmt.format(resp.tipHeight)}` : ""}
        </span>
      </div>

      {/* Address row */}
      <div className="flex flex-wrap items-center gap-2 mb-3">
        {wallet ? (
          <span className="text-xs text-mempool-text-dim font-mono truncate max-w-full">
            wallet: <span className="text-mempool-text break-all">{wallet.address}</span>
          </span>
        ) : (
          <input
            type="text"
            value={addrInput}
            onChange={(e) => setAddrInput(e.target.value)}
            placeholder="ob1q… (paste address to audit)"
            className="flex-1 min-w-0 sm:min-w-[280px] w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
        )}
        <select
          value={days}
          onChange={(e) => setDays(parseInt(e.target.value, 10))}
          className="bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text focus:outline-none focus:border-mempool-blue"
        >
          <option value={7}>7 days</option>
          <option value={30}>30 days</option>
          <option value={90}>90 days</option>
          <option value={365}>365 days</option>
        </select>
        <button
          onClick={() => void refresh()}
          disabled={loading}
          className="flex items-center gap-1.5 px-3 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-50"
        >
          <RefreshCw className={`w-3.5 h-3.5 ${loading ? "animate-spin" : ""}`} />
          Refresh
        </button>
        <button
          onClick={exportCsv}
          disabled={!resp || sortedRows.length === 0}
          className="flex items-center gap-1.5 px-3 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-green hover:border-mempool-green disabled:opacity-40"
        >
          <Download className="w-3.5 h-3.5" />
          Export CSV
        </button>
      </div>

      {/* Reputation snapshot — current cups (LOVE/FOOD/RENT/VACATION) */}
      {rep && (
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 mb-3">
          {(["love", "food", "rent", "vacation"] as const).map((k) => (
            <div key={k} className="bg-mempool-bg border border-mempool-border rounded p-2.5">
              <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim">{k}</div>
              <div className="text-sm font-mono text-mempool-text mt-0.5">{rep.cups[k]}</div>
            </div>
          ))}
        </div>
      )}

      {/* Window totals — chain-derived, recomputed each render */}
      {resp && (
        <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-2 mb-3">
          <SummaryCell label="TX (window)" value={intFmt.format(totals.txCount)} />
          <SummaryCell label="Sent" value={`${fmtOmni(totals.sent)} OMNI`} />
          <SummaryCell label="Received" value={`${fmtOmni(totals.received)} OMNI`} accent="text-mempool-green" />
          <SummaryCell label="Mining" value={`${fmtOmni(totals.miningReward)} OMNI`} accent="text-mempool-green" />
          <SummaryCell label="Fees burned" value={`${fmtOmni(totals.feesBurned)} OMNI`} accent="text-mempool-orange" />
          <SummaryCell
            label="Stake Δ"
            value={`${totals.stakeChange >= 0 ? "+" : "−"}${fmtOmni(Math.abs(totals.stakeChange))} OMNI`}
            accent={totals.stakeChange >= 0 ? "text-mempool-green" : "text-mempool-orange"}
          />
        </div>
      )}

      {!effectiveAddress && (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          Connect a wallet (or paste an address) to view daily activity.
        </p>
      )}

      {err && (
        <div className="flex items-start gap-2 text-xs text-mempool-orange font-mono bg-mempool-orange/10 border border-mempool-orange/30 rounded px-3 py-2">
          <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5" />
          <span>{err}</span>
        </div>
      )}

      {/* Daily table */}
      {resp && sortedRows.length > 0 && (
        <div className="overflow-x-auto -mx-3 sm:mx-0">
          <table className="w-full min-w-[720px] text-xs font-mono">
            <thead className="sticky top-0 bg-mempool-bg-elev">
              <tr className="text-left text-mempool-text-dim uppercase tracking-wider">
                <SortableTh label="Date" col="date" sortKey={sortKey} sortDir={sortDir} onClick={toggleSort} />
                <th className="py-2 px-2 font-medium text-right">Blocks</th>
                <SortableTh label="TX" col="txCount" sortKey={sortKey} sortDir={sortDir} onClick={toggleSort} align="right" />
                <SortableTh label="Sent" col="sent" sortKey={sortKey} sortDir={sortDir} onClick={toggleSort} align="right" />
                <SortableTh label="Received" col="received" sortKey={sortKey} sortDir={sortDir} onClick={toggleSort} align="right" />
                <SortableTh label="Mining" col="miningReward" sortKey={sortKey} sortDir={sortDir} onClick={toggleSort} align="right" />
                <SortableTh label="Fees" col="feesBurned" sortKey={sortKey} sortDir={sortDir} onClick={toggleSort} align="right" />
                <SortableTh label="Stake Δ" col="stakeChange" sortKey={sortKey} sortDir={sortDir} onClick={toggleSort} align="right" />
              </tr>
            </thead>
            <tbody>
              {sortedRows.map((d) => (
                <tr key={d.dayIndex} className="border-t border-mempool-border/40">
                  <td className="py-2 px-2 text-mempool-text">{dayDate(d, resp)}</td>
                  <td className="py-2 px-2 text-right text-mempool-text-dim">
                    {intFmt.format(d.blockStart)}–{intFmt.format(d.blockEnd)}
                  </td>
                  <td className="py-2 px-2 text-right text-mempool-text">{intFmt.format(d.txCount)}</td>
                  <td className="py-2 px-2 text-right text-mempool-text">{fmtOmni(d.sent)}</td>
                  <td className="py-2 px-2 text-right text-mempool-green">{fmtOmni(d.received)}</td>
                  <td className="py-2 px-2 text-right text-mempool-green">{fmtOmni(d.miningReward)}</td>
                  <td className="py-2 px-2 text-right text-mempool-orange">{fmtOmni(d.feesBurned)}</td>
                  <td className={`py-2 px-2 text-right ${d.stakeChange >= 0 ? "text-mempool-green" : "text-mempool-orange"}`}>
                    {d.stakeChange >= 0 ? "+" : "−"}{fmtOmni(Math.abs(d.stakeChange))}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {resp && sortedRows.length === 0 && !loading && (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          No activity for this address in the selected window.
        </p>
      )}
    </section>
  );
}

function SummaryCell({ label, value, accent }: { label: string; value: string; accent?: string }) {
  return (
    <div className="bg-mempool-bg border border-mempool-border rounded p-2.5">
      <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim">{label}</div>
      <div className={`text-sm font-mono mt-0.5 ${accent ?? "text-mempool-text"}`}>{value}</div>
    </div>
  );
}

function SortableTh({
  label, col, sortKey, sortDir, onClick, align,
}: {
  label: string;
  col: SortKey;
  sortKey: SortKey;
  sortDir: SortDir;
  onClick: (k: SortKey) => void;
  align?: "right";
}) {
  const active = sortKey === col;
  return (
    <th className={`py-2 px-2 font-medium ${align === "right" ? "text-right" : ""}`}>
      <button
        type="button"
        onClick={() => onClick(col)}
        className={`inline-flex items-center gap-1 ${active ? "text-mempool-blue" : "text-mempool-text-dim hover:text-mempool-text"}`}
      >
        {label}
        <ArrowUpDown className="w-3 h-3" />
        {active && <span className="text-[9px]">{sortDir === "asc" ? "↑" : "↓"}</span>}
      </button>
    </th>
  );
}

export default DailyAuditPage;
