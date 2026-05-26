import { useState, useEffect, useRef } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import { TxSearch } from "../search/TxSearch";
import { SAT_PER_OMNI } from "../../utils/fmt";
import { getActiveChain, setActiveChain, type ChainName, rpc as _searchRpc } from "../../api/rpc-client";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import { PlasmaLogo } from "../effects/PlasmaLogo";
import { PlasmaLogoOrange } from "../effects/PlasmaLogoOrange";
import { ElectricOrganism } from "../effects/ElectricOrganism";
import { MatrixRain } from "../effects/MatrixRain";
import { WalletConnectButton } from "./WalletConnectButton";
import { GlobalBalancePill } from "./GlobalBalancePill";
import { useActiveSlot, setActiveSlot, SLOT_COUNT } from "../../api/use-active-slot";
import { useAllSlotsBalance } from "../../api/use-all-slots-balance";
import { useWallet } from "../../api/use-wallet";

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

  // Other components can open search pre-filled with a TX id via window.__openTx.
  // If the input is a 64-char hex we keep legacy TxSearch modal; otherwise we
  // navigate directly with hash routing.
  useEffect(() => {
    window.__openTx = (txid: string) => {
      const s = txid.trim();
      if (!s) return;
      // Block number
      if (/^\d+$/.test(s)) { window.location.hash = `#/block/${s}`; return; }
      // Full TX hash
      if (/^[0-9a-fA-F]{64}$/.test(s)) { window.location.hash = `#/tx/${s}`; return; }
      // Any OmniBus address (ECDSA ob1q/ob1p/ob1m, soulbound ob_k1_/ob_f5_/ob_d5_/ob_s3_,
      // transferable PQ obk1_/obf5_/obd5_/obs3_) — navigate directly to address explorer.
      if (/^ob[1_][a-z0-9_]{5,}/.test(s)) { window.location.hash = `#/address/${s}`; return; }
      // ENS-style name — try resolveaddress, fall back to TxSearch
      if (/^[a-zA-Z0-9_-]+(\.[a-zA-Z0-9]+)?$/.test(s) && !/^[0-9a-fA-F]+$/.test(s)) {
        _searchRpc.request_raw("resolveaddress", [s]).then((r: any) => {
          const resolved = typeof r === "string" ? r : r?.address;
          if (resolved && resolved.length > 8) {
            window.location.hash = `#/address/${resolved}`;
          } else {
            setSearchInitial(s); setShowSearch(true);
          }
        }).catch(() => { setSearchInitial(s); setShowSearch(true); });
        return;
      }
      // Partial / direct address
      if (s.length >= 8) { window.location.hash = `#/address/${s}`; return; }
      setSearchInitial(s);
      setShowSearch(true);
    };
    return () => { delete window.__openTx; };
  }, []);

  const ibd = state.ibdProgress;

  return (
    <>
      {/* IBD sync progress banner — visible only while node is catching up */}
      {ibd && ibd.active && (
        <div className="sticky top-0 z-[60] bg-mempool-orange/10 border-b border-mempool-orange/40 px-4 py-1.5 flex items-center gap-3">
          <span className="text-[11px] text-mempool-orange font-medium animate-pulse">Syncing…</span>
          <div className="flex-1 bg-mempool-bg rounded-full h-1.5 overflow-hidden">
            <div
              className="h-full bg-mempool-orange rounded-full transition-all duration-500"
              style={{ width: `${Math.min(100, ibd.progress)}%` }}
            />
          </div>
          <span className="text-[10px] font-mono text-mempool-text-dim whitespace-nowrap">
            {ibd.local_height.toLocaleString()} / {ibd.peer_height.toLocaleString()} ({ibd.progress}%)
          </span>
        </div>
      )}
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
            <ExplorerSearchBar onFallback={() => setShowSearch(true)} />
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
            {/* Active-slot selector + 19-slot total. Only renders when a wallet
                is connected (otherwise nothing to switch between). */}
            <ActiveSlotSelector />

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
                title="Search"
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

/**
 * ExplorerSearchBar — inline search in the desktop header.
 * Detects input type:
 *   - block number → #/block/:n
 *   - 64-hex       → #/tx/:h
 *   - name.tld     → resolves via resolveaddress RPC → #/address/:resolved
 *   - anything 8+  → #/address/:s (direct address or name the address page handles)
 */
function ExplorerSearchBar({ onFallback }: { onFallback: () => void }) {
  const [q, setQ] = useState("");
  const [resolving, setResolving] = useState(false);
  const abortRef = useRef<AbortController | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  // "/" or Ctrl+K / Cmd+K → focus this search bar
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement)?.tagName;
      const inInput = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";
      if (inInput) return;
      if (e.key === "/" || ((e.ctrlKey || e.metaKey) && e.key === "k")) {
        e.preventDefault();
        inputRef.current?.focus();
        inputRef.current?.select();
      }
    };
    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, []);

  const navigate = async (raw: string) => {
    const s = raw.trim();
    if (!s) { onFallback(); return; }
    if (/^\d+$/.test(s)) { window.location.hash = `#/block/${s}`; setQ(""); return; }
    if (/^[0-9a-fA-F]{64}$/.test(s)) { window.location.hash = `#/tx/${s}`; setQ(""); return; }
    // ENS-style name (contains a dot, like "savacazan.omnibus")
    if (/^[a-zA-Z0-9_-]+\.[a-zA-Z0-9]+$/.test(s)) {
      setResolving(true);
      if (abortRef.current) abortRef.current.abort();
      abortRef.current = new AbortController();
      try {
        const r = (await _searchRpc.request_raw("resolveaddress", [s])) as { address?: string } | string | null;
        const resolved = typeof r === "string" ? r : r?.address;
        if (resolved && resolved.length > 8) {
          window.location.hash = `#/address/${resolved}`;
          setQ("");
          return;
        }
      } catch { /* fall through to direct address lookup */ }
      finally { setResolving(false); }
    }
    if (s.length >= 8) { window.location.hash = `#/address/${s}`; setQ(""); return; }
    onFallback();
  };

  return (
    <div className="relative flex items-center">
      <svg
        width="13" height="13"
        viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"
        className="absolute left-2.5 text-mempool-text-dim pointer-events-none"
      >
        <circle cx="11" cy="11" r="8" />
        <path d="M21 21l-4.35-4.35" />
      </svg>
      <input
        ref={inputRef}
        type="text"
        value={q}
        onChange={(e) => setQ(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") void navigate(q);
          if (e.key === "Escape") { setQ(""); (e.target as HTMLInputElement).blur(); }
        }}
        placeholder="Block / TX / Address / name.tld…"
        title="Press / or Ctrl+K to focus"
        className="bg-mempool-bg border border-mempool-border rounded-lg pl-8 pr-8 py-1.5 text-xs text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue w-56 lg:w-72 transition-colors"
      />
      {resolving ? (
        <span className="absolute right-2 text-mempool-text-dim text-[10px] animate-pulse">…</span>
      ) : q ? (
        <button
          onClick={() => setQ("")}
          className="absolute right-2 text-mempool-text-dim hover:text-mempool-text"
        >
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M18 6 6 18M6 6l12 12" />
          </svg>
        </button>
      ) : (
        <button
          onClick={onFallback}
          className="absolute right-2 text-mempool-text-dim hover:text-mempool-blue"
          title="Advanced TX search"
        >
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M4 6h16M4 12h8m-8 6h4" />
          </svg>
        </button>
      )}
    </div>
  );
}

