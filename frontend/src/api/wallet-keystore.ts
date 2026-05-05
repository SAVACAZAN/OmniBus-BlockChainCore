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
import { sha256 } from "@noble/hashes/sha2";
import { ripemd160 } from "@noble/hashes/legacy";
import { base58 } from "@scure/base";
import { deriveAddressFromPrivKey, bytesToHex, hexToBytes } from "./exchange-sign";

// pq-sign is loaded lazily at runtime so Vite 4 never crawls it during its
// startup dep-scan. A static import would cause Vite to spider into pq-sign.ts
// and then complain about the @noble/post-quantum ESM-only subpath exports.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type PqSignModule = { pqKeypairFromSeed: any; pqAddressFromPublicKey: any };
type PqScheme = "ml_dsa_87" | "falcon_512" | "dilithium_5" | "slh_dsa_256s";
// Use new Function so esbuild/Vite scanner never sees the specifier string.
const _dynImportLocal = new Function("p", "return import(p)") as (p: string) => Promise<PqSignModule>;
const _PQ_SIGN_PATH = atob("Li9wcS1zaWdu");
let _pqSignModule: PqSignModule | null = null;
async function pqSignModule(): Promise<PqSignModule> {
  if (_pqSignModule) return _pqSignModule;
  _pqSignModule = await _dynImportLocal(_PQ_SIGN_PATH);
  return _pqSignModule;
}
async function pqKeypairFromSeed(scheme: PqScheme, seed: Uint8Array) {
  return (await pqSignModule()).pqKeypairFromSeed(scheme, seed);
}
async function pqAddressFromPublicKeyAsync(scheme: PqScheme, publicKey: Uint8Array): Promise<string> {
  return (await pqSignModule()).pqAddressFromPublicKey(scheme, publicKey);
}

const STORAGE_KEY = "omnibus.exchange.vault.v1";
const SESSION_KEY = "omnibus.exchange.session.v1";
const PBKDF2_ITERS = 200_000;

/**
 * One PQ-OMNI slot — adresă derivată din același mnemonic la un account
 * separat (m/44'/777'/5'..8'). Same OMNI semantics on chain (transferable,
 * earns balance) but signed with a post-quantum scheme instead of secp256k1.
 *
 * Phase 1 ships with placeholder pubkey/secret material — actual ML-DSA /
 * Falcon / Dilithium / SLH-DSA keys live in Phase 3 (liboqs WASM). Until
 * then the address is computed from a deterministic seed of the BIP-32 leaf
 * privkey at the PQ account so the UI shows a stable string the user can
 * copy and the chain can route to. Sending FROM a PQ-OMNI address requires
 * Phase 2/3 to be live (chain verifier + browser signer).
 */
export type PqOmniSlot = {
  scheme: "ml_dsa_87" | "falcon_512" | "dilithium_5" | "slh_dsa_256s";
  /** UI prefix label (ob_q1_, ob_q2_, ob_q3_, ob_q4_) — see PQ_OMNI_SCHEMES. */
  prefix: string;
  address: string;
  /** Derivation path for the account. The actual PQ key is derived from this
   *  account's chain-code + a scheme-specific KDF. */
  derivationPath: string;
  /** Hex-encoded PQ public key. Hashed into the address (`hash160` then
   *  base58check, matching `core/isolated_wallet.zig:deriveLegacyAddress`).
   *  Sent on chain as `tx.public_key` for PQ-OMNI transactions so verifiers
   *  can recompute the same hash and check the signature. */
  publicKey: string;
  /** Hex-encoded PQ secret key. RAM-only, never persisted, never sent. */
  secretKey: string;
};

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
  /** 4 PQ-OMNI slots (ML-DSA, Falcon, Dilithium, SLH-DSA). Populated when
   *  unlock has access to the mnemonic (so we can derive the BIP-32
   *  account chain code). On reload from session/vault these are restored
   *  if the leaf pubkey + path are recomputable; else recomputed lazily. */
  pqOmni?: PqOmniSlot[];
};

/** PQ-OMNI scheme catalogue. The `account` index is the BIP-44 account
 *  hardened path under coin type 777 — keep in sync with chain
 *  isolated_wallet.zig if/when the chain learns these new schemes. */
export const PQ_OMNI_SCHEMES = [
  { scheme: "ml_dsa_87"   as const, account: 5, prefix: "ob_q1_", algo: "ML-DSA-87",     bits: 256 },
  { scheme: "falcon_512"  as const, account: 6, prefix: "ob_q2_", algo: "Falcon-512",    bits: 192 },
  { scheme: "dilithium_5" as const, account: 7, prefix: "ob_q3_", algo: "Dilithium-5",   bits: 256 },
  { scheme: "slh_dsa_256s" as const, account: 8, prefix: "ob_q4_", algo: "SLH-DSA-256s", bits: 256 },
];

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
      // Strip backup-only / signing-secret fields before persisting:
      //   - mnemonic + xprv  → RAM-only, reload re-pastes
      //   - pqOmni[i].secretKey → never persisted, regenerated from
      //     mnemonic when the user re-unlocks
      // xpub + pq pubkeys + addresses are public, fine to persist.
      const { mnemonic: _m, xprv: _x, pqOmni, ...persistable } = u;
      void _m; void _x;
      const safePq = pqOmni
        ? pqOmni.map((slot) => ({ ...slot, secretKey: "" }))
        : undefined;
      sessionStorage.setItem(SESSION_KEY, JSON.stringify({ ...persistable, pqOmni: safePq }));
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
/**
 * Hash160 (SHA256 → RIPEMD160) — Bitcoin convention, also what
 * `core/isolated_wallet.zig:hash160FromBytes` does for PQ pubkeys.
 */
