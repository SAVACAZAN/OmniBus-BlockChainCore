/**
 * GlobalBalancePill.tsx — header pill that shows wallet / staked / available
 * in one place, refreshing every 8 s. Same numbers visible on every tab.
 *
 * Replaces the old practice where each tab fetched its own balance and got a
 * slightly different answer ("stake page says 100, exchange says 0").
 */

import { useGlobalBalance, formatOmni } from "../../api/use-global-balance";

export function GlobalBalancePill() {
  const b = useGlobalBalance();

  // Hide when no wallet connected — the connect button itself handles that state.
  if (!b.address) return null;

  const stale = b.fetched_at > 0 && Date.now() - b.fetched_at > 30_000;

  return (
    <div
      className="hidden md:flex items-center gap-2 px-2.5 py-1 rounded-md bg-mempool-bg-elev border border-mempool-border text-[11px] leading-tight"
      title={`Wallet: ${formatOmni(b.wallet_sat)} OMNI · Staked: ${formatOmni(b.staked_sat)} · In orders: ${formatOmni(b.in_orders_sat)} · Available: ${formatOmni(b.available_sat)}${b.error ? `\nError: ${b.error}` : ""}`}
    >
      <span className="text-mempool-text-dim uppercase tracking-wider text-[9px]">Avail</span>
      <span className={`font-mono font-semibold ${stale ? "text-mempool-text-dim" : "text-mempool-blue"}`}>
        {formatOmni(b.available_sat)}
      </span>
      {b.staked_sat > 0 && (
        <>
          <span className="text-mempool-text-dim">·</span>
          <span className="text-mempool-text-dim uppercase tracking-wider text-[9px]">Stake</span>
          <span className="font-mono text-mempool-purple">{formatOmni(b.staked_sat)}</span>
        </>
      )}
      {b.in_orders_sat > 0 && (
        <>
          <span className="text-mempool-text-dim">·</span>
          <span className="text-mempool-text-dim uppercase tracking-wider text-[9px]">Orders</span>
          <span className="font-mono text-mempool-orange">{formatOmni(b.in_orders_sat)}</span>
        </>
      )}
    </div>
  );
}
