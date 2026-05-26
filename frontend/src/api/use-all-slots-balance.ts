/**
 * use-all-slots-balance.ts — aggregate balance across ALL 19 BIP-44 slots.
 *
 * Where `use-global-balance` answers "what is happening on the ACTIVE slot",
 * this hook answers "how much do I have total across the whole wallet".
 * Refreshed every 12 s while a wallet is unlocked. All consumers share one
 * snapshot so Header / Wallet / Exchange show the same numbers.
 *
 * Returns OMNI totals broken down the same way as `use-global-balance`
 * (wallet / staked / in_orders / available) plus a per-slot table the
 * Wallet detail card can render directly.
 *
 * EVM tokens are NOT included here — that lives in MultiWalletBalances and
 * uses Promise.allSettled against many external RPCs which is slow enough
 * that polling it from a header chip would make every page sluggish.
 * Wallet's aggregate card can compose this hook + MultiWalletBalances.
 */

import { useEffect, useState } from "react";
import { rpc } from "./rpc-client";
import { useWallet } from "./use-wallet";

const POLL_MS = 12_000;

export type SlotSnapshot = {
  index: number;
  address: string;
  wallet_sat: number;
  staked_sat: number;
  in_orders_sat: number;
  available_sat: number;
};

export type AllSlotsSnapshot = {
  slots: SlotSnapshot[];
  total_wallet_sat: number;
  total_staked_sat: number;
  total_in_orders_sat: number;
  total_available_sat: number;
  height: number;
  fetched_at: number;
  loading: boolean;
  error: string | null;
};

const EMPTY: AllSlotsSnapshot = {
  slots: [],
  total_wallet_sat: 0,
  total_staked_sat: 0,
  total_in_orders_sat: 0,
  total_available_sat: 0,
  height: 0,
  fetched_at: 0,
  loading: false,
  error: null,
};

let current: AllSlotsSnapshot = EMPTY;
const subscribers = new Set<(s: AllSlotsSnapshot) => void>();

function emit(next: AllSlotsSnapshot) {
  current = next;
  subscribers.forEach((cb) => cb(next));
}

let pollTimer: ReturnType<typeof setInterval> | null = null;
let activeAddrs: string[] = [];

type WalletSummaryResp = {
  wallet_sat?: number;
  staked_sat?: number;
  in_orders_sat?: number;
  available_sat?: number;
  height?: number;
};

async function fetchSlotSummary(address: string): Promise<WalletSummaryResp> {
  try {
    const r = (await rpc.request_raw("getwalletsummary", [{ address }])) as WalletSummaryResp;
    return r ?? {};
  } catch {
    return {};
  }
}

async function refreshAll(addrs: { index: number; address: string }[]): Promise<void> {
  if (addrs.length === 0) return;
  const results = await Promise.all(addrs.map((a) => fetchSlotSummary(a.address)));

  let total_wallet = 0;
  let total_staked = 0;
  let total_orders = 0;
  let total_avail = 0;
  let height = 0;

  const slots: SlotSnapshot[] = results.map((r, i) => {
    const addr = addrs[i];
    const wallet_sat = Number(r.wallet_sat ?? 0);
    const staked_sat = Number(r.staked_sat ?? 0);
    const in_orders_sat = Number(r.in_orders_sat ?? 0);
    const available_sat = Number(r.available_sat ?? Math.max(0, wallet_sat - staked_sat - in_orders_sat));
    total_wallet += wallet_sat;
    total_staked += staked_sat;
    total_orders += in_orders_sat;
    total_avail += available_sat;
    if (r.height && r.height > height) height = Number(r.height);
    return {
      index: addr.index,
      address: addr.address,
      wallet_sat,
      staked_sat,
      in_orders_sat,
      available_sat,
    };
  });

  emit({
    slots,
    total_wallet_sat: total_wallet,
    total_staked_sat: total_staked,
    total_in_orders_sat: total_orders,
    total_available_sat: total_avail,
    height,
    fetched_at: Date.now(),
    loading: false,
    error: null,
  });
}

function startPolling(addrs: { index: number; address: string }[]) {
  const sig = addrs.map((a) => a.address).join(",");
  if (sig === activeAddrs.join(",") && pollTimer) return;
  stopPolling();
  activeAddrs = addrs.map((a) => a.address);
  emit({ ...EMPTY, loading: true });
  refreshAll(addrs);
  pollTimer = setInterval(() => refreshAll(addrs), POLL_MS);
}

function stopPolling() {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
  activeAddrs = [];
  emit(EMPTY);
}

/**
 * Subscribe a React component to the aggregate snapshot across all 19
 * BIP-44 slots. Re-renders every 12 s while wallet is unlocked.
 */
export function useAllSlotsBalance(): AllSlotsSnapshot {
  const wallet = useWallet();
  const [snap, setSnap] = useState<AllSlotsSnapshot>(current);

  useEffect(() => {
    subscribers.add(setSnap);
    return () => {
      subscribers.delete(setSnap);
    };
  }, []);

  useEffect(() => {
    const addrs = (wallet?.allAddresses ?? []).map((a) => ({ index: a.index, address: a.address }));
    if (addrs.length > 0) startPolling(addrs);
    else stopPolling();
  }, [wallet?.address, wallet?.allAddresses?.length]);

  return snap;
}

/** Force immediate refresh. */
export function refreshAllSlots(): void {
  if (activeAddrs.length > 0) {
    const addrs = activeAddrs.map((address, index) => ({ index, address }));
    refreshAll(addrs);
  }
}
