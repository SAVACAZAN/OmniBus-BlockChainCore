import { useEffect, useMemo, useState } from "react";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsNewBlockEvent } from "../../types";
import {
  Heart,
  Utensils,
  Wallet as WalletIcon,
  Plane,
  Crown,
  TrendingUp,
  Lock,
  AlertTriangle,
  Activity,
  Sparkles,
} from "lucide-react";
import { rpc } from "../../api/rpc-client";
import { AddressLabel } from "../common/AddressLabel";
import { useWallet } from "../../api/use-wallet";


// ─── Constants ─────────────────────────────────────────────────────────────

type CupKey = "love" | "food" | "rent" | "vacation";

interface CupMeta {
  key: CupKey;
  label: string;
  color: string;       // hex
  bgClass: string;     // tailwind bg
  textClass: string;   // tailwind text
  borderClass: string; // tailwind border
  Icon: typeof Heart;
  desc: string;
}

const CUPS: CupMeta[] = [
  {
    key: "love",
    label: "LOVE",
    color: "#ec4899",
    bgClass: "bg-pink-500",
    textClass: "text-pink-300",
    borderClass: "border-pink-500/40",
    Icon: Heart,
    desc: "Uptime + continuity",
  },
  {
    key: "food",
    label: "FOOD",
    color: "#f97316",
    bgClass: "bg-orange-500",
    textClass: "text-orange-300",
    borderClass: "border-orange-500/40",
    Icon: Utensils,
    desc: "Useful work — mining, oracle, agents",
  },
  {
    key: "rent",
    label: "RENT",
    color: "#22c55e",
    bgClass: "bg-green-500",
    textClass: "text-green-300",
    borderClass: "border-green-500/40",
    Icon: WalletIcon,
    desc: "Capital engaged — stake, LP, hold",
  },
  {
    key: "vacation",
    label: "VACATION",
    color: "#3b82f6",
    bgClass: "bg-blue-500",
    textClass: "text-blue-300",
    borderClass: "border-blue-500/40",
    Icon: Plane,
    desc: "Longevity on-network",
  },
];

const BADGE_META: Record<string, { label: string; cls: string }> = {
  none:    { label: "No badge",  cls: "bg-gray-700/40 text-gray-400" },
  bronze:  { label: "Bronze",    cls: "bg-amber-700/40 text-amber-200" },
  silver:  { label: "Silver",    cls: "bg-slate-400/30 text-slate-100" },
  gold:    { label: "Gold",      cls: "bg-yellow-500/30 text-yellow-200" },
  satoshi: { label: "SATOSHI",   cls: "bg-gradient-to-r from-yellow-500/40 to-orange-500/40 text-yellow-100 border border-yellow-400/60 font-bold" },
};

const HISTORY_KIND_LABEL: Record<string, string> = {
  mined:     "Block mined",
  oracle:    "Oracle push",
  agent:     "Agent decision",
  stake:     "Stake activity",
  hold:      "Capital hold",
  vacation:  "Longevity bonus",
  violation: "Violation",
};

// ─── Types (RPC shapes) ────────────────────────────────────────────────────

interface HistoryEvent {
  block: number;
  kind: string;
  delta: number;     // ×100
  domain: "LOVE" | "FOOD" | "RENT" | "VACATION";
}

interface ReputationData {
  address: string;
  love: number;       // 0-10000 (×100)
  food: number;
  rent: number;
  vacation: number;
  total: number;      // 0-1,000,000
  badge: "none" | "bronze" | "silver" | "gold" | "satoshi";
  last_update_block?: number;
  history?: HistoryEvent[];
  // legacy/optional fields the older RPC may still return
  tier?: string;
  satoshi_badge?: boolean;
  cups?: Record<CupKey, string>;
}

interface LeaderboardEntry {
  rank: number;
  address: string;
  love: number;
  food: number;
  rent: number;
  vacation: number;
  total: number;
  badge: "none" | "bronze" | "silver" | "gold" | "satoshi";
}

type SortKey = "total" | CupKey;
type Tab = "mine" | "earn" | "leaderboard" | "decay";

// ─── Helpers ───────────────────────────────────────────────────────────────

function fmtCup(v: number): string {
  // Backend stores cups as integer ×100. UI shows X.YY out of 100.
  return (v / 100).toFixed(2);
}

function pctCup(v: number): number {
  return Math.min(100, Math.max(0, v / 100));
}

