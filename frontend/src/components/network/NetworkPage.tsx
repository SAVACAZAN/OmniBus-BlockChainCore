import { useEffect, useState } from "react";
import { NetworkStatus } from "./NetworkStatus";
import { MinerTable } from "./MinerTable";
import { AddressLookup } from "../search/AddressLookup";
import { useBlockchain } from "../../stores/useBlockchainStore";
import { OmniBusRpcClient } from "../../api/rpc-client";

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

function NetworkRpcPanels() {
  const [sync, setSync] = useState<SyncStatus | null>(null);
  const [peers, setPeers] = useState<PeerInfo[]>([]);
  const [miners, setMiners] = useState<MinerEntry[]>([]);

  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      const [s, p, m] = await Promise.allSettled([
        rpc.request_raw("getsyncstatus", []) as Promise<SyncStatus>,
        rpc.request_raw("getpeerinfo", []) as Promise<{ result: PeerInfo[] } | PeerInfo[]>,
        rpc.request_raw("omnibus_getminers", []) as Promise<MinerEntry[]>,
      ]);
      if (cancelled) return;
      if (s.status === "fulfilled") setSync(s.value);
      if (p.status === "fulfilled") {
        const v = p.value;
        setPeers(Array.isArray(v) ? v : ((v as { result: PeerInfo[] }).result ?? []));
      }
      if (m.status === "fulfilled") setMiners(Array.isArray(m.value) ? m.value : []);
    };
    refresh();
    const id = setInterval(refresh, 8_000);
    return () => { cancelled = true; clearInterval(id); };
  }, []);

  return (
    <div className="space-y-4">
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
          <div className="px-4 py-2.5 border-b border-mempool-border">
            <h3 className="text-xs font-semibold text-mempool-text-dim uppercase tracking-wider">
              Peer Info (RPC) — {peers.length} peers
            </h3>
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
                      {p.last_seen ? new Date(p.last_seen * 1000).toLocaleTimeString() : "—"}
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
                <span className="font-mono text-mempool-text">{m.address}</span>
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
