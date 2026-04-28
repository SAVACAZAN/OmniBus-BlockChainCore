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
  // BIP-39 §8 "25th word" — mixed into seed; same mnemonic + different
  // passphrase = different wallet. Hardware wallets call this "passphrase"
  // or "hidden wallet". OPTIONAL.
  const [bip39Pass, setBip39Pass] = useState("");
  // Local PIN — encrypts the derived privkey under AES-GCM and stores it
  // in localStorage so the next visit only asks for the PIN, no need to
  // re-paste the 12 words. Doesn't change the wallet identity. OPTIONAL.
  const [vaultPin, setVaultPin] = useState("");
  // Default OFF — within a single browser tab you stay connected via
  // sessionStorage automatically; the "save with PIN" checkbox is only
  // for surviving across browser restarts.
  const [remember, setRemember] = useState(false);
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
        remember && vaultPin ? vaultPin : undefined,
        bip39Pass || "",
      );
      setMnemonicInput("");
      setBip39Pass("");
      setVaultPin("");
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
        remember && vaultPin ? vaultPin : undefined,
      );
      setPkInput("");
      setVaultPin("");
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
      await unlockFromVault(vaultPin);
      setVaultPin("");
    } catch (e: any) {
      setError(e?.message || "Wrong PIN");
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
          <div className="text-[10px] uppercase tracking-wider text-green-300/80 flex items-center gap-2">
            <span>Wallet connected</span>
            <span className="text-green-300/60 normal-case tracking-normal text-[10px]">
              · stays connected while you navigate (this tab)
            </span>
          </div>
          <div className="font-mono text-xs text-mempool-text truncate" title={u.address}>
            {u.address}
          </div>
        </div>
        <button
          onClick={lockWallet}
          className="px-3 py-1.5 text-xs rounded bg-mempool-bg-elev hover:bg-red-500/20 text-mempool-text-dim hover:text-red-300 transition-colors"
          title="Disconnect this wallet from the browser tab"
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
            placeholder="PIN (the one you set when saving)"
            value={vaultPin}
            onChange={(e) => setVaultPin(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter" && vaultPin) onUnlockVault(); }}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text text-xs focus:outline-none focus:border-mempool-blue"
            autoFocus
          />
          <button
            onClick={onUnlockVault}
            disabled={busy || !vaultPin}
            className="w-full px-3 py-1.5 text-xs rounded bg-mempool-blue hover:bg-blue-600 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
          >
            {busy ? "Unlocking…" : "Unlock"}
          </button>
        </div>
      )}

      {mode === "mnemonic" && (
        <div className="space-y-2">
          <div>
            <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim block mb-1">
              Mnemonic (12 or 24 words)
            </label>
            <textarea
              placeholder="abandon abandon … about"
              value={mnemonicInput}
              onChange={(e) => setMnemonicInput(e.target.value)}
              rows={2}
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text font-mono text-xs focus:outline-none focus:border-mempool-blue resize-none"
              spellCheck={false}
              autoComplete="off"
            />
          </div>

          {/* BIP-39 §8 passphrase — the "25th word" / "hidden wallet" */}
          <div>
            <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim block mb-1">
              BIP-39 passphrase <span className="text-mempool-text-dim/60">— optional 13th/25th word</span>
            </label>
            <input
              type="password"
              placeholder="leave empty for standard wallet"
              value={bip39Pass}
              onChange={(e) => setBip39Pass(e.target.value)}
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text font-mono text-xs focus:outline-none focus:border-mempool-blue"
              spellCheck={false}
              autoComplete="off"
            />
            <p className="text-[10px] text-mempool-text-dim mt-1 leading-snug">
              Same 12 words + different BIP-39 passphrase = different wallet
              and different ob1q… address. Hardware wallets call this
              "passphrase" or "hidden wallet". <strong>Lose it = lose the wallet.</strong>
              Empty for the standard derivation.
            </p>
          </div>

          <PinRow remember={remember} setRemember={setRemember} pin={vaultPin} setPin={setVaultPin} />
          <button
            onClick={onUnlockMnemonic}
            disabled={busy || mnemonicInput.trim().split(/\s+/).length < 12 || (remember && vaultPin.length < 4)}
            className="w-full px-3 py-1.5 text-xs rounded bg-mempool-blue hover:bg-blue-600 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
          >
            {busy ? "Deriving…" : "Connect"}
          </button>
        </div>
      )}

      {mode === "privkey" && (
        <div className="space-y-2">
          <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim block mb-1">
            Private key (32 bytes hex)
          </label>
          <input
            type="password"
            placeholder="64 hex chars (no 0x)"
            value={pkInput}
            onChange={(e) => setPkInput(e.target.value)}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text font-mono text-xs focus:outline-none focus:border-mempool-blue"
            spellCheck={false}
            autoComplete="off"
          />
          <PinRow remember={remember} setRemember={setRemember} pin={vaultPin} setPin={setVaultPin} />
          <button
            onClick={onUnlockPriv}
            disabled={busy || pkInput.trim().length === 0 || (remember && vaultPin.length < 4)}
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

function PinRow({
  remember,
  setRemember,
  pin,
  setPin,
}: {
  remember: boolean;
  setRemember: (v: boolean) => void;
  pin: string;
  setPin: (v: string) => void;
}) {
  return (
    <div className="space-y-1.5 rounded border border-mempool-border/60 bg-mempool-bg/40 p-2">
      <label className="flex items-start gap-2 text-[11px] text-mempool-text cursor-pointer">
        <input
          type="checkbox"
          checked={remember}
          onChange={(e) => setRemember(e.target.checked)}
          className="accent-mempool-blue mt-0.5"
        />
        <span className="leading-snug">
          <span className="font-semibold">OPTIONAL</span> — save the wallet on this device under a
          local PIN, so next visit I just type the PIN (no need to paste 12 words
          again). The PIN is local-only — it does not change which wallet you
          unlock. AES-GCM, PBKDF2-SHA256, 200k iters.
        </span>
      </label>
      {remember && (
        <input
          type="password"
          placeholder="Set a local PIN (min 4 chars)"
          value={pin}
          onChange={(e) => setPin(e.target.value)}
          minLength={4}
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text text-xs focus:outline-none focus:border-mempool-blue"
        />
      )}
      <p className="text-[10px] text-mempool-text-dim leading-relaxed pl-6">
        💡 Within this browser tab you stay connected automatically while
        navigating between tabs (Wallet ↔ Exchange ↔ Blocks). The PIN is only
        for surviving a full browser restart.
      </p>
    </div>
  );
}