// Normalize whatever shape the node returns into our internal ReputationData.
// Older builds returned `cups: { love: "12.07", … }` (already divided by 100).
function normalizeRep(raw: any): ReputationData | null {
  if (!raw || typeof raw !== "object") return null;
  const numericLove = typeof raw.love === "number" ? raw.love : null;
  if (numericLove !== null) {
    return raw as ReputationData;
  }
  // Legacy shape with .cups string values
  if (raw.cups && typeof raw.cups === "object") {
    const c = raw.cups;
    const toInt = (s: any) => Math.round(parseFloat(String(s ?? "0")) * 100);
    return {
      address: raw.address,
      love: toInt(c.love),
      food: toInt(c.food),
      rent: toInt(c.rent),
      vacation: toInt(c.vacation),
      total: raw.total ?? 0,
      badge: raw.satoshi_badge ? "satoshi" : (raw.badge ?? "none"),
      tier: raw.tier,
      history: raw.history,
      last_update_block: raw.last_update_block,
    };
  }
  return null;
}

function normalizeLeaderboard(raw: any): LeaderboardEntry[] {
  if (!raw) return [];
  const entries = Array.isArray(raw) ? raw : raw.entries;
  if (!Array.isArray(entries)) return [];
  return entries.map((e: any, idx: number) => {
    const numericLove = typeof e.love === "number" ? e.love : null;
    if (numericLove !== null) {
      return {
        rank: e.rank ?? idx + 1,
        address: e.address,
        love: e.love,
        food: e.food,
        rent: e.rent,
        vacation: e.vacation,
        total: e.total ?? 0,
        badge: e.badge ?? (e.satoshi_badge ? "satoshi" : "none"),
      } as LeaderboardEntry;
    }
    const c = e.cups || {};
    const toInt = (s: any) => Math.round(parseFloat(String(s ?? "0")) * 100);
    return {
      rank: e.rank ?? idx + 1,
      address: e.address,
      love: toInt(c.love),
      food: toInt(c.food),
      rent: toInt(c.rent),
      vacation: toInt(c.vacation),
      total: e.total ?? 0,
      badge: e.satoshi_badge ? "satoshi" : (e.badge ?? "none"),
    } as LeaderboardEntry;
  });
}

// ─── Sub-components ────────────────────────────────────────────────────────

function BigCup({ cup, value, animated }: { cup: CupMeta; value: number; animated: boolean }) {
  const pct = pctCup(value);
  const Icon = cup.Icon;
  return (
    <div
      className={`relative bg-mempool-bg-elev rounded-xl border ${cup.borderClass} p-2 sm:p-3 md:p-4 overflow-hidden`}
      style={{ minHeight: 200 }}
    >
      <div className="flex items-center justify-between mb-2 sm:mb-3">
        <div className={`flex items-center gap-1 sm:gap-2 ${cup.textClass} font-semibold uppercase tracking-wider text-[11px] sm:text-sm min-w-0`}>
          <Icon size={16} className="flex-shrink-0" />
          <span className="truncate">{cup.label}</span>
        </div>
        <span className="text-[10px] text-mempool-text-dim flex-shrink-0">/100</span>
      </div>

      {/* Cup body */}
      <div className="relative mx-auto w-20 h-28 sm:w-24 sm:h-32 rounded-b-3xl rounded-t-md border-2 border-mempool-border bg-mempool-bg overflow-hidden">
        <div
          className="absolute bottom-0 left-0 right-0 transition-[height] ease-out duration-1000"
          style={{
            height: animated ? `${pct}%` : "0%",
            background: `linear-gradient(180deg, ${cup.color}cc 0%, ${cup.color} 100%)`,
            boxShadow: `inset 0 -8px 16px ${cup.color}66`,
          }}
        />
        <div className="absolute inset-0 flex items-center justify-center">
          <span className="font-mono text-lg sm:text-2xl font-bold text-white drop-shadow-lg">
            {fmtCup(value)}
          </span>
        </div>
      </div>

      <p className="text-[10px] sm:text-[11px] text-mempool-text-dim mt-2 sm:mt-3 text-center leading-tight">{cup.desc}</p>
    </div>
  );
}

