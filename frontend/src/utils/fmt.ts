/** Shared formatting utilities for the OmniBus frontend. */

export const SAT_PER_OMNI = 1_000_000_000;

/**
 * Convert satoshis to OMNI and format with 8 decimals + " OMNI" suffix.
 * Use when the unit label is part of the display string.
 */
export function fmtSat(sat: number): string {
  return (sat / SAT_PER_OMNI).toFixed(8) + " OMNI";
}

/**
 * Convert satoshis to OMNI and format with 8 decimals, no suffix.
 * Use when the unit is displayed separately or in a context that adds it.
 */
export function satToOmni(sat: number, decimals = 8): string {
  return (sat / SAT_PER_OMNI).toFixed(decimals);
}

/**
 * Truncate a long string (hash, address) by keeping `head` chars, an ellipsis,
 * and `tail` chars from the end. Returns "—" for falsy input.
 */
export function midTrunc(
  s: string | undefined | null,
  head = 8,
  tail = 6,
): string {
  if (!s) return "—";
  if (s.length <= head + tail + 3) return s;
  return `${s.slice(0, head)}…${s.slice(-tail)}`;
}

/**
 * Human-readable age from a Unix timestamp (seconds or milliseconds).
 * Accepts both — values > 1e12 are treated as milliseconds.
 * Returns strings like "42s ago", "5m ago", "3h ago", "2d ago".
 * Returns "" for falsy / future timestamps.
 */
export function fmtAge(ts: number): string {
  if (!ts) return "";
  const epochSec = ts > 1e12 ? ts / 1000 : ts;
  const diff = Math.floor(Date.now() / 1000 - epochSec);
  if (diff < 0) return "";
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

/**
 * Compact duration (no "ago" suffix). Suitable for mempool/live feeds.
 * Input is Unix epoch seconds. Returns "42s", "5m", "3h".
 */
export function fmtDuration(epochSec: number): string {
  const diff = Math.floor(Date.now() / 1000 - epochSec);
  if (diff < 60) return `${diff}s`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m`;
  return `${Math.floor(diff / 3600)}h`;
}
