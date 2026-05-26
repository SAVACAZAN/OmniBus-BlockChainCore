import { useState, useEffect } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import type { BlockData } from "../../types";

const rpc = new OmniBusRpcClient();

const KIND_STYLE: Record<string, string> = {
  coinbase:       "bg-yellow-500/20 text-yellow-300",
  faucet:         "bg-cyan-500/20 text-cyan-300",
  registrar:      "bg-purple-500/20 text-purple-300",
  exchange:       "bg-blue-500/20 text-blue-300",
  stake:          "bg-green-500/20 text-green-300",
  unstake:        "bg-amber-500/20 text-amber-300",
  ns_claim:       "bg-violet-500/20 text-violet-300",
  agent_register: "bg-indigo-500/20 text-indigo-300",
  notarize:       "bg-rose-500/20 text-rose-300",
  demo_grant:     "bg-pink-500/20 text-pink-300",
  transfer:       "bg-gray-700/40 text-gray-300",
};

interface PriceEntry {
  exchange: string;
  pair: string;
  bidMicroUsd: number;
  askMicroUsd: number;
  timestampMs: number;
  success: boolean;
}

interface BlockDetailProps {
  block: BlockData;
  onClose: () => void;
}

// Format micro-USD as $price with thousand-comma + dot decimals.
// BTC -> $100,000.00 (2 decimals), LCX -> $0.0316 (4 decimals).
function fmtUsd(micro: number, isLcx: boolean): string {
  if (!micro) return "—";
  const usd = micro / 1_000_000;
  const decimals = isLcx ? 4 : 2;
  return "$" + usd.toLocaleString("en-US", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
}

// Format millisecond timestamp with 3 decimals (.123)
function fmtTs(ms: number): string {
  if (!ms) return "—";
  const d = new Date(ms);
  const time = d.toLocaleTimeString([], { hour12: false });
  const mil = (ms % 1000).toString().padStart(3, "0");
  return `${time}.${mil}`;
}

// Block timestamp can be either Unix-seconds (Zig std.time.timestamp())
// or accidentally Unix-millis. If the value is unreasonably large for
// 'seconds' (year > 5000), assume it was already millis.
function blockDate(ts: number | undefined): Date {
  if (!ts) return new Date(0);
  // Year 5000 in seconds is ~95e9. Anything larger must already be ms.
  return new Date(ts > 95_000_000_000 ? ts : ts * 1000);
}

export function BlockDetail({ block, onClose }: BlockDetailProps) {
  const [txs, setTxs] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [prices, setPrices] = useState<PriceEntry[]>([]);
  // Tip height is used to decide whether prices were read live (from the
  // in-memory map) or from the on-chain block. Blocks older than tip-100
  // are likely served from chain.items because the legacy in-memory cache
  // trims that far behind the tip.
  const [tipHeight, setTipHeight] = useState<number>(0);
  // The `block` prop from a list view often misses miner/nonce/previousHash —
  // fetch the full block detail and merge over the props so the modal always
  // has authoritative data.
  const [full, setFull] = useState<BlockData>(block);

  useEffect(() => {
    setFull(block);
    setPrices([]);
    loadTxs();
    loadFull();
    loadTip();
  }, [block.height]);

  const loadTip = async () => {
    try {
      const r: any = await rpc.request_raw("getblockcount", []);
      // Some nodes return { count } and others a bare number — handle both.
      const h = typeof r === "number" ? r : r?.count;
      if (typeof h === "number") setTipHeight(h);
    } catch {}
  };

  const loadFull = async () => {
    try {
      const result: any = await rpc.request_raw("getblock", [block.height]);
      if (result && typeof result === "object") {
        setFull({
          height:          result.height ?? block.height,
          hash:            result.hash ?? block.hash,
          previousHash:    result.previousHash ?? block.previousHash,
          timestamp:       result.timestamp ?? block.timestamp,
          nonce:           result.nonce ?? block.nonce,
          txCount:         result.txCount ?? block.txCount,
          miner:           result.miner ?? block.miner,
          rewardSAT:       result.rewardSAT ?? block.rewardSAT,
          pricesRoot:      result.pricesRoot ?? block.pricesRoot,
          pricesValidated: result.pricesValidated ?? block.pricesValidated,
        });
        if (Array.isArray(result.prices)) setPrices(result.prices);
      }
    } catch {}
  };

  const loadTxs = async () => {
    setLoading(true);
    try {
      const result: any = await rpc.request_raw("gettransactions");
      const blockTxs = (result?.transactions || []).filter(
        (tx: any) => tx.blockHeight === block.height
      );

      // Enrich each TX with detail (confirmations, fee) from gettransaction
      const enriched = await Promise.all(
        blockTxs.map(async (tx: any) => {
          try {
            const detail = await rpc.getTransactionDetail(tx.txid);
            return {
              ...tx,
              fee: detail?.fee ?? tx.fee ?? 0,
              confirmations: detail?.confirmations ?? 0,
            };
          } catch {
            return { ...tx, fee: tx.fee ?? 0, confirmations: 0 };
          }
        })
      );
      setTxs(enriched);
    } catch {}
    setLoading(false);
  };

  const totalFees = txs.reduce((sum, tx) => sum + (tx.fee || 0), 0);
  const feeBurned = Math.floor(totalFees * 0.5);
  const feeToMiner = totalFees - feeBurned;

  return (
    <div className="fixed inset-0 bg-black/60 backdrop-blur-sm z-50 flex items-center justify-center p-4"
      onClick={onClose}>
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl max-w-2xl w-full max-h-[80vh] overflow-y-auto"
        onClick={(e) => e.stopPropagation()}>

        {/* Header */}
        <div className="flex items-center justify-between px-5 py-4 border-b border-mempool-border">
          <h3 className="text-lg font-bold text-mempool-text">
            Block #{full.height}
          </h3>
          <button onClick={onClose} className="text-mempool-text-dim hover:text-mempool-text text-xl">
            x
          </button>
        </div>

        {/* Block Info */}
        <div className="p-5 space-y-3">
          <div className="grid grid-cols-2 gap-3">
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase">Hash</p>
              <p className="text-xs font-mono text-mempool-blue break-all">{full.hash}</p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase">Previous Hash</p>
              <p className="text-xs font-mono text-mempool-text-dim break-all">{full.previousHash || "--"}</p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase">Miner</p>
              <p className="text-xs font-mono text-mempool-green break-all">{full.miner || "--"}</p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase">Reward</p>
              <p className="text-xs font-mono text-mempool-green">
                {((full.rewardSAT || 0) / 1e9).toFixed(8)} OMNI ({full.rewardSAT?.toLocaleString()} SAT)
              </p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase">Timestamp</p>
              <p className="text-xs text-mempool-text">
                {full.timestamp ? blockDate(full.timestamp).toLocaleString() : "--"}
              </p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase">Nonce</p>
              <p className="text-xs font-mono text-mempool-text">{full.nonce?.toLocaleString() || "--"}</p>
            </div>
          </div>

          {/* prices_root commitment badge — shown even when the prices
              array is empty so users still see the integrity status. */}
          {(full.pricesRoot || full.pricesValidated !== undefined) && (
            <div
              className="flex items-center gap-2 text-[10px] font-mono"
              title="SHA-256 of canonical prices encoding, mixed into block hash. Verified means tamper-free."
            >
              <span className="text-mempool-text-dim uppercase tracking-wider">pricesRoot:</span>
              <span className="text-mempool-blue truncate">
                {full.pricesRoot
                  ? `0x${full.pricesRoot.slice(0, 4)}...${full.pricesRoot.slice(-4)}`
                  : "0x0000...0000"}
              </span>
              {full.pricesValidated ? (
                <span className="text-mempool-green">✓ verified</span>
              ) : (
                <span className="text-mempool-red">✗ root mismatch</span>
              )}
            </div>
          )}

          {/* Oracle Prices captured at mining time. Source label shows
              whether the entries were served from the in-memory cache
              ("live") or read from the on-chain block ("on-chain"). The
              legacy cache trims after ~100 blocks behind tip, so anything
              older is almost certainly chain-sourced. */}
          {prices.length > 0 && (() => {
            const isOnChain = tipHeight > 0 && full.height < tipHeight - 100;
            const sourceLabel = isOnChain ? "on-chain" : "live";
            const sourceClass = isOnChain
              ? "bg-mempool-blue/20 text-mempool-blue"
              : "bg-mempool-green/20 text-mempool-green";
            return (
              <div className="bg-mempool-bg rounded-lg p-3 border border-mempool-border/50">
                <p className="text-[10px] text-mempool-text-dim uppercase tracking-wider mb-2">
                  Oracle Prices @ Mining ({prices.length} entries)
                </p>
                <div className="grid grid-cols-2 gap-3">
                  {(["BTC/USD", "LCX/USD"] as const).map((pair) => {
                    const isLcx = pair === "LCX/USD";
                    const rows = prices.filter((p) => p.pair === pair);
                    if (rows.length === 0) return null;
                    return (
                      <div key={pair}>
                        <p className="text-[10px] font-bold text-mempool-text mb-1 flex items-center gap-1">
                          {pair}
                        </p>
                        <table className="w-full text-[10px]">
                          <thead>
                            <tr className="text-mempool-text-dim">
                              <th className="text-left pr-1">Ex</th>
                              <th className="text-right">Bid</th>
                              <th className="text-right">Ask</th>
                              <th className="text-right pl-1">Time</th>
                              <th className="text-right pl-1">Src</th>
                            </tr>
                          </thead>
                          <tbody>
                            {rows.map((p) => (
                              <tr
                                key={`${p.exchange}-${p.pair}`}
                                className={p.success ? "" : "opacity-40"}
                              >
                                <td className="text-mempool-text-dim pr-1">{p.exchange}</td>
                                <td className="text-right font-mono text-mempool-green">
                                  {p.success ? fmtUsd(p.bidMicroUsd, isLcx) : "n/a"}
                                </td>
                                <td className="text-right font-mono text-mempool-orange">
                                  {p.success ? fmtUsd(p.askMicroUsd, isLcx) : "n/a"}
                                </td>
                                <td className="text-right font-mono text-mempool-text-dim pl-1">
                                  {p.success ? fmtTs(p.timestampMs) : "—"}
                                </td>
                                <td className="text-right pl-1">
                                  <span className={`text-[9px] px-1 py-0.5 rounded ${sourceClass}`}>
                                    {sourceLabel}
                                  </span>
                                </td>
                              </tr>
                            ))}
                          </tbody>
                        </table>
                      </div>
                    );
                  })}
                </div>
              </div>
            );
          })()}

          {/* Fee Summary */}
          {txs.length > 0 && (
            <div className="bg-mempool-bg rounded-lg p-3 grid grid-cols-3 gap-3">
              <div>
                <p className="text-[10px] text-mempool-text-dim uppercase">Total Fees</p>
                <p className="text-xs font-mono text-mempool-orange">{totalFees.toLocaleString()} SAT</p>
              </div>
              <div>
                <p className="text-[10px] text-mempool-text-dim uppercase">Miner Receives</p>
                <p className="text-xs font-mono text-mempool-green">{feeToMiner.toLocaleString()} SAT</p>
              </div>
              <div>
                <p className="text-[10px] text-mempool-text-dim uppercase">Fee Burned (50%)</p>
                <p className="text-xs font-mono text-mempool-red">{feeBurned.toLocaleString()} SAT</p>
              </div>
            </div>
          )}

          {/* Transactions */}
          <div className="pt-3 border-t border-mempool-border/50">
            <h4 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider mb-2">
              Transactions ({(full.txCount ?? 0) + 1})
            </h4>

            {/* Block Reward (coinbase TX). Show the real miner address,
                not the literal word 'miner...' from before. */}
            <div className="bg-mempool-bg rounded-lg p-3 mb-2">
              <div className="flex items-center gap-2">
                <div className="w-2 h-2 rounded-full bg-mempool-green flex-shrink-0" />
                <span className="text-xs font-mono text-mempool-green font-bold">Block Reward</span>
                <span className="text-mempool-green ml-auto font-mono text-xs">
                  +{((full.rewardSAT || 0) / 1e9).toFixed(8)} OMNI
                </span>
              </div>
              {full.miner && (
                <p className="mt-1 text-[11px] font-mono text-mempool-blue break-all" title={full.miner}>
                  → {full.miner}
                </p>
              )}
            </div>

            {/* User TXs */}
            {loading ? (
              <p className="text-xs text-mempool-text-dim text-center py-4">Loading transactions...</p>
            ) : txs.length === 0 ? (
              <p className="text-xs text-mempool-text-dim text-center py-2">
                No user transactions in this block (coinbase only)
              </p>
            ) : (
              txs.map((tx: any, i: number) => (
                <div key={tx.txid || i} className="bg-mempool-bg rounded-lg p-3 mb-1">
                  <div className="flex items-center gap-2 flex-wrap">
                    <div className="w-2 h-2 rounded-full bg-mempool-blue flex-shrink-0" />
                    <button
                      onClick={() => { window.location.hash = `#/tx/${tx.txid}`; }}
                      className="text-xs font-mono text-mempool-blue hover:underline truncate"
                      title={tx.txid}
                    >
                      {tx.txid?.slice(0, 16)}…{tx.txid?.slice(-6)}
                    </button>
                    {tx.kind && (
                      <span className={`text-[9px] px-1.5 py-0.5 rounded uppercase tracking-wider ${KIND_STYLE[tx.kind] ?? KIND_STYLE.transfer}`}>
                        {tx.kind}
                      </span>
                    )}
                    <span className={`text-[10px] px-1.5 py-0.5 rounded ml-auto ${
                      tx.status === "confirmed"
                        ? "bg-mempool-green/20 text-mempool-green"
                        : "bg-mempool-orange/20 text-mempool-orange"
                    }`}>{tx.status}</span>
                  </div>
                  <div className="mt-1 text-[10px] text-mempool-text-dim flex items-center gap-2 flex-wrap">
                    <span className="flex items-center gap-1 min-w-0">
                      {tx.from && tx.from !== "coinbase" ? (
                        <button onClick={() => { window.location.hash = `#/address/${tx.from}`; }}
                          className="font-mono text-mempool-blue hover:underline truncate" title={tx.from}>
                          {tx.from.slice(0, 14)}…
                        </button>
                      ) : (
                        <span className="font-mono italic text-mempool-text-dim">(coinbase)</span>
                      )}
                      <span className="text-mempool-text-dim flex-shrink-0">→</span>
                      {tx.to ? (
                        <button onClick={() => { window.location.hash = `#/address/${tx.to}`; }}
                          className="font-mono text-mempool-blue hover:underline truncate" title={tx.to}>
                          {tx.to.slice(0, 14)}…
                        </button>
                      ) : null}
                    </span>
                    <span className="text-mempool-orange">
                      {((tx.amount || 0) / 1e9).toFixed(8)} OMNI
                    </span>
                    {tx.fee > 0 && (
                      <span className="text-mempool-text-dim">
                        fee: {tx.fee} SAT
                      </span>
                    )}
                    <span className={`text-[9px] px-1.5 py-0.5 rounded-full font-mono ${
                      tx.confirmations >= 6
                        ? "bg-mempool-green/20 text-mempool-green"
                        : tx.confirmations >= 1
                        ? "bg-mempool-orange/20 text-mempool-orange"
                        : "bg-mempool-red/20 text-mempool-red"
                    }`}>
                      {tx.confirmations} conf
                    </span>
                  </div>
                </div>
              ))
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
