import { useEffect, useState } from "react";
import { getUnlocked, subscribeWallet } from "../../api/wallet-keystore";
import OmniBusRpcClient, { ExchangeBalance } from "../../api/rpc-client";
import { fetchUsdcBalance, fetchEvmBalance } from "../../api/multichain-balances";
import { useGlobalBalance, formatOmni } from "../../api/use-global-balance";

const rpc = new OmniBusRpcClient();
const SAT = 1_000_000_000;
const MU  = 1_000_000;

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
      return sat / SAT;
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
      locked[base] = (locked[base] ?? 0) + o.remaining / SAT;
    } else {
      // buy order locks quote (USDC): remaining base × price / SAT / 1e6 → USDC human
      const quoteLockedRaw = (o.remaining / SAT) * (o.price / MU);
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

  const u = getUnlocked();
  const omniAddr = u?.address ?? "";
  const evmAddr  = u?.allAddresses?.[0]?.evmAddress
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
    const id = setInterval(load, 8000);
    return () => { cancelled = true; clearInterval(id); };
  }, [omniAddr]);

  if (!u) return null;

  // Compute locked from orders (most reliable source)
  const ordersLocked = computeLockedFromOrders(userOrders, base, quote);

  // Also try exchBalances.locked as fallback (in case orders RPC unavailable)
  const ebLocked = (token: string) => {
    const eb = exchBalances.find(b => b.token === token);
    if (!eb || !eb.locked) return 0;
    if (token === "OMNI") return eb.locked / SAT;
    if (token === "ETH")  return eb.locked / 1e18;
    return eb.locked / MU;
  };

  // Use orders-derived locked if > 0, else fall back to exchBalances.locked
  const inOrders = (token: string) => {
    const fromOrders = ordersLocked[token] ?? 0;
    if (fromOrders > 0) return fromOrders;
    return ebLocked(token);
  };

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

      {/* OMNI breakdown banner (wallet / staked / orders / available) so user
          can see the full split right here in the trade panel, not only on
          stake page. Sourced from useGlobalBalance — same numbers as Header. */}
      {gb.address && (
        <div className="mb-2 p-2 rounded border border-mempool-border/50 bg-mempool-bg-elev text-[10px] font-mono leading-snug">
          <div className="grid grid-cols-4 gap-2">
            <div title="On-chain wallet balance (getbalance)">
              <div className="text-[8px] uppercase tracking-wider text-mempool-text-dim">Wallet</div>
              <div className="text-mempool-text">{formatOmni(gb.wallet_sat)} OMNI</div>
            </div>
            <div title={gb.stakes.length > 0
              ? gb.stakes.map(s => `#${s.id}: ${formatOmni(s.amount_sat)} OMNI, lock ${s.lock_blocks}b (started @${s.started_at_block}, ${s.days_locked}d, ${s.status})${s.unbonding_until ? `, unlock @${s.unbonding_until}` : ""}`).join("\n")
              : "No active stakes"}>
              <div className="text-[8px] uppercase tracking-wider text-mempool-text-dim">Staked 🔒</div>
              <div className="text-mempool-purple">{formatOmni(gb.staked_sat)} OMNI</div>
            </div>
            <div title="OMNI locked in active sell orders on the DEX">
              <div className="text-[8px] uppercase tracking-wider text-mempool-text-dim">In Orders</div>
              <div className="text-yellow-400">{formatOmni(gb.in_orders_sat)} OMNI</div>
            </div>
            <div title="wallet − staked − in_orders. Spendable right now.">
              <div className="text-[8px] uppercase tracking-wider text-mempool-text-dim">Available ✓</div>
              <div className="text-green-400">{formatOmni(gb.available_sat)} OMNI</div>
            </div>
          </div>
          {gb.stakes.length > 0 && (
            <div className="mt-1.5 pt-1.5 border-t border-mempool-border/40 text-[9px] text-mempool-text-dim">
              Locks:{" "}
              {gb.stakes.map((s) => {
                const unlock = s.started_at_block + s.lock_blocks;
                const remaining = Math.max(0, unlock - gb.block_height);
                return (
                  <span key={s.id} className="mr-2">
                    #{s.id} → {formatOmni(s.amount_sat)} until block {unlock}
                    {" "}({remaining > 0 ? `${remaining} blocks left` : "unlocked"})
                  </span>
                );
              })}
            </div>
          )}
        </div>
      )}

      {/* Header */}
      <div className="grid grid-cols-4 text-[8px] uppercase tracking-wider text-mempool-text-dim mb-1 px-0.5">
        <span></span>
        <span className="text-center text-green-500/70">Free</span>
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
          //   free = total - in_orders (what can still be moved/spent)
          // Adding `locked` to `onChain` would double-count — it's the same
          // funds, just earmarked.
          const onChain   = walletAmt[token] ?? 0;
          const locked    = Math.min(inOrders(token), onChain); // cap at total
          const total     = onChain;
          const free      = Math.max(0, onChain - locked);
          const loading   = fetching[token] ?? true;

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
