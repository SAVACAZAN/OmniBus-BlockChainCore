/**
 * OnboardingPage.tsx — multi-step "first-time user" wizard.
 *
 * Goal: anyone landing on the site can spin up a fresh OmniBus wallet AND
 * start trading without any external tool — full parity with the CLI flow.
 *
 * Steps:
 *   1) Welcome              → "Create new" | "Import existing"
 *   2a) Create / display 12 words + confirmation re-type
 *   2b) Import + address preview
 *   3) Encrypt with password (optional skip)
 *   4) Backup options (download JSON / print PDF / hardware placeholder)
 *   5) Done
 *
 * The wizard itself never persists anything until step 3 (or the explicit
 * "skip" path on the same step). Until then, everything is held in this
 * component's state — closing the tab discards the in-progress mnemonic.
 */

import { useEffect, useMemo, useState } from "react";
import {
  generateMnemonic,
  validateMnemonic,
  mnemonicToAddress,
  encryptWallet,
  downloadBlob,
  pickConfirmationIndices,
  passwordStrength,
} from "../../api/wallet-generator";
import { unlockFromMnemonic } from "../../api/wallet-keystore";
import { useBlockchain } from "../../stores/useBlockchainStore";
import { initProfileForAddress } from "../../api/profile-init";

type StepId =
  | "welcome"
  | "create-display"
  | "create-confirm"
  | "import"
  | "password"
  | "backup"
  | "done";

export type OnboardingPageProps = {
  /** Called when the user completes (or skips) onboarding so the parent can
   *  flip back to a normal tab. The wallet is already unlocked at that point
   *  via the global keystore singleton. */
  onComplete?: () => void;
};

export function OnboardingPage({ onComplete }: OnboardingPageProps) {
  const [step, setStep] = useState<StepId>("welcome");
  const [mode, setMode] = useState<"create" | "import" | null>(null);
  const [mnemonic, setMnemonic] = useState<string>("");
  const [confirmedAddress, setConfirmedAddress] = useState<string>("");
  const [password, setPassword] = useState<string>("");
  const [error, setError] = useState<string | null>(null);

  // Reset error whenever step changes — a stale "wrong password" shouldn't
  // hang around when the user moves on.
  useEffect(() => { setError(null); }, [step]);

  return (
    <div className="min-h-[calc(100vh-220px)] flex items-center justify-center px-3 py-6">
      <div className="w-full max-w-2xl bg-mempool-bg-elev border border-mempool-border rounded-2xl shadow-2xl p-5 sm:p-8 space-y-6">
        <ProgressBar step={step} />

        {step === "welcome" && (
          <WelcomeStep
            onCreate={() => { setMode("create"); setMnemonic(generateMnemonic(12)); setStep("create-display"); }}
            onImport={() => { setMode("import"); setStep("import"); }}
          />
        )}

        {step === "create-display" && (
          <CreateDisplayStep
            mnemonic={mnemonic}
            onBack={() => setStep("welcome")}
            onContinue={() => setStep("create-confirm")}
            onRegenerate={() => setMnemonic(generateMnemonic(12))}
          />
        )}

        {step === "create-confirm" && (
          <CreateConfirmStep
            mnemonic={mnemonic}
            onBack={() => setStep("create-display")}
            onConfirmed={(addr) => {
              setConfirmedAddress(addr);
              setStep("password");
            }}
          />
        )}

        {step === "import" && (
          <ImportStep
            onBack={() => setStep("welcome")}
            onConfirmed={(phrase, addr) => {
              setMnemonic(phrase);
              setConfirmedAddress(addr);
              setStep("password");
            }}
          />
        )}

        {step === "password" && (
          <PasswordStep
            mnemonic={mnemonic}
            address={confirmedAddress}
            onSkip={async () => {
              try {
                const u = await unlockFromMnemonic(mnemonic, 0);
                // Fire-and-forget: create OmniBus ID on chain. Failure does
                // not block onboarding — user can retry on profile tab.
                void initProfileForAddress(u.address);
                setStep("backup");
              } catch (e: any) {
                setError(e?.message || "Unlock failed");
              }
            }}
            onSet={async (pw) => {
              try {
                const u = await unlockFromMnemonic(mnemonic, 0, pw);
                void initProfileForAddress(u.address);
                setPassword(pw);
                setStep("backup");
              } catch (e: any) {
                setError(e?.message || "Unlock failed");
              }
            }}
            onBack={() => setStep(mode === "create" ? "create-confirm" : "import")}
          />
        )}

        {step === "backup" && (
          <BackupStep
            mnemonic={mnemonic}
            address={confirmedAddress}
            password={password}
            onContinue={() => setStep("done")}
          />
        )}

        {step === "done" && (
          <DoneStep
            address={confirmedAddress}
            onFinish={() => onComplete?.()}
          />
        )}

        {error && (
          <div className="text-xs text-red-400 bg-red-500/10 border border-red-500/30 rounded px-3 py-2">
            {error}
          </div>
        )}
      </div>
    </div>
  );
}

