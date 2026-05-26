import { useEffect, useState } from "react";
import { NetworkStatus } from "./NetworkStatus";
import { MinerTable } from "./MinerTable";
import { AddressLookup } from "../search/AddressLookup";
import { useBlockchain } from "../../stores/useBlockchainStore";
import { fmtAge, SAT_PER_OMNI } from "../../utils/fmt";
import { OmniBusRpcClient } from "../../api/rpc-client";
import { AddressLabel } from "../common/AddressLabel";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsNewBlockEvent } from "../../types";

const rpc = new OmniBusRpcClient();

interface SyncStatus {
  status: string;
  localHeight: number;
  peerHeight: number;
  behind: number;
  progress: number;
  synced: boolean;
  stalled: boolean;
  ibd: boolean;
}

interface PeerInfo {
  id: string;
  addr: string;
  host: string;
  port: number;
  height: number;
  version: string;
  alive: boolean;
  last_seen: number;
}

interface MinerEntry {
  address: string;
  node_id: string;
  status: string;
}

interface NodeStatus {
  status: string;
  blockCount: number;
  mempoolSize: number;
  address: string;
  balance: number;
}

interface MiningInfo {
  blocks: number;
  difficulty: number;
  networkhashps: number;
  hashrate: number;
  pooledtx: number;
  chain: string;
  currentblockreward: number;
}

interface PerformanceInfo {
  uptime_seconds: number;
  blocks_mined: number;
  blocks_per_minute: number;
  txs_processed: number;
  tps_current: number;
  mempool_throughput: number;
  avg_block_time_ms: number;
  peak_tps: number;
  rpc_requests_total: number;
  p2p_messages_total: number;
  hashrate: number;
}

interface MempoolInfo {
  size: number;
  bytes: number;
}

