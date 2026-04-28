import { useEffect, useState } from "react";
import {
  clearVault,
  getUnlocked,
  hasVault,
  lockWallet,
  readVaultMeta,
  subscribeWallet,
  unlockFromMnemonic,
  unlockFromPrivKey,
  unlockFromVault,
} from "../../api/wallet-keystore";

type Mode = "vault" | "mnemonic" | "privkey";

export function AuthPanel() {
  const [, force] = useState(0);
  const [mode, setMode] = useState<Mode>(() => (hasVault() ? "vault" : "mnemonic"));
  const [mnemonicInput, setMnemonicInput] = useState("");
  const [pkInput, setPkInput] = useState("");
  const [passphrase, setPassphrase] = useState("");
  const [remember, setRemember] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => subscribeWallet(() => force((n) => n + 1)), []);

  const u = getUnlocked();
  const meta = readVaultMeta();

  const onUnlockMnemonic = async () => {
    setError(null);
    setBusy(true);
    try {
      await unlockFromMnemonic(
        mnemonicInput,
        0,
        remember && passphrase ? passphrase : undefined,
      );
      setMnemonicInput("");
      setPassphrase("");
    } catch (e: any) {
      setError(e?.message || "Invalid mnemonic");
    } finally {
      setBusy(false);
    }
  };

  const onUnlockPriv = async () => {
    setError(null);
    setBusy(true);
    try {
      await unlockFromPrivKey(
        pkInput,
        0,
        remember && passphrase ? passphrase : undefined,
      );
      setPkInput("");
      setPassphrase("");
    } catch (e: any) {
      setError(e?.message || "Invalid private key");
    } finally {
      setBusy(false);
    }
  };

  const onUnlockVault = async () => {
    setError(null);
    setBusy(true);
    try {
      await unlockFromVault(passphrase);
      setPassphrase("");
    } catch (e: any) {
      setError(e?.message || "Wrong passphrase");
    } finally {
      setBusy(false);
    }
  };

  const onForgetVault = () => {
    if (!confirm("Forget the saved wallet on this device? You will need the mnemonic to restore it.")) return;
    clearVault();
    setMode("mnemonic");
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
    <div className="rounded-lg border border-amber-500/30 bg-amber-500/5 p-3 space-y-3">
      <div className="flex items-center justify-between">
        <div className="text-[10px] uppercase tracking-wider text-amber-300/80">
          Connect wallet — sign orders client-side
        </div>
        {meta && (
          <button
            onClick={onForgetVault}
            className="text-[10px] text-mempool-text-dim hover:text-red-300"
            title="Remove the encrypted wallet from this browser"
          >
            Forget device
          </button>
        )}
      </div>

      {/* Mode tabs */}
      <div className="flex gap-1 text-[11px]">
        {meta && (
          <button
            onClick={() => { setMode("vault"); setError(null); }}
            className={`px-2 py-1 rounded ${mode === "vault" ? "bg-mempool-blue text-white" : "bg-mempool-bg-elev text-mempool-text-dim hover:text-mempool-text"}`}
          >
            Saved
          </button>
        )}
        <button
          onClick={() => { setMode("mnemonic"); setError(null); }}
          className={`px-2 py-1 rounded ${mode === "mnemonic" ? "bg-mempool-blue text-white" : "bg-mempool-bg-elev text-mempool-text-dim hover:text-mempool-text"}`}
        >
          Mnemonic
        </button>
        <button
          onClick={() => { setMode("privkey"); setError(null); }}
          className={`px-2 py-1 rounded ${mode === "privkey" ? "bg-mempool-blue text-white" : "bg-mempool-bg-elev text-mempool-text-dim hover:text-mempool-text"}`}
        >
          Private key
        </button>
      </div>

      {mode === "vault" && meta && (
        <div className="space-y-2">
          <div className="text-[10px] text-mempool-text-dim">
            Saved wallet: <span className="font-mono text-mempool-text">{meta.address.slice(0, 14)}…{meta.address.slice(-8)}</span>
          </div>
          <input
            type="password"
            placeholder="Passphrase"
            value={passphrase}
            onChange={(e) => setPassphrase(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter" && passphrase) onUnlockVault(); }}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text text-xs focus:outline-none focus:border-mempool-blue"
            autoFocus
          />
          <button
            onClick={onUnlockVault}
            disabled={busy || !passphrase}
            className="w-full px-3 py-1.5 text-xs rounded bg-mempool-blue hover:bg-blue-600 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
          >
            {busy ? "Unlocking…" : "Unlock"}
          </button>
        </div>
      )}

      {mode === "mnemonic" && (
        <div className="space-y-2">
          <textarea
            placeholder="abandon abandon … about (12 or 24 words)"
            value={mnemonicInput}
            onChange={(e) => setMnemonicInput(e.target.value)}
            rows={2}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text font-mono text-xs focus:outline-none focus:border-mempool-blue resize-none"
            spellCheck={false}
            autoComplete="off"
          />
          <RememberRow remember={remember} setRemember={setRemember} passphrase={passphrase} setPassphrase={setPassphrase} />
          <button
            onClick={onUnlockMnemonic}
            disabled={busy || mnemonicInput.trim().split(/\s+/).length < 12 || (remember && !passphrase)}
            className="w-full px-3 py-1.5 text-xs rounded bg-mempool-blue hover:bg-blue-600 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
          >
            {busy ? "Deriving…" : "Connect"}
          </button>
        </div>
      )}

      {mode === "privkey" && (
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
          <RememberRow remember={remember} setRemember={setRemember} passphrase={passphrase} setPassphrase={setPassphrase} />
          <button
            onClick={onUnlockPriv}
            disabled={busy || pkInput.trim().length === 0 || (remember && !passphrase)}
            className="w-full px-3 py-1.5 text-xs rounded bg-mempool-blue hover:bg-blue-600 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
          >
            {busy ? "Unlocking…" : "Unlock"}
          </button>
        </div>
      )}

      {error && <div className="text-[11px] text-red-300">{error}</div>}

      <div className="text-[10px] text-mempool-text-dim leading-relaxed">
        Keys never leave this browser. Only ECDSA signatures are sent to the node.
      </div>
    </div>
  );
}

function RememberRow({
  remember,
  setRemember,
  passphrase,
  setPassphrase,
}: {
  remember: boolean;
  setRemember: (v: boolean) => void;
  passphrase: string;
  setPassphrase: (v: string) => void;
}) {
  return (
    <div className="space-y-1.5">
      <label className="flex items-center gap-2 text-[11px] text-mempool-text-dim cursor-pointer">
        <input
          type="checkbox"
          checked={remember}
          onChange={(e) => setRemember(e.target.checked)}
          className="accent-mempool-blue"
        />
        <span>Remember on this device (AES-GCM, PBKDF2-200k)</span>
      </label>
      {remember && (
        <input
          type="password"
          placeholder="Passphrase to encrypt the wallet"
          value={passphrase}
          onChange={(e) => setPassphrase(e.target.value)}
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text text-xs focus:outline-none focus:border-mempool-blue"
        />
      )}
    </div>
  );
}
