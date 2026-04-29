/**
 * use-names.ts — global cache + React hooks for ENS-style name resolution.
 *
 * Two questions to answer:
 *
 *   useNameForAddress(addr)   →  the user's *primary* name for that address
 *                                 ("savacazan.omnibus") or null if no name owns it.
 *   useNamesOwnedBy(addr)     →  the full list of names that resolve to `addr`,
 *                                 used by WalletPage so the user can pick which
 *                                 one is "primary".
 *
 * The chain has `reverseresolvename` — but it returns a single name (the first
 * one the registry happens to find). For a real "I own 10 names, here's my
 * Twitter handle" experience we filter `listnames` client-side and let the user
 * pick a primary that gets cached in localStorage. The chain is the source of
 * truth for ownership; the choice of which one to *display* is per-browser.
 */

import { useEffect, useState } from "react";
import OmniBusRpcClient from "./rpc-client";

const rpc = new OmniBusRpcClient();

const PRIMARY_LS_PREFIX = "omnibus:primary-name:";
const MAX_NAMES_PER_WALLET = 10;

export type DnsEntry = {
  name: string;
  tld: string;
  fullLabel: string;
  address: string;
  registeredAtBlock: number;
  expiresAtBlock: number;
};

// ── Global cache ──────────────────────────────────────────────────────────
//
// Resolved names rarely change (registration/transfer is on-chain). One fetch
// per address per session is plenty — Header pill + every panel that shows
// the same address all hit the cache after the first network round-trip.

const namesByAddress = new Map<string, DnsEntry[]>();
const inflight = new Map<string, Promise<DnsEntry[]>>();
const subscribers = new Set<() => void>();
let allEntriesPromise: Promise<DnsEntry[]> | null = null;

function notify() { subscribers.forEach((cb) => cb()); }

async function loadAllEntries(): Promise<DnsEntry[]> {
  if (allEntriesPromise) return allEntriesPromise;
  allEntriesPromise = (async () => {
    try {
      const r = (await rpc.request_raw("listnames", [])) as { entries?: DnsEntry[] };
      const entries = r?.entries ?? [];
      // Re-bucket by address so subsequent useNamesOwnedBy() calls are O(1).
      namesByAddress.clear();
      for (const e of entries) {
        const list = namesByAddress.get(e.address) ?? [];
        list.push(e);
        namesByAddress.set(e.address, list);
      }
      notify();
      return entries;
    } catch {
      return [];
    } finally {
      // Keep the cache, but allow another refresh to fire later.
      setTimeout(() => { allEntriesPromise = null; }, 30_000);
    }
  })();
  return allEntriesPromise;
}

/** Force a fresh fetch — call after a successful registername. */
export function refreshNameCache() {
  allEntriesPromise = null;
  inflight.clear();
  loadAllEntries();
}

/** What the user picked as their public-facing name for `addr`. */
export function getPrimaryName(addr: string): string | null {
  if (!addr) return null;
  try { return localStorage.getItem(PRIMARY_LS_PREFIX + addr); } catch { return null; }
}

export function setPrimaryName(addr: string, fullLabel: string | null) {
  try {
    if (fullLabel) localStorage.setItem(PRIMARY_LS_PREFIX + addr, fullLabel);
    else localStorage.removeItem(PRIMARY_LS_PREFIX + addr);
  } catch {}
  notify();
}

// ── Hooks ─────────────────────────────────────────────────────────────────

/**
 * Returns the display name for an address, or null if none registered.
 * Priority:
 *   1. user-chosen primary (localStorage)
 *   2. first active name owned by the address (alphabetical, .omnibus first)
 */
export function useNameForAddress(addr: string | null | undefined): string | null {
  const [, force] = useState(0);

  useEffect(() => {
    const cb = () => force((n) => n + 1);
    subscribers.add(cb);
    if (addr && !namesByAddress.has(addr) && !allEntriesPromise) loadAllEntries();
    return () => { subscribers.delete(cb); };
  }, [addr]);

  if (!addr) return null;

  const primary = getPrimaryName(addr);
  if (primary) return primary;

  const list = namesByAddress.get(addr);
  if (!list || list.length === 0) return null;

  // Stable default: .omnibus before .arbitraje, then alphabetical.
  const sorted = [...list].sort((a, b) => {
    if (a.tld !== b.tld) return a.tld === "omnibus" ? -1 : 1;
    return a.name.localeCompare(b.name);
  });
  return sorted[0].fullLabel;
}

/**
 * All active names that resolve to this address. Capped at
 * MAX_NAMES_PER_WALLET so the UI doesn't have to handle pathological cases.
 */
export function useNamesOwnedBy(addr: string | null | undefined): DnsEntry[] {
  const [, force] = useState(0);

  useEffect(() => {
    const cb = () => force((n) => n + 1);
    subscribers.add(cb);
    if (addr && !namesByAddress.has(addr) && !allEntriesPromise) loadAllEntries();
    return () => { subscribers.delete(cb); };
  }, [addr]);

  if (!addr) return [];
  const list = namesByAddress.get(addr) ?? [];
  return list.slice(0, MAX_NAMES_PER_WALLET);
}

export { MAX_NAMES_PER_WALLET };
