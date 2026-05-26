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
import { rpc } from "./rpc-client";
import { subscribe as wsSubscribe } from "./ws-bus";


const PRIMARY_LS_PREFIX = "omnibus:primary-name:";
const MAX_NAMES_PER_WALLET = 10;

export type DnsEntry = {
  name: string;
  tld: string;
  fullLabel: string;
  address: string;
  registeredAtBlock: number;
  expiresAtBlock: number;
  // Phase 2 NS — optional fields, present on Phase-2 nodes via listnames RPC.
  // Older nodes omit them; UI must treat undefined as "legacy entry".
  category?: string;        // "personal" | "bank" | "gov" | "mil" | "fin" | "edu" | "org" | "dev" | "trading" | "none"
  preferred_slot?: number;  // 0 = primary; 1..4 = ML-DSA / Falcon / Dilithium / SLH-DSA
  registered_years?: number;
};

/**
 * Maps a TLD to its rendering color + emoji + category fallback. UI-only —
 * the source of truth for category lives on-chain in the `category` field.
 * When category is absent (older node), we infer from TLD as a best-effort.
 */
export const TLD_THEME: Record<string, { color: string; emoji: string; categoryHint: string }> = {
  omnibus:   { color: "text-mempool-blue",  emoji: "👤", categoryHint: "personal" },
  arbitraje: { color: "text-amber-400",     emoji: "📈", categoryHint: "trading" },
  quantum:   { color: "text-purple-400",    emoji: "⚛",  categoryHint: "personal" },
  bank:      { color: "text-emerald-400",   emoji: "🏦", categoryHint: "bank" },
  gov:       { color: "text-red-400",       emoji: "🏛", categoryHint: "gov" },
  mil:       { color: "text-orange-400",    emoji: "⚔",  categoryHint: "mil" },
  fin:       { color: "text-teal-400",      emoji: "💼", categoryHint: "fin" },
  edu:       { color: "text-sky-400",       emoji: "🎓", categoryHint: "edu" },
  org:       { color: "text-lime-400",      emoji: "🤝", categoryHint: "org" },
  dev:       { color: "text-fuchsia-400",   emoji: "💻", categoryHint: "dev" },
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

// Auto-refresh when node broadcasts a name_registered or name_renewed WS event
wsSubscribe("name_registered", () => { refreshNameCache(); });
wsSubscribe("name_renewed",    () => { refreshNameCache(); });

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

  // Stable default: institutional categories first (gov/mil/bank/fin pin
  // identity to a regulated entity), then quantum (premium personal),
  // then omnibus (default), then niche (edu/org/dev), then arbitraje last.
  const TLD_PRIORITY: Record<string, number> = {
    gov: 0, mil: 1, bank: 2, fin: 3,
    quantum: 4, omnibus: 5,
    edu: 6, org: 7, dev: 8,
    arbitraje: 9,
  };
  const sorted = [...list].sort((a, b) => {
    const pa = TLD_PRIORITY[a.tld] ?? 99;
    const pb = TLD_PRIORITY[b.tld] ?? 99;
    if (pa !== pb) return pa - pb;
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

/**
 * Phase 2 — like useNameForAddress but returns the FULL DnsEntry (with
 * category, preferred_slot, registered_years) for the chosen name.
 * Useful when the UI wants to render a category badge alongside the name.
 */
export function useEntryForAddress(addr: string | null | undefined): DnsEntry | null {
  const [, force] = useState(0);

  useEffect(() => {
    const cb = () => force((n) => n + 1);
    subscribers.add(cb);
    if (addr && !namesByAddress.has(addr) && !allEntriesPromise) loadAllEntries();
    return () => { subscribers.delete(cb); };
  }, [addr]);

  if (!addr) return null;
  const list = namesByAddress.get(addr);
  if (!list || list.length === 0) return null;

  // Honor user-set primary if one exists; else use the same priority order
  // as useNameForAddress.
  const primaryLabel = getPrimaryName(addr);
  if (primaryLabel) {
    const found = list.find((e) => e.fullLabel === primaryLabel);
    if (found) return found;
  }
  const TLD_PRIORITY: Record<string, number> = {
    gov: 0, mil: 1, bank: 2, fin: 3,
    quantum: 4, omnibus: 5,
    edu: 6, org: 7, dev: 8,
    arbitraje: 9,
  };
  const sorted = [...list].sort((a, b) => {
    const pa = TLD_PRIORITY[a.tld] ?? 99;
    const pb = TLD_PRIORITY[b.tld] ?? 99;
    if (pa !== pb) return pa - pb;
    return a.name.localeCompare(b.name);
  });
  return sorted[0];
}

export { MAX_NAMES_PER_WALLET };

// ── Phase 2 lifecycle: expiry warnings ────────────────────────────────────
//
// Surfaces names that are about to expire so the UI can nudge the owner to
// renew. Backed by `ns_expiringSoon` RPC. Auto-refresh every 60s — expiry
// is on the scale of months, so we don't need tighter polling.

/// One entry from `ns_expiringSoon` — a name owned by the queried address
/// that's within `blocks_threshold` blocks of expiry (or already in grace).
export type ExpiringNameEntry = {
  name: string;
  tld: string;
  fullLabel: string;
  expiresAtBlock: number;
  blocks_remaining: number;
  estimated_days_remaining: number;
  registered_years: number;
  in_grace: boolean;
};

/**
 * Returns the list of the user's names that expire within `blocks_threshold`
 * blocks (default ~30 days at the canonical 10s block time). Re-fetches
 * every 60s. Empty array when the address is null, the RPC isn't shipped on
 * this node, or no names match the threshold.
 *
 * Used by:
 *   - WalletConnectButton header pill — shows a warning badge if length > 0
 *   - NamesPage — drives the "expires in N days" badge per-row
 */
export function useExpiringNames(
  addr: string | null | undefined,
  blocksThreshold?: number,
): ExpiringNameEntry[] {
  const [list, setList] = useState<ExpiringNameEntry[]>([]);

  useEffect(() => {
    if (!addr) {
      setList([]);
      return;
    }
    let cancelled = false;
    const tick = async () => {
      try {
        const params: any[] = blocksThreshold == null
          ? [addr]
          : [addr, blocksThreshold];
        const r = (await rpc.request_raw("ns_expiringSoon", params)) as {
          entries?: ExpiringNameEntry[];
        };
        if (!cancelled) setList(r?.entries ?? []);
      } catch {
        // Older nodes without ns_expiringSoon — silently treat as "nothing
        // expiring", same UX as a fully renewed wallet.
        if (!cancelled) setList([]);
      }
    };
    tick();
    const id = setInterval(tick, 60_000);
    return () => { cancelled = true; clearInterval(id); };
  }, [addr, blocksThreshold]);

  return list;
}

/**
 * Helper: estimate days remaining until a DnsEntry expires, given the
 * current chain tip block. Returns Infinity if expiresAtBlock is missing
 * or already passed (callers should also check `in_grace` separately).
 * Block time = 10s, so 1 day = 8640 blocks.
 */
export function daysUntilExpiry(
  entry: { expiresAtBlock: number },
  currentBlock: number,
): number {
  if (!entry.expiresAtBlock || entry.expiresAtBlock <= currentBlock) return 0;
  return Math.floor((entry.expiresAtBlock - currentBlock) / 8640);
}