// ── Progress indicator ──────────────────────────────────────────────────

const PROGRESS_ORDER: StepId[] = ["welcome", "create-display", "password", "backup", "done"];

function ProgressBar({ step }: { step: StepId }) {
  // For the import path, treat "import"/"create-confirm" as create-display.
  const order = PROGRESS_ORDER;
  // For the import path, treat "import" as create-display.
  const flat: StepId = step === "import" || step === "create-confirm" ? "create-display" : step;
  const idx = order.indexOf(flat);
  return (
    <div className="flex items-center gap-2">
      {order.map((s, i) => (
        <div key={s} className="flex-1">
          <div
            className={`h-1.5 rounded-full transition-colors ${
              i <= idx ? "bg-mempool-blue" : "bg-mempool-border"
            }`}
          />
        </div>
      ))}
    </div>
  );
}

// ── Step 1: Welcome ─────────────────────────────────────────────────────

function WelcomeStep({ onCreate, onImport }: { onCreate: () => void; onImport: () => void }) {
  const { state } = useBlockchain();
  return (
    <div className="space-y-6">
      <div className="text-center space-y-2">
        <div className="inline-flex items-center justify-center w-16 h-16 rounded-2xl bg-gradient-to-br from-amber-400 to-orange-600 text-white text-3xl font-bold shadow-lg">
          OB
        </div>
        <h1 className="text-2xl sm:text-3xl font-bold bg-gradient-to-b from-amber-300 to-orange-500 bg-clip-text text-transparent">
          Welcome to OmniBus
        </h1>
        <p className="text-sm text-mempool-text-dim">
          Quantum-secure blockchain. Create a wallet in 60 seconds — no
          email, no KYC, keys stay in your browser.
        </p>
      </div>

      <div className="grid grid-cols-3 gap-3">
        <Stat label="Block Height" value={state.blockCount.toLocaleString()} />
        <Stat label="Miners" value={state.miners.length.toString()} />
        <Stat label="Peers" value={state.peers.length.toString()} />
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <button
          onClick={onCreate}
          className="bg-gradient-to-br from-amber-500 to-orange-600 hover:from-amber-400 hover:to-orange-500 text-white font-semibold rounded-xl py-4 px-4 transition-all shadow-lg hover:shadow-xl"
        >
          <div className="text-base">Create new wallet</div>
          <div className="text-[11px] opacity-80 font-normal mt-0.5">
            Generate fresh 12-word phrase
          </div>
        </button>
        <button
          onClick={onImport}
          className="bg-mempool-bg border border-mempool-border hover:border-mempool-blue text-mempool-text font-semibold rounded-xl py-4 px-4 transition-colors"
        >
          <div className="text-base">Import existing</div>
          <div className="text-[11px] text-mempool-text-dim font-normal mt-0.5">
            Restore from 12 / 24 words
          </div>
        </button>
      </div>

      <p className="text-[10px] text-mempool-text-dim text-center">
        By continuing you accept that lost mnemonic = lost funds. There is no
        password reset. There is no support that can recover your wallet.
      </p>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="bg-mempool-bg rounded-lg border border-mempool-border p-3 text-center">
      <div className="text-[9px] text-mempool-text-dim uppercase tracking-wider">{label}</div>
      <div className="text-base font-mono font-semibold text-mempool-text mt-0.5">{value}</div>
    </div>
  );
}

