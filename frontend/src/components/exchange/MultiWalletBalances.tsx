import { useEffect, useRef, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import { getUnlocked, subscribeWallet } from "../../api/wallet-keystore";
import {
  fetchEvmBalance,
  fetchUsdcBalance,
  fetchLcxBalance,
  fetchEurcBalance,
  fetchSolanaBalance,
  fetchSolanaUsdcBalance,
  fetchXrpBalance,
} from "../../api/multichain-balances";

const rpc = new OmniBusRpcClient();
const SAT = 1_000_000_000;

const WALLET_NAMES: Record<number, string> = {
  0: "savacazan.omnibus",  1: "admin.omnibus",
  2: "exchange.omnibus",   3: "ens.omnibus",
  4: "sava.omnibus",       5: "blockchain.omnibus",
  6: "tornetwork.omnibus", 7: "faucet.omnibus",
  8: "cazan.omnibus",      9: "database.omnibus",
};

// Columns in display order — Circle faucet.circle.com supported testnets + our chains
const COLS = [
  // OmniBus chain
  { key: "omni",       label: "OMNI",       sym: "OMNI", isSat: true  },
  // Solana devnet (Circle supports SOL devnet USDC)
  { key: "solDev",     label: "SOL Dev",    sym: "SOL",  isSat: false },
  { key: "usdcSol",    label: "USDC Sol",   sym: "USDC", isSat: false },
  // Ethereum Sepolia
  { key: "ethSep",     label: "ETH Sep",    sym: "ETH",  isSat: false },
  { key: "usdcSep",    label: "USDC Sep",   sym: "USDC", isSat: false },
  { key: "eurcSep",    label: "EURC Sep",   sym: "EURC", isSat: false },
  // Base Sepolia
  { key: "ethBase",    label: "ETH Base",   sym: "ETH",  isSat: false },
  { key: "usdcBase",   label: "USDC Base",  sym: "USDC", isSat: false },
  { key: "eurcBase",   label: "EURC BSep",  sym: "EURC", isSat: false },
  // Arbitrum Sepolia
  { key: "usdcArb",    label: "USDC Arb",   sym: "USDC", isSat: false },
  // Optimism Sepolia
  { key: "usdcOp",     label: "USDC Op",    sym: "USDC", isSat: false },
  // Polygon Amoy
  { key: "usdcAmoy",   label: "USDC Amoy",  sym: "USDC", isSat: false },
  // Avalanche Fuji
  { key: "usdcFuji",   label: "USDC Fuji",  sym: "USDC", isSat: false },
  // LCX Liberty
  { key: "lcxLib",     label: "LCX Lib",    sym: "LCX",  isSat: false },
  // XRP testnet
  { key: "xrpTest",    label: "XRP Test",   sym: "XRP",  isSat: false },
] as const;

type ColKey = typeof COLS[number]["key"];
type BalVal = number | null | "loading";

type WRow = {
  index: number;
  omniAddr: string;
  evmAddr: string;
  solAddr: string;
  omni: BalVal;
  solDev: BalVal;
  usdcSol: BalVal;
  ethSep: BalVal;
  usdcSep: BalVal;
  eurcSep: BalVal;
  ethBase: BalVal;
  usdcBase: BalVal;
  eurcBase: BalVal;
  usdcArb: BalVal;
  usdcOp: BalVal;
  usdcAmoy: BalVal;
  usdcFuji: BalVal;
  lcxLib: BalVal;
  xrpTest: BalVal;
};

function blank(): Pick<WRow, ColKey> {
  return Object.fromEntries(COLS.map(c => [c.key, "loading" as BalVal])) as Pick<WRow, ColKey>;
}

function fmt(v: BalVal, isSat: boolean): string {
  if (v === "loading") return "…";
  if (v === null || v === undefined) return "—";
  const n = isSat ? (v as number) / SAT : (v as number);
  if (n === 0) return "0";
  if (n > 0 && n < 0.01) return n.toFixed(4);
  return n.toFixed(2);
}

function cellCls(v: BalVal): string {
  if (v === "loading") return "text-mempool-text-dim/60 animate-pulse";
  if (v === null || (typeof v === "number" && v === 0)) return "text-mempool-text-dim/30";
  return "text-mempool-green";
}

function sumCol(rows: WRow[], key: ColKey, isSat: boolean): number {
  return rows.reduce((acc, r) => {
    const v = r[key];
    if (typeof v !== "number") return acc;
    return acc + (isSat ? v / SAT : v);
  }, 0);
}

export function MultiWalletBalances() {
  const [, force] = useState(0);
  useEffect(() => subscribeWallet(() => force((n) => n + 1)), []);
  const u = getUnlocked();

  const [rows, setRows] = useState<WRow[]>([]);
  const [fetching, setFetching] = useState(false);
  const [view, setView] = useState<"cards" | "table">("table");
  const cancelRef = useRef(false);

  useEffect(() => {
    if (!u?.allAddresses?.length) { setRows([]); return; }
    cancelRef.current = false;
    setFetching(true);

    const addrs = u.allAddresses.slice(0, 10);
    const skeleton: WRow[] = addrs.map(({ index, address, evmAddress, solAddress }) => ({
      index, omniAddr: address, evmAddr: evmAddress ?? "", solAddr: solAddress ?? "",
      ...blank(),
    }));
    // XRP address for wallet #0 (same path m/44'/144'/0'/0/0 for all users)
    const xrpAddr0 = (u.allAddresses[0] as any)?.xrpAddress as string | undefined;
    setRows(skeleton);

    const setVal = (index: number, key: ColKey, val: BalVal) => {
      if (cancelRef.current) return;
      setRows(prev => prev.map(r => r.index === index ? { ...r, [key]: val } : r));
    };
    const setAllEvm = (key: ColKey, val: BalVal) => {
      if (cancelRef.current) return;
      setRows(prev => prev.map(r => ({ ...r, [key]: val })));
    };

    const fetches: Promise<void>[] = [];

    // SOL devnet + USDC on Solana — per address (each wallet index has own SOL address)
    // Fallback: if allAddresses[i].solAddress is empty (old session before fix),
    // use multichainAddresses SOL entry (wallet #0 address) for index 0.
    const solFallback = u.multichainAddresses?.find(a => a.chain === "SOL")?.address ?? "";
    for (const { index, solAddress } of addrs) {
      const sol = solAddress || (index === 0 ? solFallback : "");
      if (!sol) {
        setVal(index, "solDev", null);
        setVal(index, "usdcSol", null);
        continue;
      }
      fetches.push(
        fetchSolanaBalance(sol, "devnet")
          .then(b => setVal(index, "solDev", b ? Number(b.native) : null))
          .catch(() => setVal(index, "solDev", null))
      );
      fetches.push(
        fetchSolanaUsdcBalance(sol, "devnet")
          .then(b => setVal(index, "usdcSol", b ? Number(b.native) : null))
          .catch(() => setVal(index, "usdcSol", null))
      );
    }

    // OMNI — per address
    for (const { index, address } of addrs) {
      fetches.push(
        rpc.request_raw("getbalance", [address])
          .then((res: any) => setVal(index, "omni", res?.balance ?? 0))
          .catch(() => setVal(index, "omni", null))
      );
    }

    // EVM — group by unique evmAddr to avoid duplicate fetches
    const evmGroups = new Map<string, number[]>();
    for (const { index, evmAddress } of addrs) {
      if (!evmAddress) continue;
      if (!evmGroups.has(evmAddress)) evmGroups.set(evmAddress, []);
      evmGroups.get(evmAddress)!.push(index);
    }
    const allSame = evmGroups.size === 1;

    for (const [evmAddr, indices] of evmGroups) {
      const upd = (key: ColKey, val: BalVal) => {
        if (cancelRef.current) return;
        if (allSame) setAllEvm(key, val);
        else indices.forEach(i => setVal(i, key, val));
      };

      // Ethereum Sepolia
      fetches.push(fetchEvmBalance("SEPOLIA", evmAddr).then(b => upd("ethSep", b ? Number(b.native) : null)).catch(() => upd("ethSep", null)));
      fetches.push(fetchUsdcBalance("SEPOLIA", evmAddr).then(b => upd("usdcSep", b ? Number(b.native) : null)).catch(() => upd("usdcSep", null)));
      fetches.push(fetchEurcBalance("SEPOLIA", evmAddr).then(b => upd("eurcSep", b ? Number(b.native) : null)).catch(() => upd("eurcSep", null)));
      // Base Sepolia
      fetches.push(fetchEvmBalance("BASE_SEPOLIA", evmAddr).then(b => upd("ethBase", b ? Number(b.native) : null)).catch(() => upd("ethBase", null)));
      fetches.push(fetchUsdcBalance("BASE_SEPOLIA", evmAddr).then(b => upd("usdcBase", b ? Number(b.native) : null)).catch(() => upd("usdcBase", null)));
      // Base Sepolia EURC (Circle testnet 0x808456652...)
      fetches.push(fetchEurcBalance("BASE_SEPOLIA", evmAddr).then(b => upd("eurcBase", b ? Number(b.native) : null)).catch(() => upd("eurcBase", null)));
      // Arbitrum Sepolia — Circle USDC faucet supported
      fetches.push(fetchUsdcBalance("ARB_SEPOLIA", evmAddr).then(b => upd("usdcArb", b ? Number(b.native) : null)).catch(() => upd("usdcArb", null)));
      // Optimism Sepolia — Circle USDC faucet supported
      fetches.push(fetchUsdcBalance("OP_SEPOLIA", evmAddr).then(b => upd("usdcOp", b ? Number(b.native) : null)).catch(() => upd("usdcOp", null)));
      // Polygon Amoy — Circle USDC faucet supported
      fetches.push(fetchUsdcBalance("POLYGON_AMOY", evmAddr).then(b => upd("usdcAmoy", b ? Number(b.native) : null)).catch(() => upd("usdcAmoy", null)));
      // Avalanche Fuji — Circle USDC faucet supported
      fetches.push(fetchUsdcBalance("AVAX_FUJI", evmAddr).then(b => upd("usdcFuji", b ? Number(b.native) : null)).catch(() => upd("usdcFuji", null)));
      // LCX Liberty — native LCX token
      fetches.push(fetchLcxBalance("LIBERTY", evmAddr).then(b => upd("lcxLib", b ? Number(b.native) : null)).catch(() => upd("lcxLib", null)));
    }

    // XRP testnet — adresa din allAddresses[0].xrpAddress (salvată în session)
    const xrpFetchAddr = xrpAddr0 || u.multichainAddresses?.find(a => a.chain === "XRP")?.address;
    if (xrpFetchAddr && !xrpFetchAddr.includes("failed")) {
      fetches.push(
        fetchXrpBalance(xrpFetchAddr, "testnet")
          .then(b => { if (!cancelRef.current) setRows(prev => prev.map(r => ({ ...r, xrpTest: b ? Number(b.native) : null }))); })
          .catch(() => { if (!cancelRef.current) setRows(prev => prev.map(r => ({ ...r, xrpTest: null }))); })
      );
    } else {
      setRows(prev => prev.map(r => ({ ...r, xrpTest: null })));
    }

    Promise.all(fetches).finally(() => { if (!cancelRef.current) setFetching(false); });
    return () => { cancelRef.current = true; };
  }, [u?.address]);

  if (!u) return <p className="text-xs text-mempool-text-dim p-2">Unlock wallet with mnemonic.</p>;
  if (!u.allAddresses?.length) return <p className="text-xs text-mempool-text-dim p-2">Re-unlock with mnemonic to derive all addresses.</p>;

  const totals = Object.fromEntries(
    COLS.map(c => [c.key, sumCol(rows, c.key, c.isSat)])
  ) as Record<ColKey, number>;

  const evmAddrs = [...new Set(rows.map(r => r.evmAddr).filter(Boolean))];
  const sameEvm = evmAddrs.length === 1;

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div>
          <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
            OmniBus Multi-Chain Wallet
          </h3>
          <p className="text-[10px] text-mempool-text-dim mt-0.5">
            10 wallets × OMNI + SOL + Sepolia + Base + Arb + OP + Amoy + Fuji + LCX — Circle faucet.circle.com
          </p>
        </div>
        <div className="flex items-center gap-2">
          {fetching && <span className="text-[10px] text-mempool-text-dim animate-pulse">Fetching…</span>}
          <div className="flex gap-0.5 bg-mempool-bg rounded p-0.5">
            <button onClick={() => setView("cards")}
              className={`px-2 py-1 text-[10px] rounded transition-colors ${view === "cards" ? "bg-mempool-blue/20 text-mempool-blue font-semibold" : "text-mempool-text-dim hover:text-mempool-text"}`}>
              Cards
            </button>
            <button onClick={() => setView("table")}
              className={`px-2 py-1 text-[10px] rounded transition-colors ${view === "table" ? "bg-mempool-blue/20 text-mempool-blue font-semibold" : "text-mempool-text-dim hover:text-mempool-text"}`}>
              Table
            </button>
          </div>
        </div>
      </div>

      {sameEvm && (
        <div className="text-[10px] text-mempool-text-dim bg-mempool-bg px-3 py-1.5 rounded">
          Same EVM address for all wallets (index 0):{" "}
          <span className="font-mono text-mempool-text">{evmAddrs[0]?.slice(0,10)}…{evmAddrs[0]?.slice(-6)}</span>
          {" "}— Sepolia/Liberty/Base balances shown once, applied to all rows.
        </div>
      )}

      {view === "cards" ? (
        <div className="space-y-2">
          {rows.map(row => {
            const omniVal = typeof row.omni === "number" ? row.omni / SAT : 0;
            const hasBalance = omniVal > 0 || COLS.slice(1).some(c => typeof row[c.key] === "number" && (row[c.key] as number) > 0);
            return (
              <div key={row.index} className={`rounded-lg border p-3 ${hasBalance ? "border-mempool-blue/30 bg-mempool-bg-elev" : "border-mempool-border bg-mempool-bg-elev/50"}`}>
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2 mb-1">
                      <span className="text-[10px] font-mono text-mempool-text-dim bg-mempool-bg px-1.5 py-0.5 rounded">#{row.index}</span>
                      <span className="text-xs font-semibold text-mempool-text">@ {WALLET_NAMES[row.index]}</span>
                    </div>
                    <div className="space-y-0.5">
                      {row.evmAddr && (
                        <div className="flex items-center gap-1 text-[10px]">
                          <span className="text-mempool-text-dim w-8 shrink-0">EVM</span>
                          <span className="font-mono text-mempool-text-dim truncate" title={row.evmAddr}>
                            {row.evmAddr.slice(0,12)}…{row.evmAddr.slice(-6)}
                          </span>
                        </div>
                      )}
                      <div className="flex items-center gap-1 text-[10px]">
                        <span className="text-mempool-text-dim w-8 shrink-0">OMNI</span>
                        <span className="font-mono text-[10px] text-mempool-text-dim truncate" title={row.omniAddr}>
                          {row.omniAddr.slice(0,14)}…{row.omniAddr.slice(-8)}
                        </span>
                      </div>
                    </div>
                  </div>
                  <div className="text-right shrink-0">
                    <div className={`font-mono text-sm font-semibold ${row.omni === "loading" ? "text-mempool-text-dim animate-pulse" : omniVal > 0 ? "text-mempool-green" : "text-mempool-text-dim"}`}>
                      {fmt(row.omni, true)}
                    </div>
                    <div className="text-[10px] text-mempool-text-dim">OMNI</div>
                  </div>
                </div>
                {/* EVM token pills */}
                <div className="flex flex-wrap gap-1 mt-2">
                  {COLS.slice(1).map(c => {
                    const v = row[c.key];
                    const n = typeof v === "number" ? v : 0;
                    if (v === "loading") return <span key={c.key} className="text-[10px] text-mempool-text-dim/50 animate-pulse">{c.label}…</span>;
                    if (v === null || n === 0) return null;
                    return (
                      <span key={c.key} className="inline-flex items-center gap-1 text-[10px] px-1.5 py-0.5 rounded bg-mempool-bg border border-mempool-border/60 text-mempool-green font-mono">
                        <span className="text-mempool-text-dim">{c.label}</span>
                        {fmt(v, false)}
                      </span>
                    );
                  })}
                  {COLS.slice(1).every(c => row[c.key] === null || row[c.key] === 0) &&
                   COLS.slice(1).every(c => row[c.key] !== "loading") && (
                    <span className="text-[10px] text-mempool-text-dim/40">no EVM balance</span>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      ) : (
        <div className="w-full">
          <table className="w-full border-collapse" style={{ tableLayout: "fixed", fontSize: "9px" }}>
            <colgroup>
              <col style={{ width: "20px" }} />
              <col style={{ width: "90px" }} />
              {COLS.map(c => <col key={c.key} style={{ width: `${100 / COLS.length}%` }} />)}
            </colgroup>
            <thead>
              <tr className="text-mempool-text-dim border-b border-mempool-border" style={{ fontSize: "8px" }}>
                <th className="text-left py-1 px-1 font-normal">#</th>
                <th className="text-left py-1 px-1 font-normal">Wallet</th>
                {COLS.map(c => {
                  // Split label on space for 2-line header (e.g. "USDC Sep" → "USDC\nSep")
                  const parts = c.label.split(" ");
                  return (
                    <th key={c.key} className="text-right py-0.5 px-0.5 font-normal leading-tight">
                      {parts.map((p, i) => <div key={i}>{p}</div>)}
                    </th>
                  );
                })}
              </tr>
            </thead>
            <tbody>
              {rows.map(row => (
                <tr key={row.index} className="border-t border-mempool-border/20 hover:bg-mempool-bg/50">
                  <td className="py-1 px-1 text-mempool-text-dim font-mono">{row.index}</td>
                  <td className="py-1 px-1">
                    <div className="text-mempool-text font-semibold truncate" style={{ fontSize: "8px" }}>{WALLET_NAMES[row.index].split(".")[0]}</div>
                    <div className="font-mono text-mempool-text-dim truncate" style={{ fontSize: "7px" }} title={row.evmAddr}>
                      {row.evmAddr ? `${row.evmAddr.slice(0,6)}…${row.evmAddr.slice(-3)}` : ""}
                    </div>
                  </td>
                  {COLS.map(c => (
                    <td key={c.key} className={`py-1 px-0.5 text-right font-mono tabular-nums ${cellCls(row[c.key])}`} style={{ fontSize: "9px" }}>
                      {fmt(row[c.key], c.isSat)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr className="border-t-2 border-mempool-border">
                <td className="py-1 px-1 text-mempool-text-dim font-semibold" colSpan={2} style={{ fontSize: "8px" }}>TOT</td>
                {COLS.map(c => {
                  const tot = totals[c.key];
                  return (
                    <td key={c.key} className={`py-1 px-0.5 text-right font-mono tabular-nums font-semibold ${tot > 0 ? "text-mempool-green" : "text-mempool-text-dim"}`} style={{ fontSize: "9px" }}>
                      {tot.toFixed(2)}
                    </td>
                  );
                })}
              </tr>
            </tfoot>
          </table>
        </div>
      )}

      {/* Summary cards */}
      <div className="grid grid-cols-4 sm:grid-cols-7 gap-1.5 pt-1 border-t border-mempool-border">
        {COLS.map(c => {
          const tot = totals[c.key];
          return (
            <div key={c.key} className="rounded bg-mempool-bg px-2 py-1.5">
              <div className="text-[9px] uppercase tracking-wider text-mempool-text-dim">{c.label}</div>
              <div className={`font-mono text-xs font-semibold ${tot > 0 ? "text-mempool-green" : "text-mempool-text-dim"}`}>
                {tot.toFixed(4)} <span className="text-[9px] font-normal">{c.sym}</span>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
