/**
 * AddressLabel.tsx — show a name (foo.omnibus) when one is registered for
 * the address, and a truncated bech32 (ob1q…6f8x) otherwise.
 *
 * Drop-in replacement for inline `addr.slice(0, 8)…addr.slice(-6)` patterns
 * scattered across Header, Names, Faucet, Reputation, Exchange. The hover
 * tooltip always shows the full ob1q… so power users can copy-paste it.
 */

import { useNameForAddress } from "../../api/use-names";

type Props = {
  address: string;
  /** Show the full address even when a name exists (e.g. "savacazan.omnibus · ob1q…6f8x"). */
  showRawAddress?: boolean;
  /** Override truncation length. Defaults to 8/6. */
  truncate?: { left: number; right: number };
  className?: string;
};

export function AddressLabel({
  address,
  showRawAddress = false,
  truncate = { left: 8, right: 6 },
  className = "",
}: Props) {
  const name = useNameForAddress(address);

  if (!address) return null;

  const truncated =
    address.length > truncate.left + truncate.right + 1
      ? `${address.slice(0, truncate.left)}…${address.slice(-truncate.right)}`
      : address;

  if (!name) {
    return (
      <span className={className} title={address}>
        {truncated}
      </span>
    );
  }

  if (showRawAddress) {
    return (
      <span className={className} title={address}>
        <span className="font-semibold">{name}</span>
        <span className="opacity-60"> · {truncated}</span>
      </span>
    );
  }

  return (
    <span className={className} title={`${name} → ${address}`}>
      {name}
    </span>
  );
}
