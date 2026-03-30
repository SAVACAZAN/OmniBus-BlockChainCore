import { TransactionSquare } from "./TransactionSquare";
import type { BlockData, PendingTx } from "../../types";

interface MempoolBlockProps {
  block?: BlockData;
  pendingTxs?: PendingTx[];
  isPending?: boolean;
  isLatest?: boolean;
}

export function MempoolBlock({
  block,
  pendingTxs,
  isPending = false,
  isLatest = false,
}: MempoolBlockProps) {
  const txCount = isPending
    ? pendingTxs?.length || 0
    : block?.txCount || 0;

  const reward = block?.rewardSAT || 0;
  const height = block?.height ?? "?";
  const hash = block?.hash || "";

  // Generate TX squares
  const squares = [];
  if (isPending && pendingTxs) {
    for (let i = 0; i < Math.min(txCount, 100); i++) {
      squares.push(
        <TransactionSquare
          key={pendingTxs[i]?.txid || i}
          amount={pendingTxs[i]?.amount_sat || 0}
          index={i}
          isPending
        />
      );
    }
  } else {
    // Confirmed block — generate squares based on txCount
    for (let i = 0; i < Math.min(txCount, 100); i++) {
      squares.push(
        <TransactionSquare
          key={`${height}-${i}`}
          amount={reward}
          index={i}
        />
      );
    }
    // Always show at least the coinbase TX
    if (squares.length === 0) {
      squares.push(
        <TransactionSquare key={`${height}-cb`} amount={reward} index={0} />
      );
    }
  }

  const timeStr = block?.timestamp
    ? new Date(block.timestamp * 1000).toLocaleTimeString()
    : "";

  return (
    <div
      className={`
        relative flex-shrink-0 w-40 rounded-xl overflow-hidden
        transition-all duration-500 ease-out
        ${isLatest ? "animate-slideInRight" : ""}
        ${isPending ? "animate-pulseGlow" : ""}
      `}
      style={{
        background: isPending
          ? "linear-gradient(135deg, rgba(26,29,58,0.6), rgba(45,27,105,0.4))"
          : "linear-gradient(135deg, #1a1d3e, #2d1b69)",
        border: isPending
          ? "1px dashed rgba(74,144,217,0.5)"
          : "1px solid rgba(42,45,74,0.8)",
      }}
    >
      {/* TX Grid */}
      <div className="p-3 min-h-[120px]">
        <div
          className="flex flex-wrap gap-[3px]"
          style={{ maxHeight: 100, overflow: "hidden" }}
        >
          {squares}
        </div>
        {txCount > 100 && (
          <p className="text-[10px] text-mempool-text-dim mt-1">
            +{txCount - 100} more
          </p>
        )}
      </div>

      {/* Block Info */}
      <div className="px-3 pb-2 border-t border-mempool-border/50">
        <div className="flex items-center justify-between mt-2">
          <span className="text-xs font-mono font-bold text-mempool-text">
            {isPending ? "Next" : `#${height}`}
          </span>
          <span className="text-[10px] text-mempool-text-dim">
            {txCount} tx{txCount !== 1 ? "s" : ""}
          </span>
        </div>
        {!isPending && (
          <div className="mt-1">
            <p className="text-[10px] text-mempool-text-dim truncate">
              {hash.slice(0, 12)}...
            </p>
            <p className="text-[10px] text-mempool-green">
              +{(reward / 1e9).toFixed(4)} OMNI
            </p>
            {timeStr && (
              <p className="text-[10px] text-mempool-text-dim">{timeStr}</p>
            )}
          </div>
        )}
        {isPending && (
          <p className="text-[10px] text-mempool-blue mt-1">
            {txCount > 0 ? "Pending..." : "Waiting for TXs"}
          </p>
        )}
      </div>
    </div>
  );
}
