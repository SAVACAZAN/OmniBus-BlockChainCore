import { useState, useEffect } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import OmniBusRpcClient from "../../api/rpc-client";

const rpc = new OmniBusRpcClient();

// Trunchiaza hash/adresa la mijloc cu '**' (gen 0000abcd**1234ef).
function midTrunc(s: string | undefined | null, head = 8, tail = 6): string {
  if (!s) return "—";
  if (s.length <= head + tail + 2) return s;
  return `${s.slice(0, head)}**${s.slice(-tail)}`;
}

// Click pe hash → deschide modal cu detalii TX (in TxSearch, mai jos)
declare global {
  interface Window { __openTx?: (txid: string) => void }
}

function ConfirmationBadge({ count }: { count: number }) {
  if (count === 0) {
    return (
      <span className="text-[9px] px-1.5 py-0.5 rounded-full bg-mempool-red/20 text-mempool-red font-mono font-medium">
        0
      </span>
    );
  }
  if (count >= 1 && count <= 5) {
    return (
      <span className="text-[9px] px-1.5 py-0.5 rounded-full bg-mempool-orange/20 text-mempool-orange font-mono font-medium">
        {count}
      </span>
    );
  }
  return (
    <span className="text-[9px] px-1.5 py-0.5 rounded-full bg-mempool-green/20 text-mempool-green font-mono font-medium">
      {count}+
    </span>
  );
}

export function RecentTransactions() {
  const { state } = useBlockchain();
  const [recentTxs, setRecentTxs] = useState<any[]>([]);

  // Fetch recent TXs with confirmations from the new endpoint
  useEffect(() => {
    const fetchRecent = async () => {
      try {
        const result = await rpc.listTransactions(15);
        if (result?.transactions) {
          setRecentTxs(result.transactions);
          return;
        }
      } catch {}
      // Fallback: no data from new endpoint
      setRecentTxs([]);
    };
    fetchRecent();
    const id = setInterval(fetchRecent, 6000);
    return () => clearInterval(id);
  }, [state.blockCount]);

  // Combine: new endpoint TXs + fallback pending + block rewards
  const items = recentTxs.length > 0
    ? recentTxs.slice(0, 15).map((tx: any) => ({
        id: tx.txid || tx.id,
        from: tx.from || "",
        to: tx.to || "",
        amount: tx.amount || 0,
        fee: tx.fee || 0,
        status: tx.status || "pending",
        confirmations: tx.confirmations ?? 0,
        time: tx.timestamp || Date.now(),
      }))
    : [
        ...state.pendingTxs.slice(0, 10).map((tx) => ({
          id: tx.txid,
          from: tx.from,
          to: "",
          amount: tx.amount_sat,
          fee: 0,
          status: "pending" as const,
          confirmations: 0,
          time: tx.timestamp,
        })),
        ...state.recentBlocks.slice(0, 10).map((block) => ({
          id: `coinbase-${block.height}`,
          from: "coinbase",
          to: block.miner || state.address,
          amount: block.rewardSAT || 0,
          fee: 0,
          status: "confirmed" as const,
          confirmations: Math.max(1, state.blockCount - block.height),
          time: block.timestamp ? block.timestamp * 1000 : Date.now(),
        })),
      ].slice(0, 15);

  // Dedupe by id — pending TX + coinbase reward at same block can collide.
  const uniqueItems = [...new Map(items.map((it) => [it.id, it])).values()];

  return (
    <div className="bg-mempool-bg-elev rounded-lg border border-mempool-border backdrop-blur-sm">
      <div className="px-4 py-3 border-b border-mempool-border">
        <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
          Recent Activity
        </h3>
      </div>
      <div className="divide-y divide-mempool-border/50 max-h-80 overflow-y-auto">
        {uniqueItems.length === 0 ? (
          <div className="px-4 py-8 text-center text-mempool-text-dim text-sm">
            No transactions yet. Start mining to see activity.
          </div>
        ) : (
          uniqueItems.map((item) => (
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
                  {item.from === "coinbase" ? (
                    <span className="text-xs font-mono text-mempool-text truncate">Block Reward</span>
                  ) : (
                    <button
                      type="button"
                      onClick={() => { window.location.hash = `#/tx/${item.id}`; }}
                      title={item.id}
                      className="text-xs font-mono text-mempool-blue hover:underline truncate"
                    >
                      {midTrunc(item.id, 10, 8)}
                    </button>
                  )}
                  <span
                    className={`text-[10px] px-1.5 py-0.5 rounded ${
                      item.status === "pending"
                        ? "bg-mempool-orange/20 text-mempool-orange"
                        : "bg-mempool-green/20 text-mempool-green"
                    }`}
                  >
                    {item.status}
                  </span>
                  <ConfirmationBadge count={item.confirmations} />
                </div>
                <p className="text-[10px] text-mempool-text-dim truncate" title={`${item.from}${item.to ? " -> " + item.to : ""}`}>
                  {item.from === "coinbase" ? (
                    item.to ? (
                      <button onClick={() => { window.location.hash = `#/address/${item.to}`; }}
                        className="font-mono text-mempool-green hover:underline">
                        → {midTrunc(item.to, 8, 6)}
                      </button>
                    ) : null
                  ) : (
                    <>
                      <button onClick={() => { window.location.hash = `#/address/${item.from}`; }}
                        className="font-mono hover:text-mempool-blue hover:underline transition-colors">
                        {midTrunc(item.from, 8, 6)}
                      </button>
                      {item.to ? (
                        <> &nbsp;→&nbsp;{" "}
                          <button onClick={() => { window.location.hash = `#/address/${item.to}`; }}
                            className="font-mono hover:text-mempool-blue hover:underline transition-colors">
                            {midTrunc(item.to, 8, 6)}
                          </button>
                        </>
                      ) : null}
                    </>
                  )}
                </p>
              </div>

              {/* Amount + Fee */}
              <div className="text-right flex-shrink-0">
                <span className="text-xs font-mono text-mempool-text">
                  {(item.amount / 1e9).toFixed(8)}
                </span>
                {item.fee > 0 && (
                  <p className="text-[9px] text-mempool-text-dim font-mono">
                    fee: {item.fee} SAT
                  </p>
                )}
              </div>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
