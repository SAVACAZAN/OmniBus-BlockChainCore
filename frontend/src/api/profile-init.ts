/**
 * profile-init.ts — fire-and-forget OmniBus ID creation.
 *
 * Called immediately after a wallet's mnemonic is confirmed and the OMNI
 * address is derived. The chain allocates a per-address salt used later
 * for selective disclosure of profile facets. The salt is persisted in
 * localStorage under `omnibus_kyc_salt_<address>` so the same browser can
 * recompute disclosure proofs without re-asking the chain.
 *
 * Failure modes (node offline, RPC missing) are swallowed — onboarding
 * does NOT block on this; the user can retry from the Profile tab.
 */

import OmniBusRpcClient from "./rpc-client";

const rpc = new OmniBusRpcClient();

const SALT_KEY_PREFIX = "omnibus_kyc_salt_";
const TOAST_EVENT = "omnibus:profile-init-toast";

export interface ProfileInitToastDetail {
  address: string;
  did: string;
}

export function getSaltForAddress(address: string): string | null {
  try {
    return localStorage.getItem(SALT_KEY_PREFIX + address);
  } catch {
    return null;
  }
}

function storeSalt(address: string, salt: string): void {
  try {
    localStorage.setItem(SALT_KEY_PREFIX + address, salt);
  } catch {
    /* quota / disabled — ignore */
  }
}

/**
 * Fire-and-forget profile init. Returns a promise (resolves to null on
 * failure) but callers are expected to NOT await it — onboarding flow
 * keeps moving.
 */
export async function initProfileForAddress(address: string): Promise<{ did: string; salt: string } | null> {
  if (!address) return null;
  // If we already have a salt cached, skip the round-trip.
  const cached = getSaltForAddress(address);
  if (cached) return { did: `did:omnibus:${address}`, salt: cached };

  try {
    const res = await rpc.profileInit(address);
    if (!res) return null;
    storeSalt(address, res.salt);
    // Dispatch a window event so a global toast listener can show
    // "OmniBus ID created" without OnboardingPage needing to plumb props.
    try {
      const detail: ProfileInitToastDetail = { address, did: res.did };
      window.dispatchEvent(new CustomEvent(TOAST_EVENT, { detail }));
    } catch { /* SSR / no window */ }
    return { did: res.did, salt: res.salt };
  } catch {
    return null;
  }
}

export const PROFILE_INIT_TOAST_EVENT = TOAST_EVENT;
