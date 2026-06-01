//! ws/ — WebSocket server (port 8334) for the React frontend.
//!
//! Sibling port of `core/ws_server.zig`. Same JSON event schema the
//! frontend's `api/rpc-client.ts` already understands, so swapping the
//! backend is transparent to the UI.
//!
//! Protocol:
//!   - ws://127.0.0.1:8334 (no TLS — localhost only)
//!   - Client sends {"subscribe":"<topic>"} / {"unsubscribe":"<topic>"}
//!   - Topics: "blocks" | "txs" | "trades" | "orderbook" | "oracle" | "all"
//!   - Server pushes JSON event frames; heartbeat every 25 s.
//!
//! Topic bitmask (matches Zig `ws_server.zig::Topic`):
//!   blocks=0x01, txs=0x02, trades=0x04, orderbook=0x08, oracle=0x10, all=0x1F

pub mod broadcaster;
pub mod events;
pub mod server;

#[allow(unused_imports)]
pub use broadcaster::Broadcaster;
#[allow(unused_imports)]
pub use events::{Event, Topic};
#[allow(unused_imports)]
pub use server::{start, WS_PORT};

// ── Global broadcaster handle ──────────────────────────────────────────────
//
// Modules across the chain (mempool, matching engine, NS registry, peer
// registry, agents, oracle) need to emit `Event::*` when state transitions
// happen, but threading an `Option<Arc<Broadcaster>>` through every
// constructor would force a wide signature change across other agents'
// modules. Instead the orchestrator installs the live broadcaster once at
// startup via `install_broadcaster()`, and modules call `try_broadcast()`,
// which silently no-ops if no broadcaster is installed (e.g. unit tests or
// `--mode evm`). This is the `Some` / `None` semantics from the spec
// expressed as a single global rather than per-module fields.
//
// Thread-safety: `OnceLock<Broadcaster>` — set once, read-many. Broadcasting
// uses async (`broadcast().await`), so the emit helper spawns a task on the
// current Tokio runtime; callers stay sync.

use std::sync::OnceLock;

static GLOBAL: OnceLock<Broadcaster> = OnceLock::new();

/// Install the chain-wide broadcaster. Idempotent: subsequent calls are
/// ignored (useful in tests that may try to install twice). Called once by
/// `node::run_seed` / `node::run_miner` right after `ws::start()`.
pub fn install_broadcaster(b: Broadcaster) {
    let _ = GLOBAL.set(b);
}

/// Get a clone of the installed broadcaster, if any. Returns `None` in
/// `--mode evm`, in unit tests, or before the WS server has booted.
pub fn broadcaster() -> Option<Broadcaster> {
    GLOBAL.get().cloned()
}

/// Fire-and-forget broadcast — call this from any sync code path on a
/// state transition. Silently no-ops if no broadcaster is installed or
/// no Tokio runtime is available (e.g. inside a unit test that's not
/// `#[tokio::test]`).
///
/// Cheap when no broadcaster is installed (one OnceLock load + branch).
pub fn try_broadcast(event: Event) {
    let Some(b) = broadcaster() else { return };
    // We need to .await broadcast, but callers are sync. Spawn on the
    // current runtime; fall back to a blocking send if no runtime is
    // available (very unlikely in production).
    match tokio::runtime::Handle::try_current() {
        Ok(handle) => {
            handle.spawn(async move {
                let _ = b.broadcast(&event).await;
            });
        }
        Err(_) => {
            // No runtime — drop the event silently. Production always has
            // one (the main #[tokio::main]); only unit tests outside
            // `#[tokio::test]` hit this path.
        }
    }
}
