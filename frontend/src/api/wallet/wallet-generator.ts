/**
 * wallet-generator.ts — pure functions for fresh-wallet onboarding.
 *
 * The existing `wallet-keystore.ts` is the workhorse: it derives every address
 * (OMNI primary, 4 PQ-OMNI slots, 4 soulbound, 24 multichain) from a mnemonic
 * and persists an encrypted vault to localStorage. This module wraps the same
 * primitives behind a thin, side-effect-free API the OnboardingPage / Wallet
 * Generator can call without polluting the global keystore singleton — useful
 * for "preview before commit" flows (show the user the address they're about
 * to import, let them confirm, THEN unlock).
 *
 * Encrypt/decrypt helpers also expose a portable JSON envelope so users can
 * download a plain-file backup outside the browser's localStorage vault.
 *
 * No new crypto dependencies — everything reuses libs already in node_modules:
 *   @scure/bip39   → generateMnemonic / validateMnemonic
 *   @scure/bip32   → indirectly via derivedKeysFromMnemonic
 *   @noble/secp256k1 → indirectly via deriveAddressFromPrivKey
 *   @noble/hashes  → PBKDF2 (browser native)
 *   crypto.subtle  → AES-GCM
 */

import {
  generateMnemonic as scureGenerateMnemonic,
  validateMnemonic as scureValidateMnemonic,
} from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english.js";
import {
  derivedKeysFromMnemonic,
  type Unlocked,
  type PqOmniSlot,
} from "./wallet-keystore";
import { deriveAddressFromPrivKey, hexToBytes, bytesToHex } from "../sign/exchange-sign";

// ── Mnemonic generation / validation ────────────────────────────────────

/**
 * Generate a fresh BIP-39 mnemonic with cryptographically secure entropy.
 * @param words 12 (default, 128 bits) or 24 (256 bits).
 */
export function generateMnemonic(words: 12 | 24 = 12): string {
  const strength = words === 24 ? 256 : 128;
  return scureGenerateMnemonic(wordlist, strength);
}

/** True iff the phrase is a valid BIP-39 mnemonic in the English wordlist. */
export function validateMnemonic(phrase: string): boolean {
  if (!phrase || typeof phrase !== "string") return false;
  return scureValidateMnemonic(phrase.trim().toLowerCase(), wordlist);
}

/**
 * Derive ONLY the OMNI primary address from a mnemonic (lightweight preview).
 * Does NOT compute PQ slots / multichain / soulbound — for that, use
 * `mnemonicToFullWallet`. Useful for the import flow's "address preview"
 * before the user clicks Confirm.
 */
export function mnemonicToAddress(phrase: string, walletIndex = 0): string {
  if (!validateMnemonic(phrase)) throw new Error("Invalid mnemonic");
  const { privateKey } = derivedKeysFromMnemonic(phrase.trim().toLowerCase(), walletIndex);
  return deriveAddressFromPrivKey(privateKey).address;
}

/**
 * Full derivation pipeline. Returns an object shaped like `Unlocked` (so it can
 * be displayed in the WalletGenerator preview without unlocking the singleton).
 * PQ slots are awaited synchronously here — they take ~1-3s on cold start
 * (post-quantum keygen is genuinely heavy), so callers should show a spinner.
 */
export async function mnemonicToFullWallet(
  phrase: string,
  walletIndex = 0,
  bip39Passphrase = "",
): Promise<Unlocked> {
  if (!validateMnemonic(phrase)) throw new Error("Invalid mnemonic");
  const trimmed = phrase.trim().toLowerCase();
  const {
    privateKey,
    xprv,
    xpub,
    pqOmni: pqOmniPromise,
    allAddresses,
    multichainAddresses,
    soulboundAddresses,
  } = derivedKeysFromMnemonic(trimmed, walletIndex, bip39Passphrase);
  const pqOmni: PqOmniSlot[] = await pqOmniPromise;
  const { publicKey, address } = deriveAddressFromPrivKey(privateKey);
  return {
    privateKey,
    publicKey,
    address,
    walletIndex,
    mnemonic: trimmed,
    xprv,
    xpub,
    pqOmni,
    allAddresses,
    multichainAddresses,
    soulboundAddresses,
  };
}

// ── Backup envelope (portable encrypted JSON) ───────────────────────────

/**
 * What we serialize when the user clicks "Download encrypted backup". This is
 * SEPARATE from the localStorage vault written by `wallet-keystore.persistVault`
 * because the user may want a portable file they can store offline (USB, paper
 * QR, etc.) without committing to a browser-bound vault.
 *
 * Format is intentionally simple + self-describing:
 *   v=1, AES-GCM(256), PBKDF2-SHA256 200k iterations.
 * Anyone with the same script can decrypt — no proprietary container.
 */
export type WalletBackupBlob = {
  v: 1;
  app: "omnibus";
  type: "wallet-backup";
  /** ob1q… address — cleartext so the user can identify the file at a glance. */
  address: string;
  /** Hex-encoded random salt (16 B). */
  salt: string;
  /** Hex-encoded random IV (12 B). */
  iv: string;
  /** Hex-encoded AES-GCM ciphertext over UTF-8(mnemonic). */
  ciphertext: string;
  /** PBKDF2 iteration count. We keep this in the file in case we bump it later. */
  iterations: number;
  /** ISO timestamp the file was generated. */
  createdAt: string;
};