/**
 * ActiveSlotSelector — header dropdown to switch the BIP-44 OMNI slot that
 * every page (Trade / Wallet / Stake / Send) reads from. Also shows the
 * total OMNI across all 19 slots so the user always sees the wallet's full
 * picture even when MultiWalletBalances isn't open.
 *
 * No-op (hidden) when no wallet is connected.
 */
function ActiveSlotSelector() {
  const wallet = useWallet();
  const activeSlot = useActiveSlot();
  const all = useAllSlotsBalance();

  if (!wallet) return null;
  const slotsCount = wallet.allAddresses?.length ?? SLOT_COUNT;

  // Find OMNI on the active slot for the inline chip; fall back to the
  // unlocked wallet's primary balance when the snapshot hasn't loaded yet.
  const activeRow = all.slots.find((s) => s.index === activeSlot);
  const activeOmni = activeRow ? activeRow.wallet_sat / SAT_PER_OMNI : 0;
  const totalOmni = all.total_wallet_sat / SAT_PER_OMNI;

  return (
    <div className="hidden md:flex items-center gap-2 px-2 py-1 rounded-lg bg-mempool-bg-elev border border-mempool-border">
      <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Slot</span>
      <select
        value={activeSlot}
        onChange={(e) => setActiveSlot(Number(e.target.value))}
        className="bg-mempool-bg border border-mempool-border rounded px-1.5 py-0.5 text-xs text-mempool-text hover:border-mempool-blue cursor-pointer font-mono"
        title="Active BIP-44 slot — Trade / Send / Stake use this index"
      >
        {Array.from({ length: slotsCount }, (_, i) => {
          const row = all.slots.find((s) => s.index === i);
          const bal = row ? (row.wallet_sat / SAT_PER_OMNI).toFixed(2) : "—";
          return (
            <option key={i} value={i}>
              #{i} · {bal}
            </option>
          );
        })}
      </select>
      <span className="text-[10px] text-mempool-text-dim border-l border-mempool-border pl-2">
        <span className="text-mempool-text font-mono">{activeOmni.toFixed(2)}</span> OMNI
      </span>
      <span className="text-[10px] text-mempool-text-dim/70" title="Total OMNI across all 19 BIP-44 slots">
        all: <span className="text-mempool-green font-mono">{totalOmni.toFixed(2)}</span>
      </span>
    </div>
  );
}
