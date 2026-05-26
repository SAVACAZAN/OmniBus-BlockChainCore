/**
 * TxHashLink.tsx — clickable TX hash that opens the global TX search modal.
 *
 * Drop-in replacement for `<span>{txid.slice(0, 16)}…</span>` patterns.
 * Header.tsx wires `window.__openTx(txid)` — calling that from any tab pops
 * the TxSearch modal pre-filled with the hash, showing block, confirmations,
 * inputs/outputs, op_return memo, etc.
 */

import { midTrunc } from "../../utils/fmt";

type Props = {
  txid: string;
  truncate?: { left: number; right: number };
  className?: string;
};

export function TxHashLink({
  txid,
  truncate = { left: 16, right: 8 },
  className = "",
}: Props) {
  if (!txid) return null;

  const display = midTrunc(txid, truncate.left, truncate.right);

  return (
    <button
      type="button"
      onClick={(e) => {
        e.stopPropagation();
        if (typeof window !== "undefined" && (window as any).__openTx) {
          (window as any).__openTx(txid);
        }
      }}
      title={`${txid} — click to open transaction details`}
      className={`font-mono text-mempool-blue hover:text-mempool-orange hover:underline cursor-pointer ${className}`}
    >
      {display}
    </button>
  );
}
