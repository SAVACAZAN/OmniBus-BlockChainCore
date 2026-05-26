import { useEffect, useState } from "react";
import { getUnlocked, subscribeWallet, deriveSlotKey } from "../../api/wallet-keystore";
import OmniBusRpcClient, { ExchangeBalance } from "../../api/rpc-client";
import { SAT_PER_OMNI, MICRO_PER_USD } from "../../utils/fmt";
import { fetchUsdcBalance, fetchEvmBalance } from "../../api/multichain-balances";
import { useGlobalBalance, formatOmni } from "../../api/use-global-balance";
import { useActiveSlot } from "../../api/use-active-slot";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsOrderbookUpdateEvent } from "../../types";

const rpc = new OmniBusRpcClient();

function dec(token: string) {
  if (token === "OMNI") return 4;
  if (token === "ETH")  return 6;
  return 2;
}

// Fetch wallet on-chain balance (human units)
async function fetchOnChain(token: string, omniAddr: string, evmAddr: string): Promise<number> {
  if (token === "OMNI") {
    try {
      const r = await rpc.request_raw("getbalance", [omniAddr]);
      const sat: number = typeof r === "number" ? r : (r?.balance ?? 0);
      return sat / SAT_PER_OMNI;
    } catch { return 0; }
  }
  if (token === "USDC") {
    const chains = ["SEPOLIA", "BASE_SEPOLIA", "ARB_SEPOLIA", "OP_SEPOLIA", "POLYGON_AMOY", "AVAX_FUJI"];
    const results = await Promise.all(chains.map(c => fetchUsdcBalance(c, evmAddr)));
    let total = 0;
    for (const b of results) if (b) total += Number(b.native);
    return total;
  }
  if (token === "ETH") {
    const b = await fetchEvmBalance("SEPOLIA", evmAddr);
    return b ? Number(b.native) : 0;
  }
  if (token === "LCX") {
    const b = await fetchEvmBalance("LIBERTY", evmAddr);
    return b ? Number(b.native) : 0;
  }
  return 0;
}

interface UserOrder {
  orderId: number;
  side: "buy" | "sell";
  pairId: number;
  price: number;
  amount: number;
  filled: number;
  remaining: number;
  status: "active" | "partial" | "filled" | "cancelled";
}

// Compute tokens locked in open orders for base and quote.
// sell orders → base token locked (remaining sat)
// buy  orders → quote token locked (remaining_sat / price_micro * quote_unit)
//
// For OMNI exchange: amount_sat = base (OMNI), price_micro_usd = USDC per OMNI × 1e6
// quote locked for a buy order = remaining_sat / 1e9 OMNI × price_micro_usd / 1e6 USDC
function computeLockedFromOrders(orders: UserOrder[], base: string, quote: string): Record<string, number> {
  const locked: Record<string, number> = { [base]: 0, [quote]: 0 };
  for (const o of orders) {
    if (o.status !== "active" && o.status !== "partial") continue;
    if (o.side === "sell") {
      // sell order locks base (OMNI sat → human)
      locked[base] = (locked[base] ?? 0) + o.remaining / SAT_PER_OMNI;
    } else {
      // buy order locks quote (USDC): remaining base × price / SAT_PER_OMNI / 1e6 → USDC human
      const quoteLockedRaw = (o.remaining / SAT_PER_OMNI) * (o.price / MICRO_PER_USD);
      locked[quote] = (locked[quote] ?? 0) + quoteLockedRaw;
    }
  }
  return locked;
}

interface Props {
  base: string;
  quote: string;
  exchBalances: ExchangeBalance[];
}