const PBKDF2_ITERS = 200_000;

async function deriveBackupKey(password: string, salt: Uint8Array): Promise<CryptoKey> {
  const enc = new TextEncoder();
  const baseKey = await crypto.subtle.importKey(
    "raw",
    enc.encode(password),
    "PBKDF2",
    false,
    ["deriveKey"],
  );
  return crypto.subtle.deriveKey(
    {
      name: "PBKDF2",
      salt: salt as BufferSource,
      iterations: PBKDF2_ITERS,
      hash: "SHA-256",
    },
    baseKey,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

/**
 * Encrypt a wallet's mnemonic into a downloadable JSON envelope.
 *
 * We store ONLY the mnemonic — every derived field (privkey / pubkey / PQ
 * keypairs / multichain addresses) is regenerated from it on import, so the
 * file stays small and forward-compatible if we add new derivation paths.
 */
export async function encryptWallet(
  mnemonic: string,
  address: string,
  password: string,
): Promise<WalletBackupBlob> {
  if (!validateMnemonic(mnemonic)) throw new Error("Invalid mnemonic");
  if (!password) throw new Error("Password required");
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await deriveBackupKey(password, salt);
  const plaintext = new TextEncoder().encode(mnemonic.trim().toLowerCase());
  const ct = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: iv as BufferSource },
    key,
    plaintext as BufferSource,
  );
  return {
    v: 1,
    app: "omnibus",
    type: "wallet-backup",
    address,
    salt: bytesToHex(salt),
    iv: bytesToHex(iv),
    ciphertext: bytesToHex(new Uint8Array(ct)),
    iterations: PBKDF2_ITERS,
    createdAt: new Date().toISOString(),
  };
}

/**
 * Decrypt a backup envelope back to the original mnemonic.
 * Throws on wrong password / corrupted file.
 */
export async function decryptWallet(
  blob: WalletBackupBlob,
  password: string,
): Promise<string> {
  if (blob.v !== 1 || blob.type !== "wallet-backup") {
    throw new Error("Unrecognized backup format");
  }
  if (!password) throw new Error("Password required");
  const salt = hexToBytes(blob.salt);
  const iv = hexToBytes(blob.iv);
  const ct = hexToBytes(blob.ciphertext);
  const key = await deriveBackupKey(password, salt);
  let pt: ArrayBuffer;
  try {
    pt = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: iv as BufferSource },
      key,
      ct as BufferSource,
    );
  } catch {
    throw new Error("Wrong password or corrupted backup");
  }
  const mnemonic = new TextDecoder().decode(pt);
  if (!validateMnemonic(mnemonic)) {
    throw new Error("Decrypted payload is not a valid mnemonic — file corrupted?");
  }
  return mnemonic;
}

// ── Helpers for UI (pure, browser-friendly) ─────────────────────────────

/**
 * Trigger a browser download of a blob with the given filename. Pure DOM,
 * no React, no extra deps.
 */
export function downloadBlob(filename: string, content: string, mime = "application/json"): void {
  const blob = new Blob([content], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  // Revoke after a short delay so the browser can finish flushing the blob.
  setTimeout(() => URL.revokeObjectURL(url), 1_500);
}

/**
 * Pick 3 distinct random indices in [0, count). Used for the "re-type 3 random
 * words" confirmation step during onboarding.
 */
export function pickConfirmationIndices(count: number, n = 3): number[] {
  const all = Array.from({ length: count }, (_, i) => i);
  // Fisher-Yates partial shuffle — only need the first n.
  for (let i = 0; i < n && i < all.length; i++) {
    const j = i + Math.floor(Math.random() * (all.length - i));
    [all[i], all[j]] = [all[j], all[i]];
  }
  return all.slice(0, n).sort((a, b) => a - b);
}

/**
 * Quick-and-dirty password strength score 0..4.
 *  0 — empty / <6 chars
 *  1 — short OR lowercase only
 *  2 — mixed case OR digit
 *  3 — mixed case + digit, length >= 10
 *  4 — mixed case + digit + symbol, length >= 12
 */
export function passwordStrength(pwd: string): { score: 0 | 1 | 2 | 3 | 4; label: string } {
  if (!pwd || pwd.length < 6) return { score: 0, label: "Too short" };
  const hasLower = /[a-z]/.test(pwd);
  const hasUpper = /[A-Z]/.test(pwd);
  const hasDigit = /[0-9]/.test(pwd);
  const hasSym = /[^A-Za-z0-9]/.test(pwd);
  const classes = [hasLower, hasUpper, hasDigit, hasSym].filter(Boolean).length;
  if (pwd.length >= 12 && classes >= 4) return { score: 4, label: "Excellent" };
  if (pwd.length >= 10 && classes >= 3) return { score: 3, label: "Strong" };
  if (classes >= 2) return { score: 2, label: "Good" };
  if (classes >= 1) return { score: 1, label: "Weak" };
  return { score: 1, label: "Weak" };
}
