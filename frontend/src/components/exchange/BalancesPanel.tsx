import { useEffect, useState } from "react";
import OmniBusRpcClient, { ExchangeBalance } from "../../api/rpc-client";
import { SAT_PER_OMNI } from "../../utils/fmt";
import { getUnlocked, subscribeWallet } from "../../api/wallet-keystore";
import { fetchChainBalance, fetchUsdcBalance, fetchEurcBalance, type ChainBalance } from "../../api/multichain-balances";
import { MultiWalletBalances } from "./MultiWalletBalances";
import { useGlobalBalance } from "../../api/use-global-balance";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsNewBlockEvent } from "../../types";

const rpc = new OmniBusRpcClient();
const SAT = SAT_PER_OMNI;
const MU  = 1_000_000;

type WalletRow = {
  label: string;
  chain: string;           // key for exchange balance lookup
  exchToken: string | null; // "OMNI" | "USDC" | "ETH" | "LCX" | null
  address: string;
  balance: ChainBalance | null | "loading";
  explorerUrl: string;
  role: "maker" | "taker" | "omni";
};

function explorerFor(chain: string, address: string): string {
  switch (chain) {
    case "OMNI":         return `https://omnibusblockchain.cc:8443/#/address/${address}`;
    case "SEPOLIA":      return `https://sepolia.etherscan.io/address/${address}`;
    case "BASE_SEPOLIA": return `https://sepolia-explorer.base.org/address/${address}`;
    case "ETH":          return `https://etherscan.io/address/${address}`;
    case "BASE":         return `https://basescan.org/address/${address}`;
    default:             return `#`;
  }
}

// How much is locked in open orders for a given token
function exchLocked(exchBalances: ExchangeBalance[], token: string | null): number {
  if (!token) return 0;
  const b = exchBalances.find(b => b.token === token);
  if (!b || !b.locked) return 0;
  if (token === "OMNI") return b.locked / SAT;
  if (token === "ETH")  return b.locked / 1e18;
  if (token === "USDC" || token === "LCX") return b.locked / MU;
  return b.locked;
}

