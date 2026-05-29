/**
 * WalletConnectButton.tsx — global wallet connect / disconnect button.
 *
 * Lives in the Header so it's visible from every tab. When connected,
 * shows the truncated `ob1q…` address with a disconnect option. When
 * disconnected, opens a modal that mirrors the existing Exchange
 * AuthPanel flow (vault / mnemonic / privkey) but compact.
 *
 * Backed by the same `wallet-keystore` singleton every other panel uses,
 * so the moment you connect here, ApiKeysPanel / NamesPage / FaucetPage
 * etc. all see the wallet without prop-drilling. Disconnect from here
 * propagates to every subscriber via `lockWallet()`.
 */

import { useEffect, useState } from "react";
import { midTrunc } from "../../utils/fmt";
import { useWallet } from "../../api/hooks/use-wallet";
import { useNameForAddress, useEntryForAddress, useExpiringNames, TLD_THEME } from "../../api/hooks/use-names";

// Inline SVG icons (lucide-react isn't installed in this frontend; matches the
// inline-SVG style used everywhere else in Header.tsx).
const IconWallet = ({ className = "w-4 h-4" }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M21 12V7H5a2 2 0 0 1 0-4h14v4" />
    <path d="M3 5v14a2 2 0 0 0 2 2h16v-5" />
    <path d="M18 12a2 2 0 0 0 0 4h4v-4Z" />
  </svg>
);
const IconX = ({ className = "w-4 h-4" }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M18 6 6 18" />
    <path d="m6 6 12 12" />
  </svg>
);
const IconEye = ({ className = "w-3.5 h-3.5" }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z" />
    <circle cx="12" cy="12" r="3" />
  </svg>
);
const IconEyeOff = ({ className = "w-3.5 h-3.5" }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M9.88 9.88a3 3 0 1 0 4.24 4.24" />
    <path d="M10.73 5.08A10.43 10.43 0 0 1 12 5c7 0 10 7 10 7a13.16 13.16 0 0 1-1.67 2.68" />
    <path d="M6.61 6.61A13.526 13.526 0 0 0 2 12s3 7 10 7a9.74 9.74 0 0 0 5.39-1.61" />
    <line x1="2" x2="22" y1="2" y2="22" />
  </svg>
);
const IconLogOut = ({ className = "w-3.5 h-3.5" }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
    <polyline points="16 17 21 12 16 7" />
    <line x1="21" x2="9" y1="12" y2="12" />
  </svg>
);
import {
  clearVault,
  hasVault,
  lockWallet,
  readVaultMeta,
  unlockFromMnemonic,
  unlockFromPrivKey,
  unlockFromVault,
} from "../../api/wallet/wallet-keystore";

type Mode = "vault" | "mnemonic" | "privkey";

