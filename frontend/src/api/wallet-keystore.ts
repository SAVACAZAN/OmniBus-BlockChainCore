/**
 * wallet-keystore.ts — encrypted browser wallet for the Exchange UI.
 *
 * Three ways to unlock:
 *   1. BIP-39 mnemonic (12/24 words) — derives m/44'/777'/0'/0/0 by default,
 *      same path as core/bip32_wallet.zig and the Wallet tab.
 *   2. Raw private-key hex (32 bytes) — for advanced users / dev.
 *   3. Encrypted vault — once unlocked the first time, the key is AES-GCM
 *      encrypted with a passphrase (PBKDF2-SHA256, 200k iters) and stored
 *      in localStorage. Subsequent visits prompt for the passphrase only.
 *
 * The plaintext private key NEVER leaves memory. Only the ciphertext +
 * salt + iv are persisted. Lock = wipe in-memory state.
 */

import { mnemonicToSeedSync, validateMnemonic } from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english.js";
import { HDKey } from "@scure/bip32";
import { deriveAddressFromPrivKey, bytesToHex, hexToBytes } from "./exchange-sign";

const STORAGE_KEY = "omnibus.exchange.vault.v1";
const SESSION_KEY = "omnibus.exchange.session.v1";
const PBKDF2_ITERS = 200_000;

export type Unlocked = {
  privateKey: string; // 64 hex chars, no 0x
  publicKey: string;  // 66 hex chars compressed
  address: string;    // ob1q…
  walletIndex: number; // BIP-44 index used to derive (0 by default)
  /** BIP-39 mnemonic in plaintext. ONLY present when the user unlocked via
   *  mnemonic this session (not when restoring from privkey or vault). Never
   *  persisted — held in RAM only, lost on page reload unless the user
   *  re-pastes. UI uses this for the "Backup wallet" panel. */
  mnemonic?: string;
  /** BIP-32 extended private key (xprv). Same lifecycle as `mnemonic` —
   *  only present when unlocked from mnemonic. */
  xprv?: string;
  /** BIP-32 extended public key (xpub) at account level. Always derivable
   *  from privkey + chain_code so we populate it whenever we can compute
   *  it (mnemonic and privkey unlock paths). */
  xpub?: string;
};

export type VaultMetadata = {
  walletIndex: number;
  address: string; // we store the address in cleartext so the UI can show
                   //   "unlock wallet ob1q…" without first decrypting
};

let unlocked: Unlocked | null = null;
const listeners = new Set<() => void>();

// On module load, try to restore an unlocked session from sessionStorage.
// sessionStorage is per-tab — switching tabs in the SPA keeps the state,
// but closing the tab wipes it. This is what users mean by "stay connected
// while I navigate" without committing to AES-encrypted long-term storage.
(function restoreSession() {
  if (typeof sessionStorage === "undefined") return;
  try {
    const raw = sessionStorage.getItem(SESSION_KEY);
    if (!raw) return;
    const parsed = JSON.parse(raw);
    if (
      typeof parsed?.privateKey === "string" &&
      typeof parsed?.publicKey === "string" &&
      typeof parsed?.address === "string" &&
      typeof parsed?.walletIndex === "number"
    ) {
      unlocked = {
        privateKey: parsed.privateKey,
        publicKey: parsed.publicKey,
        address: parsed.address,
        walletIndex: parsed.walletIndex,
      };
    }
  } catch { /* corrupted session — ignore */ }
})();

function writeSession(u: Unlocked | null) {
  if (typeof sessionStorage === "undefined") return;
  try {
    if (u) {
      // Strip backup-only fields before persisting. mnemonic + xprv stay in
      // RAM only; reload requires the user to re-paste the mnemonic to see
      // them again. xpub is public — fine to persist.
      const { mnemonic: _m, xprv: _x, ...persistable } = u;
      void _m; void _x;
      sessionStorage.setItem(SESSION_KEY, JSON.stringify(persistable));
    } else {
      sessionStorage.removeItem(SESSION_KEY);
    }
  } catch { /* quota / disabled — ignore */ }
}

/// Whether we currently have a sessionStorage cached unlocked wallet.
export function hasSession(): boolean {
  if (typeof sessionStorage === "undefined") return false;
  try { return sessionStorage.getItem(SESSION_KEY) !== null; } catch { return false; }
}

