/**
 * use-global-balance.ts — single source of truth for "how much OMNI do I have?"
 *
 * Before this hook, every page asked the chain a different question:
 *   - StakePage:    getstake + getbalance
 *   - ExchangePage: exchange_getBalances (internal sub-ledger, not chain truth)
 *   - WalletPage:   getbalance
 *   - Header:       useBlockchainStore.balance (one-shot, never refreshed)
 *
 * Result: stake page said "100 staked", exchange page said "0", wallet header
 * said something stale from page load. The user (correctly) asked: "where IS
 * my money?". This hook answers it.
 *
 * Returns four numbers in SAT (1 OMNI = 1e9 SAT):
 *   wallet     — chain confirmed balance (`getbalance`)
 *   staked     — sum of `getstake.stakes[].amount_sat` (locked, earning votes)
 *   in_orders  — exchange sub-ledger "locked in resting orders" (`exchange_getBalances.locked`)
 *   available  — wallet - staked - in_orders   (what user can actually spend NOW)
 *
 * Polls every 8 s while a wallet is connected. Pauses when no wallet. All
 * consumers subscribe to the SAME snapshot so the number is identical across
 * Header / Exchange / Stake / Wallet tabs.
 */

import { useEffect, useState } from "react";
import { rpc } from "../clients/rpc-client";
import { useWallet } from "./use-wallet";
import { useActiveSlot } from "./use-active-slot";
import { SAT_PER_OMNI } from "../../utils/fmt";

const POLL_MS = 8_000;

export type StakeLockEntry = {
  id: number;
  amount_sat: number;
  lock_blocks: number;
  started_at_block: number;
  days_locked: number;
  status: "active" | "unbonding" | "completed";
  unbonding_until?: number;
};

export type GlobalBalance = {
  address: string;
  wallet_sat: number;
  staked_sat: number;
  in_orders_sat: number;
  available_sat: number;
  /** Per-stake breakdown so callers can show "Lock duration" / unlock block. */
  stakes: StakeLockEntry[];
  /** Block height at refresh time. Lets UI compute "X blocks remaining". */
  block_height: number;
  /** Last successful refresh (ms epoch). 0 = never fetched. */
  fetched_at: number;
  /** True while a fetch is in-flight (first load). */
  loading: boolean;
  /** Last error message (network / RPC). null when healthy. */
  error: string | null;
};

const EMPTY: GlobalBalance = {
  address: "",
  wallet_sat: 0,
  staked_sat: 0,
  in_orders_sat: 0,
  available_sat: 0,
  stakes: [],
  block_height: 0,
  fetched_at: 0,
  loading: false,
  error: null,
};

// ── Singleton snapshot + subscriber set ────────────────────────────────
// We share ONE in-memory state across all hook instances so every page
// reads the same number. React's useSyncExternalStore would be more
// idiomatic but we already mix useState/useEffect everywhere; this stays
// consistent with the existing wallet-keystore pattern.

let current: GlobalBalance = EMPTY;
const subscribers = new Set<(s: GlobalBalance) => void>();

function emit(next: GlobalBalance) {
  current = next;
  subscribers.forEach((cb) => cb(next));
}

let pollTimer: ReturnType<typeof setInterval> | null = null;
let activeAddress = "";

type WalletSummaryRpc = {
  address: string;
  height?: number;
  wallet_sat?: number;
  staked_sat?: number;
  in_orders_sat?: number;
  available_sat?: number;
  stakes?: StakeLockEntry[];
};

