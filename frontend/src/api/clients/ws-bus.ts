/**
 * ws-bus.ts — lightweight pub/sub for WebSocket events.
 *
 * Why a separate bus?
 *   `WebSocketProvider.tsx` already owns the (single) WS connection and the
 *   reducer-driven state tree. But individual UI components often want a
 *   one-off side effect on a specific event (e.g. "pulse the header pill on
 *   every new block") without going through the reducer. This module is a
 *   thin pub/sub the provider feeds.
 *
 *   Consumers do NOT open their own WebSocket — they call `subscribe(name, cb)`
 *   and `WebSocketProvider` calls `publish(event)` from its single onmessage
 *   handler. This keeps connection count = 1 even with many listeners.
 */
import type { WsEvent } from "../../types";

export type WsEventName = WsEvent["event"];

// Map of event name → set of callbacks. Set semantics make
// unsubscribe O(1) and prevent double-registration.
type Listener<E extends WsEvent = WsEvent> = (e: E) => void;
const listeners: Map<WsEventName, Set<Listener>> = new Map();

/**
 * Subscribe to a typed WS event. Returns an unsubscribe function — call it
 * from React `useEffect` cleanup to prevent leaks.
 */
export function subscribe<E extends WsEvent>(
  name: E["event"],
  cb: (e: Extract<WsEvent, { event: E["event"] }>) => void,
): () => void {
  let set = listeners.get(name);
  if (!set) {
    set = new Set();
    listeners.set(name, set);
  }
  // Cast through Listener — runtime contract is "publisher only invokes cb
  // when payload.event === name", so the narrowed E is safe at the boundary.
  set.add(cb as unknown as Listener);
  return () => {
    listeners.get(name)?.delete(cb as unknown as Listener);
  };
}

/**
 * Called by WebSocketProvider for every parsed message. Dispatches to all
 * registered listeners for that event name. Errors in listeners are swallowed
 * so one buggy consumer can't break the bus for everyone else.
 */
export function publish(event: WsEvent): void {
  const set = listeners.get(event.event);
  if (!set) return;
  for (const cb of set) {
    try {
      cb(event);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.error(`[ws-bus] listener for "${event.event}" threw:`, err);
    }
  }
}

/**
 * Test/debug helper — drop all listeners. Not used in production paths.
 */
export function clearAllListeners(): void {
  listeners.clear();
}
