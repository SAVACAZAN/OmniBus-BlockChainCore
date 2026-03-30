import { useBlockchain } from "../../stores/useBlockchainStore";

export function RecentTransactions() {
  const { state } = useBlockchain();

  // Show pending TXs + recent block rewards
  const items = [
    ...state.pendingTxs.slice(0, 10).map((tx) => ({
      id: tx.txid,
      from: tx.from,
      to: "",
      amount: tx.amount_sat,
      status: "pending" as const,
      time: tx.timestamp,
    })),
    ...state.recentBlocks.slice(0, 10).map((block) => ({
      id: `coinbase-${block.height}`,
      from: "coinbase",
      to: block.miner || state.address,
      amount: block.rewardSAT || 0,
      status: "confirmed" as const,
      time: block.timestamp ? block.timestamp * 1000 : Date.now(),
    })),
  ].slice(0, 15);

  return (
    <div className="bg-mempool-card rounded-lg border border-mempool-border">
      <div className="px-4 py-3 border-b border-mempool-border">
        <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
          Recent Activity
        </h3>
      </div>
      <div className="divide-y divide-mempool-border/50 max-h-80 overflow-y-auto">
        {items.length === 0 ? (
          <div className="px-4 py-8 text-center text-mempool-text-dim text-sm">
            No transactions yet. Start mining to see activity.
          </div>
        ) : (
          items.map((item) => (
            <div
              key={item.id}
              className="px-4 py-2.5 flex items-center gap-3 animate-fadeIn"
            >
              {/* Status dot */}
              <div
                className={`w-2 h-2 rounded-full flex-shrink-0 ${
                  item.status === "pending"
                    ? "bg-mempool-orange"
                    : item.from === "coinbase"
                    ? "bg-mempool-green"
                    : "bg-mempool-blue"
                }`}
              />

              {/* Info */}
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2">
                  <span className="text-xs font-mono text-mempool-text truncate">
                    {item.from === "coinbase"
                      ? "Block Reward"
                      : item.id.slice(0, 16) + "..."}
                  </span>
                  <span
                    className={`text-[10px] px-1.5 py-0.5 rounded ${
                      item.status === "pending"
                        ? "bg-mempool-orange/20 text-mempool-orange"
                        : "bg-mempool-green/20 text-mempool-green"
                    }`}
                  >
                    {item.status}
                  </span>
                </div>
                <p className="text-[10px] text-mempool-text-dim truncate">
                  {item.from.slice(0, 20)}
                  {item.to ? ` → ${item.to.slice(0, 20)}` : ""}
                </p>
              </div>

              {/* Amount */}
              <span className="text-xs font-mono text-mempool-text flex-shrink-0">
                {(item.amount / 1e9).toFixed(4)}
              </span>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