export function WalletConnectButton() {
  const wallet = useWallet();
  const primaryName = useNameForAddress(wallet?.address);
  const entry = useEntryForAddress(wallet?.address);  // Phase 2: full entry for category
  // Phase 2 lifecycle — warn if any of the wallet's names is in / approaching grace.
  const expiring = useExpiringNames(wallet?.address);
  const [showModal, setShowModal] = useState(false);
  const [showDropdown, setShowDropdown] = useState(false);

  // Connected: pill with name + Phase 2 category badge (if registered) or truncated address.
  if (wallet) {
    const tld = entry?.tld;
    const theme = tld ? TLD_THEME[tld] : undefined;
    const cat = entry?.category && entry.category !== "none" ? entry.category : null;
    const expiringCount = expiring.length;
    const expiringTitle = expiringCount > 0
      ? `${expiringCount} name${expiringCount === 1 ? "" : "s"} expiring soon — click to renew`
      : "";
    return (
      <div className="relative">
        <button
          onClick={() => {
            // Click jumps to NamesPage when there's something to renew —
            // otherwise toggles the existing wallet dropdown.
            if (expiringCount > 0) {
              window.location.hash = "#names";
            } else {
              setShowDropdown((v) => !v);
            }
          }}
          className="flex items-center gap-2 bg-mempool-blue/15 border border-mempool-blue/40 rounded-lg px-3 py-1.5 hover:bg-mempool-blue/25 transition-colors"
          title={
            expiringTitle ||
            (primaryName ? `${primaryName} → ${wallet.address}${cat ? ` [${cat}]` : ""}` : wallet.address)
          }
        >
          <span className="w-2 h-2 rounded-full bg-green-400 animate-pulse" />
          <span className={`text-xs ${theme?.color ?? "text-mempool-blue"} ${primaryName ? "font-semibold" : "font-mono"}`}>
            {theme?.emoji && <span className="mr-1">{theme.emoji}</span>}
            {primaryName ?? `${midTrunc(wallet.address, 8, 6)}`}
          </span>
          {cat && (
            <span className="text-[9px] uppercase tracking-wider px-1 rounded bg-mempool-blue/30 text-mempool-blue font-bold">
              {cat}
            </span>
          )}
          {expiringCount > 0 && (
            <span
              className="text-[9px] uppercase tracking-wider px-1 rounded bg-amber-500/30 text-amber-300 font-bold"
              title={expiringTitle}
            >
              ⚠ {expiringCount} expiring
            </span>
          )}
        </button>
        {showDropdown && (
          <>
            <div
              className="fixed inset-0 z-40"
              onClick={() => setShowDropdown(false)}
            />
            <div className="absolute right-0 mt-2 w-72 bg-mempool-bg-elev border border-mempool-border rounded-lg shadow-xl z-50 p-3 space-y-2">
              <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
                Connected wallet
              </div>
              {primaryName && (
                <div className={`text-sm font-semibold ${theme?.color ?? "text-mempool-blue"} flex items-center gap-1`}>
                  {theme?.emoji && <span>{theme.emoji}</span>}
                  <span>{primaryName}</span>
                  {cat && (
                    <span className="text-[9px] uppercase tracking-wider px-1 rounded bg-mempool-blue/30 text-mempool-blue font-bold">
                      {cat}
                    </span>
                  )}
                </div>
              )}
              <div className="font-mono text-xs text-mempool-text break-all bg-mempool-bg rounded p-2">
                {wallet.address}
              </div>
              <div className="grid grid-cols-2 gap-1">
                <button
                  onClick={() => { navigator.clipboard.writeText(wallet.address); setShowDropdown(false); }}
                  className="text-xs text-mempool-text-dim hover:text-mempool-blue hover:bg-mempool-blue/10 rounded px-2 py-1.5 flex items-center gap-1.5"
                >
                  <svg className="w-3 h-3" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <rect x="9" y="9" width="13" height="13" rx="2" />
                    <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
                  </svg>
                  Copy address
                </button>
                <button
                  onClick={() => {
                    window.location.hash = `#/address/${wallet.address}`;
                    setShowDropdown(false);
                  }}
                  className="text-xs text-mempool-text-dim hover:text-mempool-blue hover:bg-mempool-blue/10 rounded px-2 py-1.5 flex items-center gap-1.5"
                >
                  <svg className="w-3 h-3" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <circle cx="11" cy="11" r="8" /><path d="M21 21l-4.35-4.35" />
                  </svg>
                  Explorer
                </button>
                <button
                  onClick={() => { window.location.hash = "#wallet"; setShowDropdown(false); }}
                  className="text-xs text-mempool-text-dim hover:text-mempool-blue hover:bg-mempool-blue/10 rounded px-2 py-1.5 flex items-center gap-1.5"
                >
                  <svg className="w-3 h-3" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <path d="M21 12V7H5a2 2 0 0 1 0-4h14v4" /><path d="M3 5v14a2 2 0 0 0 2 2h16v-5" /><path d="M18 12a2 2 0 0 0 0 4h4v-4Z" />
                  </svg>
                  Wallet
                </button>
                <button
                  onClick={() => { window.location.hash = "#names"; setShowDropdown(false); }}
                  className="text-xs text-mempool-text-dim hover:text-mempool-blue hover:bg-mempool-blue/10 rounded px-2 py-1.5 flex items-center gap-1.5"
                >
                  <svg className="w-3 h-3" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <path d="M3 12h18M3 6h18M3 18h18" />
                  </svg>
                  Names
                </button>
              </div>
              <div className="border-t border-mempool-border pt-1">
                <button
                  onClick={() => {
                    lockWallet();
                    setShowDropdown(false);
                  }}
                  className="w-full flex items-center gap-2 text-xs text-red-400 hover:text-red-300 hover:bg-red-500/10 rounded px-2 py-1.5"
                >
                  <IconLogOut className="w-3.5 h-3.5" />
                  Disconnect
                </button>
              </div>
            </div>
          </>
        )}
      </div>
    );
  }

  // Disconnected: connect button + modal.
  return (
    <>
      <button
        onClick={() => setShowModal(true)}
        className="flex items-center gap-2 bg-mempool-blue/20 border border-mempool-blue/50 hover:bg-mempool-blue/30 rounded-lg px-3 py-1.5 text-xs font-semibold text-mempool-blue transition-colors"
      >
        <IconWallet className="w-3.5 h-3.5" />
        Connect Wallet
      </button>
      {showModal && <ConnectModal onClose={() => setShowModal(false)} />}
    </>
  );
}