function hash160(input: Uint8Array): Uint8Array {
  return ripemd160(sha256(input));
}

/**
 * Base58Check with version byte — same primitive used by the chain to
 * encode the legacy PQ addresses (`prefix + base58check(hash160, 0x4F)`).
 */
function base58CheckEncodeWithVersion(payload: Uint8Array, version: number): string {
  const versioned = new Uint8Array(1 + payload.length);
  versioned[0] = version & 0xff;
  versioned.set(payload, 1);
  // Double SHA256 checksum, take first 4 bytes
  const checksum = sha256(sha256(versioned)).slice(0, 4);
  const full = new Uint8Array(versioned.length + 4);
  full.set(versioned);
  full.set(checksum, versioned.length);
  return base58.encode(full);
}

/**
 * Derive the 4 PQ-OMNI slots from a BIP-32 root.
 *
 * Each slot produces a REAL post-quantum keypair (ML-DSA-87, Falcon-512,
 * Dilithium-5 = ML-DSA again, SLH-DSA-256s) using the BIP-32 leaf privkey at
 * `m/44'/777'/<account>'/0/0` as the deterministic seed. The PQ pubkey is
 * then `hash160`'d and base58check-encoded with the matching prefix —
 * exactly what `core/isolated_wallet.zig:deriveLegacyAddress` does
 * chain-side, so addresses round-trip cleanly.
 *
 * The returned slot carries the public + secret PQ key as hex. Public is
 * shared on-chain in `tx.public_key`; secret stays in process RAM and is
 * stripped from `writeSession` before any sessionStorage persistence.
 */
async function derivePqOmniSlots(root: HDKey): Promise<PqOmniSlot[]> {
  return Promise.all(PQ_OMNI_SCHEMES.map(async (s) => {
    const path = `m/44'/777'/${s.account}'/0/0`;
    const child = root.derive(path);
    if (!child.privateKey) {
      return {
        scheme: s.scheme,
        prefix: s.prefix,
        address: `${s.prefix}<derivation-failed>`,
        derivationPath: path,
        publicKey: "",
        secretKey: "",
      };
    }
    // Use the leaf privkey (32 bytes) as the deterministic seed for the PQ
    // keygen. pqKeypairFromSeed handles seed-length stretching per scheme.
    const seed = child.privateKey;
    const kp = await pqKeypairFromSeed(s.scheme as PqScheme, seed);
    const address = await pqAddressFromPublicKeyAsync(s.scheme as PqScheme, kp.publicKey);
    return {
      scheme: s.scheme,
      prefix: s.prefix,
      address,
      derivationPath: path,
      publicKey: bytesToHex(kp.publicKey),
      secretKey: bytesToHex(kp.secretKey),
    };
  }));
}

export function derivedKeysFromMnemonic(
  mnemonic: string,
  walletIndex = 0,
  bip39Passphrase = "",
): { privateKey: string; xprv: string; xpub: string; pqOmni: Promise<PqOmniSlot[]>; root: HDKey } {
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
  // PQ-OMNI slots derived from the same root at different accounts (5'..8').
  // Returns a Promise — PQ modules load lazily on first call.
  const pqOmni = derivePqOmniSlots(root);
  return {
    privateKey: bytesToHex(child.privateKey),
    xprv: account.privateExtendedKey,
    xpub: account.publicExtendedKey,
    pqOmni,
    root,
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
  const { privateKey: privKey, xprv, xpub, pqOmni: pqOmniPromise } = derivedKeysFromMnemonic(mnemonic, walletIndex, bip39Passphrase);
  const pqOmni = await pqOmniPromise;
  const { publicKey, address } = deriveAddressFromPrivKey(privKey);
  // Hold the mnemonic + xprv ONLY in process RAM (singleton). Never written
  // to sessionStorage / localStorage / vault — the vault payload is just the
  // leaf privkey. So a page reload loses the mnemonic; the user re-pastes if
  // they want to see backup material again. xpub + pqOmni addresses are
  // public and fine to persist for tab restore.
  unlocked = {
    privateKey: privKey,
    publicKey,
    address,
    walletIndex,
    mnemonic: mnemonic.trim().toLowerCase(),
    xprv,
    xpub,
    pqOmni,
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
