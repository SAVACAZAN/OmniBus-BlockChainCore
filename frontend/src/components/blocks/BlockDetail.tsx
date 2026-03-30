import { useState, useEffect } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import type { BlockData } from "../../types";

const rpc = new OmniBusRpcClient("/api");

interface BlockDetailProps {
  block: BlockData;
  onClose: () => void;
}

export function BlockDetail({ block, onClose }: BlockDetailProps) {
  const [txs, setTxs] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    loadTxs();
  }, [block.height]);

  const loadTxs = async () => {
    setLoading(true);
    try {
      const result: any = await rpc.request_raw("gettransactions");
      // Filter TXs for this block height
      const blockTxs = (result?.transactions || []).filter(
        (tx: any) => tx.blockHeight === block.height
      );
      setTxs(blockTxs);
    } catch {}
    setLoading(false);
  };

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
            ✕
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
              <p className="text-xs font-mono text-mempool-text-dim break-all">{block.previousHash || "—"}</p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase">Miner</p>
              <p className="text-xs font-mono text-mempool-green break-all">{block.miner || "—"}</p>
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
                {block.timestamp ? new Date(block.timestamp * 1000).toLocaleString() : "—"}
              </p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase">Nonce</p>
              <p className="text-xs font-mono text-mempool-text">{block.nonce?.toLocaleString() || "—"}</p>
            </div>
          </div>

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
                <span className="text-mempool-text-dim">→ </span>
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
                  <div className="mt-1 text-[10px] text-mempool-text-dim">
                    <span className="font-mono">{tx.from?.slice(0, 20)}</span>
                    <span className="text-mempool-text-dim"> → </span>
                    <span className="font-mono">{tx.to?.slice(0, 20)}</span>
                    <span className="text-mempool-orange ml-2">
                      {((tx.amount || 0) / 1e9).toFixed(4)} OMNI
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
