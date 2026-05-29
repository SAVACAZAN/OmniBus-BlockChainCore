/**
 * WalletGenerator.tsx — embedded "create new wallet" flow inside the Wallet tab.
 *
 * The full multi-step OnboardingPage handles first-visit users. This is the
 * compact, single-card version users can pull up from the Wallet tab to spin
 * up an additional wallet without leaving the page (e.g. they want a hot
 * wallet for trading + a cold wallet for savings, both managed in the same
 * browser).
 *
 * Behaviour:
 *   - Click "Generate" → fresh BIP-39 mnemonic + full derivation pipeline
 *     (OMNI primary + 4 PQ slots + 4 soulbound + 24 multichain).
 *   - User can copy/download the mnemonic / encrypted backup.
 *   - "Use this wallet" → unlocks the global keystore singleton with the
 *     newly generated mnemonic, replacing the current session.
 */

import { useState } from "react";
import {
  generateMnemonic,
  mnemonicToFullWallet,
  encryptWallet,
  downloadBlob,
} from "../../api/wallet/wallet-generator";
import { unlockFromMnemonic, type Unlocked } from "../../api/wallet/wallet-keystore";

export function WalletGenerator({ onUnlocked }: { onUnlocked?: () => void }) {
  const [open, setOpen] = useState(false);
  const [mnemonic, setMnemonic] = useState<string>("");
  const [preview, setPreview] = useState<Unlocked | null>(null);
  const [busy, setBusy] = useState(false);
  const [revealed, setRevealed] = useState(false);
  const [acknowledged, setAcknowledged] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [downloaded, setDownloaded] = useState(false);

  const onGenerate = async () => {
    setError(null);
    setBusy(true);
    try {
      const phrase = generateMnemonic(12);
      const wallet = await mnemonicToFullWallet(phrase, 0);
      setMnemonic(phrase);
      setPreview(wallet);
      setRevealed(false);
      setAcknowledged(false);
      setCopied(false);
      setDownloaded(false);
    } catch (e: any) {
      setError(e?.message || "Generation failed");
    } finally {
      setBusy(false);
    }
  };

  const onCopy = () => {
    navigator.clipboard.writeText(mnemonic);
    setCopied(true);
    setTimeout(() => setCopied(false), 1_500);
  };

  const onDownload = async () => {
    setError(null);
    if (!preview) return;
    const pw = prompt("Password to encrypt the backup file:") || "";
    if (!pw) {
      setError("Password required");
      return;
    }
    try {
      const blob = await encryptWallet(mnemonic, preview.address, pw);
      downloadBlob(`omnibus-wallet-${preview.address.slice(0, 12)}.json`,
        JSON.stringify(blob, null, 2));
      setDownloaded(true);
    } catch (e: any) {
      setError(e?.message || "Backup failed");
    }
  };

  const onUseThis = async () => {
    if (!preview || !acknowledged) return;
    setBusy(true);
    setError(null);
    try {
      await unlockFromMnemonic(mnemonic, 0);
      setOpen(false);
      setMnemonic("");
      setPreview(null);
      onUnlocked?.();
    } catch (e: any) {
      setError(e?.message || "Unlock failed");
    } finally {
      setBusy(false);
    }
  };

  if (!open) {
    return (
      <button
        onClick={() => setOpen(true)}
        className="w-full bg-gradient-to-r from-amber-500/20 to-orange-500/20 hover:from-amber-500/30 hover:to-orange-500/30 border border-amber-500/40 text-amber-300 font-semibold rounded-xl px-4 py-3 text-sm transition-all"
      >
        ✨ Generate new wallet
      </button>
    );
  }

  return (
    <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4 space-y-4">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-bold text-mempool-text">New wallet generator</h3>
        <button
          onClick={() => { setOpen(false); setMnemonic(""); setPreview(null); }}
          className="text-mempool-text-dim hover:text-mempool-text text-xs"
        >
          ✕
        </button>
      </div>

      {!mnemonic && (
        <div className="text-center space-y-3 py-4">
          <p className="text-xs text-mempool-text-dim">
            Click below to generate a fresh BIP-39 wallet. Derivation runs
            entirely in your browser — no network call, no server-side
            secret. Includes OMNI primary + 4 PQ-OMNI slots + 4 soulbound
            domains + 24 multichain addresses.
          </p>
          <button
            onClick={onGenerate}
            disabled={busy}
            className="bg-gradient-to-br from-amber-500 to-orange-600 hover:from-amber-400 hover:to-orange-500 disabled:opacity-50 text-white font-semibold rounded-lg px-6 py-2.5 text-sm transition-all"
          >
            {busy ? "Generating…" : "✨ Generate"}
          </button>
        </div>
      )}

      {mnemonic && preview && (
        <>
          <div>
            <div className="text-[10px] text-mempool-text-dim uppercase tracking-wider mb-1">
              Recovery phrase (12 words)
            </div>
            <div
              className="grid grid-cols-3 gap-1.5 bg-mempool-bg rounded-lg p-2 relative cursor-pointer"
              onClick={() => setRevealed(true)}
            >
              {!revealed && (
                <div className="absolute inset-0 z-10 backdrop-blur-md bg-mempool-bg/60 rounded-lg flex items-center justify-center">
                  <span className="text-xs text-mempool-text font-semibold">Click to reveal</span>
                </div>
              )}
              {mnemonic.split(/\s+/).map((w, i) => (
                <div key={i} className="bg-mempool-bg-elev rounded px-2 py-1 text-xs font-mono text-mempool-text border border-mempool-border">
                  <span className="text-mempool-text-dim text-[10px] mr-1">{i + 1}.</span>{w}
                </div>
              ))}
            </div>
          </div>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-2 text-xs">
            <div className="bg-mempool-bg rounded-lg border border-mempool-border p-2">
              <div className="text-[10px] text-mempool-text-dim uppercase">OMNI primary</div>
              <div className="font-mono text-mempool-blue break-all text-[11px]">{preview.address}</div>
            </div>
            <div className="bg-mempool-bg rounded-lg border border-mempool-border p-2">
              <div className="text-[10px] text-mempool-text-dim uppercase">PQ slots</div>
              <div className="text-mempool-text">{preview.pqOmni?.length ?? 0} derived</div>
            </div>
            <div className="bg-mempool-bg rounded-lg border border-mempool-border p-2">
              <div className="text-[10px] text-mempool-text-dim uppercase">Soulbound</div>
              <div className="text-mempool-text">{preview.soulboundAddresses?.length ?? 0} domains</div>
            </div>
            <div className="bg-mempool-bg rounded-lg border border-mempool-border p-2">
              <div className="text-[10px] text-mempool-text-dim uppercase">Multichain</div>
              <div className="text-mempool-text">{preview.multichainAddresses?.length ?? 0} chains</div>
            </div>
          </div>

          {preview.pqOmni && preview.pqOmni.length > 0 && (
            <details className="text-xs">
              <summary className="text-mempool-text-dim cursor-pointer hover:text-mempool-text">
                Show all {preview.pqOmni.length} PQ addresses
              </summary>
              <div className="mt-2 space-y-1">
                {preview.pqOmni.map((s) => (
                  <div key={s.scheme} className="flex justify-between gap-2 bg-mempool-bg rounded px-2 py-1">
                    <span className="text-mempool-text-dim">{s.scheme}</span>
                    <span className="font-mono text-mempool-blue text-[10px] break-all text-right">{s.address}</span>
                  </div>
                ))}
              </div>
            </details>
          )}

          <div className="bg-amber-500/10 border border-amber-500/40 rounded-lg p-2 text-[11px] text-amber-300">
            ⚠ Save the phrase before continuing. Lost = lost funds forever.
          </div>

          <div className="flex flex-wrap gap-2">
            <button
              onClick={onCopy}
              className="text-xs px-3 py-1.5 bg-mempool-bg border border-mempool-border hover:border-mempool-blue rounded text-mempool-text-dim hover:text-mempool-text"
            >
              {copied ? "✓ Copied" : "Copy phrase"}
            </button>
            <button
              onClick={onDownload}
              className="text-xs px-3 py-1.5 bg-mempool-bg border border-mempool-border hover:border-mempool-blue rounded text-mempool-text-dim hover:text-mempool-text"
            >
              {downloaded ? "✓ Downloaded" : "Download backup"}
            </button>
            <button
              onClick={onGenerate}
              className="text-xs px-3 py-1.5 bg-mempool-bg border border-mempool-border hover:border-mempool-orange rounded text-mempool-text-dim hover:text-mempool-orange"
            >
              ↻ Regenerate
            </button>
          </div>

          <label className="flex items-start gap-2 text-xs text-mempool-text-dim cursor-pointer">
            <input
              type="checkbox"
              checked={acknowledged}
              onChange={(e) => setAcknowledged(e.target.checked)}
              className="mt-0.5"
            />
            I have saved my recovery phrase securely.
          </label>

          {error && (
            <div className="text-xs text-red-400 bg-red-500/10 border border-red-500/30 rounded px-3 py-2">
              {error}
            </div>
          )}

          <button
            onClick={onUseThis}
            disabled={!acknowledged || busy}
            className="w-full bg-mempool-blue hover:bg-mempool-blue/80 disabled:bg-mempool-bg-light disabled:text-mempool-text-dim text-white font-semibold rounded-lg px-4 py-2 text-sm transition-colors"
          >
            {busy ? "Connecting…" : "Use this wallet"}
          </button>
        </>
      )}
    </div>
  );
}
