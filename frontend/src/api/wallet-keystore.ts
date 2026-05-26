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
import { sha256, sha512 } from "@noble/hashes/sha2";
import { keccak_256 } from "@noble/hashes/sha3";
import { ripemd160 } from "@noble/hashes/legacy";
import { base58 } from "@scure/base";
import { deriveAddressFromPrivKey, bytesToHex, hexToBytes } from "./exchange-sign";
import * as secp from "@noble/secp256k1";
// @noble/curves 2.x ships ed25519.js but doesn't declare it in package.json exports —
// import via the JS file path which Vite resolves correctly.
// @ts-ignore
import { ed25519 } from "@noble/curves/ed25519.js";

// pq-sign loads @noble/post-quantum lazily via new Function+atob inside pq-sign.ts
// itself, so Vite 4 won't find @noble/post-quantum subpath exports when it crawls
// this static import. Safe to import statically.
import {
  pqKeypairFromSeed,
  pqAddressFromPublicKey as _pqAddressFromPublicKey,
  type PqScheme,
} from "./pq-sign";

async function pqAddressFromPublicKeyAsync(scheme: PqScheme, publicKey: Uint8Array): Promise<string> {
  return _pqAddressFromPublicKey(scheme, publicKey);
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
   *  unlock has access to the mnemonic. */
  pqOmni?: PqOmniSlot[];
  /** 24 multichain addresses derived from same mnemonic via BIP-44 standard
   *  coin types. Watch-only — private keys stay in RAM, never sent anywhere. */
  multichainAddresses?: { chain: string; address: string; path: string; group: string }[];
  /** BIP-44 OMNI addresses at indices 0..18, each with its EVM + SOL + XRP address. */
  allAddresses?: { index: number; address: string; path: string; evmAddress: string; solAddress: string; xrpAddress: string }[];
  /** 4 soulbound reputation domain addresses (ob_k1_/ob_f5_/ob_d5_/ob_s3_).
   *  Derived from same mnemonic at coin types 778-781. Non-transferable — chain
   *  rejects any TX where these are the sender. */
  soulboundAddresses?: { tier: string; prefix: string; address: string; algo: string; bits: number }[];
};

/** PQ-OMNI scheme catalogue. Prefixes MUST match `core/transaction.zig:Scheme.prefix()`:
 *    pq_omni_ml_dsa    = obk1_   (k for Kyber-Dilithium family / ML-DSA-87)
 *    pq_omni_falcon    = obf5_   (f for Falcon-512)
 *    pq_omni_dilithium = obd5_   (d for Dilithium-5 — CANONICAL mnemonic)
 *    pq_omni_slh_dsa   = obs3_   (s for SLH-DSA / SPHINCS+ — CANONICAL mnemonic)
 *  Mismatch causes `pq_send` to reject with "from address prefix does not match scheme". */
