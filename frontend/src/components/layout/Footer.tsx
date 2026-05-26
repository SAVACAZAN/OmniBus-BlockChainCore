import { useBlockchain } from "../../stores/useBlockchainStore";
import { getActiveChain } from "../../api/rpc-client";

export function Footer() {
  const { state } = useBlockchain();
  const chain = getActiveChain();

  const chainBadge =
    chain === "mainnet"
      ? "text-mempool-blue"
      : chain === "testnet"
      ? "text-mempool-orange"
      : "text-mempool-purple";

  return (
    <footer className="border-t border-mempool-border py-2.5 mt-auto">
      <div className="max-w-7xl mx-auto px-4 flex flex-wrap items-center justify-between gap-x-4 gap-y-1 text-[10px] text-mempool-text-dim font-mono">
        {/* Left — branding + chain */}
        <div className="flex items-center gap-2">
          <span className="text-mempool-text">OmniBus</span>
          <span className={`uppercase font-semibold ${chainBadge}`}>{chain}</span>
          <span className="text-mempool-border">·</span>
          <span>Post-Quantum</span>
          <span className="text-mempool-border">·</span>
          <span>SAT/OMNI: 1e9</span>
        </div>

        {/* Right — live chain status */}
        <div className="flex items-center gap-3">
          {/* WS status */}
          <span className="flex items-center gap-1">
            <span
              className={`inline-block w-1.5 h-1.5 rounded-full ${
                state.wsConnected ? "bg-mempool-green" : "bg-mempool-red"
              }`}
            />
            {state.wsConnected ? "WS connected" : "WS disconnected"}
          </span>

          {state.peers.length > 0 && (
            <>
              <span className="text-mempool-border">·</span>
              <span>{state.peers.length} peer{state.peers.length !== 1 ? "s" : ""}</span>
            </>
          )}

          {state.blockCount > 0 && (
            <>
              <span className="text-mempool-border">·</span>
              <span>
                block{" "}
                <span className="text-mempool-blue">#{state.blockCount.toLocaleString()}</span>
              </span>
            </>
          )}

          {state.mempoolSize > 0 && (
            <>
              <span className="text-mempool-border">·</span>
              <span>
                mempool{" "}
                <span className="text-mempool-orange">{state.mempoolSize}</span>
              </span>
            </>
          )}

          <span className="text-mempool-border">·</span>
          <span>RPC :8332 · WS :8334</span>
        </div>
      </div>
    </footer>
  );
}