export function BalancesPanel() {
  const [, force] = useState(0);
  useEffect(() => subscribeWallet(() => force((n) => n + 1)), []);
  const u = getUnlocked();

  // Use the global atomic snapshot for OMNI so this panel agrees with
  // Wallet / Stake / Header. Previously we did `getbalance` directly and
  // had no visibility on staked / in_orders, so Exchange tab disagreed
  // with Wallet tab for the same address.
  const globalBal = useGlobalBalance();

  const [view, setView] = useState<"single" | "all">("single");
  const [rows, setRows] = useState<WalletRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [exchBalances, setExchBalances] = useState<ExchangeBalance[]>([]);

  // Fetch exchange internal balances; live refresh on new blocks.
  useEffect(() => {
    if (!u?.address) return;
    let cancelled = false;
    const fetch = () =>
      rpc.exchangeGetBalances(u.address).then(bal => { if (!cancelled) setExchBalances(bal); });
    fetch();
    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", () => { void fetch(); });
    const id = setInterval(fetch, 60_000);
    return () => { cancelled = true; clearInterval(id); unsub(); };
  }, [u?.address]);

  useEffect(() => {
    if (!u) { setRows([]); return; }

    let cancelled = false;
    const evmAddr = u.multichainAddresses?.find(a => a.chain === "ETH")?.address
      ?? u.allAddresses?.[0]?.evmAddress
      ?? null;

    const initial: WalletRow[] = [
      {
        label: "OMNI (OmniBus testnet)",
        chain: "OMNI", exchToken: "OMNI",
        address: u.address,
        balance: "loading",
        explorerUrl: explorerFor("OMNI", u.address),
        role: "omni",
      },
    ];

    if (evmAddr) {
      initial.push(
        { label: "ETH (Sepolia)",       chain: "SEPOLIA",          exchToken: "ETH",  address: evmAddr, balance: "loading", explorerUrl: explorerFor("SEPOLIA", evmAddr),      role: "taker" },
        { label: "USDC (Sepolia)",      chain: "SEPOLIA_USDC",     exchToken: "USDC", address: evmAddr, balance: "loading", explorerUrl: explorerFor("SEPOLIA", evmAddr),      role: "taker" },
        { label: "EURC (Sepolia)",      chain: "SEPOLIA_EURC",     exchToken: null,   address: evmAddr, balance: "loading", explorerUrl: explorerFor("SEPOLIA", evmAddr),      role: "taker" },
        { label: "ETH (Base Sepolia)",  chain: "BASE_SEPOLIA",     exchToken: "ETH",  address: evmAddr, balance: "loading", explorerUrl: explorerFor("BASE_SEPOLIA", evmAddr), role: "taker" },
        { label: "USDC (Base Sepolia)", chain: "BASE_SEPOLIA_USDC",exchToken: "USDC", address: evmAddr, balance: "loading", explorerUrl: explorerFor("BASE_SEPOLIA", evmAddr), role: "taker" },
      );
    }

    if (!cancelled) { setRows(initial); setLoading(true); }

    const update = (chain: string, bal: ChainBalance | null) => {
      if (!cancelled) setRows(prev => prev.map(r => r.chain === chain ? { ...r, balance: bal } : r));
    };

    // OMNI row comes from useGlobalBalance (atomic wallet/staked/orders).
    // We still kick a single immediate update with whatever we have right
    // now so the "loading…" placeholder doesn't linger; subsequent
    // updates flow through the separate useEffect below that listens to
    // globalBal changes.
    const fetches: Promise<void>[] = [];
    if (globalBal.address === u.address && globalBal.fetched_at > 0) {
      update("OMNI", {
        native: (globalBal.wallet_sat / SAT).toFixed(8),
        symbol: "OMNI",
        raw: String(globalBal.wallet_sat),
      });
    }

    if (evmAddr) {
      fetches.push(fetchChainBalance("SEPOLIA", evmAddr).then(b => update("SEPOLIA", b)));
      fetches.push(fetchUsdcBalance("SEPOLIA", evmAddr).then(b => update("SEPOLIA_USDC", b)));
      fetches.push(fetchEurcBalance("SEPOLIA", evmAddr).then(b => update("SEPOLIA_EURC", b)));
      fetches.push(fetchChainBalance("BASE_SEPOLIA", evmAddr).then(b => update("BASE_SEPOLIA", b)));
      fetches.push(fetchUsdcBalance("BASE_SEPOLIA", evmAddr).then(b => update("BASE_SEPOLIA_USDC", b)));
    }

    Promise.all(fetches).finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [u?.address]);

  if (!u) {
    return (
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
        <p className="text-xs text-mempool-text-dim">Connect a wallet to see balances.</p>
      </div>
    );
  }

  const evmAddr = u.multichainAddresses?.find(a => a.chain === "ETH")?.address
    ?? u.allAddresses?.[0]?.evmAddress ?? null;

  if (view === "all") {
    return (
      <div className="space-y-3">
        <div className="flex gap-1 bg-mempool-bg rounded p-0.5">
          <button onClick={() => setView("single")} className="flex-1 py-1 text-xs rounded text-mempool-text-dim hover:text-mempool-text">Current wallet</button>
          <button onClick={() => setView("all")} className="flex-1 py-1 text-xs rounded bg-mempool-blue/20 text-mempool-blue font-semibold">All wallets</button>
        </div>
        <MultiWalletBalances />
      </div>
    );
  }

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-3 sm:p-4 space-y-3">

      {/* View toggle */}
      <div className="flex gap-1 bg-mempool-bg rounded p-0.5">
        <button onClick={() => setView("single")} className="flex-1 py-1 text-xs rounded bg-mempool-blue/20 text-mempool-blue font-semibold">Current wallet</button>
        <button onClick={() => setView("all")} className="flex-1 py-1 text-xs rounded text-mempool-text-dim hover:text-mempool-text">All wallets</button>
      </div>

      {/* DEX notice */}
      <div className="rounded border border-mempool-blue/20 bg-mempool-blue/5 px-3 py-2 text-[10px] text-mempool-blue/80 leading-relaxed">
        OmniBus DEX — funds stay in <strong>your wallet</strong>. No deposit needed.
        HTLC locks only at trade fill.
      </div>

      {/* Header */}
      {rows.length > 0 && rows.every(r => r.balance !== "loading") && (
        <div className="flex justify-end">
          <button
            onClick={() => {
              const csvRows = [
                ["chain", "token", "label", "address", "free", "in_orders", "total", "role"].join(","),
                ...rows.map((row) => {
                  const bal = row.balance as import("../../api/multichain-balances").ChainBalance | null;
                  const onChain = bal ? Number(bal.native) : 0;
                  const eb = row.exchToken ? exchBalances.find(b => b.token === row.exchToken) : null;
                  const div = row.exchToken === "OMNI" ? SAT : row.exchToken === "ETH" ? 1e18 : MU;
                  const inOrders = eb ? eb.locked / div : 0;
                  const free = Math.max(0, onChain - inOrders);
                  const dec = row.exchToken === "OMNI" ? 8 : row.exchToken === "ETH" ? 8 : 6;
                  return [
                    `"${row.chain}"`,
                    `"${row.exchToken ?? ""}"`,
                    `"${row.label}"`,
                    `"${row.address}"`,
                    free.toFixed(dec),
                    inOrders.toFixed(dec),
                    onChain.toFixed(dec),
                    row.role,
                  ].join(",");
                }),
              ].join("\n");
              const blob = new Blob([csvRows], { type: "text/csv" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url; a.download = "omnibus-balances.csv";
              a.click(); URL.revokeObjectURL(url);
            }}
            className="flex items-center gap-1.5 px-3 py-1 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-text font-mono"
          >
            ⬇ CSV
          </button>
        </div>
      )}
      <div className="overflow-x-auto -mx-1">
      <div className="min-w-[440px] px-1">
      <div className="grid text-[9px] uppercase tracking-wider text-mempool-text-dim mb-1 gap-1"
        style={{ gridTemplateColumns: "1fr 70px 70px 70px 50px" }}>
        <span>Chain / Token</span>
        <span className="text-right text-green-500/80">Free</span>
        <span className="text-right text-yellow-500/80">In Orders</span>
        <span className="text-right">Total</span>
        <span className="text-right">Role</span>
      </div>

      {/* Rows */}
      <div className="space-y-0.5">
        {rows.map((row) => {
          const isLoading = row.balance === "loading";
          const bal = isLoading ? null : row.balance as ChainBalance | null;

          // On-chain wallet balance — this IS the total. Funds never leave
          // the user's wallet on OmniBus DEX (no deposit). The "exchange"
          // balance fields are only used in paper-trading mode and for
          // tracking reserved-by-orders metadata; they MUST NOT be added
          // to onChain (would double-count).
          const onChain = bal ? Number(bal.native) : 0;

          // Reserved-by-orders metadata (for OMNI: amount tied up in active
          // sell orders so the user can't double-spend that part). Pulled
          // from exchange balance lookup; null/0 if not in any order.
          const eb = row.exchToken ? exchBalances.find(b => b.token === row.exchToken) : null;
          const div = row.exchToken === "OMNI" ? SAT : row.exchToken === "ETH" ? 1e18 : MU;
          const inOrders = eb ? eb.locked / div : 0;

          // Total = on-chain wallet balance (single source of truth).
          // Free = total minus what's reserved by active orders.
          const total = onChain;
          const free  = Math.max(0, onChain - inOrders);

          // Decimals
          const dec = row.exchToken === "OMNI" ? 4
            : row.exchToken === "ETH" ? 6
            : 2;

          const sym = bal?.symbol ?? "";

          return (
            <div key={row.chain}
              className="grid items-center py-1.5 px-1 hover:bg-mempool-bg/40 rounded gap-1"
              style={{ gridTemplateColumns: "1fr 70px 70px 70px 50px" }}>

              {/* Label + address */}
              <div className="min-w-0">
                <div className="text-xs text-mempool-text truncate">{row.label}</div>
                <a href={row.explorerUrl} target="_blank" rel="noopener noreferrer"
                  className="text-[10px] font-mono text-mempool-text-dim hover:text-mempool-blue truncate block max-w-[28ch]"
                  title={row.address}>
                  {row.address.slice(0, 14)}…{row.address.slice(-6)}
                </a>
              </div>

              {/* Free */}
              <div className={`text-right font-mono text-xs tabular-nums ${
                isLoading ? "text-mempool-text-dim animate-pulse"
                : free > 0 ? "text-green-400"
                : "text-mempool-text-dim"}`}>
                {isLoading ? "…" : `${free.toFixed(dec)} ${sym}`}
              </div>

              {/* In Orders */}
              <div className={`text-right font-mono text-xs tabular-nums ${
                isLoading ? "text-mempool-text-dim"
                : inOrders > 0 ? "text-yellow-400"
                : "text-mempool-text-dim/40"}`}>
                {isLoading ? "" : inOrders > 0 ? `${inOrders.toFixed(dec)} ${sym}` : "—"}
              </div>

              {/* Total */}
              <div className="text-right font-mono text-xs tabular-nums text-mempool-text">
                {isLoading ? "…" : `${total.toFixed(dec)} ${sym}`}
              </div>

              {/* Role badge */}
              <div className="text-right">
                <span className={`text-[9px] px-1.5 py-0.5 rounded font-semibold ${
                  row.role === "omni"  ? "bg-mempool-blue/20 text-mempool-blue" :
                  row.role === "maker" ? "bg-orange-500/20 text-orange-300" :
                                         "bg-purple-500/20 text-purple-300"}`}>
                  {row.role === "omni" ? "OMNI" : row.role === "maker" ? "MAKER" : "TAKER"}
                </span>
              </div>
            </div>
          );
        })}
      </div>

      </div>
      </div>

      {loading && (
        <p className="text-[10px] text-mempool-text-dim animate-pulse text-right">Fetching balances…</p>
      )}

      {/* Addresses */}
      <div className="border-t border-mempool-border pt-3 space-y-1">
        <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">Your Addresses</div>
        <div className="rounded bg-mempool-bg px-3 py-2 space-y-1">
          <div className="flex justify-between text-[10px]">
            <span className="text-mempool-text-dim">OMNI</span>
            <span className="font-mono text-mempool-text" title={u.address}>{u.address}</span>
          </div>
          {evmAddr && (
            <div className="flex justify-between text-[10px]">
              <span className="text-mempool-text-dim">EVM (ETH/USDC)</span>
              <span className="font-mono text-mempool-text" title={evmAddr}>{evmAddr.slice(0, 10)}…{evmAddr.slice(-6)}</span>
            </div>
          )}
        </div>
      </div>

    </div>
  );
}
