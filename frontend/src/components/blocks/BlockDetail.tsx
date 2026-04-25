import { useState, useEffect } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import type { BlockData } from "../../types";

const rpc = new OmniBusRpcClient();

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

export function BlockDetail({ block, onClose }: BlockDetailProps) {
  const [txs, setTxs] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [prices, setPrices] = useState<PriceEntry[]>([]);

  useEffect(() => {
    loadTxs();
    loadPrices();
  }, [block.height]);

  const loadPrices = async () => {
    try {
      const result: any = await rpc.request_raw("getblock", [block.height]);
      if (Array.isArray(result?.prices)) setPrices(result.prices);
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
      <div className="bg-mempool-card border border-mempool-border rounded-xl max-w-2xl w-full max-h-[80vh] overflow-y-auto"
        onClick={(e) => e.stopPropagation()}>

        {/* Header */}
        <div className="flex items-center justify-between px-5 py-4 border-b border-mempool-border">
          <h3 className="text-lg font-bold text-mempool-text">
            Block #{block.height}
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
              <p className="text-xs font-mono text-mempool-blue break-all">{block.hash}</p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase">Previous Hash</p>
              <p className="text-xs font-mono text-mempool-text-dim break-all">{block.previousHash || "--"}</p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase">Miner</p>
              <p className="text-xs font-mono text-mempool-green break-all">{block.miner || "--"}</p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase">Reward</p>
              <p className="text-xs font-mono text-mempool-green">
                {((block.rewardSAT || 0) / 1e9).toFixed(4)} OMNI ({block.rewardSAT?.toLocaleString()} SAT)
              </p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase">Timestamp</p>
              <p className="text-xs text-mempool-text">
                {block.timestamp ? new Date(block.timestamp * 1000).toLocaleString() : "--"}
              </p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase">Nonce</p>
              <p className="text-xs font-mono text-mempool-text">{block.nonce?.toLocaleString() || "--"}</p>
            </div>
          </div>

          {/* Oracle Prices captured at mining time */}
          {prices.length > 0 && (
            <div className="bg-mempool-bg rounded-lg p-3 border border-mempool-border/50">
              <p className="text-[10px] text-mempool-text-dim uppercase tracking-wider mb-2">
                Oracle Prices @ Mining (3 exchanges × 2 pairs)
              </p>
              <div className="grid grid-cols-2 gap-3">
                {(["BTC/USD", "LCX/USD"] as const).map((pair) => {
                  const isLcx = pair === "LCX/USD";
                  const rows = prices.filter((p) => p.pair === pair);
                  return (
                    <div key={pair}>
                      <p className="text-[10px] font-bold text-mempool-text mb-1">{pair}</p>
                      <table className="w-full text-[10px]">
                        <thead>
                          <tr className="text-mempool-text-dim">
                            <th className="text-left pr-1">Ex</th>
                            <th className="text-right">Bid</th>
                            <th className="text-right">Ask</th>
                            <th className="text-right pl-1">Time</th>
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
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  );
                })}
              </div>
            </div>
          )}

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
              Transactions ({block.txCount + 1})
            </h4>

            {/* Coinbase TX (always present) */}
            <div className="bg-mempool-bg rounded-lg p-3 mb-2">
              <div className="flex items-center gap-2">
                <div className="w-2 h-2 rounded-full bg-mempool-green flex-shrink-0" />
                <span className="text-xs font-mono text-mempool-green font-bold">COINBASE</span>
                <span className="text-[10px] text-mempool-text-dim ml-auto">Block Reward</span>
              </div>
              <div className="mt-1 text-xs text-mempool-text-dim">
                <span className="text-mempool-text-dim">-&gt; </span>
                <span className="font-mono text-mempool-blue">{block.miner?.slice(0, 32) || "miner"}...</span>
                <span className="text-mempool-green ml-2">
                  +{((block.rewardSAT || 0) / 1e9).toFixed(4)} OMNI
                </span>
              </div>
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
                  <div className="flex items-center gap-2">
                    <div className="w-2 h-2 rounded-full bg-mempool-blue flex-shrink-0" />
                    <span className="text-xs font-mono text-mempool-text truncate">{tx.txid?.slice(0, 24)}...</span>
                    <span className={`text-[10px] px-1.5 py-0.5 rounded ml-auto ${
                      tx.status === "confirmed"
                        ? "bg-mempool-green/20 text-mempool-green"
                        : "bg-mempool-orange/20 text-mempool-orange"
                    }`}>{tx.status}</span>
                  </div>
                  <div className="mt-1 text-[10px] text-mempool-text-dim flex items-center gap-2 flex-wrap">
                    <span>
                      <span className="font-mono">{tx.from?.slice(0, 20)}</span>
                      <span className="text-mempool-text-dim"> -&gt; </span>
                      <span className="font-mono">{tx.to?.slice(0, 20)}</span>
                    </span>
                    <span className="text-mempool-orange">
                      {((tx.amount || 0) / 1e9).toFixed(4)} OMNI
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