function notify() {
  for (const fn of listeners) {
    try { fn(); } catch { /* swallow */ }
  }
}

export function getUnlocked(): Unlocked | null { return unlocked; }
export function subscribeWallet(fn: () => void): () => void {
  listeners.add(fn);
  return () => { listeners.delete(fn); };
}

export function lockWallet(): void {
  if (unlocked) {
    // Best effort: overwrite the privkey hex before dropping the ref so
    // a snapshot debugger sees zeros. JS strings are immutable so this
    // only helps for the wrapper object, but better than nothing.
    unlocked = null;
  }
  writeSession(null);
  notify();
}

/**
 * Derive a private key from a BIP-39 mnemonic at m/44'/777'/0'/0/<index>.
 * Throws on invalid mnemonic.
 *
 * `bip39Passphrase` is the OPTIONAL "25th word" (BIP-39 §8 passphrase),
 * mixed into the seed via PBKDF2 — same mnemonic + different passphrase
 * = completely different wallet. This is what hardware wallets call
 * "passphrase" or "hidden wallet". Not to be confused with the local
 * vault PIN, which only encrypts the cached privkey in localStorage.
 * Empty string = standard derivation (no extension).
 */
export function privKeyFromMnemonic(
  mnemonic: string,
  walletIndex = 0,
  bip39Passphrase = "",
): string {
  return derivedKeysFromMnemonic(mnemonic, walletIndex, bip39Passphrase).privateKey;
}

/**
 * Same derivation as `privKeyFromMnemonic` but returns the full key bundle —
 * useful for the wallet metadata / backup panel which needs xprv (account
 * level) and xpub alongside the leaf privkey.
 *
 * Account-level xprv/xpub are at `m/44'/777'/0'`. We use account level rather
 * than the leaf so a single xpub can derive every receiving address under
 * that account (BIP-44 standard).
 */
export function derivedKeysFromMnemonic(
  mnemonic: string,
  walletIndex = 0,
  bip39Passphrase = "",
): { privateKey: string; xprv: string; xpub: string } {
  const trimmed = mnemonic.trim().toLowerCase();
  if (!validateMnemonic(trimmed, wordlist)) {
    throw new Error("Invalid BIP-39 mnemonic");
  }
  const seed = mnemonicToSeedSync(trimmed, bip39Passphrase);
  const root = HDKey.fromMasterSeed(seed);
  // Account level — supports xpub-derived public-only watchers.
  const account = root.derive(`m/44'/777'/0'`);
  // Leaf for actual signing.
  const child = account.derive(`/0/${walletIndex}`);
  if (!child.privateKey) throw new Error("Mnemonic derivation produced no private key");
  return {
    privateKey: bytesToHex(child.privateKey),
    xprv: account.privateExtendedKey, // base58check-encoded BIP-32 extended privkey
    xpub: account.publicExtendedKey,  // base58check-encoded BIP-32 extended pubkey
  };
}

/**
 * Unlock by mnemonic. Two distinct optional secrets, do NOT confuse them:
 *
 *   bip39Passphrase — BIP-39 §8 "25th word". Mixed into the seed before
 *     derivation. Same 12 words + different passphrase = different wallet
 *     and different ob1q address. Empty = legacy / no extension.
 *
 *   vaultPin — PIN to encrypt the derived privkey under AES-GCM and
 *     persist it in localStorage. Only used to skip re-pasting the 12
 *     words on next visit. Doesn't touch the wallet identity.
 */
export async function unlockFromMnemonic(
  mnemonic: string,
  walletIndex = 0,
  vaultPin?: string,
  bip39Passphrase = "",
): Promise<Unlocked> {
  const { privateKey: privKey, xprv, xpub } = derivedKeysFromMnemonic(mnemonic, walletIndex, bip39Passphrase);
  const { publicKey, address } = deriveAddressFromPrivKey(privKey);
  // Hold the mnemonic + xprv ONLY in process RAM (singleton). Never written
  // to sessionStorage / localStorage / vault — the vault payload is just the
  // leaf privkey. So a page reload loses the mnemonic; the user re-pastes if
  // they want to see backup material again. xpub is fine to persist (public).
  unlocked = {
    privateKey: privKey,
    publicKey,
    address,
    walletIndex,
    mnemonic: mnemonic.trim().toLowerCase(),
    xprv,
    xpub,
  };
  writeSession(unlocked);
  if (vaultPin) {
    await persistVault(privKey, walletIndex, address, vaultPin);
  }
  notify();
  return unlocked;
}

