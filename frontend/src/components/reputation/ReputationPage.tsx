import { useEffect, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import { useWallet } from "../../api/use-wallet";

const rpc = new OmniBusRpcClient();

// Each cup = 1 PQ domain (vezi WalletPage.tsx + memory/reputation_economy.md).
const CUPS = [
  { key: "love",     label: "LOVE",     emoji: "❤️",   color: "bg-rose-500",    text: "text-rose-300",    desc: "Uptime + continuitate" },
  { key: "food",     label: "FOOD",     emoji: "🥖",   color: "bg-amber-500",   text: "text-amber-300",   desc: "Work util — mining, oracle, agents" },
  { key: "rent",     label: "RENT",     emoji: "🏠",   color: "bg-orange-500",  text: "text-orange-300",  desc: "Capital angajat — stake, LP, hold" },
  { key: "vacation", label: "VACATION", emoji: "🏖️",  color: "bg-cyan-500",    text: "text-cyan-300",    desc: "Longevitate pe rețea" },
] as const;

type CupKey = typeof CUPS[number]["key"];

type Cups = Record<CupKey, string>; // strings ca "12.07"

type ReputationEntry = {
  rank: number;
  address: string;
  total: number;
  tier: string;
  cups: Cups;
  satoshi_badge: boolean;
  is_zen: boolean;
  blocks_mined: number;
  first_active_block: number;
  uptime_blocks: number;
};

type TopResp = {
  count: number;
  total: number;
  entries: ReputationEntry[];
};

const TIER_COLOR: Record<string, string> = {
  OMNI:     "bg-gray-700/60 text-gray-300",
  LOVE:     "bg-rose-500/20 text-rose-300",
  FOOD:     "bg-amber-500/20 text-amber-300",
  RENT:     "bg-orange-500/20 text-orange-300",
  VACATION: "bg-cyan-500/20 text-cyan-300",
  // Zen = financial independence achievement. Permanent. Aur stralucitor.
  ZEN:      "bg-gradient-to-r from-orange-500/30 to-yellow-500/30 text-yellow-200 border border-yellow-500/50 font-bold",
};

export function ReputationPage() {
  const wallet = useWallet();
  const [top, setTop] = useState<TopResp | null>(null);
  const [search, setSearch] = useState("");
  const [searchResult, setSearchResult] = useState<ReputationEntry | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [methodMissing, setMethodMissing] = useState(false);
  const [limit, setLimit] = useState(50);

  // Auto-fill the address search with the connected wallet so users see their
  // own reputation immediately on page open.
  useEffect(() => {
    if (wallet && !search) setSearch(wallet.address);
  }, [wallet, search]);

  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      try {
        // Pass limit as positional array string (handler accepts both array
        // arg and "limit" object key). Avoid object wrap which depends on
        // backend extractStr quirks.
        const r = (await rpc.request_raw("getreputationtop", [String(limit)])) as TopResp;
        if (!cancelled) {
          // Defensive: result may have shape {entries: [...], count, total}
          // OR be wrapped by an outer object on some node versions.
          const safe: TopResp = (r && typeof r === "object" && Array.isArray((r as any).entries))
            ? r
            : { count: 0, total: 0, entries: [] };
          setTop(safe);
          setError(null);
          setMethodMissing(false);
        }
      } catch (e: any) {
        if (cancelled) return;
        const msg = e?.message || "RPC error";
        if (msg.includes("Method not found") || msg.includes("-32601")) setMethodMissing(true);
        else setError(msg);
      } finally {
        if (!cancelled) setLoading(false);
      }
    };
    refresh();
    const id = setInterval(refresh, 8000);
    return () => { cancelled = true; clearInterval(id); };
  }, [limit]);

  const lookupAddress = async () => {
    if (!search.trim()) return;
    try {
      const r: any = await rpc.request_raw("getreputation", [search.trim()]);
      // Normalize getreputation result into a ReputationEntry-like shape.
      setSearchResult({
        rank: 0,
        address: r.address,
        total: r.total,
        tier: r.tier,
        cups: r.cups,
        satoshi_badge: r.satoshi_badge,
        is_zen: r.is_zen ?? r.satoshi_badge,
        blocks_mined: r.total_blocks_mined,
        first_active_block: r.first_active_block,
        uptime_blocks: r.uptime_blocks ?? 0,
      });
    } catch (e: any) {
      setError(e?.message || "Lookup failed");
    }
  };

  const cupValue = (cups: Cups, key: CupKey): number => parseFloat(cups[key] || "0");

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      <h1 className="text-2xl font-bold text-mempool-text mb-2 flex items-center gap-3">
        <span>Reputation</span>
        <span className="text-sm text-mempool-text-dim font-normal">
          ❤️ 🥖 🏠 🏖️ <span className="opacity-60">soulbound</span>
        </span>
      </h1>
      <p className="text-mempool-text-dim text-sm mb-6">
        4 paharele soulbound (0–100 fiecare). Praguri etapizate cu beneficii reale în ecosistem.
        Toate paharele 100/100 = <span className="text-yellow-400 font-bold">🏆 ZEN</span> — financial
        independence achievement, permanent. Post-Zen, ranking-ul continuă cu{" "}
        <code className="text-mempool-text">uptime_blocks</code> ca tiebreaker (memory:
        validator vision — imposibil de cumpărat retroactiv). Nu se transferă, nu se vinde.
      </p>

      {methodMissing && (
        <div className="mb-6 p-4 rounded-lg border border-amber-500/40 bg-amber-500/10 text-amber-200 text-sm">
          <p className="font-semibold mb-1">Reputation system not exposed by this node.</p>
          <p>The connected node does not expose <code>getreputation</code> RPC — older build.</p>
        </div>
      )}

      {/* Search */}
      <div className="mb-6 flex gap-2">
        <input
          type="text"
          placeholder="Search address (ob1q…)"
          value={search}
          onChange={(e) => setSearch(e.target.value.trim())}
          onKeyDown={(e) => { if (e.key === "Enter") lookupAddress(); }}
          className="flex-1 bg-mempool-bg-elev border border-mempool-border rounded px-3 py-2 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
        />
        <button
          onClick={lookupAddress}
          className="px-4 py-2 text-sm bg-mempool-blue text-white rounded hover:bg-blue-500"
        >
          Lookup
        </button>
      </div>

      {/* Search result detail card */}
      {searchResult && (
        <div className="mb-6 rounded-lg border border-mempool-blue/40 bg-mempool-bg-elev p-4">
          <div className="flex items-start gap-4 flex-wrap">
            <div className="flex-1 min-w-[280px]">
              <p className="font-mono text-xs text-mempool-blue break-all mb-2">{searchResult.address}</p>
              <div className="flex items-center gap-3 mb-3">
                <TierBadge tier={searchResult.tier} />
                {searchResult.satoshi_badge && (
                  <span className="px-2 py-0.5 text-[10px] uppercase tracking-wider bg-orange-500/30 text-orange-200 rounded font-bold">
                    🏆 Satoshi
                  </span>
                )}
                <span className="text-xs text-mempool-text-dim">
                  Total <span className="text-mempool-text font-mono font-semibold">{searchResult.total.toLocaleString()}</span> / 1,000,000
                </span>
              </div>
              <div className="flex gap-3 text-xs text-mempool-text-dim">
                <span>{searchResult.blocks_mined.toLocaleString()} blocks mined</span>
                <span>·</span>
                <span>first @ #{searchResult.first_active_block.toLocaleString()}</span>
              </div>
            </div>
          </div>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 mt-4">
            {CUPS.map((c) => (
              <CupCard
                key={c.key}
                cup={c}
                value={cupValue(searchResult.cups, c.key)}
              />
            ))}
          </div>
        </div>
      )}

      {/* Limit selector */}
      <div className="flex items-center gap-2 mb-4">
        <span className="text-xs text-mempool-text-dim">Show:</span>
        {[20, 50, 100, 200].map((n) => (
          <button
            key={n}
            onClick={() => setLimit(n)}
            className={`px-2 py-1 text-xs rounded transition-colors ${
              limit === n
                ? "bg-mempool-blue text-white"
                : "bg-mempool-bg-elev text-mempool-text-dim hover:text-mempool-text"
            }`}
          >
            top {n}
          </button>
        ))}
        {top && (
          <span className="ml-auto text-xs text-mempool-text-dim">
            showing {top.count} of {top.total}
          </span>
        )}
      </div>

      {/* Top list table */}
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-hidden">
        {loading && !top ? (
          <div className="p-8 text-center text-mempool-text-dim text-sm">Loading reputation top…</div>
        ) : error && !methodMissing ? (
          <div className="p-4 text-red-400 text-sm">RPC error: {error}</div>
        ) : top && top.entries.length === 0 ? (
          <div className="p-8 text-center text-mempool-text-dim text-sm">
            No reputation data yet. Mine some blocks to populate FOOD cup.
          </div>
        ) : top && top.entries.length > 0 ? (
          <div className="overflow-x-auto">
          <table className="w-full text-sm min-w-[560px]">
            <thead>
              <tr className="border-b border-mempool-border bg-mempool-bg/50">
                <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-12">#</th>
                <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Address</th>
                <th className="text-center px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-24">Tier</th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-28">Total</th>
                {CUPS.map((c) => (
                  <th key={c.key} className="text-center px-2 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-20" title={c.desc}>
                    {c.emoji} {c.label}
                  </th>
                ))}
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-20">Mined</th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-24" title="Cumulative uptime — tiebreaker for Zen ranking">Uptime</th>
              </tr>
            </thead>
            <tbody>
              {top.entries.map((e) => {
                const isZen = e.is_zen || e.tier === "ZEN";
                return (
                  <tr
                    key={e.address}
                    className={`border-b border-mempool-border/40 hover:bg-mempool-bg/30 ${
                      isZen ? "bg-gradient-to-r from-yellow-500/5 to-transparent" : ""
                    }`}
                  >
                    <td className="px-3 py-2 text-mempool-text-dim font-mono text-xs">
                      {isZen ? <span className="text-yellow-400 font-bold">★{e.rank}</span> : e.rank}
                    </td>
                    <td className="px-3 py-2 font-mono text-xs">
                      <button
                        onClick={() => navigator.clipboard.writeText(e.address)}
                        className="text-mempool-blue hover:underline"
                        title="Click to copy"
                      >
                        {e.address.slice(0, 12)}…{e.address.slice(-6)}
                      </button>
                      {isZen && (
                        <span className="ml-2 text-[10px]" title="Zen — all cups 100/100, financial independence achievement">🏆</span>
                      )}
                    </td>
                    <td className="px-3 py-2 text-center">
                      <TierBadge tier={e.tier} />
                    </td>
                    <td className="px-3 py-2 text-right font-mono text-mempool-text">
                      {isZen ? <span className="text-yellow-300">∞</span> : e.total.toLocaleString()}
                    </td>
                    {CUPS.map((c) => (
                      <td key={c.key} className="px-2 py-2 text-center">
                        <CupBar value={cupValue(e.cups, c.key)} color={c.color} text={c.text} />
                      </td>
                    ))}
                    <td className="px-3 py-2 text-right text-xs text-mempool-text-dim">
                      {e.blocks_mined.toLocaleString()}
                    </td>
                    <td className="px-3 py-2 text-right text-xs font-mono text-mempool-text-dim" title={`${e.uptime_blocks.toLocaleString()} blocks uptime`}>
                      {e.uptime_blocks > 0 ? e.uptime_blocks.toLocaleString() : "—"}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          </div>
        ) : null}
      </div>

      <div className="mt-6 text-xs text-mempool-text-dim space-y-1">
        <p>
          <span className="font-semibold text-mempool-text">Cum cresc paharele:</span>{" "}
          ❤️ LOVE = uptime · 🥖 FOOD = mining + oracle + agents · 🏠 RENT = stake/LP/hold · 🏖️ VACATION = vechime
        </p>
        <p>
          <span className="font-semibold text-mempool-text">Tiers:</span>{" "}
          OMNI (start) → LOVE (≥800k) → FOOD (≥900k) → RENT (≥950k) → VACATION (≥999k) →{" "}
          <span className="text-yellow-400 font-bold">🏆 ZEN</span> (toate paharele 100/100/100/100)
        </p>
        <p>
          <span className="font-semibold text-yellow-400">Post-Zen:</span> paharele rămân la 100,
          dar <code className="text-mempool-text">uptime_blocks</code> continuă să crească.
          Ranking-ul între Zen-i = cine a fost mai mult activ pe rețea (memory: imposibil de
          cumpărat retroactiv).
        </p>
        <p>
          <span className="font-semibold text-mempool-text">Refresh:</span> auto every 8s.
        </p>
      </div>
    </div>
  );
}

// ─── Sub-components ────────────────────────────────────────────────────────

function TierBadge({ tier }: { tier: string }) {
  const cls = TIER_COLOR[tier] || TIER_COLOR.OMNI;
  return (
    <span className={`inline-block px-2 py-0.5 text-[10px] uppercase tracking-wider rounded ${cls}`}>
      {tier}
    </span>
  );
}

function CupCard({ cup, value }: { cup: typeof CUPS[number]; value: number }) {
  const pct = Math.min(100, Math.max(0, value));
  return (
    <div className="bg-mempool-bg rounded-lg border border-mempool-border p-3">
      <div className="flex items-center justify-between mb-2">
        <span className={`text-xs uppercase tracking-wider font-semibold ${cup.text}`}>
          {cup.emoji} {cup.label}
        </span>
        <span className="font-mono text-sm text-mempool-text">{value.toFixed(2)}/100</span>
      </div>
      <div className="h-2 bg-mempool-border rounded-full overflow-hidden">
        <div
          className={`h-full ${cup.color} transition-all`}
          style={{ width: `${pct}%` }}
        />
      </div>
      <p className="text-[10px] text-mempool-text-dim mt-2">{cup.desc}</p>
    </div>
  );
}

function CupBar({ value, color, text }: { value: number; color: string; text: string }) {
  const pct = Math.min(100, Math.max(0, value));
  return (
    <div className="flex flex-col items-center">
      <div className="w-full h-1.5 bg-mempool-border/60 rounded-full overflow-hidden">
        <div className={`h-full ${color} transition-all`} style={{ width: `${pct}%` }} />
      </div>
      <span className={`text-[10px] font-mono mt-0.5 ${text}`}>{value.toFixed(1)}</span>
    </div>
  );
}