function ConnectModal({ onClose }: { onClose: () => void }) {
  const [mode, setMode] = useState<Mode>(() => (hasVault() ? "vault" : "mnemonic"));
  const [mnemonicInput, setMnemonicInput] = useState("");
  const [pkInput, setPkInput] = useState("");
  const [bip39Pass, setBip39Pass] = useState("");
  const [vaultPin, setVaultPin] = useState("");
  const [remember, setRemember] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showSecret, setShowSecret] = useState(false);
  const meta = readVaultMeta();

  // Close on Escape.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const onSubmit = async () => {
    setError(null);
    setBusy(true);
    try {
      if (mode === "vault") {
        if (!vaultPin) throw new Error("PIN required");
        await unlockFromVault(vaultPin);
      } else if (mode === "mnemonic") {
        if (!mnemonicInput.trim()) throw new Error("Mnemonic required");
        await unlockFromMnemonic(
          mnemonicInput,
          0,
          remember && vaultPin ? vaultPin : undefined,
          bip39Pass || "",
        );
      } else {
        if (!pkInput.trim()) throw new Error("Private key required");
        await unlockFromPrivKey(
          pkInput,
          0,
          remember && vaultPin ? vaultPin : undefined,
        );
      }
      onClose();
    } catch (e: any) {
      setError(e?.message || "Unlock failed");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/60 backdrop-blur-sm p-4">
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl shadow-2xl max-w-md w-full p-5 space-y-4">
        <div className="flex items-center justify-between">
          <h2 className="text-base font-bold text-mempool-text flex items-center gap-2">
            <IconWallet className="w-4 h-4 text-mempool-blue" />
            Connect wallet
          </h2>
          <button
            onClick={onClose}
            className="text-mempool-text-dim hover:text-mempool-text"
          >
            <IconX className="w-4 h-4" />
          </button>
        </div>

        <p className="text-[11px] text-mempool-text-dim">
          Keys never leave this browser. Signing happens client-side
          (secp256k1 ECDSA). Connection persists across tabs in this session.
        </p>

        {/* Mode tabs */}
        <div className="flex gap-1 p-1 bg-mempool-bg rounded-lg">
          {hasVault() && (
            <ModeTab
              active={mode === "vault"}
              onClick={() => setMode("vault")}
              label="Saved"
            />
          )}
          <ModeTab
            active={mode === "mnemonic"}
            onClick={() => setMode("mnemonic")}
            label="Mnemonic"
          />
          <ModeTab
            active={mode === "privkey"}
            onClick={() => setMode("privkey")}
            label="Private key"
          />
        </div>

        {mode === "vault" && (
          <div className="space-y-2">
            <div className="text-[10px] text-mempool-text-dim">
              Saved wallet:{" "}
              <span className="font-mono text-mempool-blue">
                {midTrunc(meta?.address ?? "", 12, 8)}
              </span>
            </div>
            <input
              type="password"
              placeholder="PIN (the one you set when saving)"
              value={vaultPin}
              onChange={(e) => setVaultPin(e.target.value)}
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-sm text-mempool-text"
              autoFocus
              onKeyDown={(e) => { if (e.key === "Enter") onSubmit(); }}
            />
            <button
              onClick={() => { clearVault(); setMode("mnemonic"); }}
              className="text-[10px] text-mempool-text-dim hover:text-red-400"
            >
              Forget device
            </button>
          </div>
        )}

        {mode === "mnemonic" && (
          <div className="space-y-2">
            <div className="relative">
              <textarea
                placeholder="Enter your 12 / 24 word recovery phrase, space-separated"
                value={mnemonicInput}
                onChange={(e) => setMnemonicInput(e.target.value)}
                rows={3}
                className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text resize-none"
                style={{ filter: showSecret ? undefined : "blur(4px)" }}
                autoFocus
              />
              <button
                type="button"
                onClick={() => setShowSecret((v) => !v)}
                className="absolute top-2 right-2 text-mempool-text-dim hover:text-mempool-text"
              >
                {showSecret ? <IconEyeOff className="w-3.5 h-3.5" /> : <IconEye className="w-3.5 h-3.5" />}
              </button>
            </div>
            <input
              type="password"
              placeholder="BIP-39 passphrase (optional, 25th word)"
              value={bip39Pass}
              onChange={(e) => setBip39Pass(e.target.value)}
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs text-mempool-text"
            />
          </div>
        )}

        {mode === "privkey" && (
          <div className="relative">
            <input
              type={showSecret ? "text" : "password"}
              placeholder="Private key hex (64 chars, with or without 0x)"
              value={pkInput}
              onChange={(e) => setPkInput(e.target.value)}
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text"
              autoFocus
              onKeyDown={(e) => { if (e.key === "Enter") onSubmit(); }}
            />
            <button
              type="button"
              onClick={() => setShowSecret((v) => !v)}
              className="absolute top-2 right-2 text-mempool-text-dim hover:text-mempool-text"
            >
              {showSecret ? <IconEyeOff className="w-3.5 h-3.5" /> : <IconEye className="w-3.5 h-3.5" />}
            </button>
          </div>
        )}

        {/* Save with PIN */}
        {mode !== "vault" && (
          <div className="flex items-center gap-2 text-[11px] text-mempool-text-dim">
            <input
              id="remember-pin"
              type="checkbox"
              checked={remember}
              onChange={(e) => setRemember(e.target.checked)}
            />
            <label htmlFor="remember-pin" className="cursor-pointer">
              Save in browser with PIN (survives restart)
            </label>
            {remember && (
              <input
                type="password"
                placeholder="set PIN"
                value={vaultPin}
                onChange={(e) => setVaultPin(e.target.value)}
                className="ml-auto bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs w-24"
              />
            )}
          </div>
        )}

        {error && (
          <div className="text-xs text-red-400 bg-red-500/10 border border-red-500/30 rounded px-3 py-2">
            {error}
          </div>
        )}

        <button
          onClick={onSubmit}
          disabled={busy}
          className="w-full bg-mempool-blue hover:bg-mempool-blue/80 disabled:bg-gray-700 disabled:text-gray-500 text-white font-semibold rounded py-2 text-sm transition-colors"
        >
          {busy ? "Unlocking…" : "Connect"}
        </button>
      </div>
    </div>
  );
}

function ModeTab({
  active,
  onClick,
  label,
}: {
  active: boolean;
  onClick: () => void;
  label: string;
}) {
  return (
    <button
      onClick={onClick}
      className={`flex-1 px-3 py-1.5 text-xs rounded transition-colors ${
        active
          ? "bg-mempool-blue text-white font-semibold"
          : "text-mempool-text-dim hover:text-mempool-text"
      }`}
    >
      {label}
    </button>
  );
}
