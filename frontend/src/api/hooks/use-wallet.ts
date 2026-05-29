/**
 * use-wallet.ts — React hook over the existing wallet-keystore singleton.
 *
 * `wallet-keystore.ts` already implements a singleton with `subscribeWallet`
 * (callback-based change notifications) + `getUnlocked()` (current state).
 * This hook just plugs that into React's render loop so any component can:
 *
 *   const wallet = useWallet();
 *   if (!wallet) return <ConnectPrompt />;
 *   // wallet.address, wallet.publicKey, wallet.privateKey are all here
 *
 * The same instance is shared across every tab — connect once in the Header,
 * every panel sees it instantly without prop-drilling. Disconnect anywhere
 * (e.g. `lockWallet()`) and every subscriber re-renders to its locked state.
 */

import { useEffect, useState } from "react";
import {
  Unlocked,
  getUnlocked,
  subscribeWallet,
} from "../wallet/wallet-keystore";

/**
 * Returns the currently-unlocked wallet (or null when no session exists).
 * Re-renders the calling component whenever the global wallet state changes:
 *   - user unlocks via mnemonic / privkey / vault → re-render with the unlocked state
 *   - user calls lockWallet() anywhere → re-render with null
 *   - another tab in the same browser session unlocks (sessionStorage sync) → re-render
 */
export function useWallet(): Unlocked | null {
  const [wallet, setWallet] = useState<Unlocked | null>(() => getUnlocked());

  useEffect(() => {
    // subscribeWallet returns the unsubscribe function. The keystore calls
    // every subscriber on any state change; we just snapshot the new state.
    const unsubscribe = subscribeWallet(() => {
      setWallet(getUnlocked());
    });
    return unsubscribe;
  }, []);

  return wallet;
}

/**
 * Convenience: returns true when a wallet is unlocked. Use as a render gate
 * when the only thing that matters is connected/not-connected, not the
 * actual address (e.g. showing/hiding "Connect" button).
 */
export function useIsConnected(): boolean {
  return useWallet() !== null;
}