async function refreshOnce(address: string): Promise<void> {
  if (!address) return;
  try {
    // One atomic RPC: getwalletsummary returns wallet / staked / in_orders /
    // available + per-stake list under a single chain mutex. Replaces the
    // previous 5-RPC fan-out (getBalance + getstake + exchange_getBalances
    // + getBlockCount + exchange_getUserOrders) that suffered from two bugs:
    //   1) rpc.getBalance() called WITHOUT an address argument returned the
    //      balance for the unlocked wallet's primary address (slot 0), not
    //      the requested `address`. So the snapshot returned 0 wallet_sat
    //      for any non-zero slot while staked/orders still showed correctly.
    //   2) Five independent RPCs could observe different chain states if a
    //      block landed mid-fetch — caller saw "wallet=0 staked=212" for a
    //      single tick which the UI rendered as a glaring inconsistency.
    const summary = (await rpc
      .getWalletSummary(address)
      .catch(() => null)) as WalletSummaryRpc | null;

    if (!summary) {
      // Fall through to legacy fan-out only if the new RPC isn't reachable.
      // Old nodes (pre 2026-05-13) don't ship getwalletsummary.
      const balRaw = await rpc.getAddressBalance(address).catch(() => null);
      const wallet_sat = balRaw?.balance ?? 0;
      emit({
        address,
        wallet_sat,
        staked_sat: 0,
        in_orders_sat: 0,
        available_sat: wallet_sat,
        stakes: [],
        block_height: 0,
        fetched_at: Date.now(),
        loading: false,
        error: "getwalletsummary unavailable (legacy node?)",
      });
      return;
    }

    const wallet_sat    = Number(summary.wallet_sat    ?? 0);
    const staked_sat    = Number(summary.staked_sat    ?? 0);
    const in_orders_sat = Number(summary.in_orders_sat ?? 0);
    const available_sat = Number(
      summary.available_sat ?? Math.max(0, wallet_sat - staked_sat - in_orders_sat),
    );

    const stakes: StakeLockEntry[] = (summary.stakes ?? [])
      .filter((s) => s.status === "active" || s.status === "unbonding")
      .map((s) => ({
        id: Number(s.id) || 0,
        amount_sat: Number(s.amount_sat) || 0,
        lock_blocks: Number(s.lock_blocks) || 0,
        started_at_block: Number(s.started_at_block) || 0,
        days_locked: Number(s.days_locked) || 0,
        status: s.status,
        unbonding_until: s.unbonding_until ? Number(s.unbonding_until) : undefined,
      }));

    emit({
      address,
      wallet_sat,
      staked_sat,
      in_orders_sat,
      available_sat,
      stakes,
      block_height: Number(summary.height ?? 0),
      fetched_at: Date.now(),
      loading: false,
      error: null,
    });
  } catch (err) {
    emit({
      ...current,
      address,
      loading: false,
      error: err instanceof Error ? err.message : String(err),
    });
  }
}

function startPolling(address: string) {
  if (activeAddress === address && pollTimer) return; // already polling this addr
  stopPolling();
  activeAddress = address;
  emit({ ...EMPTY, address, loading: true });
  refreshOnce(address);
  pollTimer = setInterval(() => refreshOnce(address), POLL_MS);
}

function stopPolling() {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
  activeAddress = "";
  emit(EMPTY);
}

/**
 * Subscribe a React component to the global balance. Returns the latest
 * snapshot and re-renders on every refresh. Automatically starts/stops the
 * background poll based on whether any wallet is connected.
 */
export function useGlobalBalance(): GlobalBalance {
  const wallet = useWallet();
  const slot = useActiveSlot();
  // Resolve the address for the SELECTED BIP-44 slot rather than the
  // unlock-session primary. When the user picks slot #7 in the Header
  // dropdown, this hook now switches its polling to that address so
  // every page that subscribes (Wallet / Stake / Trade / Header pill)
  // immediately reflects slot #7's balance.
  const slotRow = wallet?.allAddresses?.find((a) => a.index === slot);
  const address = slotRow?.address ?? wallet?.address ?? "";
  const [snap, setSnap] = useState<GlobalBalance>(current);

  useEffect(() => {
    subscribers.add(setSnap);
    return () => {
      subscribers.delete(setSnap);
    };
  }, []);

  useEffect(() => {
    if (address) startPolling(address);
    else stopPolling();
  }, [address]);

  return snap;
}

/**
 * Force an immediate refresh (e.g. after the user submits a stake / order).
 * Pages that mutate balance should call this so the global view updates
 * without waiting for the next 8 s tick.
 */
export function refreshGlobalBalance(): void {
  if (activeAddress) refreshOnce(activeAddress);
}

/** Format SAT → "1.2345" OMNI string (4 decimals). */
export function formatOmni(sat: number): string {
  return (sat / SAT_PER_OMNI).toFixed(4);
}
