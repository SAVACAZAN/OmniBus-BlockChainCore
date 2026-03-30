import { useBlockchain } from "../../stores/useBlockchainStore";

export function NetworkStatus() {
  const { state } = useBlockchain();
  const net = state.networkInfo;

  return (
    <div className="bg-mempool-card rounded-lg border border-mempool-border">
      <div className="px-4 py-3 border-b border-mempool-border">
        <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
          Network
        </h3>
      </div>
      <div className="p-4 grid grid-cols-2 md:grid-cols-4 gap-4">
        <div>
          <p className="text-[10px] text-mempool-text-dim uppercase">Chain</p>
          <p className="text-sm font-mono text-mempool-text">
            {net?.chain || "omnibus-mainnet"}
          </p>
        </div>
        <div>
          <p className="text-[10px] text-mempool-text-dim uppercase">Peers</p>
          <p className="text-sm font-mono text-mempool-blue">
            {state.peers.length}
          </p>
        </div>
        <div>
          <p className="text-[10px] text-mempool-text-dim uppercase">Miners</p>
          <p className="text-sm font-mono text-mempool-green">
            {state.miners.length}
          </p>
        </div>
        <div>
          <p className="text-[10px] text-mempool-text-dim uppercase">Block Time</p>
          <p className="text-sm font-mono text-mempool-text">
            {net?.blockTimeMs ? `${net.blockTimeMs}ms` : "1000ms"}
          </p>
        </div>
        <div>
          <p className="text-[10px] text-mempool-text-dim uppercase">Max Supply</p>
          <p className="text-sm font-mono text-mempool-text">
            21M OMNI
          </p>
        </div>
        <div>
          <p className="text-[10px] text-mempool-text-dim uppercase">Halving</p>
          <p className="text-sm font-mono text-mempool-text">
            {net?.halvingInterval ? (net.halvingInterval / 1e6).toFixed(0) + "M blocks" : "126M blocks"}
          </p>
        </div>
        <div>
          <p className="text-[10px] text-mempool-text-dim uppercase">Sub-blocks</p>
          <p className="text-sm font-mono text-mempool-text">
            {net?.subBlocksPerBlock || 10} × 100ms
          </p>
        </div>
        <div>
          <p className="text-[10px] text-mempool-text-dim uppercase">Version</p>
          <p className="text-sm font-mono text-mempool-text">
            {net?.version || "1.0.0"}
          </p>
        </div>
      </div>
    </div>
  );
}
