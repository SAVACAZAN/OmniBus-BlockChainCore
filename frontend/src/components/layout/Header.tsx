import { useState, useEffect } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import { TxSearch } from "../search/TxSearch";
import { getActiveChain, setActiveChain, type ChainName } from "../../api/rpc-client";

declare global {
  interface Window { __openTx?: (txid: string) => void }
}

const CHAIN_BADGE: Record<ChainName, { label: string; cls: string }> = {
  mainnet: { label: "Mainnet", cls: "bg-mempool-blue/20 text-mempool-blue" },
  testnet: { label: "Testnet", cls: "bg-mempool-orange/20 text-mempool-orange" },
  regtest: { label: "Regtest", cls: "bg-mempool-purple/20 text-mempool-purple" },
};

export function Header() {
  const { state } = useBlockchain();
  const [showSearch, setShowSearch] = useState(false);
  const [searchInitial, setSearchInitial] = useState<string>("");
  const activeChain = getActiveChain();

  // Permite altor componente sa deschida cautarea cu un TX preselectat
  // — RecentTransactions.tsx face <button onClick={() => window.__openTx(id)}>
  useEffect(() => {
    window.__openTx = (txid: string) => {
      setSearchInitial(txid);
      setShowSearch(true);
    };
    return () => { delete window.__openTx; };
  }, []);

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
            {/* Chain switcher — saves to localStorage and reloads */}
            <div className="flex items-center gap-2">
              <span className={`px-2 py-0.5 rounded text-[10px] font-bold uppercase ${CHAIN_BADGE[activeChain].cls}`}>
                {CHAIN_BADGE[activeChain].label}
              </span>
              <select
                value={activeChain}
                onChange={(e) => setActiveChain(e.target.value as ChainName)}
                className="bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text hover:border-mempool-blue cursor-pointer"
                title="Switch chain (reloads page)"
              >
                <option value="mainnet">Mainnet :8332</option>
                <option value="testnet">Testnet :18332</option>
                <option value="regtest">Regtest :28332</option>
              </select>
            </div>

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
      {showSearch && (
        <TxSearch
          onClose={() => { setShowSearch(false); setSearchInitial(""); }}
          initialQuery={searchInitial}
        />
      )}
    </>
  );
}