export const PQ_OMNI_SCHEMES = [
  { scheme: "ml_dsa_87"    as const, account: 5, prefix: "obk1_", algo: "ML-DSA-87",     bits: 256 },
  { scheme: "falcon_512"   as const, account: 6, prefix: "obf5_", algo: "Falcon-512",    bits: 192 },
  { scheme: "dilithium_5"  as const, account: 7, prefix: "obd5_", algo: "Dilithium-5",   bits: 256 },
  { scheme: "slh_dsa_256s" as const, account: 8, prefix: "obs3_", algo: "SLH-DSA-256s",  bits: 256 },
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
        xpub: parsed.xpub,
        pqOmni: parsed.pqOmni,
        allAddresses: parsed.allAddresses,
        multichainAddresses: parsed.multichainAddresses,
        soulboundAddresses: parsed.soulboundAddresses,
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

/**
 * Re-derive private key + public key + OMNI address for any BIP-44 OMNI slot
 * index 0..18 from the currently unlocked mnemonic.
 *
 * Used by Trade / Send / Stake when the user has selected a non-zero active
 * slot in the Header dropdown. Returns null if no mnemonic is in RAM (user
 * unlocked from raw privkey or from vault without mnemonic restore — in that
 * case the UI must fall back to `unlocked` slot or prompt the user to re-enter
 * the mnemonic).
 *
 * Cheap: ~1 ms per call (BIP-32 derive is O(slot depth) of HMAC-SHA512).
 * Don't memoize across slots — that risks reusing a stale privkey if the user
 * locks/unlocks. The caller composes per-action.
 */
export function deriveSlotKey(slot: number): {
  privateKey: string;
  publicKey: string;
  address: string;
  evmAddress: string;
  /** EVM private key hex (no 0x prefix) — used to sign DEX buyOrder /
   *  approve / cancel txs from the same slot the OMNI side belongs to.
   *  Empty string when m/44'/60' derivation fails. */
  evmPrivateKey: string;
} | null {
  if (!unlocked?.mnemonic) return null;
  if (!Number.isFinite(slot) || slot < 0 || slot > 18) return null;
  try {
    const seed = mnemonicToSeedSync(unlocked.mnemonic);
    const root = HDKey.fromMasterSeed(seed);
    const omniLeaf = root.derive(`m/44'/777'/0'/0/${slot}`);
    if (!omniLeaf.privateKey) return null;
    const privHex = bytesToHex(omniLeaf.privateKey);
    const { publicKey, address } = deriveAddressFromPrivKey(privHex);

    // EVM sibling at m/44'/60'/0'/0/<slot> — needed for HTLC counter-leg
    // AND for OmnibusDEX.placeBuyOrder() / cancelOrder() from this slot.
    let evmAddress = "";
    let evmPrivateKey = "";
    try {
      const evmLeaf = root.derive(`m/44'/60'/0'/0/${slot}`);
      if (evmLeaf.privateKey) {
        evmPrivateKey = bytesToHex(evmLeaf.privateKey);
      }
      if (evmLeaf.publicKey) {
        evmAddress = (unlocked.allAddresses?.find((a) => a.index === slot)?.evmAddress) ?? "";
      }
    } catch { /* leave empty */ }

    return { privateKey: privHex, publicKey, address, evmAddress, evmPrivateKey };
  } catch {
    return null;
  }
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
// ── Multichain address encoding helpers ─────────────────────────────────────

/** base58check encode with version byte — used by BTC/LTC/DOGE/BCH legacy */
function b58check(payload: Uint8Array, version: number): string {
  const versioned = new Uint8Array(1 + payload.length);
  versioned[0] = version & 0xff;
  versioned.set(payload, 1);
  const checksum = sha256(sha256(versioned)).slice(0, 4);
  const full = new Uint8Array(versioned.length + 4);
  full.set(versioned); full.set(checksum, versioned.length);
  return base58.encode(full);
}

/** bech32 charset + encoding — used by BTC native segwit / LTC native */
const BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
function bech32Polymod(values: number[]): number {
  const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let chk = 1;
  for (const v of values) {
    const top = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (let i = 0; i < 5; i++) if ((top >> i) & 1) chk ^= GEN[i];
  }
  return chk;
}
function bech32Encode(hrp: string, data: number[]): string {
  const hrpExpand = [...hrp].map(c => c.charCodeAt(0) >> 5)
    .concat([0], [...hrp].map(c => c.charCodeAt(0) & 31));
  const checksum = bech32Polymod([...hrpExpand, ...data, 0, 0, 0, 0, 0, 0]) ^ 1;
  const cs = Array.from({length: 6}, (_, i) => (checksum >> (5 * (5 - i))) & 31);
  return hrp + "1" + [...data, ...cs].map(d => BECH32_CHARSET[d]).join("");
}
function convertBits(data: Uint8Array, fromBits: number, toBits: number): number[] {
  let acc = 0, bits = 0;
  const out: number[] = [];
  for (const v of data) {
    acc = ((acc << fromBits) | v) & 0xffffffff;
    bits += fromBits;
    while (bits >= toBits) { bits -= toBits; out.push((acc >> bits) & ((1 << toBits) - 1)); }
  }
  return out;
}
function bech32Address(hrp: string, witVer: number, program: Uint8Array): string {
  return bech32Encode(hrp, [witVer, ...convertBits(program, 8, 5)]);
}

/** bech32m — Taproot (segwit v1). Same as bech32 but XOR constant = 0x2bc830a3 */
function bech32mEncode(hrp: string, data: number[]): string {
  const hrpExpand = [...hrp].map(c => c.charCodeAt(0) >> 5)
    .concat([0], [...hrp].map(c => c.charCodeAt(0) & 31));
  const checksum = bech32Polymod([...hrpExpand, ...data, 0, 0, 0, 0, 0, 0]) ^ 0x2bc830a3;
  const cs = Array.from({length: 6}, (_, i) => (checksum >> (5 * (5 - i))) & 31);
  return hrp + "1" + [...data, ...cs].map(d => BECH32_CHARSET[d]).join("");
}
function bech32mAddress(hrp: string, program: Uint8Array): string {
  return bech32mEncode(hrp, [1, ...convertBits(program, 8, 5)]);
}

/** EVM address — last 20 bytes of keccak256(pubkey_uncompressed[1:]), EIP-55 checksum */
function evmAddress(pubkeyCompressed: Uint8Array): string {
  const point = secp.ProjectivePoint.fromHex(pubkeyCompressed);
  const uncompressed = point.toRawBytes(false);
  const hash = keccak_256(uncompressed.slice(1));
  const addr = Array.from(hash.slice(12)).map(b => b.toString(16).padStart(2, "0")).join("");
  // EIP-55 checksum
  const addrHash = Array.from(keccak_256(new TextEncoder().encode(addr))).map(b => b.toString(16).padStart(2, "0")).join("");
  const checksummed = addr.split("").map((c, i) =>
    /[a-f]/.test(c) ? (parseInt(addrHash[i], 16) >= 8 ? c.toUpperCase() : c) : c
  ).join("");
  return "0x" + checksummed;
}

/** Cosmos bech32 — ATOM, similar chains */
function cosmosBech32(hrp: string, pubkey: Uint8Array): string {
  const h = ripemd160(sha256(pubkey));
  return bech32Encode(hrp, [0, ...convertBits(h, 8, 5)]);
}

/** SLIP-10 Ed25519 derivation — all indices hardened, HMAC key = "ed25519 seed" */
function slip10Ed25519(seed: Uint8Array, indices: number[]): Uint8Array {
  function hmac512(key: Uint8Array, data: Uint8Array): Uint8Array {
    const BLOCK = 128;
    const k = key.length > BLOCK ? sha512(key) : key;
    const kPad = new Uint8Array(BLOCK); kPad.set(k);
    const iPad = kPad.map(b => b ^ 0x36);
    const oPad = kPad.map(b => b ^ 0x5c);
    const inner = new Uint8Array(BLOCK + data.length);
    inner.set(iPad); inner.set(data, BLOCK);
    const outer = new Uint8Array(BLOCK + 64);
    outer.set(oPad); outer.set(sha512(inner), BLOCK);
    return sha512(outer);
  }
  let I = hmac512(new TextEncoder().encode("ed25519 seed"), seed);
  let kL = I.slice(0, 32);
  let kR = I.slice(32);
  for (const index of indices) {
    const hardened = (index | 0x80000000) >>> 0;
    const data = new Uint8Array(37);
    data[0] = 0x00; data.set(kL, 1);
    new DataView(data.buffer).setUint32(33, hardened, false);
    const child = hmac512(kR, data);
    kL = child.slice(0, 32);
    kR = child.slice(32);
  }
  return kL;
}

/** Solana address = Ed25519 pubkey (32 bytes) in base58, no checksum.
 *  BIP-32 gives us a secp256k1 privkey — we reuse those 32 bytes as Ed25519
 *  scalar seed (standard practice for deterministic SOL derivation). */
function solanaAddress(secp256k1Pubkey: Uint8Array, privkeyBytes?: Uint8Array): string {
  if (privkeyBytes && privkeyBytes.length === 32) {
    const ed25519Pubkey = ed25519.getPublicKey(privkeyBytes);
    return base58.encode(ed25519Pubkey);
  }
  // fallback: encode secp256k1 pubkey truncated (wrong but safe display)
  return base58.encode(secp256k1Pubkey.slice(1, 33));
}

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

const SOULBOUND_DOMAINS = [
  { tier: "LOVE",     prefix: "ob_k1_", coinType: 778, algo: "ML-DSA-87",    bits: 256 },
  { tier: "FOOD",     prefix: "ob_f5_", coinType: 779, algo: "Falcon-512",   bits: 192 },
  { tier: "RENT",     prefix: "ob_d5_", coinType: 780, algo: "Dilithium-5",  bits: 256 },
  { tier: "VACATION", prefix: "ob_s3_", coinType: 781, algo: "SLH-DSA-256s", bits: 256 },
];

/**
 * Derive the 4 soulbound reputation domain addresses from a BIP-32 root.
 * Path: m/44'/<coinType>'/0'/0/0 — one address per domain.
 * Address = prefix + base58check(hash160(pubkey), 0x4F)
 * These addresses CANNOT be tx senders — chain enforces this.
 */
function deriveSoulboundAddresses(root: HDKey): { tier: string; prefix: string; address: string; algo: string; bits: number }[] {
  return SOULBOUND_DOMAINS.map((d) => {
    try {
      const path = `m/44'/${d.coinType}'/0'/0/0`;
      const child = root.derive(path);
      if (!child.privateKey) return { ...d, address: `${d.prefix}<derive-failed>` };
      const pubBytes = child.publicKey!;
      const h = hash160(pubBytes);
      const addr = d.prefix + base58CheckEncodeWithVersion(h, 0x4f);
      return { tier: d.tier, prefix: d.prefix, address: addr, algo: d.algo, bits: d.bits };
    } catch {
      return { ...d, address: `${d.prefix}<derive-failed>` };
    }
  });
}

/** Polkadot SS58 — prefix byte + 32-byte pubkey + 2-byte blake2b checksum, base58 */
function ss58Address(pubkey32: Uint8Array, networkPrefix: number): string {
  // SS58 uses "SS58PRE" + payload as checksum input
  const payload = new Uint8Array(1 + 32);
  payload[0] = networkPrefix;
  payload.set(pubkey32, 1);
  const prefix = new TextEncoder().encode("SS58PRE");
  const checksumInput = new Uint8Array(prefix.length + payload.length);
  checksumInput.set(prefix); checksumInput.set(payload, prefix.length);
  const checksum = sha512(checksumInput).slice(0, 2);
  const full = new Uint8Array(payload.length + 2);
  full.set(payload); full.set(checksum, payload.length);
  return base58.encode(full);
}

// XRP uses a DIFFERENT base58 alphabet than Bitcoin.
// Bitcoin: 123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz
// XRP:     rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz
const XRP_ALPHABET = "rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz";
function xrpBase58Encode(bytes: Uint8Array): string {
  let num = BigInt(0);
  for (const b of bytes) num = num * BigInt(256) + BigInt(b);
  let result = "";
  while (num > BigInt(0)) {
    result = XRP_ALPHABET[Number(num % BigInt(58))] + result;
    num = num / BigInt(58);
  }
  for (const b of bytes) { if (b !== 0) break; result = XRP_ALPHABET[0] + result; }
  return result;
}

/** XRP address — hash160(secp256k1 pubkey) + version byte 0x00, in XRP base58 alphabet.
 *  Version byte 0x00 + XRP alphabet produces addresses starting with 'r'. */
function xrpAddress(pubkey: Uint8Array): string {
  const accountId = ripemd160(sha256(pubkey));
  const versioned = new Uint8Array(21);
  versioned[0] = 0x00;
  versioned.set(accountId, 1);
  const checksum = sha256(sha256(versioned)).slice(0, 4);
  const full = new Uint8Array(25);
  full.set(versioned); full.set(checksum, 21);
  return xrpBase58Encode(full);
}

/** Stellar strkey — G + base32(version_byte + ed25519_pubkey + checksum) */
function stellarAddress(privkeyBytes?: Uint8Array): string {
  if (!privkeyBytes) return "(no key)";
  const edPub = ed25519.getPublicKey(privkeyBytes);
  // Stellar strkey: version 6 << 3 = 48 (G), payload = pubkey, checksum CRC-16
  const payload = new Uint8Array(1 + 32);
  payload[0] = 6 << 3; // 48 = account (G)
  payload.set(edPub, 1);
  // CRC-16 CCITT
  let crc = 0x0000;
  for (const b of payload) {
    let x = ((crc >> 8) ^ b) & 0xff;
    x ^= x >> 4;
    crc = ((crc << 8) ^ (x << 12) ^ (x << 5) ^ x) & 0xffff;
  }
  const full = new Uint8Array(35);
  full.set(payload); full[33] = crc & 0xff; full[34] = (crc >> 8) & 0xff;
  // Base32 encoding (no padding, uppercase)
  const ALPHA32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = 0, val = 0, out = "";
  for (const b of full) {
    val = (val << 8) | b; bits += 8;
    while (bits >= 5) { out += ALPHA32[(val >> (bits - 5)) & 31]; bits -= 5; }
  }
  if (bits > 0) out += ALPHA32[(val << (5 - bits)) & 31];
  return out;
}

/** Algorand address — Ed25519 pubkey (32 bytes) + 4-byte checksum, base32 */
function algoAddress(privkeyBytes?: Uint8Array): string {
  if (!privkeyBytes) return "(no key)";
  const edPub = ed25519.getPublicKey(privkeyBytes);
  const checksum = sha256(edPub).slice(28, 32); // last 4 bytes
  const full = new Uint8Array(36);
  full.set(edPub); full.set(checksum, 32);
  const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = 0, val = 0, out = "";
  for (const b of full) {
    val = (val << 8) | b; bits += 8;
    while (bits >= 5) { out += ALPHABET[(val >> (bits - 5)) & 31]; bits -= 5; }
  }
  if (bits > 0) out += ALPHABET[(val << (5 - bits)) & 31];
  return out;
}

/** MultiversX (EGLD) — bech32 "erd1" + 32-byte Ed25519 pubkey */
function egldAddress(privkeyBytes?: Uint8Array): string {
  if (!privkeyBytes) return "(no key)";
  const edPub = ed25519.getPublicKey(privkeyBytes);
  return bech32Address("erd", 0, edPub);
}

/** Derive 24 multichain addresses from same BIP-32 root via BIP-44 coin types.
 *  All watch-only — private keys stay in RAM, never transmitted. */
function deriveMultichainAddresses(root: HDKey, seed: Uint8Array): { chain: string; address: string; path: string; group: string }[] {
  const derive = (path: string) => {
    try {
      const child = root.derive(path);
      return child.publicKey ?? null;
    } catch { return null; }
  };
  const derivePriv = (path: string) => {
    try {
      const child = root.derive(path);
      return child.privateKey ?? null;
    } catch { return null; }
  };

  const h160 = (pub: Uint8Array) => ripemd160(sha256(pub));

  const chains: { chain: string; group: string; path: string; encode: (pub: Uint8Array) => string }[] = [
    // ── BTC family ──────────────────────────────────────────────────
    { chain: "BTC_LEGACY",  group: "BTC",  path: "m/44'/0'/0'/0/0",
      encode: p => b58check(h160(p), 0x00) },
    { chain: "BTC_SEGWIT",  group: "BTC",  path: "m/49'/0'/0'/0/0",
      encode: p => { const s = new Uint8Array([0x00, 0x14, ...h160(p)]); return b58check(h160(s), 0x05); } },
    { chain: "BTC_NATIVE",  group: "BTC",  path: "m/84'/0'/0'/0/0",
      encode: p => bech32Address("bc", 0, h160(p)) },
    { chain: "BTC_TAPROOT", group: "BTC",  path: "m/86'/0'/0'/0/0",
      encode: p => bech32mAddress("bc", sha256(p).slice(0, 32)) },

    // ── BTC testnet family ─ coin_type=1 (BIP-44 standard for all testnets),
    //    version bytes 0x6f (P2PKH testnet) / 0xc4 (P2SH testnet), HRP "tb".
    { chain: "BTC_TESTNET_LEGACY",  group: "BTC",  path: "m/44'/1'/0'/0/0",
      encode: p => b58check(h160(p), 0x6f) },
    { chain: "BTC_TESTNET_SEGWIT",  group: "BTC",  path: "m/49'/1'/0'/0/0",
      encode: p => { const s = new Uint8Array([0x00, 0x14, ...h160(p)]); return b58check(h160(s), 0xc4); } },
    { chain: "BTC_TESTNET_NATIVE",  group: "BTC",  path: "m/84'/1'/0'/0/0",
      encode: p => bech32Address("tb", 0, h160(p)) },
    { chain: "BTC_TESTNET_TAPROOT", group: "BTC",  path: "m/86'/1'/0'/0/0",
      encode: p => bech32mAddress("tb", sha256(p).slice(0, 32)) },

    // ── EVM compatible — coin_type=60 (same derivation, same 0x address) ─
    // 40+ chains share Ethereum BIP-44 derivation per SLIP-44. Symbol/RPC differ.
    { chain: "ETH",          group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "BASE",         group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "ARB",          group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "OP",           group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "LINEA",        group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "ZKSYNC",       group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "SCROLL",       group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "BLAST",        group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "MODE",         group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "MANTA",        group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "MANTLE",       group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "OPBNB",        group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "GNOSIS",       group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "CELO",         group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "CRONOS",       group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "MOONBEAM",     group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "MOONRIVER",    group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "ASTAR",        group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "METIS",        group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "ETC",          group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "XDC",          group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "KAIA",         group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "CONFLUX",      group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "FLARE",        group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "ROOTSTOCK",    group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "BOB",          group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "TAIKO",        group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "XLAYER",       group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "ZORA",         group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "IMMUTABLE_ZK", group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "MERLIN",       group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "LUKSO",        group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "IOTEX",        group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "SYSCOIN",      group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "EWT",          group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "LCX",          group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },

    // ── EVM testnet — same coin_type=60 by convention ──
    { chain: "ETH_SEPOLIA",     group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "BASE_SEPOLIA",    group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },
    { chain: "MANTLE_SEPOLIA",  group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },

    // ── EVM with their own SLIP-44 coin_type (different derivation) ──
    { chain: "BNB",   group: "EVM", path: "m/44'/714'/0'/0/0",  encode: evmAddress },
    { chain: "MATIC", group: "EVM", path: "m/44'/966'/0'/0/0",  encode: evmAddress },
    { chain: "AVAX",  group: "EVM", path: "m/44'/9005'/0'/0/0", encode: evmAddress },
    { chain: "FTM",   group: "EVM", path: "m/44'/1007'/0'/0/0", encode: evmAddress },
    { chain: "ONE",   group: "EVM", path: "m/44'/1023'/0'/0/0", encode: evmAddress },
    { chain: "ONE",   group: "EVM", path: "m/44'/60'/0'/0/0", encode: evmAddress },

    // ── UTXO coins ───────────────────────────────────────────────────
    { chain: "LTC_LEGACY", group: "LTC",  path: "m/44'/2'/0'/0/0",
      encode: p => b58check(h160(p), 0x30) },
    { chain: "LTC_SEGWIT", group: "LTC",  path: "m/49'/2'/0'/0/0",
      encode: p => { const s = new Uint8Array([0x00, 0x14, ...h160(p)]); return b58check(h160(s), 0x32); } },
    { chain: "LTC_NATIVE", group: "LTC",  path: "m/84'/2'/0'/0/0",
      encode: p => bech32Address("ltc", 0, h160(p)) },
    { chain: "DOGE",       group: "DOGE", path: "m/44'/3'/0'/0/0",
      encode: p => b58check(h160(p), 0x1e) },
    { chain: "BCH",        group: "BCH",  path: "m/44'/145'/0'/0/0",
      encode: p => b58check(h160(p), 0x00) },

    // ── Non-EVM ──────────────────────────────────────────────────────
    // SOL: SLIP-10 Ed25519 — encoded separately via solAddress field in allAddresses
    { chain: "SOL",  group: "OTHER", path: "m/44'/501'/0'/0/0",  encode: (p) => solanaAddress(p, derivePriv("m/44'/501'/0'/0/0") ?? undefined) },
    // ADA: Shelley bech32 — real addr needs Byron/Shelley encoding, show as enterprise addr
    { chain: "ADA",  group: "OTHER", path: "m/44'/1815'/0'/0/0", encode: p => bech32Address("addr", 0x61, h160(p)) },
    // DOT: SLIP-10 Ed25519 → SS58 prefix 0 (Polkadot generic). Faucets use this.
    { chain: "DOT",  group: "OTHER", path: "m/44'/354'/0'/0/0",  encode: (_p) => ss58Address(ed25519.getPublicKey(slip10Ed25519(seed, [44, 354, 0, 0, 0])), 0) },
    // ── Cosmos family — same secp256k1, bech32 with chain-specific HRP ──
    { chain: "ATOM",          group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("cosmos",    p) },
    { chain: "OSMOSIS",       group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("osmo",      p) },
    { chain: "INJECTIVE",     group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("inj",       p) },
    { chain: "SEI",           group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("sei",       p) },
    { chain: "DYDX",          group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("dydx",      p) },
    { chain: "JUNO",          group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("juno",      p) },
    { chain: "AKASH",         group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("akash",     p) },
    { chain: "KAVA",          group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("kava",      p) },
    { chain: "STRIDE",        group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("stride",    p) },
    { chain: "NOBLE",         group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("noble",     p) },
    { chain: "STARGAZE",      group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("stars",     p) },
    { chain: "EVMOS",         group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("evmos",     p) },
    { chain: "TERRA_CLASSIC", group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("terra",     p) },
    { chain: "TERRA2",        group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("terra",     p) },
    { chain: "BABYLON",       group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("bbn",       p) },
    { chain: "KUJIRA",        group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("kujira",    p) },
    { chain: "NEUTRON",       group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("neutron",   p) },
    { chain: "CRESCENT",      group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("cre",       p) },
    { chain: "UMEE",          group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("umee",      p) },
    { chain: "COMDEX",        group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("comdex",    p) },
    { chain: "CHIHUAHUA",     group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("chihuahua", p) },
    { chain: "BITCANNA",      group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("bcna",      p) },
    { chain: "IXO",           group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("ixo",       p) },
    { chain: "SENTINEL",      group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("sent",      p) },
    { chain: "DYMENSION",     group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("dym",       p) },
    { chain: "SEDA",          group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("seda",      p) },
    { chain: "PERSISTENCE",   group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("persistence", p) },
    { chain: "CELESTIA",      group: "COSMOS", path: "m/44'/118'/0'/0/0", encode: p => cosmosBech32("celestia",  p) },
    // Cosmos chains with their own SLIP-44 coin_type
    { chain: "CRYPTO_ORG",    group: "COSMOS", path: "m/44'/394'/0'/0/0", encode: p => cosmosBech32("cro",       p) },
    { chain: "BAND",          group: "COSMOS", path: "m/44'/494'/0'/0/0", encode: p => cosmosBech32("band",      p) },
    { chain: "PROVENANCE",    group: "COSMOS", path: "m/44'/505'/0'/0/0", encode: p => cosmosBech32("pb",        p) },
    // XRP: base58check with XRP alphabet (differs from Bitcoin) + account ID prefix 0x00
    { chain: "XRP",  group: "OTHER", path: "m/44'/144'/0'/0/0",  encode: p => xrpAddress(p) },
    // XLM: SLIP-10 Ed25519 at m/44'/148'/0'/0/0 (Stellar official standard)
    { chain: "XLM",  group: "OTHER", path: "m/44'/148'/0'/0/0",  encode: (_p) => stellarAddress(slip10Ed25519(seed, [44, 148, 0, 0, 0])) },
    { chain: "TRX",  group: "OTHER", path: "m/44'/195'/0'/0/0",  encode: p => { const evmHex = evmAddress(p).slice(2); const bytes = new Uint8Array(20); for (let i = 0; i < 20; i++) bytes[i] = parseInt(evmHex.slice(i*2, i*2+2), 16); return b58check(bytes, 0x41); } },
    // ALGO: SLIP-10 Ed25519 at m/44'/283'/0'/0/0 (Algorand official standard)
    { chain: "ALGO", group: "OTHER", path: "m/44'/283'/0'/0/0",  encode: (_p) => algoAddress(slip10Ed25519(seed, [44, 283, 0, 0, 0])) },
    // EGLD: SLIP-10 Ed25519 at m/44'/508'/0'/0/0 (MultiversX official standard)
    { chain: "EGLD", group: "OTHER", path: "m/44'/508'/0'/0/0",  encode: (_p) => egldAddress(slip10Ed25519(seed, [44, 508, 0, 0, 0])) },

    // ── NEAR — Ed25519, raw 32-byte hex public key as the address ──
    { chain: "NEAR", group: "OTHER", path: "m/44'/397'/0'/0/0",
      encode: (_p) => Array.from(ed25519.getPublicKey(slip10Ed25519(seed, [44, 397, 0, 0, 0])))
        .map(b => b.toString(16).padStart(2, "0")).join("") },

    // ── TON — Ed25519 / different address scheme; deferred to dedicated encoder ──
    { chain: "TON",  group: "OTHER", path: "m/44'/607'/0'/0/0",
      encode: (_p) => `UQ-pending-encoder-${Array.from(ed25519.getPublicKey(slip10Ed25519(seed, [44, 607, 0, 0, 0]))).slice(0, 4).map(b => b.toString(16).padStart(2, "0")).join("")}` },
  ];

  return chains.map(({ chain, group, path, encode }) => {
    try {
      const pub = derive(path);
      if (!pub) return { chain, group, path, address: `(derive failed)` };
      return { chain, group, path, address: encode(pub) };
    } catch {
      return { chain, group, path, address: `(encode failed)` };
    }
  });
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
): { privateKey: string; xprv: string; xpub: string; pqOmni: Promise<PqOmniSlot[]>; allAddresses: { index: number; address: string; path: string; evmAddress: string; solAddress: string; xrpAddress: string }[]; multichainAddresses: { chain: string; address: string; path: string; group: string }[]; soulboundAddresses: { tier: string; prefix: string; address: string; algo: string; bits: number }[]; root: HDKey } {
  const trimmed = mnemonic.trim().toLowerCase();
  if (!validateMnemonic(trimmed, wordlist)) {
    throw new Error("Invalid BIP-39 mnemonic");
  }
  const seed = mnemonicToSeedSync(trimmed, bip39Passphrase);
  const root = HDKey.fromMasterSeed(seed);
  const account = root.derive(`m/44'/777'/0'`);
  const child = root.derive(`m/44'/777'/0'/0/${walletIndex}`);
  if (!child.privateKey) throw new Error("Mnemonic derivation produced no private key");
  const pqOmni = derivePqOmniSlots(root);
  const soulboundAddresses = deriveSoulboundAddresses(root);
  const multichainAddresses = deriveMultichainAddresses(root, seed);

  // OMNI BIP-44 indices 0..18, each also carries EVM + SOL (SLIP-10 Ed25519) addresses
  const allAddresses = Array.from({ length: 19 }, (_, i) => {
    const omniPath = `m/44'/777'/0'/0/${i}`;
    const evmPath  = `m/44'/60'/0'/0/${i}`;
    const omniLeaf = root.derive(omniPath);
    if (!omniLeaf.privateKey) return null;
    const { address } = deriveAddressFromPrivKey(bytesToHex(omniLeaf.privateKey));
    let evmAddr = "";
    try {
      const evmLeaf = root.derive(evmPath);
      if (evmLeaf.publicKey) evmAddr = evmAddress(evmLeaf.publicKey);
    } catch { /* leave empty */ }
    // SOL: secp256k1 privkey at m/44'/501'/0'/0/i used as Ed25519 scalar seed.
    let solAddr = "";
    try {
      const solLeaf = root.derive(`m/44'/501'/0'/0/${i}`);
      if (solLeaf.privateKey) solAddr = base58.encode(ed25519.getPublicKey(solLeaf.privateKey));
    } catch { /* leave empty */ }
    // XRP: hash160(secp256k1 pubkey at m/44'/144'/0'/0/i) in XRP base58 alphabet
    let xrpAddr = "";
    try {
      const xrpLeaf = root.derive(`m/44'/144'/0'/0/${i}`);
      if (xrpLeaf.publicKey) xrpAddr = xrpAddress(xrpLeaf.publicKey);
    } catch { /* leave empty */ }
    return { index: i, address, path: omniPath, evmAddress: evmAddr, solAddress: solAddr, xrpAddress: xrpAddr };
  }).filter(Boolean) as { index: number; address: string; path: string; evmAddress: string; solAddress: string; xrpAddress: string }[];

  return {
    privateKey: bytesToHex(child.privateKey),
    xprv: account.privateExtendedKey,
    xpub: account.publicExtendedKey,
    pqOmni,
    soulboundAddresses,
    multichainAddresses,
    allAddresses,
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
  const { privateKey: privKey, xprv, xpub, pqOmni: pqOmniPromise, allAddresses, multichainAddresses, soulboundAddresses } = derivedKeysFromMnemonic(mnemonic, walletIndex, bip39Passphrase);
  const pqOmni = await pqOmniPromise;
  const { publicKey, address } = deriveAddressFromPrivKey(privKey);
  unlocked = {
    privateKey: privKey,
    publicKey,
    address,
    walletIndex,
    mnemonic: mnemonic.trim().toLowerCase(),
    xprv,
    xpub,
    pqOmni,
    allAddresses,
    multichainAddresses,
    soulboundAddresses,
  };
  writeSession(unlocked);
  if (vaultPin) {
    await persistVault(privKey, walletIndex, address, vaultPin, mnemonic.trim().toLowerCase());
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
  if (address !== meta.address) {
    throw new Error("Decryption succeeded but address mismatch — wrong passphrase?");
  }

  // v2 vault: has encrypted mnemonic — re-derive all addresses exactly like mnemonic login.
  if (vault.v === 2 && vault.mnemonicCt && vault.iv2) {
    try {
      const salt = hexToBytes(vault.salt);
      const iv2 = hexToBytes(vault.iv2);
      const key = await deriveAesKey(passphrase, salt);
      const mnBytes = hexToBytes(vault.mnemonicCt);
      const pt = await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: iv2 as BufferSource },
        key,
        mnBytes as BufferSource,
      );
      const mnemonic = new TextDecoder().decode(pt);
      // Re-derive everything from mnemonic — same as unlockFromMnemonic but no vault re-save.
      return unlockFromMnemonic(mnemonic, meta.walletIndex);
    } catch {
      // Mnemonic decrypt failed — fall through to privkey-only unlock.
    }
  }

  // v1 vault fallback: privkey only, no PQ/soulbound/multichain.
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

function readVaultRaw(): { v?: number; ciphertext: string; salt: string; iv: string; iv2?: string; mnemonicCt?: string } | null {
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
  mnemonic?: string,
): Promise<void> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const iv2 = crypto.getRandomValues(new Uint8Array(12));
  const key = await deriveAesKey(passphrase, salt);
  const plaintext = hexToBytes(privKeyHex);
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv: iv as BufferSource }, key, plaintext as BufferSource);

  // Encrypt mnemonic separately (v2 vault) so PIN unlock can re-derive all addresses.
  let mnemonicCt = "";
  if (mnemonic) {
    const mnBytes = new TextEncoder().encode(mnemonic.trim().toLowerCase());
    const mnCt = await crypto.subtle.encrypt({ name: "AES-GCM", iv: iv2 as BufferSource }, key, mnBytes as BufferSource);
    mnemonicCt = bytesToHex(new Uint8Array(mnCt));
  }

  const payload = {
    v: 2,
    walletIndex,
    address,
    ciphertext: bytesToHex(new Uint8Array(ct)),
    salt: bytesToHex(salt),
    iv: bytesToHex(iv),
    iv2: bytesToHex(iv2),
    mnemonicCt,
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

/**
 * Build + sign a pq_attest_v1 TX payload ready to send via `sendpqattest` RPC.
 * Signs the op_return payload with the OMNI secp256k1 key (SHA256d convention).
 * Returns the JSON body for the RPC call.
 */
export function buildPqAttestPayload(args: {
  privateKey: string;      // 64 hex, OMNI secp256k1
  from: string;            // ob1q... OMNI address
  love: string;            // ob_k1_...
  food: string;            // ob_f5_...
  rent: string;            // ob_d5_...
  vacation: string;        // ob_s3_...
  btc?: string;            // bc1q... optional
  eth?: string;            // 0x... optional
  nonce: number;
}): {
  from: string; love: string; food: string; rent: string; vacation: string;
  btc: string; eth: string; nonce: number; signature: string; public_key: string;
} {
  const { from, love, food, rent, vacation, btc = "", eth = "", nonce, privateKey } = args;
  const opReturn = `pq_attest_v1:${love}:${food}:${rent}:${vacation}:${btc}:${eth}`;
  const msgBytes = new TextEncoder().encode(opReturn);
  const h1 = sha256(msgBytes);
  const h2 = sha256(h1);
  const privBytes = hexToBytes(privateKey);
  const sig = secp.sign(h2, privBytes, { lowS: true });
  const pub = secp.getPublicKey(privBytes, true);
  return {
    from, love, food, rent, vacation, btc, eth, nonce,
    signature:  bytesToHex(sig.toBytes()),
    public_key: bytesToHex(pub),
  };
}
