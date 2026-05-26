import { useEffect, useState } from "react";
import { TransactionSquare } from "./TransactionSquare";
import { rpc } from "../../api/rpc-client";
import type { BlockData, BlockPriceSnapshot, PendingTx } from "../../types";
import { DashboardPlasma } from "../effects/DashboardPlasma";
import { useIsPlasmaActive } from "../effects/PlasmaSlotContext";
import { SAT_PER_OMNI, midTrunc, fmtUsd } from "../../utils/fmt";

interface MempoolBlockProps {
  block?: BlockData;
  pendingTxs?: PendingTx[];
  isPending?: boolean;
  isLatest?: boolean;
  /// Optional click handler. When supplied (only for confirmed blocks),
  /// the card becomes clickable and opens BlockDetail in the parent.
  onClick?: () => void;
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
  const plasmaActive5 = useIsPlasmaActive(5);
  const plasmaActive6 = useIsPlasmaActive(6);
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
        const result = await rpc.getBlock(block.height);
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

  // Block timestamp may be Unix-seconds (chain) or accidentally Unix-millis.
  // Year-5000 cutoff (~95e9 seconds since epoch) catches the accidental ms.
  const timeStr = block?.timestamp
    ? new Date(block.timestamp > 95_000_000_000 ? block.timestamp : block.timestamp * 1000).toLocaleTimeString()
    : "";

  const clickable = !isPending && typeof onClick === "function";

  // Empty/coinbase-only blocks need almost no TX area; keep it slim.
  // Pending block keeps a bit more height so it's visually balanced.
  const hasTxs = txCount > 0;
  const txAreaCls = isPending
    ? "p-2.5 min-h-[60px]"
    : hasTxs
      ? "p-2.5 min-h-[60px]"
      : "p-1.5 min-h-[12px]";

  return (
    <div
      onClick={clickable ? onClick : undefined}
      role={clickable ? "button" : undefined}
      tabIndex={clickable ? 0 : undefined}
      onKeyDown={clickable ? (e) => { if (e.key === "Enter" || e.key === " ") onClick?.(); } : undefined}
      className={`
        relative flex-shrink-0 w-44 rounded-xl
        transition-all duration-500 ease-out
        ${isLatest ? "animate-slideInRight" : ""}
        ${isPending ? "animate-pulseGlow" : ""}
        ${clickable ? "cursor-pointer hover:ring-2 hover:ring-mempool-orange/60 focus:outline-none focus:ring-2 focus:ring-mempool-orange" : ""}
      `}
      style={{
        background: isPending
          ? "linear-gradient(135deg, rgba(26,29,58,0.15), rgba(45,27,105,0.10))"
          : "linear-gradient(135deg, rgba(26,29,62,0.18), rgba(45,27,105,0.12))",
        border: isPending
          ? "1px dashed rgba(74,144,217,0.5)"
          : "1px solid rgba(42,45,74,0.8)",
        backdropFilter: "blur(4px)",
      }}
    >
      {/* Plasma swarm visible only on the pending Next card. Anchored
          to the right so the orange core sits past the right edge of the
          card body — same composition as the MEMPOOL stat card. */}
      {((isPending && plasmaActive5) || (isLatest && !isPending && plasmaActive6)) && (
        <div
          className="absolute top-1/2 right-0 -translate-y-1/2 pointer-events-none"
          style={{ zIndex: 0, opacity: 0.75, width: "75%", height: "100%", marginRight: "-15%" }}
        >
          <DashboardPlasma />
        </div>
      )}
      {/* TX Grid (compact when block has 0 txs — was wasting half the card) */}
      <div className={txAreaCls + " relative"} style={{ zIndex: 10 }}>
        {hasTxs && (
          <>
            <div
              className="flex flex-wrap gap-[3px]"
              style={{ maxHeight: 60, overflow: "hidden" }}
            >
              {squares}
            </div>
            {txCount > 100 && (
              <p className="text-[10px] text-mempool-text-dim mt-1">
                +{txCount - 100} more
              </p>
            )}
          </>
        )}
      </div>

      {/* Block Info — main content of the card now (was getting squashed
          under a huge empty TX grid for coinbase-only blocks). */}
      <div className="px-3 pb-3 border-t border-mempool-border/50 relative" style={{ zIndex: 10 }}>
        <div className="flex items-center justify-between mt-2">
          <span className="text-sm font-mono font-bold text-mempool-text">
            {isPending ? "Next" : `#${height}`}
          </span>
          <span className="text-[11px] text-mempool-text-dim">
            {txCount} tx{txCount !== 1 ? "s" : ""}
          </span>
        </div>
        {!isPending && (
          <div className="mt-1.5 space-y-0.5">
            <p className="text-[11px] font-mono text-mempool-text-dim truncate" title={hash}>
              {midTrunc(hash, 14, 6)}
            </p>
            <p className="text-[11px] font-mono text-mempool-green">
              +{(reward / SAT_PER_OMNI).toFixed(8)} OMNI
            </p>
            {timeStr && (
              <p className="text-[11px] text-mempool-text-dim">{timeStr}</p>
            )}
            {/* Median oracle price snapshot at mining (3-exchange median).
                Hidden when no snapshot exists (block mined before WS came up). */}
            {(btcMedian > 0 || lcxMedian > 0) && (
              <div className="mt-1.5 pt-1.5 border-t border-mempool-border/40 space-y-0.5">
                {btcMedian > 0 && (
                  <p className="text-[11px] font-mono text-mempool-orange">
                    BTC ${fmtUsd(btcMedian, 2)}
                  </p>
                )}
                {lcxMedian > 0 && (
                  <p className="text-[11px] font-mono text-mempool-blue">
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
