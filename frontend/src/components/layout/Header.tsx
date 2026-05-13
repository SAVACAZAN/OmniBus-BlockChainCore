import { useState, useEffect } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import { TxSearch } from "../search/TxSearch";
import { getActiveChain, setActiveChain, type ChainName } from "../../api/rpc-client";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import { PlasmaLogo } from "../effects/PlasmaLogo";
import { PlasmaLogoOrange } from "../effects/PlasmaLogoOrange";
import { ElectricOrganism } from "../effects/ElectricOrganism";
import { MatrixRain } from "../effects/MatrixRain";
import { WalletConnectButton } from "./WalletConnectButton";
import { GlobalBalancePill } from "./GlobalBalancePill";

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
  // Brief flash on every new_block — purely visual, signals chain liveness.
  // 600 ms matches the CSS animation length below; auto-clears via setTimeout.
  const [blockPulse, setBlockPulse] = useState(false);
  const activeChain = getActiveChain();

  useEffect(() => {
    return wsSubscribe<import("../../types").WsNewBlockEvent>("new_block", () => {
      setBlockPulse(true);
      window.setTimeout(() => setBlockPulse(false), 600);
    });
  }, []);

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
      <header className="sticky top-0 z-50 bg-mempool-bg-elev backdrop-blur-sm border-b border-mempool-border">
        {/* ── Desktop layout (sm+) ── */}
        <div className="hidden sm:flex max-w-7xl mx-auto px-4 py-3 items-center justify-between">
          {/* Logo — plasma orb (replaces static SVG) */}
          <div className="flex items-center gap-3">
            <PlasmaLogo size={120} className="drop-shadow -my-8" slotIndex={7} />
            <ElectricOrganism size={130} className="drop-shadow -my-8" />
            <div>
              <h1 className="text-lg font-bold leading-tight tracking-tight bg-gradient-to-b from-amber-300 to-orange-500 bg-clip-text text-transparent">
                OmniBus
              </h1>
              <p className="text-xs text-mempool-text-dim">BlockChain Explorer</p>
            </div>
            <MatrixRain width={60} height={120} className="drop-shadow -my-8 rounded" />
            <PlasmaLogo size={80} className="drop-shadow -my-8" slotIndex={9} />
            <PlasmaLogo size={40} className="drop-shadow -my-8" slotIndex={10} />
            <PlasmaLogoOrange size={120} className="drop-shadow -my-8" slotIndex={11} />
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
              <p
                className={`text-2xl font-mono font-bold transition-all duration-300 ${
                  blockPulse
                    ? "text-mempool-green scale-110 drop-shadow-[0_0_8px_rgba(94,234,212,0.8)]"
                    : "text-mempool-text"
                }`}
              >
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

            {/* Global wallet connect — visible on every tab. One login →
                Names / Faucet / Reputation / Exchange all see the same wallet
                via the wallet-keystore singleton. */}
            <GlobalBalancePill />
            <WalletConnectButton />
          </div>
        </div>

        {/* ── Mobile layout (< sm) ── */}
        <div className="flex sm:hidden flex-col">
          {/* Row 1: logo + title + search + block height */}
          <div className="flex items-center justify-between px-3 py-2">
            <div className="flex items-center gap-2">
              <PlasmaLogo size={44} className="drop-shadow -my-2 flex-shrink-0" slotIndex={7} />
              <div>
                <h1 className="text-base font-bold leading-tight tracking-tight bg-gradient-to-b from-amber-300 to-orange-500 bg-clip-text text-transparent">
                  OmniBus
                </h1>
                <p className="text-[10px] text-mempool-text-dim leading-none">BlockChain</p>
              </div>
            </div>

            {/* Center: block height */}
            <div className="flex-1 text-center px-2">
              <p className="text-[10px] text-mempool-text-dim uppercase tracking-wider leading-none">Height</p>
              <p
                className={`text-lg font-mono font-bold leading-tight transition-all duration-300 ${
                  blockPulse
                    ? "text-mempool-green scale-110 drop-shadow-[0_0_8px_rgba(94,234,212,0.8)]"
                    : "text-mempool-text"
                }`}
              >
                {state.blockCount.toLocaleString()}
              </p>
            </div>

            {/* Right: search + wallet */}
            <div className="flex items-center gap-1.5">
              <button
                onClick={() => setShowSearch(true)}
                className="flex items-center justify-center bg-mempool-bg border border-mempool-border rounded-lg p-1.5 text-mempool-text-dim hover:text-mempool-text hover:border-mempool-blue transition-colors"
                title="Search TX"
              >
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <circle cx="11" cy="11" r="8" />
                  <path d="M21 21l-4.35-4.35" />
                </svg>
              </button>
              <WalletConnectButton />
            </div>
          </div>

          {/* Row 2: chain switcher + WS status + miners + peers + mining badge */}
          <div className="flex items-center gap-2 px-3 pb-2 overflow-x-auto scrollbar-none">
            <select
              value={activeChain}
              onChange={(e) => setActiveChain(e.target.value as ChainName)}
              className="bg-mempool-bg border border-mempool-border rounded px-1.5 py-0.5 text-[10px] text-mempool-text hover:border-mempool-blue cursor-pointer flex-shrink-0"
              title="Switch chain (reloads page)"
            >
              <option value="mainnet">Mainnet</option>
              <option value="testnet">Testnet</option>
              <option value="regtest">Regtest</option>
            </select>
            <span className={`px-1.5 py-0.5 rounded text-[9px] font-bold uppercase flex-shrink-0 ${CHAIN_BADGE[activeChain].cls}`}>
              {CHAIN_BADGE[activeChain].label}
            </span>
            <div className="flex items-center gap-1 flex-shrink-0">
              <div
                className={`w-1.5 h-1.5 rounded-full flex-shrink-0 ${
                  state.wsConnected ? "bg-mempool-green animate-pulse" : "bg-mempool-red"
                }`}
              />
              <span className="text-[10px] text-mempool-text-dim">{state.wsConnected ? "Live" : "Poll"}</span>
            </div>
            <span className="text-[10px] text-mempool-text-dim flex-shrink-0">
              {state.miners.length}M/{state.peers.length}P
            </span>
            <div
              className={`px-2 py-0.5 rounded-full text-[9px] font-medium flex-shrink-0 ${
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
