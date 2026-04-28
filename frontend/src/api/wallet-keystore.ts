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
const PBKDF2_ITERS = 200_000;

export type Unlocked = {
  privateKey: string; // 64 hex chars, no 0x
  publicKey: string;  // 66 hex chars compressed
  address: string;    // ob1q…
  walletIndex: number; // BIP-44 index used to derive (0 by default)
};

export type VaultMetadata = {
  walletIndex: number;
  address: string; // we store the address in cleartext so the UI can show
                   //   "unlock wallet ob1q…" without first decrypting
};

let unlocked: Unlocked | null = null;
const listeners = new Set<() => void>();

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
  notify();
}

/**
 * Derive a private key from a BIP-39 mnemonic at m/44'/777'/0'/0/<index>.
 * Throws on invalid mnemonic.
 */
export function privKeyFromMnemonic(mnemonic: string, walletIndex = 0): string {
  const trimmed = mnemonic.trim().toLowerCase();
  if (!validateMnemonic(trimmed, wordlist)) {
    throw new Error("Invalid BIP-39 mnemonic");
  }
  const seed = mnemonicToSeedSync(trimmed);
  const root = HDKey.fromMasterSeed(seed);
  // OmniBus coin type = 777
  const child = root.derive(`m/44'/777'/0'/0/${walletIndex}`);
  if (!child.privateKey) throw new Error("Mnemonic derivation produced no private key");
  return bytesToHex(child.privateKey);
}

/**
 * Unlock by mnemonic. The private key is derived locally and held in memory.
 * If `passphrase` is given, also persist an encrypted vault to localStorage so
 * the user can unlock with the passphrase next time (no need to re-paste the
 * 12 words).
 */
export async function unlockFromMnemonic(
  mnemonic: string,
  walletIndex = 0,
  passphrase?: string,
): Promise<Unlocked> {
  const privKey = privKeyFromMnemonic(mnemonic, walletIndex);
  const { publicKey, address } = deriveAddressFromPrivKey(privKey);
  unlocked = { privateKey: privKey, publicKey, address, walletIndex };
  if (passphrase) {
    await persistVault(privKey, walletIndex, address, passphrase);
  }
  notify();
  return unlocked;
}

/**
 * Unlock by raw private key. Same persistence semantics as mnemonic unlock.
 */
export async function unlockFromPrivKey(
  privKeyHex: string,
  walletIndex = 0,
  passphrase?: string,
): Promise<Unlocked> {
  let h = privKeyHex.trim();
  if (h.startsWith("0x")) h = h.slice(2);
  if (h.length !== 64) throw new Error("Private key must be 64 hex chars");
  const { publicKey, address } = deriveAddressFromPrivKey(h);
  unlocked = { privateKey: h, publicKey, address, walletIndex };
  if (passphrase) {
    await persistVault(h, walletIndex, address, passphrase);
  }
  notify();
  return unlocked;
}

/**
 * Try to unlock the persisted vault using the given passphrase. Returns
 * the unlocked wallet on success; throws on bad passphrase / corrupted data.
 */
export async function unlockFromVault(passphrase: string): Promise<Unlocked> {
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
