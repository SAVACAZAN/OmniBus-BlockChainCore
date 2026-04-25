import { useEffect, useState } from "react";
import { TransactionSquare } from "./TransactionSquare";
import OmniBusRpcClient from "../../api/rpc-client";
import type { BlockData, BlockPriceSnapshot, PendingTx } from "../../types";

interface MempoolBlockProps {
  block?: BlockData;
  pendingTxs?: PendingTx[];
  isPending?: boolean;
  isLatest?: boolean;
  /// Optional click handler. When supplied (only for confirmed blocks),
  /// the card becomes clickable and opens BlockDetail in the parent.
  onClick?: () => void;
}

const rpc = new OmniBusRpcClient();

// Format USD with thousand-comma + dot decimals: 100,000.00 / 0.0316.
// `decimals` is min decimals; thousands separator is locale-en-US to lock
// the comma even when the user's browser is non-EN.
function fmtUsd(micro: number, decimals: number): string {
  if (!micro) return "—";
  const usd = micro / 1_000_000;
  return usd.toLocaleString("en-US", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
}

// Median across the 3 exchange slots for a given pair label.
function median(prices: BlockPriceSnapshot[] | undefined, pair: string): number {
  if (!prices) return 0;
  const valid = prices
    .filter((p) => p.success && p.pair === pair && p.bidMicroUsd > 0)
    .map((p) => Math.floor((p.bidMicroUsd + p.askMicroUsd) / 2));
  if (valid.length === 0) return 0;
  valid.sort((a, b) => a - b);
  return valid[Math.floor(valid.length / 2)];
}

export function MempoolBlock({
  block,
  pendingTxs,
  isPending = false,
  isLatest = false,
  onClick,
}: MempoolBlockProps) {
  // Fetch full block detail (with prices array) once per height. Skipped
  // for the pending-block placeholder (no height yet).
  const [prices, setPrices] = useState<BlockPriceSnapshot[] | undefined>(
    block?.prices
  );
  useEffect(() => {
    if (isPending || block?.height == null) return;
    if (block.prices && block.prices.length > 0) {
      setPrices(block.prices);
      return;
    }
    let cancelled = false;
    (async () => {
      try {
        const result: any = await rpc.request_raw("getblock", [block.height]);
        if (!cancelled && Array.isArray(result?.prices)) {
          setPrices(result.prices);
        }
      } catch {}
    })();
    return () => { cancelled = true; };
  }, [block?.height, isPending]);

  const btcMedian = median(prices, "BTC/USD");
  const lcxMedian = median(prices, "LCX/USD");

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

  const clickable = !isPending && typeof onClick === "function";

  return (
    <div
      onClick={clickable ? onClick : undefined}
      role={clickable ? "button" : undefined}
      tabIndex={clickable ? 0 : undefined}
      onKeyDown={clickable ? (e) => { if (e.key === "Enter" || e.key === " ") onClick?.(); } : undefined}
      className={`
        relative flex-shrink-0 w-40 rounded-xl overflow-hidden
        transition-all duration-500 ease-out
        ${isLatest ? "animate-slideInRight" : ""}
        ${isPending ? "animate-pulseGlow" : ""}
        ${clickable ? "cursor-pointer hover:ring-2 hover:ring-mempool-orange/60 focus:outline-none focus:ring-2 focus:ring-mempool-orange" : ""}
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
            {/* Median oracle price snapshot at mining (3-exchange median).
                Hidden when no snapshot exists (block mined before WS came up). */}
            {(btcMedian > 0 || lcxMedian > 0) && (
              <div className="mt-1 pt-1 border-t border-mempool-border/40 space-y-0.5">
                {btcMedian > 0 && (
                  <p className="text-[9px] font-mono text-mempool-orange">
                    BTC ${fmtUsd(btcMedian, 2)}
                  </p>
                )}
                {lcxMedian > 0 && (
                  <p className="text-[9px] font-mono text-mempool-blue">
                    LCX ${fmtUsd(lcxMedian, 4)}
                  </p>
                )}
              </div>
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