// ── Step 2A: Create — display words ─────────────────────────────────────

function CreateDisplayStep({
  mnemonic,
  onBack,
  onContinue,
  onRegenerate,
}: {
  mnemonic: string;
  onBack: () => void;
  onContinue: () => void;
  onRegenerate: () => void;
}) {
  const [acknowledged, setAcknowledged] = useState(false);
  const [revealed, setRevealed] = useState(false);
  const [copied, setCopied] = useState(false);
  const words = useMemo(() => mnemonic.split(/\s+/), [mnemonic]);

  const onCopy = () => {
    navigator.clipboard.writeText(mnemonic);
    setCopied(true);
    setTimeout(() => setCopied(false), 1_500);
  };

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-lg font-bold text-mempool-text">Your recovery phrase</h2>
        <p className="text-xs text-mempool-text-dim mt-0.5">
          Write these 12 words down on paper, in order. Anyone with this phrase
          can spend your OMNI.
        </p>
      </div>

      <div className="bg-amber-500/10 border border-amber-500/40 rounded-lg p-3 text-xs text-amber-300">
        ⚠ Save this phrase securely. <strong>Lost = lost funds forever.</strong>
        {" "}OmniBus has no recovery, no password reset, no support.
      </div>

      <div
        className="grid grid-cols-2 sm:grid-cols-3 gap-2 bg-mempool-bg rounded-xl p-3 sm:p-4 relative cursor-pointer"
        onClick={() => setRevealed(true)}
        title={revealed ? "Click outside to keep visible" : "Click to reveal"}
      >
        {!revealed && (
          <div className="absolute inset-0 z-10 backdrop-blur-md bg-mempool-bg/40 rounded-xl flex flex-col items-center justify-center gap-1">
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="text-mempool-text">
              <path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z" />
              <circle cx="12" cy="12" r="3" />
            </svg>
            <span className="text-xs text-mempool-text font-semibold">Click to reveal</span>
          </div>
        )}
        {words.map((w, i) => (
          <div
            key={i}
            className="flex items-center gap-2 bg-mempool-bg-elev rounded px-2 py-2 border border-mempool-border"
          >
            <span className="text-[10px] text-mempool-text-dim w-5 text-right">{i + 1}.</span>
            <span className="font-mono text-sm text-mempool-text">{w}</span>
          </div>
        ))}
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <button
          onClick={onCopy}
          className="text-xs px-3 py-1.5 bg-mempool-bg border border-mempool-border hover:border-mempool-blue rounded text-mempool-text-dim hover:text-mempool-text"
        >
          {copied ? "✓ Copied" : "Copy phrase"}
        </button>
        <button
          onClick={() => { onRegenerate(); setRevealed(false); }}
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
        I have written down or copied my recovery phrase to a safe location.
      </label>

      <div className="flex gap-2 justify-between">
        <button
          onClick={onBack}
          className="text-xs px-4 py-2 text-mempool-text-dim hover:text-mempool-text"
        >
          ← Back
        </button>
        <button
          onClick={onContinue}
          disabled={!acknowledged}
          className="bg-mempool-blue hover:bg-mempool-blue/80 disabled:bg-mempool-bg-light disabled:text-mempool-text-dim text-white font-semibold rounded-lg px-6 py-2 text-sm transition-colors"
        >
          Continue
        </button>
      </div>
    </div>
  );
}

// ── Step 2A.b: Confirm random words ─────────────────────────────────────

