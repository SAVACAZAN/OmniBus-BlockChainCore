/**
 * useBlockHeight — returns the current chain tip height, kept live via WebSocket
 * and a 60s polling fallback.
 *
 * Replaces the duplicated pattern found in 10+ components:
 *   const [blockHeight, setBlockHeight] = useState(0);
 *   useEffect(() => { … wsSubscribe + setInterval … }, []);
 */

import { useEffect, useState } from "react";
import { rpc } from "../clients/rpc-client";
import { subscribe as wsSubscribe } from "../clients/ws-bus";
import type { WsNewBlockEvent } from "../../types";

export function useBlockHeight(): number {
  const [height, setHeight] = useState(0);

  useEffect(() => {
    let cancelled = false;

    void (async () => {
      try {
        const h = await rpc.getBlockCount();
        if (!cancelled) setHeight(h);
      } catch { /* ignore — node may not be reachable yet */ }
    })();

    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", (ev) => {
      setHeight(ev.height);
    });

    const id = window.setInterval(async () => {
      try {
        const h = await rpc.getBlockCount();
        if (!cancelled) setHeight(h);
      } catch { /* ignore */ }
    }, 60_000);

    return () => {
      cancelled = true;
      window.clearInterval(id);
      unsub();
    };
  }, []);

  return height;
}
