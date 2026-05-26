/** Shared formatting utilities for the OmniBus frontend. */

export const SAT_PER_OMNI = 1_000_000_000;

/** Price is stored as micro-USD on chain (1 USD = 1_000_000 micro-USD). */
export const MICRO_PER_USD = 1_000_000;

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

/**
 * Format a micro-USD price as a USD string with fixed decimal places.
 * Returns "—" for zero/falsy input.
 *
 * @param microUsd  Price in micro-USD (1 USD = 1_000_000 micro-USD).
 * @param decimals  Number of decimal places to show (default auto).
 */
export function fmtUsd(microUsd: number, decimals?: number): string {
  if (!microUsd) return "—";
  const usd = microUsd / MICRO_PER_USD;
  const dec = decimals !== undefined ? decimals : usd >= 1000 ? 2 : usd >= 1 ? 2 : usd >= 0.01 ? 4 : 6;
  return "$" + usd.toLocaleString("en-US", {
    minimumFractionDigits: dec,
    maximumFractionDigits: dec,
  });
}

const _omniFmt = new Intl.NumberFormat("en-US", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 4,
});

/**
 * Convert satoshis to OMNI and format with locale-aware 2-4 significant decimals.
 * Large values (≥ 1 OMNI) use toLocaleString 2–4 dp; small values use 6 dp.
 * No unit suffix — append " OMNI" at the call site as needed.
 */
export function fmtOmni(sat: number): string {
  const omni = sat / SAT_PER_OMNI;
  if (omni >= 1) return _omniFmt.format(omni);
  if (omni >= 0.000001) return omni.toFixed(6);
  return omni.toFixed(9);
}

/**
 * Pick the right number of decimal places for a micro-USD price based on magnitude.
 * Small prices (< $0.01) get 6 decimals; large prices (>= $1) get 2.
 */
export function decimalsForUsd(microUsd: number): number {
  const usd = Math.abs(microUsd / MICRO_PER_USD);
  if (usd >= 1000) return 2;
  if (usd >= 1) return 2;
  if (usd >= 0.01) return 4;
  return 6;
}
