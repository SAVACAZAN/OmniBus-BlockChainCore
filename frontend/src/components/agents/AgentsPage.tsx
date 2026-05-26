import { useEffect, useMemo, useState } from "react";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsNewBlockEvent } from "../../types";
import { satToOmni, midTrunc } from "../../utils/fmt";
import {
  Bot,
  Users,
  TrendingUp,
  TrendingDown,
  Plus,
  Pause,
  Play,
  Edit3,
  Trash2,
  Search,
  RefreshCcw,
  Activity,
} from "lucide-react";
import { rpc } from "../../api/rpc-client";
import { AddressLabel } from "../common/AddressLabel";
import { useWallet } from "../../api/use-wallet";


// ─── Types: existing system-level agents (agent_manager.zig) ────────────────

type AgentStats = {
  ticks: number;
  decisions_emitted: number;
  decisions_queued: number;
  exec_success: number;
  exec_failed: number;
  tier_transitions: number;
  total_mined_sat: number;
};

type AgentSnap = {
  name: string;
  wallet_index: number;
  address: string;
  strategy: string;
  tier: string;
  balance_sat: number;
  staked_sat: number;
  lp_locked_sat: number;
  pnl_session_sat: number;
  halted: boolean;
  stats: AgentStats;
};

type AgentListResp = {
  count: number;
  agents: AgentSnap[];
};

type PendingDecision = {
  id: number;
  wallet_index: number;
  block_height: number;
  emitted_ms: number;
  venue: string;
  kind: string;
  pair: string;
  amount_sat: number;
  reason: string;
};

type PendingResp = {
  count: number;
  decisions: PendingDecision[];
};

// ─── Types: user-registered agents (registry RPCs) ──────────────────────────

type StrategyKind =
  | "arbitrage"
  | "market_maker"
  | "oracle_relay"
  | "governance_bot"
  | "custom";

type RegistryAgent = {
  id: string;
  owner: string;
  name: string;
  strategy: StrategyKind;
  fee_bps: number;
  registered_at_block: number;
  decisions_made: number;
  decisions_ok: number;
  profit_omni_total: number; // in OMNI (not sat) per RPC contract
  profit_24h_omni?: number;
  followers: number;
  status: "active" | "halted" | "unregistered";
  reputation_total: number;
  pnl_history?: number[]; // optional sparkline
};

type GetAgentsResp = {
  agents: RegistryAgent[];
};

type SortBy = "performance" | "followers" | "recent";

// ─── Utilities ──────────────────────────────────────────────────────────────

const omniFmt = satToOmni;
const omniShort = (n: number) => (n >= 0 ? "+" : "") + n.toFixed(4);

const TIER_INFO: Record<string, { label: string; color: string; threshold: string }> = {
  t1_mining:    { label: "T1 Mining",    color: "bg-gray-700/50 text-gray-300",       threshold: "0+ OMNI" },
  t2_staking:   { label: "T2 Staking",   color: "bg-blue-500/20 text-blue-300",       threshold: "≥100 OMNI" },
  t3_liquidity: { label: "T3 Liquidity", color: "bg-purple-500/20 text-purple-300",   threshold: "≥1k OMNI" },
  t4_arbitrage: { label: "T4 Arbitrage", color: "bg-emerald-500/20 text-emerald-300", threshold: "≥10k OMNI" },
};

const TIER_KEYS = Object.keys(TIER_INFO);

const VENUE_COLOR: Record<string, string> = {
  omnibus_native: "bg-amber-500/20 text-amber-300",
  lcx:            "bg-blue-500/20 text-blue-300",
  kraken:         "bg-violet-500/20 text-violet-300",
  coinbase:       "bg-sky-500/20 text-sky-300",
  omnibus_ex:     "bg-orange-500/20 text-orange-300",
  uniswap:        "bg-pink-500/20 text-pink-300",
};

const STRATEGY_COLOR: Record<StrategyKind, string> = {
  arbitrage:      "bg-blue-500/20 text-blue-300 border-blue-500/40",
  market_maker:   "bg-green-500/20 text-green-300 border-green-500/40",
  oracle_relay:   "bg-purple-500/20 text-purple-300 border-purple-500/40",
  governance_bot: "bg-orange-500/20 text-orange-300 border-orange-500/40",
  custom:         "bg-gray-600/30 text-gray-300 border-gray-500/40",
};

const STRATEGY_LABEL: Record<StrategyKind, string> = {
  arbitrage:      "Arbitrage",
  market_maker:   "Market Maker",
  oracle_relay:   "Oracle Relay",
  governance_bot: "Governance Bot",
  custom:         "Custom",
};

function TierBadge({ tier }: { tier: string }) {
  const info = TIER_INFO[tier] || { label: tier, color: "bg-gray-700/50 text-gray-300", threshold: "?" };
  return (
    <span
      className={`inline-block px-2 py-0.5 text-[10px] uppercase tracking-wider rounded ${info.color}`}
      title={info.threshold}
    >
      {info.label}
    </span>
  );
}

function VenueBadge({ venue }: { venue: string }) {
  const color = VENUE_COLOR[venue] || "bg-gray-700/50 text-gray-300";
  return (
    <span className={`inline-block px-1.5 py-0.5 text-[9px] uppercase tracking-wider rounded font-mono ${color}`}>
      {venue}
    </span>
  );
}

function StrategyBadge({ strategy }: { strategy: StrategyKind }) {
  const color = STRATEGY_COLOR[strategy] || STRATEGY_COLOR.custom;
  const label = STRATEGY_LABEL[strategy] || strategy;
  return (
    <span className={`inline-block px-2 py-0.5 text-[10px] uppercase tracking-wider rounded border ${color}`}>
      {label}
    </span>
  );
}

function reputationFeeCap(rep: number): number {
  if (rep > 800) return 500;
  if (rep > 500) return 200;
  return 100;
}

function reputationTierLabel(rep: number): string {
  if (rep > 800) return "Elite (max 5.00%)";
  if (rep > 500) return "Trusted (max 2.00%)";
  return "Standard (max 1.00%)";
}

// Mini sparkline — pure SVG, no chart lib.
function Sparkline({ data, width = 100, height = 28 }: { data: number[]; width?: number; height?: number }) {
  if (!data || data.length < 2) {
    return <div className="text-[10px] text-mempool-text-dim italic">no data</div>;
  }
  const min = Math.min(...data);
  const max = Math.max(...data);
  const span = max - min || 1;
  const dx = width / (data.length - 1);
  const points = data
    .map((v, i) => `${(i * dx).toFixed(1)},${(height - ((v - min) / span) * height).toFixed(1)}`)
    .join(" ");
  const last = data[data.length - 1];
  const first = data[0];
  const stroke = last >= first ? "#10b981" : "#ef4444";
  return (
    <svg width={width} height={height} className="overflow-visible">
      <polyline points={points} fill="none" stroke={stroke} strokeWidth="1.5" />
    </svg>
  );
}

// ─── Page ────────────────────────────────────────────────────────────────────

type SubTab = "browse" | "mine" | "register";