function CreateConfirmStep({
  mnemonic,
  onBack,
  onConfirmed,
}: {
  mnemonic: string;
  onBack: () => void;
  onConfirmed: (address: string) => void;
}) {
  const words = useMemo(() => mnemonic.split(/\s+/), [mnemonic]);
  const indices = useMemo(() => pickConfirmationIndices(words.length, 3), [mnemonic]);
  const [inputs, setInputs] = useState<string[]>(() => indices.map(() => ""));
  const [submitting, setSubmitting] = useState(false);

  const allMatch = inputs.every((v, i) => v.trim().toLowerCase() === words[indices[i]]);

  const onSubmit = async () => {
    if (!allMatch) return;
    setSubmitting(true);
    try {
      const addr = mnemonicToAddress(mnemonic, 0);
      onConfirmed(addr);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-lg font-bold text-mempool-text">Confirm your phrase</h2>
        <p className="text-xs text-mempool-text-dim mt-0.5">
          Re-type the following 3 words from your recovery phrase to prove
          you've saved it.
        </p>
      </div>

      <div className="space-y-3">
        {indices.map((wordIdx, i) => (
          <div key={wordIdx}>
            <label className="text-[10px] text-mempool-text-dim uppercase tracking-wider">
              Word #{wordIdx + 1}
            </label>
            <input
              type="text"
              autoComplete="off"
              autoCapitalize="off"
              spellCheck={false}
              value={inputs[i]}
              onChange={(e) => {
                const next = inputs.slice();
                next[i] = e.target.value;
                setInputs(next);
              }}
              className={`w-full bg-mempool-bg border rounded-lg px-3 py-2 text-sm font-mono mt-1 ${
                inputs[i] === ""
                  ? "border-mempool-border"
                  : inputs[i].trim().toLowerCase() === words[wordIdx]
                  ? "border-mempool-green text-mempool-green"
                  : "border-mempool-red text-mempool-red"
              }`}
            />
          </div>
        ))}
      </div>

      <div className="flex gap-2 justify-between">
        <button
          onClick={onBack}
          className="text-xs px-4 py-2 text-mempool-text-dim hover:text-mempool-text"
        >
          ← Back
        </button>
        <button
          onClick={onSubmit}
          disabled={!allMatch || submitting}
          className="bg-mempool-blue hover:bg-mempool-blue/80 disabled:bg-mempool-bg-light disabled:text-mempool-text-dim text-white font-semibold rounded-lg px-6 py-2 text-sm transition-colors"
        >
          {submitting ? "Verifying…" : "Confirm"}
        </button>
      </div>
    </div>
  );
}

// ── Step 2B: Import existing ────────────────────────────────────────────

function ImportStep({
  onBack,
  onConfirmed,
}: {
  onBack: () => void;
  onConfirmed: (mnemonic: string, address: string) => void;
}) {
  const [phrase, setPhrase] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // Live preview: show derived address as the user types — only if valid.
  const trimmed = phrase.trim().toLowerCase();
  const wordCount = trimmed ? trimmed.split(/\s+/).length : 0;
  const isValid = (wordCount === 12 || wordCount === 24) && validateMnemonic(trimmed);
  const previewAddress = useMemo(() => {
    if (!isValid) return "";
    try {
      return mnemonicToAddress(trimmed, 0);
    } catch {
      return "";
    }
  }, [trimmed, isValid]);

  const onSubmit = async () => {
    setError(null);
    if (!isValid || !previewAddress) {
      setError("Phrase must be 12 or 24 valid BIP-39 words");
      return;
    }
    setBusy(true);
    try {
      onConfirmed(trimmed, previewAddress);
    } catch (e: any) {
      setError(e?.message || "Import failed");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-lg font-bold text-mempool-text">Import existing wallet</h2>
        <p className="text-xs text-mempool-text-dim mt-0.5">
          Paste your 12 or 24 word BIP-39 recovery phrase. Your phrase never
          leaves this browser.
        </p>
      </div>

      <textarea
        placeholder="word1 word2 word3 … (space-separated)"
        value={phrase}
        onChange={(e) => setPhrase(e.target.value)}
        rows={4}
        autoComplete="off"
        autoCapitalize="off"
        spellCheck={false}
        className="w-full bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2.5 text-sm font-mono text-mempool-text resize-none focus:outline-none focus:border-mempool-blue"
      />

      <div className="flex justify-between text-xs text-mempool-text-dim">
        <span>Word count: <span className={wordCount === 12 || wordCount === 24 ? "text-mempool-green" : ""}>{wordCount}</span></span>
        <span>{isValid ? "✓ Valid BIP-39" : wordCount > 0 ? "⚠ Not yet valid" : ""}</span>
      </div>

      {previewAddress && (
        <div className="bg-mempool-bg rounded-lg border border-mempool-border p-3 space-y-1">
          <div className="text-[10px] text-mempool-text-dim uppercase tracking-wider">Wallet preview</div>
          <div className="text-xs font-mono text-mempool-blue break-all">{previewAddress}</div>
        </div>
      )}

      {error && (
        <div className="text-xs text-red-400 bg-red-500/10 border border-red-500/30 rounded px-3 py-2">
          {error}
        </div>
      )}

      <div className="flex gap-2 justify-between">
        <button
          onClick={onBack}
          className="text-xs px-4 py-2 text-mempool-text-dim hover:text-mempool-text"
        >
          ← Back
        </button>
        <button
          onClick={onSubmit}
          disabled={!isValid || busy}
          className="bg-mempool-blue hover:bg-mempool-blue/80 disabled:bg-mempool-bg-light disabled:text-mempool-text-dim text-white font-semibold rounded-lg px-6 py-2 text-sm transition-colors"
        >
          {busy ? "Importing…" : "Import wallet"}
        </button>
      </div>
    </div>
  );
}

// ── Step 3: Password ────────────────────────────────────────────────────

function PasswordStep({
  mnemonic: _mnemonic,
  address,
  onSkip,
  onSet,
  onBack,
}: {
  mnemonic: string;
  address: string;
  onSkip: () => Promise<void> | void;
  onSet: (pw: string) => Promise<void> | void;
  onBack: () => void;
}) {
  void _mnemonic;
  const [pw, setPw] = useState("");
  const [pw2, setPw2] = useState("");
  const [busy, setBusy] = useState(false);
  const strength = passwordStrength(pw);
  const matches = pw && pw === pw2;
  const canSet = matches && strength.score >= 2;

  const onSubmitSet = async () => {
    if (!canSet) return;
    setBusy(true);
    try { await onSet(pw); } finally { setBusy(false); }
  };
  const onSubmitSkip = async () => {
    setBusy(true);
    try { await onSkip(); } finally { setBusy(false); }
  };

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-lg font-bold text-mempool-text">Encrypt locally?</h2>
        <p className="text-xs text-mempool-text-dim mt-0.5">
          A password lets us cache your wallet in this browser so you don't
          need to re-paste 12 words on every visit. The mnemonic is encrypted
          (AES-GCM) before being stored. Skip to keep mnemonic-only access.
        </p>
      </div>

      <div className="bg-mempool-bg rounded-lg border border-mempool-border p-3">
        <div className="text-[10px] text-mempool-text-dim uppercase tracking-wider">Wallet</div>
        <div className="text-xs font-mono text-mempool-blue break-all">{address}</div>
      </div>

      <div className="space-y-2">
        <input
          type="password"
          placeholder="Password (min 6 chars, ≥ 2 character classes)"
          value={pw}
          onChange={(e) => setPw(e.target.value)}
          className="w-full bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2.5 text-sm text-mempool-text focus:outline-none focus:border-mempool-blue"
        />
        <input
          type="password"
          placeholder="Confirm password"
          value={pw2}
          onChange={(e) => setPw2(e.target.value)}
          className="w-full bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2.5 text-sm text-mempool-text focus:outline-none focus:border-mempool-blue"
        />

        {pw && (
          <div className="flex items-center gap-2">
            <div className="flex-1 grid grid-cols-4 gap-1">
              {[1, 2, 3, 4].map((s) => (
                <div
                  key={s}
                  className={`h-1.5 rounded-full ${
                    strength.score >= s
                      ? strength.score >= 3
                        ? "bg-mempool-green"
                        : strength.score >= 2
                        ? "bg-mempool-blue"
                        : "bg-mempool-orange"
                      : "bg-mempool-border"
                  }`}
                />
              ))}
            </div>
            <span className="text-[10px] text-mempool-text-dim w-16 text-right">
              {strength.label}
            </span>
          </div>
        )}

        {pw2 && !matches && (
          <p className="text-xs text-mempool-red">Passwords don't match</p>
        )}
      </div>

      <div className="flex flex-col sm:flex-row gap-2 justify-between">
        <button
          onClick={onBack}
          className="text-xs px-4 py-2 text-mempool-text-dim hover:text-mempool-text"
        >
          ← Back
        </button>
        <div className="flex gap-2">
          <button
            onClick={onSubmitSkip}
            disabled={busy}
            className="text-xs px-4 py-2 text-mempool-text-dim hover:text-mempool-text border border-mempool-border rounded-lg"
          >
            Skip (mnemonic only)
          </button>
          <button
            onClick={onSubmitSet}
            disabled={!canSet || busy}
            className="bg-mempool-blue hover:bg-mempool-blue/80 disabled:bg-mempool-bg-light disabled:text-mempool-text-dim text-white font-semibold rounded-lg px-6 py-2 text-sm transition-colors"
          >
            {busy ? "Encrypting…" : "Set password"}
          </button>
        </div>
      </div>
    </div>
  );
}

// ── Step 4: Backup ──────────────────────────────────────────────────────

function BackupStep({
  mnemonic,
  address,
  password,
  onContinue,
}: {
  mnemonic: string;
  address: string;
  password: string;
  onContinue: () => void;
}) {
  const [downloaded, setDownloaded] = useState(false);
  const [printed, setPrinted] = useState(false);
  const [downloading, setDownloading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const onDownload = async () => {
    setError(null);
    setDownloading(true);
    try {
      const pw = password || prompt("Backup password (used only for the file):") || "";
      if (!pw) {
        setError("Password required to encrypt backup file");
        return;
      }
      const blob = await encryptWallet(mnemonic, address, pw);
      const filename = `omnibus-wallet-${address.slice(0, 12)}.json`;
      downloadBlob(filename, JSON.stringify(blob, null, 2));
      setDownloaded(true);
    } catch (e: any) {
      setError(e?.message || "Backup failed");
    } finally {
      setDownloading(false);
    }
  };

  const onPrint = () => {
    // Open a new window with a print-friendly layout. The mnemonic is rendered
    // as both text + a simple SVG QR-substitute (we show a 1D barcode via the
    // address only — full QR via DOM-only encoder lives in ReceiveDialog).
    const win = window.open("", "_blank", "width=800,height=900");
    if (!win) {
      setError("Pop-up blocked — allow pop-ups to print");
      return;
    }
    const words = mnemonic.split(/\s+/).map((w, i) => `<div class="word"><span class="num">${i + 1}.</span> ${w}</div>`).join("");
    win.document.write(`<!doctype html>
<html><head><meta charset="utf-8"><title>OmniBus Wallet Backup</title>
<style>
  body { font-family: system-ui, sans-serif; padding: 40px; color: #111; }
  h1 { color: #d97706; margin-bottom: 4px; }
  .addr { font-family: monospace; font-size: 13px; word-break: break-all; padding: 12px; background: #f5f5f5; border: 1px solid #ddd; border-radius: 6px; }
  .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-top: 16px; padding: 16px; background: #fffbeb; border: 2px solid #f59e0b; border-radius: 8px; }
  .word { font-family: monospace; font-size: 16px; padding: 8px 10px; background: white; border: 1px solid #e5e5e5; border-radius: 4px; }
  .num { color: #888; font-size: 12px; margin-right: 6px; }
  .warn { margin-top: 24px; padding: 12px; background: #fef2f2; border: 1px solid #fca5a5; border-radius: 6px; color: #991b1b; font-size: 13px; }
  .meta { color: #666; font-size: 11px; margin-top: 24px; }
</style></head>
<body>
  <h1>OmniBus Wallet — Paper Backup</h1>
  <p>Generated ${new Date().toISOString()}</p>
  <p><strong>Address:</strong></p>
  <div class="addr">${address}</div>
  <p style="margin-top:24px;"><strong>Recovery phrase (12 words):</strong></p>
  <div class="grid">${words}</div>
  <div class="warn">
    ⚠ Anyone holding this paper can spend your OMNI. Store it like cash:
    fireproof safe, safety deposit box, or split into N-of-M shares.
  </div>
  <p class="meta">OmniBus Blockchain · BIP-39 / BIP-44 · m/44'/777'/0'/0/0</p>
  <script>setTimeout(() => window.print(), 200);</script>
</body></html>`);
    win.document.close();
    setPrinted(true);
  };

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-lg font-bold text-mempool-text">Backup options</h2>
        <p className="text-xs text-mempool-text-dim mt-0.5">
          Optional but strongly recommended. The browser vault can be wiped by
          clearing site data — keep an offline copy.
        </p>
      </div>

      <div className="space-y-2">
        <BackupCard
          title="Download encrypted JSON"
          desc="Self-contained file. Decrypt anywhere with the same password."
          status={downloaded ? "✓ Downloaded" : ""}
          onClick={onDownload}
          disabled={downloading}
        />
        <BackupCard
          title="Print paper backup"
          desc="Pretty PDF-style printable page with all 12 words."
          status={printed ? "✓ Printed" : ""}
          onClick={onPrint}
        />
        <BackupCard
          title="Pair hardware wallet"
          desc="Coming soon — Ledger / Trezor / Coldcard support."
          status="Soon"
          disabled
        />
      </div>

      {error && (
        <div className="text-xs text-red-400 bg-red-500/10 border border-red-500/30 rounded px-3 py-2">
          {error}
        </div>
      )}

      <div className="flex justify-end">
        <button
          onClick={onContinue}
          className="bg-mempool-blue hover:bg-mempool-blue/80 text-white font-semibold rounded-lg px-6 py-2 text-sm transition-colors"
        >
          Continue
        </button>
      </div>
    </div>
  );
}

function BackupCard({
  title, desc, status, onClick, disabled,
}: {
  title: string; desc: string; status: string;
  onClick?: () => void; disabled?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className="w-full text-left bg-mempool-bg border border-mempool-border hover:border-mempool-blue disabled:opacity-50 disabled:hover:border-mempool-border rounded-lg px-3 py-3 transition-colors flex items-center justify-between gap-3"
    >
      <div>
        <div className="text-sm font-semibold text-mempool-text">{title}</div>
        <div className="text-[11px] text-mempool-text-dim">{desc}</div>
      </div>
      <div className="text-xs text-mempool-green whitespace-nowrap">{status}</div>
    </button>
  );
}

// ── Step 5: Done ────────────────────────────────────────────────────────

function DoneStep({ address, onFinish }: { address: string; onFinish: () => void }) {
  // Auto-redirect after 8s — user can also click Continue.
  useEffect(() => {
    const t = setTimeout(() => onFinish(), 8_000);
    return () => clearTimeout(t);
  }, [onFinish]);

  return (
    <div className="space-y-5 text-center">
      <div className="inline-flex items-center justify-center w-16 h-16 rounded-full bg-mempool-green/20 text-mempool-green text-3xl">
        ✓
      </div>
      <h2 className="text-2xl font-bold text-mempool-text">You're ready!</h2>
      <p className="text-xs text-mempool-text-dim">
        Your wallet is unlocked and ready to send/receive OMNI. Auto-redirecting
        to dashboard in a few seconds…
      </p>
      <div className="bg-mempool-bg rounded-lg border border-mempool-border p-3">
        <div className="text-[10px] text-mempool-text-dim uppercase tracking-wider">Your address</div>
        <div className="text-xs font-mono text-mempool-blue break-all mt-1">{address}</div>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-3 gap-2 text-left">
        <Tip title="Get free OMNI" desc="Visit the Faucet tab for testnet coins." />
        <Tip title="Start mining" desc="Connect a miner via stratum-v2 gateway." />
        <Tip title="Build reputation" desc="Stake and earn the 4 soulbound badges." />
      </div>

      <button
        onClick={onFinish}
        className="bg-mempool-blue hover:bg-mempool-blue/80 text-white font-semibold rounded-lg px-6 py-2 text-sm transition-colors"
      >
        Go to dashboard
      </button>
    </div>
  );
}

function Tip({ title, desc }: { title: string; desc: string }) {
  return (
    <div className="bg-mempool-bg rounded-lg border border-mempool-border p-3">
      <div className="text-xs font-semibold text-mempool-text">{title}</div>
      <div className="text-[11px] text-mempool-text-dim mt-0.5">{desc}</div>
    </div>
  );
}
