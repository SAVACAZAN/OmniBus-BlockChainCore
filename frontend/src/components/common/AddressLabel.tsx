/**
 * AddressLabel.tsx — show a name (foo.omnibus) when one is registered for
 * the address, and a truncated bech32 (ob1q…6f8x) otherwise.
 *
 * Drop-in replacement for inline `addr.slice(0, 8)…addr.slice(-6)` patterns
 * scattered across Header, Names, Faucet, Reputation, Exchange. The hover
 * tooltip always shows the full ob1q… so power users can copy-paste it.
 */

import { useNameForAddress, useEntryForAddress, TLD_THEME } from "../../api/hooks/use-names";
import { midTrunc } from "../../utils/fmt";

type Props = {
  address: string;
  /** Show the full address even when a name exists (e.g. "savacazan.omnibus · ob1q…6f8x"). */
  showRawAddress?: boolean;
  /** Override truncation length. Defaults to 8/6. */
  truncate?: { left: number; right: number };
  className?: string;
  /** Phase 2 — when true, render the category badge (BANK / GOV / …) next to the name. */
  showCategory?: boolean;
  /** Phase 2 — when true, prefix with the TLD emoji (🏦 / 🏛 / …). */
  showEmoji?: boolean;
};

export function AddressLabel({
  address,
  showRawAddress = false,
  truncate = { left: 8, right: 6 },
  className = "",
  showCategory = false,
  showEmoji = false,
}: Props) {
  const name = useNameForAddress(address);
  // Phase 2 — full entry for category/tld coloring. Same address, single
  // shared cache, so no extra RPC.
  const entry = useEntryForAddress(address);

  if (!address) return null;

  const truncated = midTrunc(address, truncate.left, truncate.right);

  if (!name) {
    return (
      <span className={className} title={address}>
        {truncated}
      </span>
    );
  }

  const tld = entry?.tld;
  const theme = tld ? TLD_THEME[tld] : undefined;
  const cat = entry?.category && entry.category !== "none" ? entry.category : null;
  const colorClass = theme?.color ?? "";

  // Build the inner content once so the three render branches stay short.
  const inner = (
    <>
      {showEmoji && theme?.emoji && <span className="mr-1">{theme.emoji}</span>}
      <span className={`font-semibold ${colorClass}`}>{name}</span>
      {showCategory && cat && (
        <span className="ml-1 text-[9px] uppercase tracking-wider px-1 rounded bg-mempool-blue/30 text-mempool-blue font-bold align-middle">
          {cat}
        </span>
      )}
    </>
  );

  if (showRawAddress) {
    return (
      <span className={className} title={`${name} → ${address}${cat ? ` [${cat}]` : ""}`}>
        {inner}
        <span className="opacity-60"> · {truncated}</span>
      </span>
    );
  }

  return (
    <span className={className} title={`${name} → ${address}${cat ? ` [${cat}]` : ""}`}>
      {inner}
    </span>
  );
}
