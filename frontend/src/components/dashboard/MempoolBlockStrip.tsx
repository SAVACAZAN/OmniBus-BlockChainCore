import { useBlockchain } from "../../stores/useBlockchainStore";
import { MempoolBlock } from "./MempoolBlock";

const MAX_VISIBLE_BLOCKS = 8;

export function MempoolBlockStrip() {
  const { state } = useBlockchain();
  const blocks = state.recentBlocks.slice(0, MAX_VISIBLE_BLOCKS);

  return (
    <section className="w-full">
      <div className="flex items-center gap-2 mb-3">
        <h2 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
          Recent Blocks
        </h2>
        <div className="flex-1 h-px bg-mempool-border" />
        <span className="text-xs text-mempool-text-dim font-mono">
          {state.mempoolSize} pending TX{state.mempoolSize !== 1 ? "s" : ""}
        </span>
      </div>

      <div className="flex gap-3 overflow-x-auto pb-2 scrollbar-thin">
        {/* Confirmed blocks (newest first, displayed left to right) */}
        {[...blocks].reverse().map((block, i) => (
          <MempoolBlock
            key={block.height}
            block={block}
            isLatest={i === blocks.length - 1}
          />
        ))}

        {/* Arrow separator */}
        <div className="flex-shrink-0 flex items-center px-1">
          <svg
            width="24"
            height="24"
            viewBox="0 0 24 24"
            fill="none"
            className="text-mempool-blue opacity-50"
          >
            <path
              d="M9 18l6-6-6-6"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        </div>

        {/* Pending block (mempool) */}
        <MempoolBlock
          isPending
          pendingTxs={state.pendingTxs}
        />
      </div>
    </section>
  );
}