function BadgePill({ badge }: { badge: ReputationData["badge"] }) {
  const meta = BADGE_META[badge] || BADGE_META.none;
  return (
    <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded text-[10px] uppercase tracking-wider ${meta.cls}`}>
      {badge === "satoshi" && <Crown size={10} />}
      {meta.label}
    </span>
  );
}

function SatoshiBadge({ achieved }: { achieved: boolean }) {
  if (!achieved) {
    return (
      <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev p-3 sm:p-4 md:p-5 flex items-center gap-3 sm:gap-4">
        <div className="w-12 h-12 sm:w-14 sm:h-14 rounded-full bg-mempool-bg flex items-center justify-center text-mempool-text-dim flex-shrink-0">
          <Lock size={24} />
        </div>
        <div className="min-w-0">
          <h3 className="font-semibold text-mempool-text mb-0.5 text-sm sm:text-base">Satoshi Badge — locked</h3>
          <p className="text-xs text-mempool-text-dim">Reach 100/100/100/100 across all four cups to unlock.</p>
        </div>
      </div>
    );
  }
  return (
    <div
      className="relative rounded-xl border-2 border-yellow-400/70 p-3 sm:p-4 md:p-5 flex items-center gap-3 sm:gap-4 overflow-hidden"
      style={{
        background: "linear-gradient(135deg, rgba(234,179,8,0.18), rgba(249,115,22,0.18))",
        animation: "satoshiGlow 3s ease-in-out infinite",
      }}
    >
      <style>{`
        @keyframes satoshiGlow {
          0%, 100% { box-shadow: 0 0 18px rgba(234,179,8,0.30); }
          50%      { box-shadow: 0 0 36px rgba(234,179,8,0.65); }
        }
      `}</style>
      <div className="w-12 h-12 sm:w-14 sm:h-14 rounded-full bg-gradient-to-br from-yellow-400 to-orange-500 flex items-center justify-center text-white shadow-lg flex-shrink-0">
        <Crown size={26} />
      </div>
      <div className="min-w-0">
        <h3 className="font-bold text-yellow-200 text-base sm:text-lg flex items-center gap-2">
          Satoshi Badge <Sparkles size={16} className="text-yellow-300" />
        </h3>
        <p className="text-xs text-yellow-100/80">Financial-independence achievement — permanent. All four cups full.</p>
      </div>
    </div>
  );
}

function MiniCup({ value, color }: { value: number; color: string }) {
  const pct = pctCup(value);
  return (
    <div className="flex flex-col items-center gap-0.5">
      <div className="w-8 h-2 bg-mempool-border/60 rounded-full overflow-hidden">
        <div className="h-full transition-all" style={{ width: `${pct}%`, background: color }} />
      </div>
      <span className="text-[9px] font-mono text-mempool-text-dim">{fmtCup(value)}</span>
    </div>
  );
}

// ─── Tab: My Reputation ────────────────────────────────────────────────────

function TabMine({ data, animated }: { data: ReputationData | null; animated: boolean }) {
  if (!data) {
    return (
      <div className="p-8 text-center text-mempool-text-dim text-sm">
        No reputation data for this address yet. Mine a block, push an oracle update, or stake to start filling cups.
      </div>
    );
  }
  const totalPct = Math.min(100, (data.total / 1_000_000) * 100);
  const allFull = data.love >= 10000 && data.food >= 10000 && data.rent >= 10000 && data.vacation >= 10000;
  const isSatoshi = data.badge === "satoshi" || allFull;
  const events: HistoryEvent[] = (data.history || []).slice(0, 30);

  return (
    <div className="space-y-6">
      {/* 4 large cups — 2 cols on phone, 4 on tablets+ */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 sm:gap-3 md:gap-4">
        {CUPS.map((c) => (
          <BigCup key={c.key} cup={c} value={data[c.key]} animated={animated} />
        ))}
      </div>

      {/* Total reputation */}
      <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev p-3 sm:p-4">
        <div className="flex items-center justify-between mb-2 flex-wrap gap-2">
          <div className="flex items-center gap-2 text-mempool-text font-semibold text-sm">
            <TrendingUp size={16} className="text-mempool-blue flex-shrink-0" />
            Total Reputation
          </div>
          <div className="flex items-center gap-2 flex-wrap">
            <BadgePill badge={data.badge} />
            <span className="font-mono text-xs sm:text-sm text-mempool-text">
              {data.total.toLocaleString()} <span className="text-mempool-text-dim">/ 1,000,000</span>
            </span>
          </div>
        </div>
        <div className="h-3 bg-mempool-border rounded-full overflow-hidden">
          <div
            className="h-full bg-gradient-to-r from-pink-500 via-orange-500 via-green-500 to-blue-500 transition-all duration-1000"
            style={{ width: animated ? `${totalPct}%` : "0%" }}
          />
        </div>
      </div>

      <SatoshiBadge achieved={isSatoshi} />

      {/* History */}
      <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev overflow-hidden">
        <div className="px-4 py-2 border-b border-mempool-border flex items-center gap-2 text-sm">
          <Activity size={14} className="text-mempool-blue" />
          <span className="font-semibold text-mempool-text">Recent activity</span>
          <span className="text-xs text-mempool-text-dim">last {events.length} events</span>
        </div>
        {events.length === 0 ? (
          <div className="p-6 text-center text-mempool-text-dim text-sm">No events yet.</div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-xs sm:text-sm min-w-[420px]">
              <thead>
                <tr className="border-b border-mempool-border/60 bg-mempool-bg/40 text-[10px] uppercase tracking-wider text-mempool-text-dim">
                  <th className="text-left px-3 py-1.5">Block</th>
                  <th className="text-left px-3 py-1.5">Source</th>
                  <th className="text-left px-3 py-1.5">Domain</th>
                  <th className="text-right px-3 py-1.5">Delta</th>
                </tr>
              </thead>
              <tbody>
                {events.map((ev, i) => {
                  const cup = CUPS.find((c) => c.label === ev.domain);
                  return (
                    <tr key={`${ev.block}:${ev.kind}:${i}`} className="border-b border-mempool-border/30 hover:bg-mempool-bg/40">
                      <td className="px-3 py-1.5 font-mono text-xs text-mempool-text-dim">#{ev.block}</td>
                      <td className="px-3 py-1.5 text-xs text-mempool-text">
                        {HISTORY_KIND_LABEL[ev.kind] || ev.kind}
                      </td>
                      <td className="px-3 py-1.5">
                        {cup ? (
                          <span className={`inline-flex items-center gap-1 text-xs ${cup.textClass}`}>
                            <cup.Icon size={11} /> {ev.domain}
                          </span>
                        ) : (
                          <span className="text-xs text-mempool-text-dim">{ev.domain}</span>
                        )}
                      </td>
                      <td className={`px-3 py-1.5 text-right font-mono text-xs ${ev.delta >= 0 ? "text-green-400" : "text-red-400"}`}>
                        {ev.delta >= 0 ? "+" : ""}{(ev.delta / 100).toFixed(2)}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}

// ─── Tab: How to Earn ──────────────────────────────────────────────────────

interface EarnRule { label: string; rate: string; }
interface EarnSection { cup: CupMeta; rules: EarnRule[]; }

const EARN_RULES: EarnSection[] = [
  {
    cup: CUPS[0],
    rules: [
      { label: "Online (per minute)",      rate: "+0.01" },
      { label: "Daily streak (per day)",   rate: "+0.10" },
      { label: "Clean week (no downtime)", rate: "+1.00" },
    ],
  },
  {
    cup: CUPS[1],
    rules: [
      { label: "Block mined",          rate: "+0.01" },
      { label: "PoUW report accepted", rate: "+0.10" },
      { label: "Oracle push",          rate: "+0.01" },
      { label: "Agent decision OK",    rate: "+0.10" },
      { label: "Arbitrage profit",     rate: "+1.00" },
    ],
  },
  {
    cup: CUPS[2],
    rules: [
      { label: "Per OMNI staked × day", rate: "+0.10" },
      { label: "Validator tier 2 / day", rate: "+0.50" },
      { label: "Validator tier 3 / day", rate: "+1.00" },
      { label: "Validator tier 4 / day", rate: "+2.00" },
    ],
  },
  {
    cup: CUPS[3],
    rules: [
      { label: "Daily base",         rate: "+0.03" },
      { label: "30-day milestone",   rate: "+1.00" },
      { label: "100-day milestone",  rate: "+3.00" },
      { label: "365-day milestone",  rate: "+10.00" },
    ],
  },
];

function TabEarn() {
  return (
    <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 sm:gap-4">
      {EARN_RULES.map(({ cup, rules }) => {
        const Icon = cup.Icon;
        return (
          <div key={cup.key} className={`rounded-xl border ${cup.borderClass} bg-mempool-bg-elev p-3 sm:p-4`}>
            <div className={`flex items-center gap-2 mb-3 ${cup.textClass} font-semibold uppercase tracking-wider text-sm`}>
              <Icon size={16} />
              <span>{cup.label}</span>
              <span className="text-[10px] text-mempool-text-dim font-normal normal-case ml-auto">{cup.desc}</span>
            </div>
            <table className="w-full text-sm">
              <tbody>
                {rules.map((r) => (
                  <tr key={r.label} className="border-b border-mempool-border/30 last:border-b-0">
                    <td className="py-1.5 text-mempool-text">{r.label}</td>
                    <td className="py-1.5 text-right font-mono text-green-400">{r.rate}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        );
      })}
      <div className="sm:col-span-2 rounded-xl border border-mempool-border bg-mempool-bg-elev p-3 sm:p-4">
        <p className="text-xs text-mempool-text-dim leading-relaxed">
          Each cup is capped at 100. Once full it stops accepting deposits in that domain — your effort
          shifts to whichever cup still has room. Hit <strong className="text-yellow-300">100/100/100/100</strong>
          {" "}and the Satoshi badge unlocks permanently. Total reputation (0–1,000,000) is a weighted aggregate;
          ranking between Satoshi holders is broken by lifetime uptime.
        </p>
      </div>
    </div>
  );
}

// ─── Tab: Leaderboard ──────────────────────────────────────────────────────

function TabLeaderboard({
  entries,
  loading,
  sortBy,
  setSortBy,
  onCopy,
}: {
  entries: LeaderboardEntry[];
  loading: boolean;
  sortBy: SortKey;
  setSortBy: (k: SortKey) => void;
  onCopy: (addr: string) => void;
}) {
  const sortOptions: Array<{ key: SortKey; label: string }> = [
    { key: "total", label: "Total" },
    { key: "love", label: "LOVE" },
    { key: "food", label: "FOOD" },
    { key: "rent", label: "RENT" },
    { key: "vacation", label: "VACATION" },
  ];

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2 flex-wrap">
        <span className="text-xs text-mempool-text-dim">Sort by:</span>
        {sortOptions.map((o) => (
          <button
            key={o.key}
            onClick={() => setSortBy(o.key)}
            className={`px-3 py-1.5 text-xs rounded transition-colors ${
              sortBy === o.key
                ? "bg-mempool-blue text-white"
                : "bg-mempool-bg-elev text-mempool-text-dim hover:text-mempool-text"
            }`}
          >
            {o.label}
          </button>
        ))}
        <div className="ml-auto flex items-center gap-2">
          <span className="text-xs text-mempool-text-dim">Top 100</span>
          {entries.length > 0 && (
            <button
              onClick={() => {
                const rows = [
                  ["rank", "address", "love", "food", "rent", "vacation", "total", "badge"].join(","),
                  ...entries.map((e) => [
                    e.rank,
                    `"${e.address}"`,
                    (e.love / 100).toFixed(2),
                    (e.food / 100).toFixed(2),
                    (e.rent / 100).toFixed(2),
                    (e.vacation / 100).toFixed(2),
                    e.total,
                    e.badge,
                  ].join(",")),
                ].join("\n");
                const blob = new Blob([rows], { type: "text/csv" });
                const url = URL.createObjectURL(blob);
                const a = document.createElement("a");
                a.href = url; a.download = "omnibus-reputation-leaderboard.csv";
                a.click(); URL.revokeObjectURL(url);
              }}
              className="text-[10px] px-2 py-1 bg-mempool-bg-elev border border-mempool-border rounded text-mempool-text-dim hover:text-mempool-text transition-colors font-mono"
            >
              ⬇ CSV
            </button>
          )}
        </div>
      </div>

      <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev overflow-hidden">
        {loading && entries.length === 0 ? (
          <div className="p-8 text-center text-mempool-text-dim text-sm">Loading leaderboard…</div>
        ) : entries.length === 0 ? (
          <div className="p-8 text-center text-mempool-text-dim text-sm">No entries yet.</div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-xs sm:text-sm min-w-[640px]">
              <thead>
                <tr className="border-b border-mempool-border bg-mempool-bg/50 text-[10px] uppercase tracking-wider text-mempool-text-dim">
                  <th className="text-left px-3 py-2 w-12">#</th>
                  <th className="text-left px-3 py-2">Address</th>
                  {CUPS.map((c) => (
                    <th key={c.key} className="text-center px-2 py-2 w-16">{c.label}</th>
                  ))}
                  <th className="text-right px-3 py-2 w-28">Total</th>
                  <th className="text-center px-3 py-2 w-20">Badge</th>
                </tr>
              </thead>
              <tbody>
                {entries.map((e) => {
                  const isSatoshi = e.badge === "satoshi";
                  return (
                    <tr
                      key={e.address}
                      className={`border-b border-mempool-border/40 hover:bg-mempool-bg/30 ${
                        isSatoshi ? "bg-gradient-to-r from-yellow-500/10 to-transparent" : ""
                      }`}
                      style={isSatoshi ? { boxShadow: "inset 0 0 0 1px rgba(234,179,8,0.45)" } : undefined}
                    >
                      <td className="px-3 py-2 font-mono text-xs text-mempool-text-dim">
                        {isSatoshi ? <span className="text-yellow-400 font-bold">★{e.rank}</span> : e.rank}
                      </td>
                      <td className="px-3 py-2 font-mono text-xs">
                        <button
                          onClick={() => { window.location.hash = `#/address/${e.address}`; }}
                          className="text-mempool-blue hover:underline"
                          title={e.address}
                        >
                          <AddressLabel address={e.address} showEmoji truncate={{ left: 8, right: 6 }} />
                        </button>
                      </td>
                      {CUPS.map((c) => (
                        <td key={c.key} className="px-2 py-2 text-center">
                          <MiniCup value={e[c.key]} color={c.color} />
                        </td>
                      ))}
                      <td className="px-3 py-2 text-right font-mono text-xs text-mempool-text">
                        {e.total.toLocaleString()}
                      </td>
                      <td className="px-3 py-2 text-center">
                        <BadgePill badge={e.badge} />
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}

// ─── Tab: Decay & Penalties ────────────────────────────────────────────────

function TabDecay({ violations }: { violations: HistoryEvent[] }) {
  return (
    <div className="space-y-4">
      <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-3 sm:gap-4">
        <div className="rounded-xl border border-pink-500/40 bg-mempool-bg-elev p-3 sm:p-4">
          <div className="flex items-center gap-2 text-pink-300 font-semibold uppercase tracking-wider text-sm mb-2">
            <Heart size={16} /> LOVE decay
          </div>
          <p className="text-xs text-mempool-text-dim leading-relaxed">
            Inactive past 30 days: <span className="font-mono text-pink-300">−0.05 / day</span>.
            Goes back to filling once you are online again.
          </p>
        </div>
        <div className="rounded-xl border border-green-500/40 bg-mempool-bg-elev p-3 sm:p-4">
          <div className="flex items-center gap-2 text-green-300 font-semibold uppercase tracking-wider text-sm mb-2">
            <WalletIcon size={16} /> RENT penalty
          </div>
          <p className="text-xs text-mempool-text-dim leading-relaxed">
            Per unstake event: <span className="font-mono text-red-400">−5.00</span>.
            Hard-coded; covers the trust signal lost when capital exits.
          </p>
        </div>
        <div className="rounded-xl border border-orange-500/40 bg-mempool-bg-elev p-3 sm:p-4 sm:col-span-2 md:col-span-1">
          <div className="flex items-center gap-2 text-orange-300 font-semibold uppercase tracking-wider text-sm mb-2">
            <Utensils size={16} /> FOOD penalty
          </div>
          <p className="text-xs text-mempool-text-dim leading-relaxed">
            Invalid PoUW report: <span className="font-mono text-red-400">−0.50</span>.
            Repeat violations get amplified by the peer-scoring layer.
          </p>
        </div>
      </div>

      <div className="rounded-xl border border-red-500/40 bg-mempool-bg-elev overflow-hidden">
        <div className="px-4 py-2 border-b border-red-500/30 flex items-center gap-2 text-sm">
          <AlertTriangle size={14} className="text-red-400" />
          <span className="font-semibold text-mempool-text">Recent violations</span>
        </div>
        {violations.length === 0 ? (
          <div className="p-6 text-center text-mempool-text-dim text-sm">
            Your record is clean — no violations or penalties on file.
          </div>
        ) : (
          <div className="overflow-x-auto">
          <table className="w-full text-xs sm:text-sm min-w-[360px]">
            <thead>
              <tr className="border-b border-mempool-border/60 bg-mempool-bg/40 text-[10px] uppercase tracking-wider text-mempool-text-dim">
                <th className="text-left px-3 py-1.5">Block</th>
                <th className="text-left px-3 py-1.5">Domain</th>
                <th className="text-right px-3 py-1.5">Penalty</th>
              </tr>
            </thead>
            <tbody>
              {violations.map((v, i) => (
                <tr key={`${v.block}:${v.domain}:${i}`} className="border-b border-mempool-border/30">
                  <td className="px-3 py-1.5 font-mono text-xs text-mempool-text-dim">#{v.block}</td>
                  <td className="px-3 py-1.5 text-xs text-mempool-text">{v.domain}</td>
                  <td className="px-3 py-1.5 text-right font-mono text-xs text-red-400">
                    {(v.delta / 100).toFixed(2)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          </div>
        )}
      </div>
    </div>
  );
}

// ─── Page ──────────────────────────────────────────────────────────────────

export function ReputationPage() {
  const wallet = useWallet();
  const [tab, setTab] = useState<Tab>("mine");
  const [search, setSearch] = useState("");
  const [data, setData] = useState<ReputationData | null>(null);
  const [leaderboard, setLeaderboard] = useState<LeaderboardEntry[]>([]);
  const [sortBy, setSortBy] = useState<SortKey>("total");
  const [loadingMine, setLoadingMine] = useState(false);
  const [loadingTop, setLoadingTop] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [methodMissing, setMethodMissing] = useState(false);
  const [animated, setAnimated] = useState(false);

  // Animate cups on tab switch to "mine"
  useEffect(() => {
    if (tab === "mine") {
      setAnimated(false);
      const t = setTimeout(() => setAnimated(true), 50);
      return () => clearTimeout(t);
    }
  }, [tab, data]);

  // Auto-fill search with connected wallet
  useEffect(() => {
    if (wallet?.address && !search) setSearch(wallet.address);
  }, [wallet, search]);

  // Fetch personal reputation
  const fetchMine = async (addr: string) => {
    if (!addr) return;
    setLoadingMine(true);
    try {
      const raw = await rpc.getReputation(addr);
      const norm = normalizeRep(raw);
      setData(norm);
      setError(null);
      setMethodMissing(false);
    } catch (e: any) {
      const msg = e?.message || "RPC error";
      if (msg.includes("Method not found") || msg.includes("-32601")) setMethodMissing(true);
      else setError(msg);
    } finally {
      setLoadingMine(false);
    }
  };

  // Fetch leaderboard
  useEffect(() => {
    let cancelled = false;
    const run = async () => {
      try {
        const raw = await rpc.getReputationTop(sortBy, 100);
        if (!cancelled) {
          setLeaderboard(normalizeLeaderboard(raw));
          setMethodMissing(false);
        }
      } catch (e: any) {
        if (cancelled) return;
        const msg = e?.message || "RPC error";
        if (msg.includes("Method not found") || msg.includes("-32601")) setMethodMissing(true);
        else setError(msg);
      } finally {
        if (!cancelled) setLoadingTop(false);
      }
    };
    void run();
    // Reputation updates per-block (mining, staking rewards) — refresh on new_block.
    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", () => { void run(); });
    const id = setInterval(() => { void run(); }, 60_000);
    return () => { cancelled = true; clearInterval(id); unsub(); };
  }, [sortBy]);

  // Auto-load mine when wallet/address changes
  useEffect(() => {
    if (search) fetchMine(search);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [wallet?.address]);

  const violations = useMemo(() => {
    return (data?.history || []).filter((h) => h.kind === "violation" || h.delta < 0).slice(0, 30);
  }, [data]);

  const tabs: Array<{ key: Tab; label: string }> = [
    { key: "mine",        label: "My Reputation" },
    { key: "earn",        label: "How to Earn" },
    { key: "leaderboard", label: "Leaderboard" },
    { key: "decay",       label: "Decay & Penalties" },
  ];

  return (
    <div className="max-w-6xl mx-auto px-3 sm:px-4 py-4 sm:py-6 md:py-8">
      <h1 className="text-base sm:text-lg md:text-2xl font-bold text-mempool-text mb-1 flex items-center gap-2">
        <Crown size={22} className="text-yellow-400 flex-shrink-0" /> Reputation
      </h1>
      <p className="text-mempool-text-dim text-xs sm:text-sm mb-4 sm:mb-5">
        Four soulbound cups (LOVE / FOOD / RENT / VACATION), each 0–100. Fill all four to earn the Satoshi badge —
        permanent, non-transferable, your on-chain track record.
      </p>

      {methodMissing && (
        <div className="mb-5 p-3 rounded-lg border border-amber-500/40 bg-amber-500/10 text-amber-200 text-xs">
          The connected node does not yet expose <code>getreputation</code> RPC — older build. Reputation will appear once the node is upgraded.
        </div>
      )}
      {error && !methodMissing && (
        <div className="mb-5 p-3 rounded-lg border border-red-500/40 bg-red-500/10 text-red-300 text-xs">
          RPC error: {error}
        </div>
      )}

      {/* Search bar (used by My Reputation tab) */}
      {tab === "mine" && (
        <div className="mb-4 sm:mb-5 flex flex-col sm:flex-row gap-2">
          <input
            type="text"
            placeholder="Address (ob1q…) — defaults to connected wallet"
            value={search}
            onChange={(e) => setSearch(e.target.value.trim())}
            onKeyDown={(e) => { if (e.key === "Enter") fetchMine(search); }}
            className="flex-1 min-w-0 bg-mempool-bg-elev border border-mempool-border rounded px-3 py-2.5 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
          <button
            onClick={() => fetchMine(search)}
            disabled={loadingMine}
            className="px-4 py-2.5 text-sm bg-mempool-blue text-white rounded hover:bg-blue-500 disabled:opacity-50"
          >
            {loadingMine ? "Loading…" : "Lookup"}
          </button>
        </div>
      )}

      {/* Tabs */}
      <div className="border-b border-mempool-border mb-4 sm:mb-5 flex gap-1 overflow-x-auto scrollbar-none">
        {tabs.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className={`flex-shrink-0 px-3 sm:px-4 py-2.5 text-xs sm:text-sm border-b-2 transition-colors whitespace-nowrap ${
              tab === t.key
                ? "border-mempool-blue text-mempool-text"
                : "border-transparent text-mempool-text-dim hover:text-mempool-text"
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {tab === "mine" && <TabMine data={data} animated={animated} />}
      {tab === "earn" && <TabEarn />}
      {tab === "leaderboard" && (
        <TabLeaderboard
          entries={leaderboard}
          loading={loadingTop}
          sortBy={sortBy}
          setSortBy={setSortBy}
          onCopy={(a) => navigator.clipboard.writeText(a)}
        />
      )}
      {tab === "decay" && <TabDecay violations={violations} />}
    </div>
  );
}

export default ReputationPage;

// ── Social Follow Panel ────────────────────────────────────────────────────
// Covers: follow, unfollow, getfollowers, getfollowing RPCs

export function SocialFollowPanel({ address }: { address: string }) {
  const [followers, setFollowers] = useState<string[]>([]);
  const [following, setFollowing] = useState<string[]>([]);
  const [followTarget, setFollowTarget] = useState("");
  const [loading, setLoading] = useState(false);
  const [actionErr, setActionErr] = useState<string | null>(null);
  const [actionMsg, setActionMsg] = useState<string | null>(null);

  const loadSocial = async () => {
    if (!address) return;
    setLoading(true);
    try {
      const [frs, fing] = await Promise.all([
        rpc.getFollowers(address),
        rpc.getFollowing(address),
      ]);
      setFollowers(frs);
      setFollowing(fing);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { void loadSocial(); }, [address]); // eslint-disable-line

  const doFollow = async () => {
    if (!followTarget.trim()) return;
    setActionErr(null);
    setActionMsg(null);
    try {
      await rpc.follow(address, followTarget.trim());
      setActionMsg(`Following ${followTarget.trim().slice(0, 14)}…`);
      setFollowTarget("");
      await loadSocial();
    } catch (e: any) {
      setActionErr(e?.message ?? String(e));
    }
  };

  const doUnfollow = async (target: string) => {
    setActionErr(null);
    setActionMsg(null);
    try {
      await rpc.unfollow(address, target);
      setActionMsg(`Unfollowed ${target.slice(0, 14)}…`);
      await loadSocial();
    } catch (e: any) {
      setActionErr(e?.message ?? String(e));
    }
  };

  return (
    <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4 space-y-4">
      <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
        Social Graph
      </h3>

      <div className="flex gap-2">
        <input
          value={followTarget}
          onChange={(e) => setFollowTarget(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && doFollow()}
          className="flex-1 bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
          placeholder="ob1q… address to follow"
        />
        <button
          onClick={doFollow}
          disabled={!followTarget.trim()}
          className="px-3 py-1.5 text-xs bg-green-500/20 hover:bg-green-500/30 text-green-300 border border-green-500/30 rounded disabled:opacity-50 whitespace-nowrap"
        >
          Follow
        </button>
      </div>
      {actionErr && <p className="text-[11px] text-red-400">{actionErr}</p>}
      {actionMsg && <p className="text-[11px] text-green-400">{actionMsg}</p>}

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 text-xs">
        <div>
          <h4 className="text-[10px] uppercase text-mempool-text-dim mb-1.5">
            Following ({following.length})
          </h4>
          {loading ? (
            <p className="text-mempool-text-dim animate-pulse text-[10px]">Loading…</p>
          ) : following.length === 0 ? (
            <p className="text-mempool-text-dim text-[10px]">Not following anyone.</p>
          ) : (
            <div className="space-y-1">
              {following.map((f) => (
                <div key={f} className="flex items-center justify-between gap-2 font-mono text-[10px]">
                  <span className="text-mempool-text truncate">{f.slice(0, 16)}…</span>
                  <button
                    onClick={() => doUnfollow(f)}
                    className="text-red-400 hover:text-red-300 text-[9px] shrink-0"
                  >
                    Unfollow
                  </button>
                </div>
              ))}
            </div>
          )}
        </div>

        <div>
          <h4 className="text-[10px] uppercase text-mempool-text-dim mb-1.5">
            Followers ({followers.length})
          </h4>
          {loading ? (
            <p className="text-mempool-text-dim animate-pulse text-[10px]">Loading…</p>
          ) : followers.length === 0 ? (
            <p className="text-mempool-text-dim text-[10px]">No followers yet.</p>
          ) : (
            <div className="space-y-1">
              {followers.map((f) => (
                <div key={f} className="font-mono text-[10px] text-mempool-text truncate">
                  {f.slice(0, 20)}…
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
