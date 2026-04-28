/**
 * wallet-keystore.ts — minimal in-memory wallet for the Exchange UI.
 *
 * The user pastes a 32-byte hex private key once per session (or imports
 * from Liberty Suite). We derive the compressed pubkey + ob1q address
 * locally and keep them in memory for signing orders. The privkey is NEVER
 * sent to the server. Refresh the page → must re-paste.
 *
 * Future hardening (not in v1):
 *   - AES-encrypt the privkey with a session password, store in
 *     sessionStorage. WebCrypto PBKDF2 → AES-GCM is the natural fit.
 *   - Detect Liberty Suite Named Pipe and request signatures via that
 *     instead of holding the privkey at all.
 */

import { deriveAddressFromPrivKey } from "./exchange-sign";

export type Unlocked = {
  privateKey: string; // 64 hex chars, no 0x
  publicKey: string;  // 66 hex chars compressed
  address: string;    // ob1q…
};

let unlocked: Unlocked | null = null;
const listeners = new Set<() => void>();

function notify() {
  for (const fn of listeners) {
    try { fn(); } catch { /* swallow */ }
  }
}

export function unlockWallet(privKeyHex: string): Unlocked {
  let h = privKeyHex.trim();
  if (h.startsWith("0x")) h = h.slice(2);
  if (h.length !== 64) throw new Error("Private key must be 64 hex chars");
  const { publicKey, address } = deriveAddressFromPrivKey(h);
  unlocked = { privateKey: h, publicKey, address };
  notify();
  return unlocked;
}

export function lockWallet(): void {
  unlocked = null;
  notify();
}

export function getUnlocked(): Unlocked | null {
  return unlocked;
}

export function subscribeWallet(fn: () => void): () => void {
  listeners.add(fn);
  return () => { listeners.delete(fn); };
}

/**
 * Generate a fresh nonce that strictly grows. Server enforces per-address
 * monotonic nonce — if you re-use one, the order is rejected.
 * We use millisecond timestamp; on a fast loop, fall back to ts + counter.
 */
let lastNonce = 0;
export function nextNonce(): number {
  const now = Date.now();
  lastNonce = now > lastNonce ? now : lastNonce + 1;
  return lastNonce;
}