export function TradePairBalances({ base, quote, exchBalances }: Props) {
  const [, tick] = useState(0);
  useEffect(() => subscribeWallet(() => tick(n => n + 1)), []);
  const gb = useGlobalBalance();
  const activeSlot = useActiveSlot();

  const u = getUnlocked();
  // Use the SELECTED slot address (matches what the order will sign with),
  // not the unlock-session primary. Previously omniAddr = u.address always
  // pointed at slot #0 even when the user picked slot #7 — so getwalletsummary
  // polled slot #0 while the order signed from #7, making "In Orders" empty.
  const slotRow = u?.allAddresses?.find(a => a.index === activeSlot);
  const omniAddr = slotRow?.address ?? u?.address ?? "";
  const evmAddr  = slotRow?.evmAddress
    ?? deriveSlotKey(activeSlot)?.evmAddress
    ?? u?.allAddresses?.[0]?.evmAddress
    ?? u?.multichainAddresses?.find(a => a.chain === "ETH")?.address
    ?? "";

  const [walletAmt, setWalletAmt]   = useState<Record<string, number>>({});
  const [fetching, setFetching]     = useState<Record<string, boolean>>({});
  const [userOrders, setUserOrders] = useState<UserOrder[]>([]);

  // Re-fetch on-chain balances when pair or wallet changes
  useEffect(() => {
    if (!u) return;
    const assets = Array.from(new Set([base, quote]));
    setFetching(Object.fromEntries(assets.map(t => [t, true])));
    for (const token of assets) {
      fetchOnChain(token, omniAddr, evmAddr).then(amt => {
        setWalletAmt(prev => ({ ...prev, [token]: amt }));
        setFetching(prev => ({ ...prev, [token]: false }));
      });
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [base, quote, omniAddr, evmAddr]);

  // Fetch user open orders to compute "In Orders" reliably
  // (backend's locked field can be 0 if address format mismatch)
  useEffect(() => {
    if (!omniAddr) return;
    let cancelled = false;
    const load = async () => {
      try {
        const res = await rpc.request_raw("exchange_getUserOrders", [{ trader: omniAddr }]);
        if (!cancelled && Array.isArray(res)) setUserOrders(res as UserOrder[]);
      } catch { /* ignore */ }
    };
    load();
    // Refresh when orderbook changes (fills affect in-orders balances).
    const unsub = wsSubscribe<WsOrderbookUpdateEvent>("orderbook_update", () => {
      void load();
    });
    const id = setInterval(load, 30_000);
    return () => { cancelled = true; clearInterval(id); unsub(); };
  }, [omniAddr]);

  if (!u) return null;

  // Compute locked from chain orders. This is the SINGLE source of truth.
  // We used to fall back to `exchBalances.locked` (paper-mode sub-ledger)
  // when ordersLocked was 0, but that surfaced stale paper-trading balances
  // as "in orders" — e.g. user has 25.70 USDC on Sepolia, no buy order open,
  // yet the panel showed "USDC: free 0.00 / in orders 25.70 / total 25.70".
  // Paper-mode balances belong to a different ledger and should never count
  // against the real wallet's "available" calculation.
  const ordersLocked = computeLockedFromOrders(userOrders, base, quote);

  const inOrders = (token: string): number => ordersLocked[token] ?? 0;
  // exchBalances kept in scope for the paper-mode debug strip below (no
  // longer wired into the live `in orders` math). We mark it as used so
  // TypeScript doesn't complain about the prop being dropped.
  void exchBalances;

  const assets = Array.from(new Set([base, quote]));

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg p-3 mb-3">
      <div className="text-[9px] uppercase tracking-wider text-mempool-text-dim mb-2.5 flex items-center gap-1.5">
        <span className="text-mempool-text font-semibold">Balance</span>
        <span className="text-mempool-border">·</span>
        <span>Market Taker</span>
        {userOrders.filter(o => o.status === "active" || o.status === "partial").length > 0 && (
          <span className="ml-auto text-yellow-400/70 text-[8px]">
            {userOrders.filter(o => o.status === "active" || o.status === "partial").length} open orders
          </span>
        )}
      </div>

      {/* Lock details (only when there are active stakes) — kept here for
          context; the per-token row below already exposes Free/Staked/Orders/
          Total so we don't need a separate breakdown banner anymore. The
          earlier 4-column strip was duplicating exactly what the table below
          shows and confused users. */}
      {gb.address && gb.stakes.length > 0 && (
        <div className="mb-2 text-[9px] text-mempool-text-dim font-mono">
          Locks:{" "}
          {gb.stakes.map((s) => {
            const unlock = s.started_at_block + s.lock_blocks;
            const remaining = Math.max(0, unlock - gb.block_height);
            return (
              <span key={s.id} className="mr-2">
                #{s.id} → {formatOmni(s.amount_sat)} OMNI until block {unlock}
                {" "}({remaining > 0 ? `${remaining} blocks left` : "unlocked"})
              </span>
            );
          })}
        </div>
      )}

      {/* Header */}
      <div className="grid grid-cols-4 text-[8px] uppercase tracking-wider text-mempool-text-dim mb-1 px-0.5">
        <span></span>
        <span className="text-center text-green-500/70">Free / Staked</span>
        <span className="text-center text-yellow-500/70">In Orders</span>
        <span className="text-center">Total</span>
      </div>

      <div className="space-y-1.5">
        {assets.map(token => {
          const d = dec(token);
          // On OmniBus DEX, funds stay in the user's wallet — orders only
          // RESERVE part of it (no deposit happens until HTLC at fill time).
          // So:
          //   total = on-chain wallet balance (single source of truth)
          //   in_orders = portion of wallet reserved by active sell orders
          //   staked = portion locked in stake (only relevant for OMNI)
          //   free = total - in_orders - staked (what can still be spent)
          //
          // For OMNI we reuse the global snapshot (wallet_sat / staked_sat /
          // in_orders_sat / available_sat) so this row stays in sync with
          // the strip above and the Header pill. For non-OMNI tokens the
          // chain doesn't track staking, so the legacy on-chain-balance
          // path is fine.
          const isOmni    = token === "OMNI";
          const omniLive  = isOmni && gb.address === omniAddr && gb.fetched_at > 0;
          const onChain   = omniLive ? gb.wallet_sat / SAT_PER_OMNI : (walletAmt[token] ?? 0);
          const stakedHere = omniLive ? gb.staked_sat / SAT_PER_OMNI : 0;
          const lockedFromOrders = omniLive ? gb.in_orders_sat / SAT_PER_OMNI : Math.min(inOrders(token), onChain);
          const free      = omniLive
            ? gb.available_sat / SAT_PER_OMNI
            : Math.max(0, onChain - lockedFromOrders);
          const total     = onChain;
          const locked    = lockedFromOrders;
          const loading   = !omniLive && (fetching[token] ?? true);

          return (
            <div key={token} className="grid grid-cols-4 items-center font-mono">
              <span className="text-[10px] font-bold text-mempool-text uppercase">{token}</span>
              {loading ? (
                <span className="col-span-3 text-[9px] text-mempool-text-dim text-center animate-pulse">fetching…</span>
              ) : (
                <>
                  <div className="text-center">
                    <span className={`text-[11px] ${free > 0 ? "text-green-400" : "text-mempool-text-dim"}`}>
                      {free.toFixed(d)}
                    </span>
                    {stakedHere > 0 && (
                      <div className="text-[8px] text-mempool-purple/80" title={`Staked: ${stakedHere.toFixed(d)} ${token}`}>
                        🔒 {stakedHere.toFixed(d)}
                      </div>
                    )}
                  </div>
                  <div className="text-center">
                    <span className={`text-[11px] ${locked > 0 ? "text-yellow-400" : "text-mempool-text-dim"}`}>
                      {locked > 0 ? locked.toFixed(d) : "—"}
                    </span>
                  </div>
                  <div className="text-center">
                    <span className="text-[11px] text-mempool-text">{total.toFixed(d)}</span>
                  </div>
                </>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
