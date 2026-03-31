import { useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import type { TransactionDetail } from "../../types";

const rpc = new OmniBusRpcClient("/api");

interface TxSearchProps {
  onClose?: () => void;
}

export function TxSearch({ onClose }: TxSearchProps) {
  const [query, setQuery] = useState("");
  const [searching, setSearching] = useState(false);
  const [result, setResult] = useState<TransactionDetail | null>(null);
  const [notFound, setNotFound] = useState(false);

  const handleSearch = async () => {
    const txid = query.trim();
    if (!txid) return;
    setSearching(true);
    setNotFound(false);
    setResult(null);
    try {
      const detail = await rpc.getTransactionDetail(txid);
      if (detail && detail.txid) {
        setResult(detail);
      } else {
        setNotFound(true);
      }
    } catch {
      setNotFound(true);
    }
    setSearching(false);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter") handleSearch();
    if (e.key === "Escape" && onClose) onClose();
  };

  return (
    <div className="fixed inset-0 bg-black/60 backdrop-blur-sm z-50 flex items-start justify-center pt-24 px-4"
      onClick={onClose}>
      <div className="bg-mempool-card border border-mempool-border rounded-xl max-w-lg w-full"
        onClick={(e) => e.stopPropagation()}>

        {/* Search input */}
        <div className="p-4 border-b border-mempool-border">
          <div className="flex gap-2">
            <input
              type="text"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="Enter TX hash..."
              autoFocus
              className="flex-1 bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2.5 text-sm font-mono text-mempool-text placeholder-mempool-text-dim/40 focus:outline-none focus:border-mempool-blue"
            />
            <button
              onClick={handleSearch}
              disabled={searching || !query.trim()}
              className="bg-mempool-blue hover:bg-mempool-blue/80 disabled:opacity-30 text-white text-sm font-medium rounded-lg px-4 py-2.5 transition-colors"
            >
              {searching ? "..." : "Search"}
            </button>
          </div>
        </div>

        {/* Result */}
        <div className="p-4">
          {searching && (
            <p className="text-xs text-mempool-text-dim text-center py-4">Searching...</p>
          )}

          {notFound && (
            <div className="text-center py-6">
              <p className="text-sm text-mempool-red">TX not found</p>
              <p className="text-[10px] text-mempool-text-dim mt-1">
                Check the hash and try again. The TX may not be in the local node.
              </p>
            </div>
          )}

          {result && (
            <div className="space-y-3">
              <div className="grid grid-cols-2 gap-3">
                <div className="col-span-2">
                  <p className="text-[10px] text-mempool-text-dim uppercase">TX ID</p>
                  <p className="text-xs font-mono text-mempool-blue break-all">{result.txid}</p>
                </div>
                <div>
                  <p className="text-[10px] text-mempool-text-dim uppercase">From</p>
                  <p className="text-xs font-mono text-mempool-text break-all">{result.from}</p>
                </div>
                <div>
                  <p className="text-[10px] text-mempool-text-dim uppercase">To</p>
                  <p className="text-xs font-mono text-mempool-text break-all">{result.to}</p>
                </div>
                <div>
                  <p className="text-[10px] text-mempool-text-dim uppercase">Amount</p>
                  <p className="text-xs font-mono text-mempool-green">
                    {((result.amount || 0) / 1e9).toFixed(4)} OMNI
                  </p>
                </div>
                <div>
                  <p className="text-[10px] text-mempool-text-dim uppercase">Fee</p>
                  <p className="text-xs font-mono text-mempool-orange">{result.fee} SAT</p>
                </div>
                <div>
                  <p className="text-[10px] text-mempool-text-dim uppercase">Status</p>
                  <span className={`text-xs px-2 py-0.5 rounded ${
                    result.status === "confirmed"
                      ? "bg-mempool-green/20 text-mempool-green"
                      : "bg-mempool-orange/20 text-mempool-orange"
                  }`}>
                    {result.status}
                  </span>
                </div>
                <div>
                  <p className="text-[10px] text-mempool-text-dim uppercase">Confirmations</p>
                  <p className={`text-xs font-mono ${
                    result.confirmations >= 6
                      ? "text-mempool-green"
                      : result.confirmations >= 1
                      ? "text-mempool-orange"
                      : "text-mempool-red"
                  }`}>
                    {result.confirmations}
                  </p>
                </div>
                <div>
                  <p className="text-[10px] text-mempool-text-dim uppercase">Block Height</p>
                  <p className="text-xs font-mono text-mempool-text">{result.blockHeight || "--"}</p>
                </div>
                {result.locktime != null && result.locktime > 0 && (
                  <div>
                    <p className="text-[10px] text-mempool-text-dim uppercase">Locktime</p>
                    <p className="text-xs font-mono text-mempool-text">{result.locktime}</p>
                  </div>
                )}
                {result.op_return && (
                  <div className="col-span-2">
                    <p className="text-[10px] text-mempool-text-dim uppercase">OP_RETURN</p>
                    <p className="text-xs font-mono text-mempool-purple break-all">{result.op_return}</p>
                  </div>
                )}
              </div>
            </div>
          )}

          {!searching && !notFound && !result && (
            <p className="text-xs text-mempool-text-dim text-center py-4">
              Enter a transaction hash to look up details.
            </p>
          )}
        </div>
      </div>
    </div>
  );
}