export function NetworkPage() {
  const { state } = useBlockchain();

  return (
    <div className="max-w-7xl mx-auto px-3 sm:px-4 py-4 sm:py-6 space-y-4 sm:space-y-6">
      <h2 className="text-base sm:text-lg font-bold text-mempool-text">Network Overview</h2>

      {/* Connection status */}
      <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4 sm:p-5">
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div>
            <p className="text-[10px] text-mempool-text-dim uppercase">WebSocket</p>
            <p className={`text-sm font-bold ${state.wsConnected ? "text-mempool-green" : "text-mempool-red"}`}>
              {state.wsConnected ? "Connected" : "Disconnected"}
            </p>
          </div>
          <div>
            <p className="text-[10px] text-mempool-text-dim uppercase">Mining</p>
            <p className={`text-sm font-bold ${state.isMining ? "text-mempool-green" : "text-mempool-orange"}`}>
              {state.isMining ? "Active" : "Waiting"}
            </p>
          </div>
          <div>
            <p className="text-[10px] text-mempool-text-dim uppercase">Block Height</p>
            <p className="text-sm font-bold text-mempool-blue font-mono">{state.blockCount}</p>
          </div>
          <div>
            <p className="text-[10px] text-mempool-text-dim uppercase">Difficulty</p>
            <p className="text-sm font-bold text-mempool-text font-mono">{state.difficulty}</p>
          </div>
        </div>
      </div>

      <NetworkStatus />
      <MinerTable />

      {/* Sync status + peer info + online miners */}
      <NetworkRpcPanels />

      {/* Miner TX (minersendtx) */}
      <MinerSendTxPanel />

      {/* Address Lookup */}
      <AddressLookup />

      {/* Peers (WebSocket state) */}
      <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border overflow-hidden">
        <div className="px-5 py-3 border-b border-mempool-border">
          <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
            Peers ({state.peers.length})
          </h3>
        </div>
        {state.peers.length === 0 ? (
          <div className="px-4 sm:px-5 py-6 text-center text-sm text-mempool-text-dim">
            No peers connected (solo mining mode)
          </div>
        ) : (
          <div className="divide-y divide-mempool-border/30">
            {state.peers.map((p) => (
              <div key={p.id} className="px-4 sm:px-5 py-2.5 flex flex-wrap items-center gap-2 sm:gap-3">
                <div className={`w-2 h-2 rounded-full flex-shrink-0 ${p.alive ? "bg-mempool-green" : "bg-mempool-red"}`} />
                <span className="text-xs font-mono text-mempool-text break-all">{p.id}</span>
                <span className="text-xs text-mempool-text-dim break-all">{p.host}:{p.port}</span>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function fmtUptime(seconds: number): string {
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d}d ${h}h ${m}m`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

function NetworkRpcPanels() {
  const [sync, setSync] = useState<SyncStatus | null>(null);
  const [peers, setPeers] = useState<PeerInfo[]>([]);
  const [miners, setMiners] = useState<MinerEntry[]>([]);
  const [nodeStatus, setNodeStatus] = useState<NodeStatus | null>(null);
  const [miningInfo, setMiningInfo] = useState<MiningInfo | null>(null);
  const [perfInfo, setPerfInfo] = useState<PerformanceInfo | null>(null);
  const [mempoolInfo, setMempoolInfo] = useState<MempoolInfo | null>(null);
  const [connCount, setConnCount] = useState<number | null>(null);
  const [difficulty, setDifficulty] = useState<number | null>(null);

  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      const [s, p, m, ns, mi, perf, mpi, cc, diff] = await Promise.allSettled([
        rpc.request_raw("getsyncstatus", []) as Promise<SyncStatus>,
        rpc.request_raw("getpeerinfo", []) as Promise<{ result: PeerInfo[] } | PeerInfo[]>,
        rpc.request_raw("omnibus_getminers", []) as Promise<MinerEntry[]>,
        rpc.request_raw("getstatus", []) as Promise<NodeStatus>,
        rpc.request_raw("getmininginfo", []) as Promise<MiningInfo>,
        rpc.request_raw("getperformance", []) as Promise<PerformanceInfo>,
        rpc.request_raw("getmempoolinfo", []) as Promise<MempoolInfo>,
        rpc.request_raw("getconnectioncount", []) as Promise<number>,
        rpc.request_raw("getdifficulty", []) as Promise<number>,
      ]);
      if (cancelled) return;
      if (s.status === "fulfilled") setSync(s.value);
      if (p.status === "fulfilled") {
        const v = p.value;
        setPeers(Array.isArray(v) ? v : ((v as { result: PeerInfo[] }).result ?? []));
      }
      if (m.status === "fulfilled") setMiners(Array.isArray(m.value) ? m.value : []);
      if (ns.status === "fulfilled") setNodeStatus(ns.value);
      if (mi.status === "fulfilled") setMiningInfo(mi.value);
      if (perf.status === "fulfilled") setPerfInfo(perf.value);
      if (mpi.status === "fulfilled") setMempoolInfo(mpi.value);
      if (cc.status === "fulfilled") setConnCount(typeof cc.value === "number" ? cc.value : null);
      if (diff.status === "fulfilled") setDifficulty(typeof diff.value === "number" ? diff.value : null);
    };
    refresh();
    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", () => { void refresh(); });
    const id = setInterval(refresh, 60_000);
    return () => { cancelled = true; clearInterval(id); unsub(); };
  }, []);

  return (
    <div className="space-y-4">
      {/* Node status + mining info + performance + mempool info — 4 stat cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-3">
        {nodeStatus && (
          <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev p-3 space-y-1.5">
            <div className="text-[9px] uppercase tracking-wider text-mempool-text-dim font-semibold">Node Status</div>
            {[
              ["Status", nodeStatus.status],
              ["Blocks", String(nodeStatus.blockCount)],
              ["Mempool", `${nodeStatus.mempoolSize} tx`],
            ].map(([k, v]) => (
              <div key={k} className="flex justify-between text-xs">
                <span className="text-mempool-text-dim">{k}</span>
                <span className="font-mono text-mempool-text">{v}</span>
              </div>
            ))}
            {nodeStatus.address && (
              <div className="flex justify-between text-xs">
                <span className="text-mempool-text-dim">Address</span>
                <button onClick={() => { window.location.hash = `#/address/${nodeStatus.address}`; }} className="font-mono text-mempool-text hover:text-mempool-blue hover:underline">
                  <AddressLabel address={nodeStatus.address} showEmoji truncate={{ left: 10, right: 6 }} />
                </button>
              </div>
            )}
          </div>
        )}
        {miningInfo && (
          <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev p-3 space-y-1.5">
            <div className="text-[9px] uppercase tracking-wider text-mempool-text-dim font-semibold">Mining Info</div>
            {[
              ["Chain", miningInfo.chain],
              ["Difficulty", String(miningInfo.difficulty)],
              ["Hashrate", `${miningInfo.hashrate.toLocaleString()} H/s`],
              ["Reward", `${(miningInfo.currentblockreward / SAT_PER_OMNI).toFixed(4)} OMNI`],
              ["Pooled TX", String(miningInfo.pooledtx)],
            ].map(([k, v]) => (
              <div key={k} className="flex justify-between text-xs">
                <span className="text-mempool-text-dim">{k}</span>
                <span className="font-mono text-mempool-text">{v}</span>
              </div>
            ))}
          </div>
        )}
        {perfInfo && (
          <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev p-3 space-y-1.5">
            <div className="text-[9px] uppercase tracking-wider text-mempool-text-dim font-semibold">Performance</div>
            {[
              ["Uptime", fmtUptime(perfInfo.uptime_seconds)],
              ["TPS (now)", String(perfInfo.tps_current)],
              ["Peak TPS", String(perfInfo.peak_tps)],
              ["Blocks/min", String(perfInfo.blocks_per_minute)],
              ["Avg block", `${perfInfo.avg_block_time_ms}ms`],
              ["RPC reqs", String(perfInfo.rpc_requests_total)],
            ].map(([k, v]) => (
              <div key={k} className="flex justify-between text-xs">
                <span className="text-mempool-text-dim">{k}</span>
                <span className="font-mono text-mempool-text">{v}</span>
              </div>
            ))}
          </div>
        )}
        {mempoolInfo && (
          <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev p-3 space-y-1.5">
            <div className="text-[9px] uppercase tracking-wider text-mempool-text-dim font-semibold">Mempool &amp; Connections</div>
            {[
              ["TX count", String(mempoolInfo.size)],
              ["Bytes", mempoolInfo.bytes > 0 ? `${mempoolInfo.bytes.toLocaleString()} B` : "—"],
              ...(connCount !== null ? [["Connections", String(connCount)]] : []),
              ...(difficulty !== null ? [["Difficulty", String(difficulty)]] : []),
            ].map(([k, v]) => (
              <div key={k} className="flex justify-between text-xs">
                <span className="text-mempool-text-dim">{k}</span>
                <span className="font-mono text-mempool-text">{v}</span>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Sync status */}
      {sync && (
        <div className={`rounded-xl border p-4 ${
          sync.synced ? "border-green-500/30 bg-green-500/5" : "border-yellow-500/30 bg-yellow-500/5"
        }`}>
          <h3 className="text-xs font-semibold uppercase tracking-wider mb-2 text-mempool-text-dim">
            Sync Status
          </h3>
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 text-xs">
            <div className="bg-mempool-bg/50 rounded p-2">
              <div className="text-mempool-text-dim text-[9px] uppercase">Status</div>
              <div className={sync.synced ? "text-green-400 font-semibold" : "text-yellow-400 font-semibold"}>
                {sync.synced ? "Synced" : sync.ibd ? "IBD" : sync.stalled ? "Stalled" : sync.status}
              </div>
            </div>
            <div className="bg-mempool-bg/50 rounded p-2">
              <div className="text-mempool-text-dim text-[9px] uppercase">Local</div>
              <div className="font-mono text-mempool-text">{sync.localHeight}</div>
            </div>
            <div className="bg-mempool-bg/50 rounded p-2">
              <div className="text-mempool-text-dim text-[9px] uppercase">Peer best</div>
              <div className="font-mono text-mempool-text">{sync.peerHeight}</div>
            </div>
            <div className="bg-mempool-bg/50 rounded p-2">
              <div className="text-mempool-text-dim text-[9px] uppercase">Behind</div>
              <div className={`font-mono ${sync.behind > 0 ? "text-yellow-400" : "text-green-400"}`}>
                {sync.behind} blocks ({sync.progress.toFixed(2)}%)
              </div>
            </div>
          </div>
        </div>
      )}

      {/* Peer info (RPC) */}
      {peers.length > 0 && (
        <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev overflow-hidden">
          <div className="px-4 py-2.5 border-b border-mempool-border flex items-center justify-between">
            <h3 className="text-xs font-semibold text-mempool-text-dim uppercase tracking-wider">
              Peer Info (RPC) — {peers.length} peers
            </h3>
            <button
              onClick={() => {
                const rows = [
                  ["id", "host", "port", "height", "version", "status", "last_seen"].join(","),
                  ...peers.map((p) => [
                    `"${p.id}"`,
                    p.host,
                    p.port,
                    p.height,
                    p.version || "",
                    p.alive ? "alive" : "dead",
                    p.last_seen ? new Date(p.last_seen * 1000).toISOString() : "",
                  ].join(",")),
                ].join("\n");
                const blob = new Blob([rows], { type: "text/csv" });
                const url = URL.createObjectURL(blob);
                const a = document.createElement("a");
                a.href = url; a.download = "omnibus-peers.csv";
                a.click(); URL.revokeObjectURL(url);
              }}
              className="px-2 py-1 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue font-mono"
            >
              ⬇ CSV
            </button>
          </div>
          <div className="overflow-x-auto">
            <table className="w-full text-xs min-w-[500px]">
              <thead className="bg-mempool-bg text-mempool-text-dim uppercase text-[9px]">
                <tr>
                  <th className="px-3 py-2 text-left">ID</th>
                  <th className="px-3 py-2 text-left">Address</th>
                  <th className="px-3 py-2 text-right">Height</th>
                  <th className="px-3 py-2 text-left">Version</th>
                  <th className="px-3 py-2 text-left">Status</th>
                  <th className="px-3 py-2 text-right">Last seen</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-mempool-border/30">
                {peers.map((p) => (
                  <tr key={p.id} className="hover:bg-mempool-bg-light/30">
                    <td className="px-3 py-1.5 font-mono text-mempool-text-dim">{p.id.slice(0, 12)}…</td>
                    <td className="px-3 py-1.5 font-mono text-mempool-text">{p.host}:{p.port}</td>
                    <td className="px-3 py-1.5 text-right font-mono text-mempool-blue">{p.height}</td>
                    <td className="px-3 py-1.5 text-mempool-text-dim">{p.version || "—"}</td>
                    <td className="px-3 py-1.5">
                      <span className={`px-1.5 py-0.5 rounded text-[9px] ${p.alive ? "bg-green-500/10 text-green-400" : "bg-red-500/10 text-red-400"}`}>
                        {p.alive ? "alive" : "dead"}
                      </span>
                    </td>
                    <td className="px-3 py-1.5 text-right text-mempool-text-dim">
                      {p.last_seen
                        ? <span title={new Date(p.last_seen * 1000).toLocaleString()}>{fmtAge(p.last_seen)}</span>
                        : "—"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* Online miners (omnibus_getminers) */}
      {miners.length > 0 && (
        <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev overflow-hidden">
          <div className="px-4 py-2.5 border-b border-mempool-border">
            <h3 className="text-xs font-semibold text-mempool-text-dim uppercase tracking-wider">
              Online Miners — {miners.length}
            </h3>
          </div>
          <div className="divide-y divide-mempool-border/30">
            {miners.map((m) => (
              <div key={m.address} className="px-4 py-2 flex items-center gap-3 text-xs">
                <span className="w-2 h-2 rounded-full bg-green-400 flex-shrink-0" />
                <button onClick={() => { window.location.hash = `#/address/${m.address}`; }} className="font-mono text-mempool-text hover:text-mempool-blue hover:underline transition-colors">
                  <AddressLabel address={m.address} showEmoji truncate={{ left: 10, right: 6 }} />
                </button>
                <span className="text-mempool-text-dim">{m.node_id}</span>
                <span className="ml-auto text-green-400 text-[9px] uppercase">{m.status}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

// ── MinerSendTx panel (minersendtx) ───────────────────────────────────────────

function MinerSendTxPanel() {
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [amount, setAmount] = useState("");
  const [fee, setFee] = useState("1000");
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<{ ok: boolean; msg: string } | null>(null);

  const send = async () => {
    if (!from || !to || !amount) return;
    setLoading(true); setResult(null);
    try {
      const r = await rpc.request_raw("minersendtx", [
        from.trim(), to.trim(), parseInt(amount), parseInt(fee) || 1000,
      ]) as { txid?: string; tx_hash?: string; error?: string };
      if (r && (r.txid || r.tx_hash)) {
        setResult({ ok: true, msg: `TX: ${(r.txid ?? r.tx_hash ?? "").slice(0, 32)}…` });
      } else {
        setResult({ ok: false, msg: r?.error ?? JSON.stringify(r) });
      }
    } catch (e) { setResult({ ok: false, msg: String(e) }); }
    finally { setLoading(false); }
  };

  return (
    <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev p-4 space-y-3">
      <h3 className="text-xs font-semibold text-mempool-text-dim uppercase tracking-wider">
        Miner Send TX (minersendtx)
      </h3>
      <p className="text-[11px] text-mempool-text-dim">
        Send a transaction from a registered miner's wallet. The node must be running with that miner's key. Used for automated miner payouts or fee distribution.
      </p>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
        {([
          ["From (miner address)", from, setFrom, "ob1q…"],
          ["To (recipient)", to, setTo, "ob1q…"],
          ["Amount (SAT)", amount, setAmount, "100000000"],
          ["Fee (SAT)", fee, setFee, "1000"],
        ] as [string, string, (v: string) => void, string][]).map(([label, val, setter, ph]) => (
          <div key={label} className="space-y-0.5">
            <label className="text-[9px] uppercase text-mempool-text-dim">{label}</label>
            <input
              value={val}
              onChange={(e) => setter(e.target.value)}
              placeholder={ph}
              className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
            />
          </div>
        ))}
      </div>
      <button
        onClick={send}
        disabled={loading || !from || !to || !amount}
        className="w-full py-2 text-xs font-medium bg-orange-500/20 hover:bg-orange-500/40 text-orange-300 border border-orange-500/30 rounded disabled:opacity-50"
      >
        {loading ? "Sending…" : "Send Miner TX"}
      </button>
      {result && (
        <div className={`rounded px-3 py-2 text-xs border ${result.ok ? "bg-green-500/10 border-green-500/30 text-green-300" : "bg-red-500/10 border-red-500/30 text-red-300"}`}>
          {result.msg}
        </div>
      )}
    </div>
  );
}
