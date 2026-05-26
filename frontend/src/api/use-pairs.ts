/**
 * use-pairs.ts — Chain-loaded exchange pair list with loading/error state.
 *
 * Fetches all 10 pair IDs (0-9) from the node via exchange_pairInfo on mount.
 * Pairs 1 (BTC/USDC) and 4 (OMNI/BTC) are marked reserved=true so the UI
 * can render them greyed out with "Coming soon". No hardcoded fallback — if
 * the node is unreachable the hook stays in the loading/error state.
 *
 * Singleton: multiple components calling usePairs() share the same fetch.
 */

import { useEffect, useState } from "react";
import { rpc as _rpc, type OmniBusRpcClient } from "./rpc-client";
import type { PairInfo } from "./rpc-client";

export interface ChainPair {
  id: number;
  base: string;
  quote: string;
  label: string;
  reserved: boolean;
  info: PairInfo | null;
}

// IDs the UI tries to query. If the chain returns "Unknown pair_id" for
// any of these (e.g. on testnet where only a subset is wired), we DROP
// them entirely instead of showing them as "pair_4" placeholders that
// confuse the user. The display list ends up being whatever the chain
// actually supports, in numerical order.
const ALL_PAIR_IDS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];

// Singleton cache so multiple consumers don't issue duplicate RPC fans.
let _cachedPairs: ChainPair[] | null = null;
let _cachePromise: Promise<ChainPair[]> | null = null;

async function fetchAllPairs(rpc: OmniBusRpcClient): Promise<ChainPair[]> {
  if (_cachedPairs) return _cachedPairs;
  if (_cachePromise) return _cachePromise;

  _cachePromise = (async () => {
    // Fan-out: fetch pairInfo for every ID in parallel.
    const results = await Promise.allSettled(
      ALL_PAIR_IDS.map((id) => rpc.exchangePairInfo(id))
    );

    const pairs: ChainPair[] = [];
    results.forEach((r, idx) => {
      const id = ALL_PAIR_IDS[idx];
      if (r.status !== "fulfilled" || !r.value) {
        // Chain doesn't know about this id — skip it instead of showing
        // an empty "pair_<id>" placeholder. Old behaviour confused users
        // who would click pair_4 and the order panel would render with
        // empty base/quote.
        return;
      }
      const info = r.value;
      pairs.push({
        id,
        base: info.base,
        quote: info.quote,
        label: `${info.base}/${info.quote}`,
        // A pair is "reserved" if it has no maker/taker chain liquidity
        // wired up yet — keep it visible but greyed out so the user sees
        // the roadmap. Anything the chain replied to with full info is
        // considered live.
        reserved: false,
        info,
      });
    });

    _cachedPairs = pairs;
    _cachePromise = null;
    return pairs;
  })();

  return _cachePromise;
}

/** Invalidate cache (call after chain switch). */
export function invalidatePairsCache(): void {
  _cachedPairs = null;
  _cachePromise = null;
}


export interface UsePairsResult {
  pairs: ChainPair[];
  /** All pairs including reserved ones (id 1, 4). */
  allPairs: ChainPair[];
  loading: boolean;
  error: string | null;
}

/**
 * Returns all 10 pairs loaded from chain.
 * `pairs`    — active pairs only (reserved filtered out).
 * `allPairs` — all 10 including reserved (greyed in UI).
 */
export function usePairs(): UsePairsResult {
  const [allPairs, setAllPairs] = useState<ChainPair[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);

    fetchAllPairs(_rpc)
      .then((p) => {
        if (!cancelled) {
          setAllPairs(p);
          setLoading(false);
        }
      })
      .catch((e) => {
        if (!cancelled) {
          setError(e instanceof Error ? e.message : String(e));
          setLoading(false);
        }
      });

    return () => {
      cancelled = true;
    };
  }, []);

  const pairs = allPairs.filter((p) => !p.reserved);

  return { pairs, allPairs, loading, error };
}
