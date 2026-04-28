import { useEffect, useState } from "react";
import {
  getUnlocked,
  lockWallet,
  subscribeWallet,
  unlockWallet,
} from "../../api/wallet-keystore";

/**
 * Small panel for unlocking the wallet that signs orders client-side.
 * Shows the active address when unlocked, else a privkey paste form.
 *
 * The private key is held in memory only — page refresh wipes it.
 * For production we want WebCrypto-encrypted sessionStorage; v1 keeps
 * the surface tiny so we ship the matching-engine flow first.
 */
export function AuthPanel() {
  const [, force] = useState(0);
  const [pkInput, setPkInput] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [showPaste, setShowPaste] = useState(false);

  useEffect(() => subscribeWallet(() => force((n) => n + 1)), []);

  const u = getUnlocked();

  const onUnlock = () => {
    setError(null);
    try {
      unlockWallet(pkInput);
      setPkInput("");
      setShowPaste(false);
    } catch (e: any) {
      setError(e?.message || "Unlock failed");
    }
  };

  if (u) {
    return (
      <div className="rounded-lg border border-green-500/30 bg-green-500/5 p-3 flex items-center justify-between gap-3">
        <div className="min-w-0">
          <div className="text-[10px] uppercase tracking-wider text-green-300/80">
            Wallet unlocked
          </div>
          <div className="font-mono text-xs text-mempool-text truncate" title={u.address}>
            {u.address}
          </div>
        </div>
        <button
          onClick={lockWallet}
          className="px-3 py-1.5 text-xs rounded bg-mempool-bg-elev hover:bg-red-500/20 text-mempool-text-dim hover:text-red-300 transition-colors"
        >
          Lock
        </button>
      </div>
    );
  }

  return (
    <div className="rounded-lg border border-amber-500/30 bg-amber-500/5 p-3">
      <div className="text-[10px] uppercase tracking-wider text-amber-300/80 mb-2">
        Wallet locked — sign orders client-side
      </div>
      {!showPaste ? (
        <button
          onClick={() => setShowPaste(true)}
          className="px-3 py-1.5 text-xs rounded bg-mempool-blue hover:bg-blue-600 text-white"
        >
          Paste private key
        </button>
      ) : (
        <div className="space-y-2">
          <input
            type="password"
            placeholder="64 hex chars (no 0x)"
            value={pkInput}
            onChange={(e) => setPkInput(e.target.value)}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text font-mono text-xs focus:outline-none focus:border-mempool-blue"
            spellCheck={false}
            autoComplete="off"
          />
          <div className="flex gap-2">
            <button
              onClick={onUnlock}
              disabled={pkInput.trim().length === 0}
              className="px-3 py-1.5 text-xs rounded bg-mempool-blue hover:bg-blue-600 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
            >
              Unlock
            </button>
            <button
              onClick={() => {
                setShowPaste(false);
                setPkInput("");
                setError(null);
              }}
              className="px-3 py-1.5 text-xs rounded bg-mempool-bg-elev text-mempool-text-dim hover:text-mempool-text"
            >
              Cancel
            </button>
          </div>
          {error && (
            <div className="text-[11px] text-red-300">{error}</div>
          )}
          <div className="text-[10px] text-mempool-text-dim leading-relaxed">
            The key stays in memory only. Refresh the page to lock. Never
            shared with the server — only the resulting ECDSA signature is.
          </div>
        </div>
      )}
    </div>
  );
}
