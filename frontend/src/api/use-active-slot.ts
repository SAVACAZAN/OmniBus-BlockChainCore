/**
 * use-active-slot.ts — global "which BIP-44 slot is the user actively
 * transacting from?" state.
 *
 * Background: a single mnemonic derives 19 OMNI addresses at indices 0..18
 * (m/44'/777'/0'/0/i). Each also carries a sibling EVM (m/44'/60'/...),
 * SOL (m/44'/501'/...) and XRP (m/44'/144'/...) address. Before this hook
 * every page hardcoded `allAddresses[0]` for trading, sends, etc. — which
 * meant the user could see 19 wallets in MultiWalletBalances but only ever
 * transacted from slot 0.
 *
 * This singleton holds the currently-active slot index. Header has a
 * dropdown that writes here; Trade / Wallet / Stake / Send all read from
 * it. Persists across reloads in sessionStorage so refresh doesn't reset
 * to slot 0 if the user picked another.
 *
 * Note: this does NOT control which mnemonic unlocks the wallet — that's
 * `useWallet()`. This only chooses which BIP-44 child key under the same
 * mnemonic is "primary" for current actions. All 19 are always derived
 * from the same seed; switching slot is free (no signing).
 */

import { useEffect, useState } from "react";

const STORAGE_KEY = "omnibus.activeSlot";
const DEFAULT_SLOT = 0;
const MAX_SLOT = 18; // we derive 19 (0..18) in wallet-keystore.ts

function readStored(): number {
  if (typeof sessionStorage === "undefined") return DEFAULT_SLOT;
  const raw = sessionStorage.getItem(STORAGE_KEY);
  if (raw === null) return DEFAULT_SLOT;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0 || n > MAX_SLOT) return DEFAULT_SLOT;
  return n;
}

let current: number = readStored();
const subscribers = new Set<(slot: number) => void>();

export function getActiveSlot(): number {
  return current;
}

export function setActiveSlot(slot: number): void {
  if (!Number.isFinite(slot) || slot < 0 || slot > MAX_SLOT) return;
  if (slot === current) return;
  current = slot;
  if (typeof sessionStorage !== "undefined") {
    sessionStorage.setItem(STORAGE_KEY, String(slot));
  }
  subscribers.forEach((cb) => cb(slot));
}

export function subscribeActiveSlot(cb: (slot: number) => void): () => void {
  subscribers.add(cb);
  return () => {
    subscribers.delete(cb);
  };
}

/**
 * React hook — returns the current active slot and re-renders on change.
 * Components that need addresses (PlaceOrderForm, send dialog, stake page)
 * should pick `u.allAddresses[useActiveSlot()]` instead of `[0]`.
 */
export function useActiveSlot(): number {
  const [slot, setSlot] = useState<number>(current);
  useEffect(() => {
    return subscribeActiveSlot(setSlot);
  }, []);
  return slot;
}

export const SLOT_COUNT = MAX_SLOT + 1; // 19
