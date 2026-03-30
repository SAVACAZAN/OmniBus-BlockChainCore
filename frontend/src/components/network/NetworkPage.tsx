import { NetworkStatus } from "./NetworkStatus";
import { MinerTable } from "./MinerTable";
import { AddressLookup } from "../search/AddressLookup";
import { useBlockchain } from "../../stores/useBlockchainStore";

export function NetworkPage() {
  const { state } = useBlockchain();

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-6">
      <h2 className="text-lg font-bold text-mempool-text">Network Overview</h2>

      {/* Connection status */}
      <div className="bg-mempool-card rounded-xl border border-mempool-border p-5">
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

      {/* Address Lookup */}
      <AddressLookup />

      {/* Peers */}
      <div className="bg-mempool-card rounded-xl border border-mempool-border overflow-hidden">
        <div className="px-5 py-3 border-b border-mempool-border">
          <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
            Peers ({state.peers.length})
          </h3>
        </div>
        {state.peers.length === 0 ? (
          <div className="px-5 py-6 text-center text-sm text-mempool-text-dim">
            No peers connected (solo mining mode)
          </div>
        ) : (
          <div className="divide-y divide-mempool-border/30">
            {state.peers.map((p) => (
              <div key={p.id} className="px-5 py-2.5 flex items-center gap-3">
                <div className={`w-2 h-2 rounded-full ${p.alive ? "bg-mempool-green" : "bg-mempool-red"}`} />
                <span className="text-xs font-mono text-mempool-text">{p.id}</span>
                <span className="text-xs text-mempool-text-dim">{p.host}:{p.port}</span>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
