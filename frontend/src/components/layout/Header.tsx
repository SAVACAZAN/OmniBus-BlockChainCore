import { useState } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import { TxSearch } from "../search/TxSearch";

export function Header() {
  const { state } = useBlockchain();
  const [showSearch, setShowSearch] = useState(false);

  return (
    <>
      <header className="sticky top-0 z-50 bg-mempool-bg/95 backdrop-blur-sm border-b border-mempool-border">
        <div className="max-w-7xl mx-auto px-4 py-3 flex items-center justify-between">
          {/* Logo */}
          <div className="flex items-center gap-3">
            <div className="w-8 h-8 rounded-lg bg-gradient-to-br from-mempool-blue to-mempool-purple flex items-center justify-center text-white font-bold text-sm">
              O
            </div>
            <div>
              <h1 className="text-lg font-bold text-mempool-text leading-tight">
                OmniBus
              </h1>
              <p className="text-xs text-mempool-text-dim">BlockChain Explorer</p>
            </div>
          </div>

          {/* Search + Block Height */}
          <div className="flex items-center gap-4">
            <button
              onClick={() => setShowSearch(true)}
              className="flex items-center gap-2 bg-mempool-bg border border-mempool-border rounded-lg px-3 py-1.5 text-xs text-mempool-text-dim hover:text-mempool-text hover:border-mempool-blue transition-colors"
            >
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <circle cx="11" cy="11" r="8" />
                <path d="M21 21l-4.35-4.35" />
              </svg>
              <span className="hidden sm:inline">Search TX</span>
            </button>
            <div className="text-center">
              <p className="text-xs text-mempool-text-dim uppercase tracking-wider">
                Block Height
              </p>
              <p className="text-2xl font-mono font-bold text-mempool-text">
                {state.blockCount.toLocaleString()}
              </p>
            </div>
          </div>

          {/* Status Indicators */}
          <div className="flex items-center gap-4">
            {/* WS Status */}
            <div className="flex items-center gap-2">
              <div
                className={`w-2 h-2 rounded-full ${
                  state.wsConnected
                    ? "bg-mempool-green animate-pulse"
                    : "bg-mempool-red"
                }`}
              />
              <span className="text-xs text-mempool-text-dim">
                {state.wsConnected ? "Live" : "Polling"}
              </span>
            </div>

            {/* Miners */}
            <div className="text-right">
              <p className="text-xs text-mempool-text-dim">Miners</p>
              <p className="text-sm font-mono text-mempool-green">
                {state.miners.length}
              </p>
            </div>

            {/* Peers */}
            <div className="text-right">
              <p className="text-xs text-mempool-text-dim">Peers</p>
              <p className="text-sm font-mono text-mempool-text">
                {state.peers.length}
              </p>
            </div>

            {/* Mining Status */}
            <div
              className={`px-3 py-1 rounded-full text-xs font-medium ${
                state.isMining
                  ? "bg-mempool-green/20 text-mempool-green"
                  : "bg-mempool-orange/20 text-mempool-orange"
              }`}
            >
              {state.isMining ? "Mining" : "Syncing"}
            </div>
          </div>
        </div>
      </header>

      {/* TX Search Modal */}
      {showSearch && <TxSearch onClose={() => setShowSearch(false)} />}
    </>
  );
}
