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
import OmniBusRpcClient from "./rpc-client";
import { useWallet } from "./use-wallet";

const rpc = new OmniBusRpcClient();
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

async function refreshOnce(address: string): Promise<void> {
  if (!address) return;
  try {
    const [balRaw, stakeRaw, exchRaw, heightRaw, openOrdersRaw] = await Promise.all([
      rpc.getBalance().catch(() => 0),
      rpc.request_raw("getstake", [{ address }]).catch(() => null),
      rpc.exchangeGetBalances(address).catch(() => []),
      rpc.getBlockCount().catch(() => 0),
      rpc.request_raw("exchange_getUserOrders", [{ trader: address }]).catch(() => []),
    ]);

    const wallet_sat = Number(balRaw) || 0;
    const stakesRaw = (stakeRaw as { stakes?: StakeLockEntry[] } | null)?.stakes ?? [];
    const stakes: StakeLockEntry[] = stakesRaw
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
    const staked_sat = stakes.reduce((s, e) => s + e.amount_sat, 0);

    // Prefer chain-derived "locked in active OMNI sell orders" because the
    // internal exchange sub-ledger (`exchange_getBalances.locked`) only counts
    // funds that were deposited-into-exchange, not on-chain reservations.
    const openOrders = Array.isArray(openOrdersRaw) ? openOrdersRaw : [];
    let in_orders_sat = 0;
    for (const o of openOrders as Array<{ side?: string; remaining?: number; status?: string }>) {
      const status = String(o.status ?? "");
      if (status !== "active" && status !== "partial") continue;
      if (String(o.side ?? "") === "sell") {
        in_orders_sat += Number(o.remaining) || 0;
      }
    }
    if (in_orders_sat === 0) {
      const omniRow = (exchRaw || []).find((b) => b.token === "OMNI");
      in_orders_sat = Number(omniRow?.locked ?? 0) || 0;
    }

    const available_sat = Math.max(0, wallet_sat - staked_sat - in_orders_sat);

    emit({
      address,
      wallet_sat,
      staked_sat,
      in_orders_sat,
      available_sat,
      stakes,
      block_height: Number(heightRaw) || 0,
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
  const address = wallet?.address ?? "";
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
  return (sat / 1e9).toFixed(4);
}
