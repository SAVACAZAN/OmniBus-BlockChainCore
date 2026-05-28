import { useState } from "react";

/**
 * Single search bar that resolves any input to the right explorer page —
 * the "BTC-style" experience: type a height, a tx/block hash, or an address
 * and land on the right page automatically. Routes via window.location.hash,
 * which the App's hashchange listener already wires into the explorer.
 *
 * Disambiguation rules:
 *   - all digits           → block by height       (#/block/{n})
 *   - exactly 64 hex chars → transaction hash      (#/tx/{hash})
 *   - anything else        → address               (#/address/{addr})
 *
 * The 64-hex case favours TX (by far the most common search). If a user wants
 * to view a block by hash they can also click through from the block list.
 */
export function ExplorerSearchBar({ className = "" }: { className?: string }) {
  const [q, setQ] = useState("");
  const [hint, setHint] = useState<string | null>(null);

  function go() {
    const s = q.trim();
    if (!s) return;
    setHint(null);
    if (/^\d+$/.test(s)) {
      window.location.hash = `#/block/${s}`;
    } else if (/^[0-9a-fA-F]{64}$/.test(s)) {
      window.location.hash = `#/tx/${s.toLowerCase()}`;
    } else if (/^[A-Za-z0-9_.@\-]{6,}$/.test(s)) {
      window.location.hash = `#/address/${s}`;
    } else {
      setHint("Enter a height, a 64-char hash, or an address");
      return;
    }
    setQ("");
  }

  return (
    <form
      className={`flex items-center gap-1 ${className}`}
      onSubmit={(e) => { e.preventDefault(); go(); }}
    >
      <input
        value={q}
        onChange={(e) => setQ(e.target.value)}
        placeholder="Search block height / tx / address…"
        className="w-72 px-2 py-1 text-xs bg-mempool-bg border border-mempool-border rounded font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
        spellCheck={false}
        autoCorrect="off"
        autoCapitalize="off"
        aria-label="Explorer search"
      />
      <button
        type="submit"
        className="px-2 py-1 text-xs bg-mempool-bg-elev border border-mempool-border rounded hover:bg-mempool-bg-light text-mempool-text-dim transition-colors"
        aria-label="Go"
      >
        ↵
      </button>
      {hint && <span className="text-[11px] text-mempool-text-dim">{hint}</span>}
    </form>
  );
}
