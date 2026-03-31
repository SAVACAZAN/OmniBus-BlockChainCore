import { useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import type { AddressHistoryEntry } from "../../types";

const rpc = new OmniBusRpcClient("/api");

export function AddressLookup() {
  const [address, setAddress] = useState("");
  const [searching, setSearching] = useState(false);
  const [history, setHistory] = useState<AddressHistoryEntry[]>([]);
  const [searched, setSearched] = useState(false);
  const [error, setError] = useState("");

  const handleSearch = async () => {
    const addr = address.trim();
    if (!addr) return;
    setSearching(true);
    setError("");
    setSearched(true);
    try {
      const result = await rpc.getAddressHistory(addr);
      if (result?.transactions) {
        setHistory(result.transactions);
      } else if (Array.isArray(result)) {
        setHistory(result);
      } else {
        setHistory([]);
      }
    } catch (err: any) {
      setError(err.message || "Failed to fetch address history");
      setHistory([]);
    }
    setSearching(false);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter") handleSearch();
  };

  return (
    <div className="bg-mempool-card rounded-xl border border-mempool-border overflow-hidden">
      <div className="px-5 py-3 border-b border-mempool-border">
        <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
          Address Lookup
        </h3>
      </div>

      <div className="p-5">
        {/* Search bar */}
        <div className="flex gap-2 mb-4">
          <input
            type="text"
            value={address}
            onChange={(e) => setAddress(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="ob1q... or any address"
            className="flex-1 bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2.5 text-sm font-mono text-mempool-text placeholder-mempool-text-dim/40 focus:outline-none focus:border-mempool-blue"
          />
          <button
            onClick={handleSearch}
            disabled={searching || !address.trim()}
            className="bg-mempool-blue hover:bg-mempool-blue/80 disabled:opacity-30 text-white text-sm font-medium rounded-lg px-4 py-2.5 transition-colors"
          >
            {searching ? "..." : "Lookup"}
          </button>
        </div>

        {error && (
          <p className="text-xs text-mempool-red mb-3">{error}</p>
        )}

        {/* Results */}
        {searched && !searching && history.length === 0 && !error && (
          <p className="text-xs text-mempool-text-dim text-center py-4">
            No transactions found for this address.
          </p>
        )}

        {history.length > 0 && (
          <div className="divide-y divide-mempool-border/30 max-h-80 overflow-y-auto">
            {history.map((tx, i) => (
              <div key={tx.txid || i} className="py-2.5 flex items-center gap-3">
                <div className={`w-2 h-2 rounded-full flex-shrink-0 ${
                  tx.direction === "received" ? "bg-mempool-green" : "bg-mempool-orange"
                }`} />
                <div className="flex-1 min-w-0">
                  <p className="text-xs font-mono text-mempool-text truncate">
                    {tx.txid?.slice(0, 24)}...
                  </p>
                  <p className="text-[10px] text-mempool-text-dim">
                    {tx.from?.slice(0, 16)} -&gt; {tx.to?.slice(0, 16)}
                    {tx.blockHeight ? ` | Block #${tx.blockHeight}` : ""}
                  </p>
                </div>
                <div className="flex-shrink-0">
                  <span className={`text-[10px] px-1.5 py-0.5 rounded-full font-mono ${
                    tx.confirmations >= 6
                      ? "bg-mempool-green/20 text-mempool-green"
                      : tx.confirmations >= 1
                      ? "bg-mempool-orange/20 text-mempool-orange"
                      : "bg-mempool-red/20 text-mempool-red"
                  }`}>
                    {tx.confirmations} conf
                  </span>
                </div>
                <div className="text-right flex-shrink-0">
                  <p className={`text-xs font-mono ${
                    tx.direction === "received" ? "text-mempool-green" : "text-mempool-orange"
                  }`}>
                    {tx.direction === "received" ? "+" : "-"}{((tx.amount || 0) / 1e9).toFixed(4)}
                  </p>
                  {tx.fee > 0 && (
                    <p className="text-[9px] text-mempool-text-dim font-mono">
                      fee: {tx.fee} SAT
                    </p>
                  )}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