export function AgentsPage() {
  // Existing system-level agents (kept intact)
  const [agents, setAgents] = useState<AgentSnap[]>([]);
  const [pending, setPending] = useState<PendingDecision[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [methodMissing, setMethodMissing] = useState(false);

  // New: registry agents + sub-tabs
  const [tab, setTab] = useState<SubTab>("browse");
  const [registry, setRegistry] = useState<RegistryAgent[]>([]);
  const [registryError, setRegistryError] = useState<string | null>(null);
  const [registryLoading, setRegistryLoading] = useState(true);
  const [sortBy, setSortBy] = useState<SortBy>("performance");
  const [search, setSearch] = useState("");
  const [actionMsg, setActionMsg] = useState<{ kind: "ok" | "err"; text: string } | null>(null);

  // Live wallet from the global keystore — re-renders on connect/disconnect
  // from the Header button or any other tab. Replaces the prior stale
  // localStorage read which only resolved on first mount.
  const wallet = useWallet();
  const localAddress = wallet?.address ?? null;

  // ── Fetch system-level agents (existing) ─────────────────────────────────
  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      try {
        const [list, pend] = await Promise.all([
          rpc.agentList() as Promise<AgentListResp | null>,
          rpc.agentPendingDecisions() as Promise<PendingResp>,
        ]);
        if (!cancelled) {
          setAgents(list?.agents || []);
          setPending(pend?.decisions || []);
          setError(null);
          setMethodMissing(false);
        }
      } catch (e: any) {
        if (!cancelled) {
          const msg = e?.message || "RPC error";
          if (msg.includes("Method not found") || msg.includes("-32601")) {
            setMethodMissing(true);
          } else {
            setError(msg);
          }
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    };
    void refresh();
    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", () => { void refresh(); });
    const id = setInterval(() => { void refresh(); }, 60_000);
    return () => {
      cancelled = true;
      clearInterval(id);
      unsub();
    };
  }, []);

  // ── Fetch registry agents ────────────────────────────────────────────────
  const refreshRegistry = async () => {
    try {
      const resp = (await rpc.getAgents(sortBy, 200)) as GetAgentsResp | null;
      setRegistry(resp?.agents || []);
      setRegistryError(null);
    } catch (e: any) {
      const msg = e?.message || "RPC error";
      if (msg.includes("Method not found") || msg.includes("-32601")) {
        setRegistryError("Agent registry RPC not yet exposed by node.");
      } else {
        setRegistryError(msg);
      }
      setRegistry([]);
    } finally {
      setRegistryLoading(false);
    }
  };

  useEffect(() => {
    let cancelled = false;
    const run = async () => {
      if (!cancelled) await refreshRegistry();
    };
    void run();
    const unsub2 = wsSubscribe<WsNewBlockEvent>("new_block", () => { void run(); });
    const id = setInterval(() => {
      if (!cancelled) void run();
    }, 60_000);
    return () => {
      cancelled = true;
      clearInterval(id);
      unsub2();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sortBy]);

  // ── Aggregate metrics for system-level agents ────────────────────────────
  const { totalCapital, tierCounts, totalQueued, totalExecSuccess, totalExecFailed } = useMemo(() => {
    let totalCapital = 0;
    const tierCounts: Record<string, number> = {};
    let totalQueued = 0;
    let totalExecSuccess = 0;
    let totalExecFailed = 0;
    for (const a of agents) {
      totalCapital += a.balance_sat + a.staked_sat + a.lp_locked_sat;
      tierCounts[a.tier] = (tierCounts[a.tier] || 0) + 1;
      totalQueued += a.stats.decisions_queued;
      totalExecSuccess += a.stats.exec_success;
      totalExecFailed += a.stats.exec_failed;
    }
    return { totalCapital, tierCounts, totalQueued, totalExecSuccess, totalExecFailed };
  }, [agents]);

  // ── Filtered registry list (for browse tab) ──────────────────────────────
  const visibleRegistry = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return registry;
    return registry.filter(
      (a) =>
        a.name.toLowerCase().includes(q) ||
        a.owner.toLowerCase().includes(q) ||
        a.strategy.toLowerCase().includes(q),
    );
  }, [registry, search]);

  const myAgents = useMemo(() => {
    if (!localAddress) return [];
    return registry.filter((a) => a.owner.toLowerCase() === localAddress.toLowerCase());
  }, [registry, localAddress]);

  // ── Action helpers ────────────────────────────────────────────────────────
  const flash = (kind: "ok" | "err", text: string) => {
    setActionMsg({ kind, text });
    setTimeout(() => setActionMsg(null), 4000);
  };

  const callRpc = async (method: string, params: any) => {
    try {
      const r = await rpc.request_raw(method, [params]);
      flash("ok", `${method} ok${r?.txid ? ` — txid ${String(r.txid).slice(0, 12)}…` : ""}`);
      await refreshRegistry();
      return r;
    } catch (e: any) {
      flash("err", `${method} failed: ${e?.message || "RPC error"}`);
      return null;
    }
  };

  const handleFollow = (id: string) => {
    if (!localAddress) {
      flash("err", "Connect wallet first to follow agents.");
      return;
    }
    callRpc("agent_follow", {
      from: localAddress,
      agent_id: id,
      signature: "00".repeat(64),
      public_key: "00".repeat(33),
      nonce: Date.now(),
    });
  };

  const handleHaltResume = (a: RegistryAgent) => {
    // Halt/resume isn't in the explicit RPC list — modeled as edit on `status`.
    // Backend can route this via agent_edit or dedicated agent_halt/resume.
    if (!localAddress) return;
    const target = a.status === "halted" ? "active" : "halted";
    callRpc("agent_edit", {
      from: localAddress,
      agent_id: a.id,
      status: target,
      signature: "00".repeat(64),
      public_key: "00".repeat(33),
      nonce: Date.now(),
    });
  };

  const handleEditFee = (a: RegistryAgent, newFeeBps: number) => {
    if (!localAddress) return;
    callRpc("agent_edit", {
      from: localAddress,
      agent_id: a.id,
      fee_bps: newFeeBps,
      signature: "00".repeat(64),
      public_key: "00".repeat(33),
      nonce: Date.now(),
    });
  };

  const handleUnregister = (a: RegistryAgent) => {
    if (!localAddress) return;
    if (!window.confirm(`Unregister agent "${a.name}"? This cannot be undone.`)) return;
    callRpc("agent_unregister", {
      from: localAddress,
      agent_id: a.id,
      signature: "00".repeat(64),
      public_key: "00".repeat(33),
      nonce: Date.now(),
    });
  };

  return (
    <div className="max-w-6xl mx-auto px-3 sm:px-4 py-4 sm:py-6 md:py-8">
      <div className="flex items-center gap-2 mb-2">
        <Bot className="w-6 h-6 text-mempool-blue flex-shrink-0" />
        <h1 className="text-base sm:text-lg md:text-2xl font-bold text-mempool-text">AI Agents</h1>
      </div>
      <p className="text-mempool-text-dim text-xs sm:text-sm mb-4 sm:mb-6">
        Browse autonomous agents, follow profitable ones to mirror their
        decisions, or register your own. System-level agents loaded via
        <code className="text-mempool-blue mx-1">--agent-config agent.json</code>
        are shown below the registry.
      </p>

      {/* Sub-tab nav */}
      <div className="flex gap-1 mb-4 sm:mb-6 border-b border-mempool-border overflow-x-auto scrollbar-none">
        <SubTabButton active={tab === "browse"} onClick={() => setTab("browse")} icon={<Users className="w-4 h-4" />}>
          Browse Agents
        </SubTabButton>
        <SubTabButton active={tab === "mine"} onClick={() => setTab("mine")} icon={<Bot className="w-4 h-4" />}>
          My Agents{myAgents.length > 0 ? ` (${myAgents.length})` : ""}
        </SubTabButton>
        <SubTabButton active={tab === "register"} onClick={() => setTab("register")} icon={<Plus className="w-4 h-4" />}>
          Register New
        </SubTabButton>
      </div>

      {actionMsg && (
        <div
          className={`mb-4 p-3 rounded-lg border text-sm ${
            actionMsg.kind === "ok"
              ? "border-green-500/40 bg-green-500/10 text-green-200"
              : "border-red-500/40 bg-red-500/10 text-red-200"
          }`}
        >
          {actionMsg.text}
        </div>
      )}

      {registryError && (
        <div className="mb-4 p-3 rounded-lg border border-amber-500/40 bg-amber-500/10 text-amber-200 text-xs">
          Registry: {registryError}
        </div>
      )}

      {tab === "browse" && (
        <BrowseTab
          agents={visibleRegistry}
          loading={registryLoading}
          sortBy={sortBy}
          setSortBy={setSortBy}
          search={search}
          setSearch={setSearch}
          onFollow={handleFollow}
          onRefresh={refreshRegistry}
        />
      )}

      {tab === "mine" && (
        <MyAgentsTab
          agents={myAgents}
          localAddress={localAddress}
          onHaltResume={handleHaltResume}
          onEditFee={handleEditFee}
          onUnregister={handleUnregister}
        />
      )}

      {tab === "register" && (
        <RegisterTab
          localAddress={localAddress}
          onRegistered={refreshRegistry}
          flash={flash}
          myAgents={myAgents}
        />
      )}

      {/* ── System-level agents (existing block, kept verbatim) ─────────── */}
      <div className="mt-12 pt-6 border-t border-mempool-border">
        <h2 className="text-lg font-semibold text-mempool-text mb-2">System agents</h2>
        <p className="text-mempool-text-dim text-xs mb-4">
          Agents loaded via <code>--agent-config agent.json</code>. Their tier
          upgrades automatically based on capital (mining → staking → liquidity → arbitrage).
        </p>

        {methodMissing && (
          <div className="mb-6 p-4 rounded-lg border border-amber-500/40 bg-amber-500/10 text-amber-200 text-sm">
            <p className="font-semibold mb-1">Agent system not available on this node.</p>
            <p className="text-amber-100/80">
              The connected node does not expose <code>agent_list</code> RPC — it runs
              an older build. Deploy a build from this branch (with{" "}
              <code>core/agent_manager.zig</code>) and start it with{" "}
              <code>--agent-config FILE</code> to populate this section.
            </p>
          </div>
        )}

        {!methodMissing && agents.length > 0 && (
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
            <Metric label="Agents" value={agents.length.toString()} />
            <Metric label="Total capital" value={`${omniFmt(totalCapital)} OMNI`} />
            <Metric label="Decisions queued" value={totalQueued.toLocaleString()} />
            <Metric
              label="Exec success / fail"
              value={`${totalExecSuccess.toLocaleString()} / ${totalExecFailed.toLocaleString()}`}
            />
            {TIER_KEYS.map((tier) => (
              <Metric
                key={tier}
                label={TIER_INFO[tier].label}
                value={(tierCounts[tier] || 0).toString()}
              />
            ))}
          </div>
        )}

        <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-hidden mb-8">
          {loading && agents.length === 0 && !methodMissing && (
            <div className="p-8 text-center text-mempool-text-dim text-sm">Loading agents…</div>
          )}
          {error && (
            <div className="p-4 text-red-400 text-sm">RPC error: {error}</div>
          )}
          {!loading && !methodMissing && agents.length === 0 && !error && (
            <div className="p-8 text-center text-mempool-text-dim text-sm">
              No system agents loaded. Pass <code className="text-mempool-blue">--agent-config agent.json</code> at node startup.
            </div>
          )}
          {agents.length > 0 && (
            <div className="overflow-x-auto">
              <table className="w-full text-xs sm:text-sm min-w-[720px]">
                <thead>
                  <tr className="border-b border-mempool-border bg-mempool-bg/50">
                    <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Name</th>
                    <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Tier</th>
                    <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Strategy</th>
                    <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Address</th>
                    <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Balance</th>
                    <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Staked</th>
                    <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">LP</th>
                    <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">P&amp;L</th>
                    <th className="text-center px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Status</th>
                  </tr>
                </thead>
                <tbody>
                  {agents.map((a) => (
                    <tr key={a.wallet_index} className="border-b border-mempool-border/40 hover:bg-mempool-bg/30">
                      <td className="px-3 py-2">
                        <div className="font-mono text-mempool-text">{a.name}</div>
                        <div className="text-[10px] text-mempool-text-dim">idx {a.wallet_index}</div>
                      </td>
                      <td className="px-3 py-2"><TierBadge tier={a.tier} /></td>
                      <td className="px-3 py-2 text-xs text-mempool-text-dim">{a.strategy}</td>
                      <td className="px-3 py-2 font-mono text-xs">
                        <button
                          onClick={() => { window.location.hash = `#/address/${a.address}`; }}
                          className="text-mempool-blue hover:underline"
                          title={a.address}
                        >
                          <AddressLabel address={a.address} showEmoji truncate={{ left: 10, right: 6 }} />
                        </button>
                      </td>
                      <td className="px-3 py-2 text-right font-mono text-mempool-text">{omniFmt(a.balance_sat)}</td>
                      <td className="px-3 py-2 text-right font-mono text-mempool-text-dim">{omniFmt(a.staked_sat)}</td>
                      <td className="px-3 py-2 text-right font-mono text-mempool-text-dim">{omniFmt(a.lp_locked_sat)}</td>
                      <td className={`px-3 py-2 text-right font-mono ${a.pnl_session_sat < 0 ? "text-red-400" : a.pnl_session_sat > 0 ? "text-green-400" : "text-mempool-text-dim"}`}>
                        {a.pnl_session_sat >= 0 ? "+" : ""}{omniFmt(a.pnl_session_sat)}
                      </td>
                      <td className="px-3 py-2 text-center">
                        {a.halted ? (
                          <span className="inline-block px-2 py-0.5 text-[10px] uppercase tracking-wider bg-red-500/20 text-red-300 rounded">halted</span>
                        ) : (
                          <span className="inline-block px-2 py-0.5 text-[10px] uppercase tracking-wider bg-green-500/20 text-green-300 rounded">running</span>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {!methodMissing && (
          <div>
            <h3 className="text-base font-semibold text-mempool-text mb-2">Pending decisions queue</h3>
            <p className="text-mempool-text-dim text-xs mb-3">
              Decisions emitted by agents for external venues (LCX, Kraken, Coinbase, ...).
              Picked up by the Python agent client via <code>agent_pending_decisions</code> RPC.
            </p>
            <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-x-auto">
              {pending.length === 0 ? (
                <div className="p-6 text-center text-mempool-text-dim text-sm">
                  No pending decisions.
                </div>
              ) : (
                <table className="w-full text-xs sm:text-sm min-w-[720px]">
                  <thead>
                    <tr className="border-b border-mempool-border bg-mempool-bg/50">
                      <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">ID</th>
                      <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Wallet</th>
                      <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Block</th>
                      <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Venue</th>
                      <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Action</th>
                      <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Pair</th>
                      <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Amount</th>
                      <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Reason</th>
                    </tr>
                  </thead>
                  <tbody>
                    {pending.map((d) => (
                      <tr key={d.id} className="border-b border-mempool-border/40">
                        <td className="px-3 py-2 font-mono text-xs text-mempool-text-dim">#{d.id}</td>
                        <td className="px-3 py-2 font-mono text-xs">idx {d.wallet_index}</td>
                        <td className="px-3 py-2 font-mono text-xs text-mempool-text-dim">{d.block_height}</td>
                        <td className="px-3 py-2"><VenueBadge venue={d.venue} /></td>
                        <td className="px-3 py-2 text-xs uppercase">{d.kind}</td>
                        <td className="px-3 py-2 font-mono text-xs">{d.pair || "—"}</td>
                        <td className="px-3 py-2 text-right font-mono">{omniFmt(d.amount_sat)}</td>
                        <td className="px-3 py-2 text-xs text-mempool-text-dim italic">{d.reason}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </div>
          </div>
        )}

        {/* agent_status — detailed stats per wallet_index */}
        {!methodMissing && <AgentStatusPanel />}

        {/* agent_report_execution — report result of a pending decision */}
        {!methodMissing && <AgentReportPanel />}

        {/* agent_edit + agent_unregister — management operations */}
        {!methodMissing && <AgentManagePanel />}

        {/* getagent — single agent lookup */}
        {!methodMissing && <AgentLookupPanel />}

        <div className="mt-6 text-xs text-mempool-text-dim">
          <p>
            <span className="font-semibold text-mempool-text">Refresh:</span> auto every 5s (system) / 8s (registry).
          </p>
          <p className="mt-1">
            <span className="font-semibold text-mempool-text">Setup:</span> see{" "}
            <code>1_CORE/BlockChainCore/docs/USER_JOURNEY.md</code> for agent.json schema and
            tier progression rules.
          </p>
        </div>
      </div>
    </div>
  );
}

// ─── AgentStatusPanel ─────────────────────────────────────────────────────

interface AgentDetailStatus {
  name: string;
  wallet_index: number;
  address: string;
  strategy: string;
  tier: string;
  balance_sat: number;
  staked_sat: number;
  lp_locked_sat: number;
  pnl_session_sat: number;
  halted: boolean;
  stats: {
    ticks: number;
    decisions_emitted: number;
    decisions_queued: number;
    exec_success: number;
    exec_failed: number;
    tier_transitions: number;
    total_mined_sat: number;
  };
}

function AgentStatusPanel() {
  const [walletIndex, setWalletIndex] = useState("");
  const [result, setResult] = useState<AgentDetailStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const lookup = async () => {
    const wi = parseInt(walletIndex, 10);
    if (isNaN(wi)) { setError("Enter a valid wallet_index integer."); return; }
    setLoading(true);
    setError(null);
    setResult(null);
    try {
      const r = await rpc.agentStatus(wi);
      if (r && typeof r === "object") setResult(r as AgentDetailStatus);
    } catch (e) {
      setError(String(e));
    } finally { setLoading(false); }
  };

  return (
    <div>
      <h3 className="text-base font-semibold text-mempool-text mb-2">Agent status (by wallet index)</h3>
      <div className="flex gap-3 mb-3">
        <input
          type="number"
          min="0"
          value={walletIndex}
          onChange={(e) => setWalletIndex(e.target.value)}
          placeholder="wallet_index (e.g. 10)"
          className="w-40 bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text focus:outline-none focus:border-mempool-blue"
        />
        <button
          onClick={lookup}
          disabled={loading}
          className="px-3 py-1.5 rounded text-xs bg-mempool-blue/20 text-mempool-blue border border-mempool-blue/30 hover:bg-mempool-blue/30 disabled:opacity-50"
        >
          {loading ? "…" : "agent_status"}
        </button>
      </div>
      {error && <div className="text-red-400 text-xs mb-2">{error}</div>}
      {result && (
        <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-3 text-xs space-y-2">
          <div className="flex items-center gap-3 flex-wrap">
            <span className="font-semibold text-mempool-text font-mono">{result.name}</span>
            <span className="text-mempool-text-dim">idx {result.wallet_index}</span>
            <span className={`px-1.5 py-0.5 rounded text-[10px] font-bold ${result.halted ? "bg-red-500/20 text-red-300" : "bg-green-500/20 text-green-300"}`}>
              {result.halted ? "HALTED" : "RUNNING"}
            </span>
            <span className="text-mempool-blue">{result.tier}</span>
            <span className="text-mempool-text-dim">{result.strategy}</span>
          </div>
          <div className="grid grid-cols-3 sm:grid-cols-4 gap-x-4 gap-y-1 font-mono">
            {[
              ["balance", omniFmt(result.balance_sat) + " OMNI"],
              ["staked", omniFmt(result.staked_sat) + " OMNI"],
              ["LP locked", omniFmt(result.lp_locked_sat) + " OMNI"],
              ["P&L session", (result.pnl_session_sat >= 0 ? "+" : "") + omniFmt(result.pnl_session_sat)],
              ["ticks", String(result.stats.ticks)],
              ["decisions ✉", String(result.stats.decisions_emitted)],
              ["queued", String(result.stats.decisions_queued)],
              ["exec ✓/✗", `${result.stats.exec_success}/${result.stats.exec_failed}`],
              ["tier Δ", String(result.stats.tier_transitions)],
              ["mined", omniFmt(result.stats.total_mined_sat) + " OMNI"],
            ].map(([k, v]) => (
              <div key={k}>
                <div className="text-[9px] text-mempool-text-dim uppercase">{k}</div>
                <div className="text-mempool-text">{v}</div>
              </div>
            ))}
          </div>
          <div className="text-[10px] font-mono text-mempool-text-dim truncate">{result.address}</div>
        </div>
      )}
    </div>
  );
}

// ─── AgentReportPanel ─────────────────────────────────────────────────────

const EXEC_STATUSES = ["success", "rejected", "network_error", "timeout", "cancelled"] as const;
type ExecStatus = typeof EXEC_STATUSES[number];

function AgentReportPanel() {
  const [decisionId, setDecisionId] = useState("");
  const [status, setStatus] = useState<ExecStatus>("success");
  const [externalId, setExternalId] = useState("");
  const [filledSat, setFilledSat] = useState("");
  const [fillPrice, setFillPrice] = useState("");
  const [errorMsg, setErrorMsg] = useState("");
  const [result, setResult] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const report = async () => {
    const did = parseInt(decisionId, 10);
    if (isNaN(did)) { setErr("Enter a valid decision_id."); return; }
    setBusy(true);
    setResult(null);
    setErr(null);
    try {
      const params: Record<string, unknown> = { decision_id: did, status };
      if (externalId) params.external_id = externalId;
      if (filledSat) params.filled_amount_sat = parseInt(filledSat, 10) || 0;
      if (fillPrice) params.fill_price_micro_usd = parseInt(fillPrice, 10) || 0;
      if (errorMsg) params.error_msg = errorMsg;
      const r = await rpc.request_raw("agent_report_execution", [params]);
      setResult(r && typeof r === "object" ? JSON.stringify(r) : String(r));
    } catch (e) {
      setErr(String(e));
    } finally { setBusy(false); }
  };

  return (
    <div>
      <h3 className="text-base font-semibold text-mempool-text mb-2">Report execution result</h3>
      <p className="text-xs text-mempool-text-dim mb-3">
        Used by the external Python agent client to report the outcome of a pending decision.
        Sets the decision's status and marks it as settled in the queue.
      </p>
      <div className="grid grid-cols-2 sm:grid-cols-3 gap-3 text-xs mb-3">
        <label className="flex flex-col">
          <span className="text-mempool-text-dim mb-1">decision_id *</span>
          <input
            type="number" min="0"
            value={decisionId} onChange={(e) => setDecisionId(e.target.value)}
            className="bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 font-mono text-mempool-text focus:outline-none focus:border-mempool-blue"
            placeholder="42"
          />
        </label>
        <label className="flex flex-col">
          <span className="text-mempool-text-dim mb-1">status *</span>
          <select
            value={status} onChange={(e) => setStatus(e.target.value as ExecStatus)}
            className="bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-mempool-text focus:outline-none focus:border-mempool-blue"
          >
            {EXEC_STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
        </label>
        <label className="flex flex-col">
          <span className="text-mempool-text-dim mb-1">external_id</span>
          <input
            value={externalId} onChange={(e) => setExternalId(e.target.value)}
            className="bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 font-mono text-mempool-text focus:outline-none focus:border-mempool-blue"
            placeholder="LCX-12345"
          />
        </label>
        <label className="flex flex-col">
          <span className="text-mempool-text-dim mb-1">filled_amount_sat</span>
          <input
            type="number" min="0"
            value={filledSat} onChange={(e) => setFilledSat(e.target.value)}
            className="bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 font-mono text-mempool-text focus:outline-none focus:border-mempool-blue"
            placeholder="0"
          />
        </label>
        <label className="flex flex-col">
          <span className="text-mempool-text-dim mb-1">fill_price_micro_usd</span>
          <input
            type="number" min="0"
            value={fillPrice} onChange={(e) => setFillPrice(e.target.value)}
            className="bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 font-mono text-mempool-text focus:outline-none focus:border-mempool-blue"
            placeholder="0"
          />
        </label>
        <label className="flex flex-col">
          <span className="text-mempool-text-dim mb-1">error_msg</span>
          <input
            value={errorMsg} onChange={(e) => setErrorMsg(e.target.value)}
            className="bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 font-mono text-mempool-text focus:outline-none focus:border-mempool-blue"
            placeholder="optional"
          />
        </label>
      </div>
      <button
        onClick={report}
        disabled={busy || !decisionId}
        className="px-4 py-1.5 rounded text-xs bg-mempool-blue hover:bg-blue-600 text-white disabled:opacity-50"
      >
        {busy ? "Reporting…" : "agent_report_execution"}
      </button>
      {result && <div className="mt-2 text-green-400 text-xs font-mono">{result}</div>}
      {err && <div className="mt-2 text-red-400 text-xs">{err}</div>}
    </div>
  );
}

// ─── AgentLookupPanel (getagent — single agent by ID) ────────────────────────

function AgentLookupPanel() {
  const [agentId, setAgentId] = useState("");
  const [result, setResult] = useState<unknown>(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState("");

  const lookup = async () => {
    const id = parseInt(agentId, 10);
    if (isNaN(id)) { setErr("Enter a numeric agent ID"); return; }
    setLoading(true); setErr(""); setResult(null);
    try {
      const r = await rpc.getAgent(id);
      setResult(r);
    } catch (e) { setErr(String(e)); }
    finally { setLoading(false); }
  };

  return (
    <div className="mt-4 rounded-xl border border-mempool-border bg-mempool-bg-elev p-4 space-y-3">
      <h3 className="text-xs font-semibold text-mempool-text-dim uppercase tracking-wider">
        Single Agent Lookup (getagent)
      </h3>
      <div className="flex gap-2">
        <input
          type="number"
          min="0"
          value={agentId}
          onChange={(e) => setAgentId(e.target.value)}
          placeholder="Agent ID (number)"
          className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-1.5 text-xs font-mono text-mempool-text"
        />
        <button
          onClick={lookup}
          disabled={loading || !agentId}
          className="px-4 py-1.5 text-xs font-medium bg-mempool-blue/20 hover:bg-mempool-blue/40 text-mempool-blue border border-mempool-blue/30 rounded disabled:opacity-50"
        >
          {loading ? "…" : "Lookup"}
        </button>
      </div>
      {err && <p className="text-xs text-red-400">{err}</p>}
      {result !== null && (
        <pre className="text-[10px] font-mono text-mempool-text-dim bg-mempool-bg rounded p-2 overflow-x-auto whitespace-pre-wrap">
          {JSON.stringify(result, null, 2)}
        </pre>
      )}
    </div>
  );
}

// ─── AgentManagePanel ─────────────────────────────────────────────────────

function AgentManagePanel() {
  const wallet = useWallet();

  // Edit state
  const [editAgentId, setEditAgentId] = useState("");
  const [editResult, setEditResult] = useState<string | null>(null);
  const [editErr, setEditErr] = useState<string | null>(null);
  const [editLoading, setEditLoading] = useState(false);

  // Unregister state
  const [unregAgentId, setUnregAgentId] = useState("");
  const [unregResult, setUnregResult] = useState<string | null>(null);
  const [unregErr, setUnregErr] = useState<string | null>(null);
  const [unregLoading, setUnregLoading] = useState(false);

  const onEdit = async () => {
    if (!wallet || !editAgentId) return;
    setEditLoading(true);
    setEditErr(null);
    setEditResult(null);
    try {
      const r = (await rpc.request_raw("agent_edit", [{
        from: wallet.address,
        agent_id: editAgentId,
        signature: "00".repeat(64),
        public_key: wallet.publicKey ?? "",
      }])) as { status?: string; agent_id?: string };
      setEditResult(`status=${r?.status ?? "ok"} agent=${r?.agent_id ?? editAgentId}`);
    } catch (e: any) {
      setEditErr(e?.message ?? String(e));
    } finally {
      setEditLoading(false);
    }
  };

  const onUnregister = async () => {
    if (!wallet || !unregAgentId) return;
    setUnregLoading(true);
    setUnregErr(null);
    setUnregResult(null);
    try {
      const nonce = await rpc.getNonce(wallet.address);
      const r = (await rpc.request_raw("agent_unregister", [{
        from: wallet.address,
        agent_id: unregAgentId,
        signature: "00".repeat(64),
        public_key: wallet.publicKey ?? "",
        nonce,
      }])) as string | { txid?: string };
      setUnregResult(typeof r === "string" ? r : (r as { txid?: string }).txid ?? "unregistered");
    } catch (e: any) {
      setUnregErr(e?.message ?? String(e));
    } finally {
      setUnregLoading(false);
    }
  };

  return (
    <div className="mt-4 rounded-xl border border-gray-700/40 bg-mempool-bg-elev p-4 space-y-4">
      <h3 className="text-sm font-semibold text-mempool-text">Agent Management</h3>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        {/* Edit */}
        <div className="space-y-2">
          <h4 className="text-xs font-semibold text-blue-300">Edit Agent</h4>
          <input
            value={editAgentId}
            onChange={(e) => setEditAgentId(e.target.value)}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
            placeholder="agent_id"
          />
          <button
            onClick={onEdit}
            disabled={editLoading || !editAgentId || !wallet}
            className="w-full py-1.5 text-xs bg-blue-500/20 hover:bg-blue-500/30 text-blue-300 border border-blue-500/30 rounded disabled:opacity-50"
          >
            {editLoading ? "…" : "Edit Agent"}
          </button>
          {editErr && <p className="text-[11px] text-red-400">{editErr}</p>}
          {editResult && <p className="text-[11px] text-green-400 font-mono">{editResult}</p>}
        </div>

        {/* Unregister */}
        <div className="space-y-2">
          <h4 className="text-xs font-semibold text-red-300">Unregister Agent</h4>
          <input
            value={unregAgentId}
            onChange={(e) => setUnregAgentId(e.target.value)}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
            placeholder="agent_id"
          />
          <button
            onClick={onUnregister}
            disabled={unregLoading || !unregAgentId || !wallet}
            className="w-full py-1.5 text-xs bg-red-500/20 hover:bg-red-500/30 text-red-300 border border-red-500/30 rounded disabled:opacity-50"
          >
            {unregLoading ? "…" : "Unregister Agent"}
          </button>
          {unregErr && <p className="text-[11px] text-red-400">{unregErr}</p>}
          {unregResult && <p className="text-[11px] text-green-400 font-mono">TX: {unregResult}</p>}
        </div>
      </div>
    </div>
  );
}

// ─── Sub-tab: Browse Agents ─────────────────────────────────────────────────

function BrowseTab(props: {
  agents: RegistryAgent[];
  loading: boolean;
  sortBy: SortBy;
  setSortBy: (s: SortBy) => void;
  search: string;
  setSearch: (s: string) => void;
  onFollow: (id: string) => void;
  onRefresh: () => void;
}) {
  const { agents, loading, sortBy, setSortBy, search, setSearch, onFollow, onRefresh } = props;

  return (
    <div>
      <div className="flex flex-col sm:flex-row sm:flex-wrap sm:items-center gap-2 mb-4">
        <div className="relative flex-1 min-w-0 sm:min-w-[200px]">
          <Search className="w-4 h-4 absolute left-2 top-1/2 -translate-y-1/2 text-mempool-text-dim" />
          <input
            type="text"
            placeholder="Search by name, owner, strategy…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="w-full pl-8 pr-3 py-2.5 text-sm bg-mempool-bg-elev border border-mempool-border rounded-lg text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
        </div>
        <div className="flex gap-2">
          <select
            value={sortBy}
            onChange={(e) => setSortBy(e.target.value as SortBy)}
            className="flex-1 sm:flex-none px-3 py-2.5 text-sm bg-mempool-bg-elev border border-mempool-border rounded-lg text-mempool-text focus:outline-none focus:border-mempool-blue"
          >
            <option value="performance">Sort: Performance</option>
            <option value="followers">Sort: Followers</option>
            <option value="recent">Sort: Recently registered</option>
          </select>
          {agents.length > 0 && (
            <button
              onClick={() => {
                const rows = [
                  ["id","name","owner","strategy","fee_bps","decisions_made","decisions_ok","profit_omni_total","profit_24h_omni","followers","status","reputation_total","registered_at_block"].join(","),
                  ...agents.map((a) => [
                    `"${a.id}"`,
                    `"${a.name.replace(/"/g, '""')}"`,
                    `"${a.owner}"`,
                    a.strategy,
                    a.fee_bps,
                    a.decisions_made,
                    a.decisions_ok,
                    a.profit_omni_total.toFixed(4),
                    (a.profit_24h_omni ?? 0).toFixed(4),
                    a.followers,
                    a.status,
                    a.reputation_total,
                    a.registered_at_block,
                  ].join(",")),
                ].join("\n");
                const blob = new Blob([rows], { type: "text/csv" });
                const url = URL.createObjectURL(blob);
                const a = document.createElement("a");
                a.href = url; a.download = "omnibus-agents-registry.csv";
                a.click(); URL.revokeObjectURL(url);
              }}
              className="px-3 py-2.5 text-sm bg-mempool-bg-elev border border-mempool-border rounded-lg text-mempool-text hover:border-mempool-blue inline-flex items-center gap-1.5"
            >
              ⬇ CSV
            </button>
          )}
          <button
            onClick={onRefresh}
            className="px-3 py-2.5 text-sm bg-mempool-bg-elev border border-mempool-border rounded-lg text-mempool-text hover:border-mempool-blue inline-flex items-center gap-1.5"
          >
            <RefreshCcw className="w-3.5 h-3.5" /> Refresh
          </button>
        </div>
      </div>

      {loading && agents.length === 0 && (
        <div className="p-8 text-center text-mempool-text-dim text-sm">Loading registry…</div>
      )}
      {!loading && agents.length === 0 && (
        <div className="p-8 text-center text-mempool-text-dim text-sm rounded-lg border border-mempool-border bg-mempool-bg-elev">
          No registered agents match. Be the first — register one in the next tab.
        </div>
      )}

      <div className="grid gap-3 grid-cols-1 sm:grid-cols-2 lg:grid-cols-3">
        {agents.map((a) => (
          <AgentCard key={a.id} agent={a} onFollow={onFollow} />
        ))}
      </div>
    </div>
  );
}

function AgentCard({ agent, onFollow }: { agent: RegistryAgent; onFollow: (id: string) => void }) {
  const okPct = agent.decisions_made > 0 ? (agent.decisions_ok / agent.decisions_made) * 100 : 0;
  const pnl24h = agent.profit_24h_omni ?? 0;
  const positive = pnl24h >= 0;
  const isHalted = agent.status === "halted";

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 flex flex-col gap-2 hover:border-mempool-blue/60 transition">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="flex items-center gap-1.5">
            <Bot className="w-4 h-4 text-mempool-blue flex-shrink-0" />
            <div className="font-semibold text-mempool-text truncate">{agent.name}</div>
            {isHalted && (
              <span className="text-[9px] uppercase bg-red-500/20 text-red-300 px-1.5 py-0.5 rounded">halted</span>
            )}
          </div>
          <div className="text-[10px] font-mono text-mempool-text-dim truncate" title={agent.owner}>
            {midTrunc(agent.owner, 14, 6)}
          </div>
        </div>
        <StrategyBadge strategy={agent.strategy} />
      </div>

      <div className="grid grid-cols-2 gap-2 text-xs">
        <div>
          <div className="text-[9px] uppercase text-mempool-text-dim">Fee</div>
          <div className="font-mono text-mempool-text">{(agent.fee_bps / 100).toFixed(2)}%</div>
        </div>
        <div>
          <div className="text-[9px] uppercase text-mempool-text-dim">Followers</div>
          <div className="font-mono text-mempool-text inline-flex items-center gap-1">
            <Users className="w-3 h-3" /> {agent.followers.toLocaleString()}
          </div>
        </div>
        <div>
          <div className="text-[9px] uppercase text-mempool-text-dim">P/L 24h</div>
          <div className={`font-mono inline-flex items-center gap-1 ${positive ? "text-green-400" : "text-red-400"}`}>
            {positive ? <TrendingUp className="w-3 h-3" /> : <TrendingDown className="w-3 h-3" />}
            {omniShort(pnl24h)}
          </div>
        </div>
        <div>
          <div className="text-[9px] uppercase text-mempool-text-dim">OK rate</div>
          <div className="font-mono text-mempool-text">
            {okPct.toFixed(1)}%
            <span className="text-mempool-text-dim text-[10px] ml-1">
              ({agent.decisions_ok}/{agent.decisions_made})
            </span>
          </div>
        </div>
      </div>

      <button
        onClick={() => onFollow(agent.id)}
        disabled={isHalted}
        className="mt-1 w-full px-3 py-2.5 text-xs font-medium bg-mempool-blue/20 text-mempool-blue border border-mempool-blue/40 rounded hover:bg-mempool-blue/30 disabled:opacity-40 disabled:cursor-not-allowed inline-flex items-center justify-center gap-1.5"
      >
        <Users className="w-3.5 h-3.5" /> Follow
      </button>
    </div>
  );
}

// ─── Sub-tab: My Agents ─────────────────────────────────────────────────────

function MyAgentsTab(props: {
  agents: RegistryAgent[];
  localAddress: string | null;
  onHaltResume: (a: RegistryAgent) => void;
  onEditFee: (a: RegistryAgent, newFeeBps: number) => void;
  onUnregister: (a: RegistryAgent) => void;
}) {
  const { agents, localAddress, onHaltResume, onEditFee, onUnregister } = props;
  const [editingFee, setEditingFee] = useState<{ agentId: string; value: string } | null>(null);

  if (!localAddress) {
    return (
      <div className="p-8 text-center text-mempool-text-dim text-sm rounded-lg border border-mempool-border bg-mempool-bg-elev">
        Connect a wallet to see your registered agents.
      </div>
    );
  }
  if (agents.length === 0) {
    return (
      <div className="p-8 text-center text-mempool-text-dim text-sm rounded-lg border border-mempool-border bg-mempool-bg-elev">
        You haven't registered any agents yet. Use <strong className="text-mempool-text">Register New</strong> to publish one.
      </div>
    );
  }

  return (
    <div className="grid gap-3">
      {agents.map((a) => (
        <div
          key={a.id}
          className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 flex flex-col sm:flex-row sm:items-center gap-3"
        >
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-2 mb-1">
              <Bot className="w-4 h-4 text-mempool-blue" />
              <span className="font-semibold text-mempool-text truncate">{a.name}</span>
              <StrategyBadge strategy={a.strategy} />
              {a.status === "halted" && (
                <span className="text-[9px] uppercase bg-red-500/20 text-red-300 px-1.5 py-0.5 rounded">halted</span>
              )}
            </div>
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 text-xs">
              <div>
                <div className="text-[9px] uppercase text-mempool-text-dim">Fee</div>
                <div className="font-mono text-mempool-text">{(a.fee_bps / 100).toFixed(2)}%</div>
              </div>
              <div>
                <div className="text-[9px] uppercase text-mempool-text-dim">Followers</div>
                <div className="font-mono text-mempool-text">{a.followers}</div>
              </div>
              <div>
                <div className="text-[9px] uppercase text-mempool-text-dim">Total profit</div>
                <div className={`font-mono ${a.profit_omni_total >= 0 ? "text-green-400" : "text-red-400"}`}>
                  {omniShort(a.profit_omni_total)}
                </div>
              </div>
              <div>
                <div className="text-[9px] uppercase text-mempool-text-dim">Sparkline</div>
                <Sparkline data={a.pnl_history || []} />
              </div>
            </div>
          </div>
          <div className="flex flex-wrap gap-1.5">
            {editingFee?.agentId === a.id ? (
              <div className="flex items-center gap-1">
                <input
                  type="number"
                  min="0"
                  max="500"
                  value={editingFee.value}
                  onChange={(e) => setEditingFee({ agentId: a.id, value: e.target.value })}
                  className="w-20 bg-mempool-bg border border-mempool-blue rounded px-2 py-1.5 text-xs text-mempool-text focus:outline-none font-mono"
                  autoFocus
                />
                <button
                  onClick={() => {
                    const next = parseInt(editingFee.value, 10);
                    if (!Number.isFinite(next) || next < 0 || next > 500) return;
                    onEditFee(a, next);
                    setEditingFee(null);
                  }}
                  className="px-2 py-1.5 text-xs bg-mempool-blue hover:bg-blue-600 text-white rounded"
                >Save</button>
                <button
                  onClick={() => setEditingFee(null)}
                  className="px-2 py-1.5 text-xs bg-mempool-bg-elev hover:bg-mempool-bg text-mempool-text-dim rounded"
                >✕</button>
              </div>
            ) : (
              <button
                onClick={() => setEditingFee({ agentId: a.id, value: String(a.fee_bps) })}
                title="Edit fee"
                className="px-3 py-2.5 text-xs bg-mempool-bg/40 border border-mempool-border rounded hover:border-mempool-blue inline-flex items-center gap-1"
              >
                <Edit3 className="w-3.5 h-3.5" /> Fee
              </button>
            )}
            <button
              onClick={() => onHaltResume(a)}
              title={a.status === "halted" ? "Resume" : "Halt"}
              className="px-3 py-2.5 text-xs bg-mempool-bg/40 border border-mempool-border rounded hover:border-mempool-blue inline-flex items-center gap-1"
            >
              {a.status === "halted" ? <Play className="w-3.5 h-3.5" /> : <Pause className="w-3.5 h-3.5" />}
              {a.status === "halted" ? "Resume" : "Halt"}
            </button>
            <button
              onClick={() => onUnregister(a)}
              title="Unregister"
              className="px-3 py-2.5 text-xs bg-red-500/10 border border-red-500/40 text-red-300 rounded hover:bg-red-500/20 inline-flex items-center gap-1"
            >
              <Trash2 className="w-3.5 h-3.5" /> Unregister
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}

// ─── Sub-tab: Register New ──────────────────────────────────────────────────

function RegisterTab(props: {
  localAddress: string | null;
  onRegistered: () => void;
  flash: (kind: "ok" | "err", text: string) => void;
  myAgents: RegistryAgent[];
}) {
  const { localAddress, onRegistered, flash, myAgents } = props;

  // Reputation comes from existing agents the user owns (display preview only).
  // Real check is on the backend.
  const ownReputation = useMemo(() => {
    if (myAgents.length === 0) return 0;
    return Math.max(...myAgents.map((a) => a.reputation_total));
  }, [myAgents]);
  const feeCap = reputationFeeCap(ownReputation);

  const [name, setName] = useState("");
  const [strategy, setStrategy] = useState<StrategyKind>("arbitrage");
  const [feeBps, setFeeBps] = useState(50);
  const [submitting, setSubmitting] = useState(false);

  const submit = async () => {
    if (!localAddress) {
      flash("err", "Connect wallet first.");
      return;
    }
    const trimmed = name.trim();
    if (!trimmed) {
      flash("err", "Agent name required.");
      return;
    }
    if (trimmed.length > 32) {
      flash("err", "Name max 32 chars.");
      return;
    }
    if (feeBps < 0 || feeBps > 500) {
      flash("err", "fee_bps must be 0..500.");
      return;
    }

    setSubmitting(true);
    try {
      const r = await rpc.request_raw("agent_register", [
        {
          from: localAddress,
          name: trimmed,
          strategy,
          fee_bps: feeBps,
          // Stub signature path — real signing happens via Tauri / wallet bridge.
          signature: "00".repeat(64),
          public_key: "00".repeat(33),
          nonce: Date.now(),
        },
      ]);
      flash("ok", `Registered "${trimmed}"${r?.agent_id ? ` (id ${r.agent_id})` : ""}.`);
      setName("");
      setFeeBps(50);
      onRegistered();
    } catch (e: any) {
      flash("err", `agent_register failed: ${e?.message || "RPC error"}`);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-3 sm:p-4 md:p-5 max-w-2xl">
      <h2 className="text-base font-semibold text-mempool-text mb-1 inline-flex items-center gap-2">
        <Plus className="w-4 h-4 text-mempool-blue" /> Register a new agent
      </h2>
      <p className="text-xs text-mempool-text-dim mb-4">
        Publish an agent visible to all OmniBus users. Followers can mirror its
        decisions; you collect fee_bps on each successful execution.
      </p>

      {!localAddress && (
        <div className="mb-4 p-3 rounded-lg border border-amber-500/40 bg-amber-500/10 text-amber-200 text-xs">
          Connect a wallet first — registration is signed by your address.
        </div>
      )}

      <div className="grid gap-4">
        <div>
          <label className="block text-xs uppercase tracking-wider text-mempool-text-dim mb-1">
            Name <span className="text-mempool-text-dim normal-case">(max 32 chars)</span>
          </label>
          <input
            type="text"
            maxLength={32}
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="MyArbitrageBot"
            className="w-full px-3 py-2 text-sm bg-mempool-bg border border-mempool-border rounded-lg text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
          <div className="text-[10px] text-mempool-text-dim mt-1">{name.length}/32</div>
        </div>

        <div>
          <label className="block text-xs uppercase tracking-wider text-mempool-text-dim mb-1">Strategy</label>
          <select
            value={strategy}
            onChange={(e) => setStrategy(e.target.value as StrategyKind)}
            className="w-full px-3 py-2 text-sm bg-mempool-bg border border-mempool-border rounded-lg text-mempool-text focus:outline-none focus:border-mempool-blue"
          >
            <option value="arbitrage">Arbitrage</option>
            <option value="market_maker">Market Maker</option>
            <option value="oracle_relay">Oracle Relay</option>
            <option value="governance_bot">Governance Bot</option>
            <option value="custom">Custom</option>
          </select>
          <div className="mt-1">
            <StrategyBadge strategy={strategy} />
          </div>
        </div>

        <div>
          <label className="block text-xs uppercase tracking-wider text-mempool-text-dim mb-1">
            Fee (bps) — {feeBps} bps = {(feeBps / 100).toFixed(2)}%
          </label>
          <input
            type="range"
            min={0}
            max={500}
            step={5}
            value={feeBps}
            onChange={(e) => setFeeBps(parseInt(e.target.value, 10))}
            className="w-full accent-mempool-blue"
          />
          <div className="flex justify-between text-[10px] text-mempool-text-dim mt-1">
            <span>0</span>
            <span>250</span>
            <span>500</span>
          </div>
          <div className="mt-2 p-2 rounded border border-mempool-border bg-mempool-bg/40 text-[11px] text-mempool-text-dim inline-flex items-start gap-1.5">
            <Activity className="w-3.5 h-3.5 text-mempool-blue mt-0.5 flex-shrink-0" />
            <div>
              Reputation gating preview: your tier is{" "}
              <span className="text-mempool-text">{reputationTierLabel(ownReputation)}</span>
              {" — "}max fee on registration is{" "}
              <span className="font-mono text-mempool-text">{feeCap} bps</span>.
              Final cap enforced by the backend; if you exceed it, the call will be rejected.
            </div>
          </div>
          {feeBps > feeCap && (
            <div className="mt-2 text-[11px] text-amber-300">
              Selected fee {feeBps} bps exceeds your tier cap {feeCap} bps — backend will likely reject.
            </div>
          )}
        </div>

        <button
          onClick={submit}
          disabled={submitting || !localAddress || !name.trim()}
          className="w-full px-4 py-2.5 text-sm font-semibold bg-mempool-blue text-white rounded-lg hover:bg-mempool-blue/90 disabled:opacity-40 disabled:cursor-not-allowed inline-flex items-center justify-center gap-2"
        >
          <Plus className="w-4 h-4" /> {submitting ? "Registering…" : "Register Agent"}
        </button>
      </div>
    </div>
  );
}

// ─── Tiny presentational helpers ────────────────────────────────────────────

function SubTabButton({
  active,
  onClick,
  icon,
  children,
}: {
  active: boolean;
  onClick: () => void;
  icon: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <button
      onClick={onClick}
      className={`flex-shrink-0 px-3 sm:px-4 py-2.5 text-xs sm:text-sm font-medium inline-flex items-center gap-1.5 border-b-2 transition whitespace-nowrap ${
        active
          ? "border-mempool-blue text-mempool-text"
          : "border-transparent text-mempool-text-dim hover:text-mempool-text"
      }`}
    >
      {icon}
      {children}
    </button>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-3">
      <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">{label}</div>
      <div className="text-sm font-mono text-mempool-text">{value}</div>
    </div>
  );
}
