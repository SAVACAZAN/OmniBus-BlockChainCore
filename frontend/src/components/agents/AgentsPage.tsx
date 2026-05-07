import { useEffect, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";

const rpc = new OmniBusRpcClient();
const SAT_PER_OMNI = 1_000_000_000;

// ─── Types (match agent_manager.zig + rpc_server.zig handlers) ──────────────

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
  tier: string; // "t1_mining" | "t2_staking" | "t3_liquidity" | "t4_arbitrage"
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
  venue: string; // "omnibus_native" | "lcx" | "kraken" | "coinbase" | "omnibus_ex" | "uniswap" | "none"
  kind: string;  // "buy" | "sell" | "stake" | etc.
  pair: string;
  amount_sat: number;
  reason: string;
};

type PendingResp = {
  count: number;
  decisions: PendingDecision[];
};

// ─── Utilities ──────────────────────────────────────────────────────────────

const omniFmt = (sat: number) => (sat / SAT_PER_OMNI).toFixed(8);

const TIER_INFO: Record<string, { label: string; color: string; threshold: string }> = {
  t1_mining:    { label: "T1 Mining",    color: "bg-gray-700/50 text-gray-300",       threshold: "0+ OMNI" },
  t2_staking:   { label: "T2 Staking",   color: "bg-blue-500/20 text-blue-300",       threshold: "≥100 OMNI" },
  t3_liquidity: { label: "T3 Liquidity", color: "bg-purple-500/20 text-purple-300",   threshold: "≥1k OMNI" },
  t4_arbitrage: { label: "T4 Arbitrage", color: "bg-emerald-500/20 text-emerald-300", threshold: "≥10k OMNI" },
};

const VENUE_COLOR: Record<string, string> = {
  omnibus_native: "bg-amber-500/20 text-amber-300",
  lcx:            "bg-blue-500/20 text-blue-300",
  kraken:         "bg-violet-500/20 text-violet-300",
  coinbase:       "bg-sky-500/20 text-sky-300",
  omnibus_ex:     "bg-orange-500/20 text-orange-300",
  uniswap:        "bg-pink-500/20 text-pink-300",
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

// ─── Page ────────────────────────────────────────────────────────────────────

export function AgentsPage() {
  const [agents, setAgents] = useState<AgentSnap[]>([]);
  const [pending, setPending] = useState<PendingDecision[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [methodMissing, setMethodMissing] = useState(false);

  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      try {
        const [list, pend] = await Promise.all([
          rpc.request_raw("agent_list", []) as Promise<AgentListResp>,
          // pending may fail independently — wrap so a single failure doesn't blank the page
          rpc.request_raw("agent_pending_decisions", []).catch(() => ({ count: 0, decisions: [] })) as Promise<PendingResp>,
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
          // -32601 "Method not found" → node runs old version without agent_list.
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
    refresh();
    const id = setInterval(refresh, 5000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, []);

  // ── Aggregate metrics ────────────────────────────────────────────────────
  const totalCapital = agents.reduce(
    (acc, a) => acc + a.balance_sat + a.staked_sat + a.lp_locked_sat,
    0,
  );
  const tierCounts = agents.reduce<Record<string, number>>((acc, a) => {
    acc[a.tier] = (acc[a.tier] || 0) + 1;
    return acc;
  }, {});
  const totalQueued = agents.reduce((acc, a) => acc + a.stats.decisions_queued, 0);
  const totalExecSuccess = agents.reduce((acc, a) => acc + a.stats.exec_success, 0);
  const totalExecFailed = agents.reduce((acc, a) => acc + a.stats.exec_failed, 0);

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      <h1 className="text-2xl font-bold text-mempool-text mb-2">AI Agents</h1>
      <p className="text-mempool-text-dim text-sm mb-6">
        Autonomous agents loaded via <code className="text-mempool-blue">--agent-config agent.json</code>.
        Each agent has its own wallet, tier and strategy. Tier upgrades automatically
        based on capital (mining → staking → liquidity → arbitrage).
      </p>

      {/* Method-not-found banner — node runs old version */}
      {methodMissing && (
        <div className="mb-6 p-4 rounded-lg border border-amber-500/40 bg-amber-500/10 text-amber-200 text-sm">
          <p className="font-semibold mb-1">Agent system not available on this node.</p>
          <p className="text-amber-100/80">
            The connected node does not expose <code>agent_list</code> RPC — it runs
            an older build. Deploy a build from this branch (with{" "}
            <code>core/agent_manager.zig</code>) and start it with{" "}
            <code>--agent-config FILE</code> to populate this page.
          </p>
        </div>
      )}

      {/* Aggregate metrics (only when we have data) */}
      {!methodMissing && agents.length > 0 && (
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
          <Metric label="Agents" value={agents.length.toString()} />
          <Metric label="Total capital" value={`${omniFmt(totalCapital)} OMNI`} />
          <Metric label="Decisions queued" value={totalQueued.toLocaleString()} />
          <Metric
            label="Exec success / fail"
            value={`${totalExecSuccess.toLocaleString()} / ${totalExecFailed.toLocaleString()}`}
          />
          {Object.keys(TIER_INFO).map((tier) => (
            <Metric
              key={tier}
              label={TIER_INFO[tier].label}
              value={(tierCounts[tier] || 0).toString()}
            />
          ))}
        </div>
      )}

      {/* Agents table */}
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-hidden mb-8">
        {loading && agents.length === 0 && !methodMissing && (
          <div className="p-8 text-center text-mempool-text-dim text-sm">Loading agents…</div>
        )}
        {error && (
          <div className="p-4 text-red-400 text-sm">RPC error: {error}</div>
        )}
        {!loading && !methodMissing && agents.length === 0 && !error && (
          <div className="p-8 text-center text-mempool-text-dim text-sm">
            No agents loaded. Pass <code className="text-mempool-blue">--agent-config agent.json</code> at node startup.
          </div>
        )}
        {agents.length > 0 && (
          <div className="overflow-x-auto">
          <table className="w-full text-sm min-w-[600px]">
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
                      onClick={() => navigator.clipboard.writeText(a.address)}
                      className="text-mempool-blue hover:underline"
                      title={a.address}
                    >
                      {a.address.slice(0, 12)}…{a.address.slice(-6)}
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

      {/* Pending decisions queue (non-native venues — Python client picks these up) */}
      {!methodMissing && (
        <div>
          <h2 className="text-lg font-semibold text-mempool-text mb-2">Pending decisions queue</h2>
          <p className="text-mempool-text-dim text-xs mb-3">
            Decisions emitted by agents for external venues (LCX, Kraken, Coinbase, ...).
            Picked up by the Python agent client via <code>agent_pending_decisions</code> RPC.
          </p>
          <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-x-auto">
            {pending.length === 0 ? (
              <div className="p-6 text-center text-mempool-text-dim text-sm">
                No pending decisions. Either no agents have emitted non-native decisions yet,
                or the Python client has already picked them all up.
              </div>
            ) : (
              <table className="w-full text-sm min-w-[600px]">
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

      <div className="mt-6 text-xs text-mempool-text-dim">
        <p>
          <span className="font-semibold text-mempool-text">Refresh:</span> auto every 5s.
        </p>
        <p className="mt-1">
          <span className="font-semibold text-mempool-text">Setup:</span> see{" "}
          <code>1_CORE/BlockChainCore/docs/USER_JOURNEY.md</code> for agent.json schema and
          tier progression rules.
        </p>
      </div>
    </div>
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