/**
 * Unlock by raw private key. `vaultPin` (optional) encrypts the privkey
 * for localStorage persistence; same semantics as mnemonic unlock.
 * No BIP-39 passphrase here — the privkey is already final.
 */
export async function unlockFromPrivKey(
  privKeyHex: string,
  walletIndex = 0,
  vaultPin?: string,
): Promise<Unlocked> {
  let h = privKeyHex.trim();
  if (h.startsWith("0x")) h = h.slice(2);
  if (h.length !== 64) throw new Error("Private key must be 64 hex chars");
  const { publicKey, address } = deriveAddressFromPrivKey(h);
  unlocked = { privateKey: h, publicKey, address, walletIndex };
  writeSession(unlocked);
  if (vaultPin) {
    await persistVault(h, walletIndex, address, vaultPin);
  }
  notify();
  return unlocked;
}

/**
 * Try to unlock the persisted vault using the given PIN. Returns
 * the unlocked wallet on success; throws on bad PIN / corrupted data.
 */
export async function unlockFromVault(vaultPin: string): Promise<Unlocked> {
  const passphrase = vaultPin;
  const meta = readVaultMeta();
  if (!meta) throw new Error("No saved vault on this device");
  const vault = readVaultRaw();
  if (!vault) throw new Error("Vault data missing");
  const privKey = await decryptVault(vault.ciphertext, vault.salt, vault.iv, passphrase);
  const { publicKey, address } = deriveAddressFromPrivKey(privKey);
  // Sanity: the derived address must match the metadata. If not, the user
  // typed the wrong passphrase OR the vault was tampered with.
  if (address !== meta.address) {
    throw new Error("Decryption succeeded but address mismatch — wrong passphrase?");
  }
  unlocked = { privateKey: privKey, publicKey, address, walletIndex: meta.walletIndex };
  writeSession(unlocked);
  notify();
  return unlocked;
}

export function hasVault(): boolean {
  return readVaultMeta() !== null;
}

export function readVaultMeta(): VaultMetadata | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (parsed?.address && typeof parsed.walletIndex === "number") {
      return { address: parsed.address, walletIndex: parsed.walletIndex };
    }
    return null;
  } catch {
    return null;
  }
}

export function clearVault(): void {
  try { localStorage.removeItem(STORAGE_KEY); } catch { /* ignore */ }
  lockWallet();
}

function readVaultRaw(): { ciphertext: string; salt: string; iv: string } | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const p = JSON.parse(raw);
    if (typeof p?.ciphertext === "string" && typeof p?.salt === "string" && typeof p?.iv === "string") {
      return p;
    }
    return null;
  } catch {
    return null;
  }
}

async function persistVault(
  privKeyHex: string,
  walletIndex: number,
  address: string,
  passphrase: string,
): Promise<void> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await deriveAesKey(passphrase, salt);
  const plaintext = hexToBytes(privKeyHex);
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv: iv as BufferSource }, key, plaintext as BufferSource);
  const payload = {
    v: 1,
    walletIndex,
    address,
    ciphertext: bytesToHex(new Uint8Array(ct)),
    salt: bytesToHex(salt),
    iv: bytesToHex(iv),
  };
  localStorage.setItem(STORAGE_KEY, JSON.stringify(payload));
}

async function decryptVault(
  ciphertextHex: string,
  saltHex: string,
  ivHex: string,
  passphrase: string,
): Promise<string> {
  const salt = hexToBytes(saltHex);
  const iv = hexToBytes(ivHex);
  const key = await deriveAesKey(passphrase, salt);
  const ct = hexToBytes(ciphertextHex);
  let pt: ArrayBuffer;
  try {
    pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: iv as BufferSource }, key, ct as BufferSource);
  } catch {
    throw new Error("Wrong passphrase");
  }
  return bytesToHex(new Uint8Array(pt));
}

async function deriveAesKey(passphrase: string, salt: Uint8Array): Promise<CryptoKey> {
  const enc = new TextEncoder();
  const baseKey = await crypto.subtle.importKey(
    "raw",
    enc.encode(passphrase),
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

let lastNonce = 0;
export function nextNonce(): number {
  const now = Date.now();
  lastNonce = now > lastNonce ? now : lastNonce + 1;
  return lastNonce;
}
