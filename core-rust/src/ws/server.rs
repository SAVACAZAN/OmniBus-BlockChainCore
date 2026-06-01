//! server.rs — async WebSocket server on port 8334.
//!
//! Sibling of `core/ws_server.zig`. Same wire protocol (RFC 6455 ws://,
//! no TLS — localhost only) and same client message format:
//!   `{"subscribe":"<topic>"}` / `{"unsubscribe":"<topic>"}`
//!
//! Implementation: `tokio-tungstenite` does the HTTP Upgrade + framing,
//! we just split the socket and run two tasks per connection:
//!   - read task — parses subscribe/unsubscribe text frames, updates the
//!     broadcaster's per-client bitmask.
//!   - write task — drains the per-client mpsc::Receiver into the socket.
//!
//! A separate global task fires `broadcaster.heartbeat()` every 25 s.

use std::net::SocketAddr;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::Message;

use super::broadcaster::Broadcaster;
use super::events::Topic;

/// WS port — fixed to match the Zig server.
pub const WS_PORT: u16 = 8334;

/// Spawn the WS server in the background. Returns a `Broadcaster` handle
/// the rest of the node uses to push events.
///
/// Caller keeps the returned `Broadcaster`; clone it cheaply (Arc inside).
pub async fn start(port: u16) -> anyhow::Result<Broadcaster> {
    let broadcaster = Broadcaster::new();
    let addr: SocketAddr = format!("127.0.0.1:{port}").parse()?;
    let listener = TcpListener::bind(addr).await?;
    tracing::info!("[WS] listening on ws://{}", addr);

    // Accept loop.
    let b_accept = broadcaster.clone();
    tokio::spawn(async move {
        loop {
            match listener.accept().await {
                Ok((stream, peer)) => {
                    let b = b_accept.clone();
                    tokio::spawn(async move {
                        if let Err(e) = handle_connection(stream, peer, b).await {
                            tracing::debug!("[WS] conn {} ended: {}", peer, e);
                        }
                    });
                }
                Err(e) => {
                    tracing::warn!("[WS] accept error: {}", e);
                    tokio::time::sleep(Duration::from_millis(500)).await;
                }
            }
        }
    });

    // Heartbeat loop — every 25 s. Mirrors Zig HEARTBEAT_INTERVAL_NS.
    let b_hb = broadcaster.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(25));
        // First tick fires immediately; skip it.
        tick.tick().await;
        loop {
            tick.tick().await;
            let _ = b_hb.heartbeat().await;
            let _ = b_hb.reap_dead().await;
        }
    });

    Ok(broadcaster)
}

async fn handle_connection(
    stream: TcpStream,
    peer: SocketAddr,
    broadcaster: Broadcaster,
) -> anyhow::Result<()> {
    let ws = tokio_tungstenite::accept_async(stream).await?;
    tracing::info!("[WS] client connected: {}", peer);

    let (mut sink, mut source) = ws.split();
    let (client_id, mut rx) = broadcaster.register().await;

    // Write task — pump mpsc -> WebSocket.
    let writer = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if sink.send(msg).await.is_err() {
                break;
            }
        }
        // Best-effort close.
        let _ = sink.close().await;
    });

    // Read task — handle subscribe/unsubscribe + Ping/Pong/Close.
    let b_read = broadcaster.clone();
    while let Some(frame) = source.next().await {
        match frame {
            Ok(Message::Text(t)) => {
                handle_subscribe_msg(&b_read, client_id, &t).await;
            }
            Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => { /* tungstenite auto-handles Ping */ }
            Ok(Message::Close(_)) | Err(_) => break,
            Ok(_) => { /* ignore binary */ }
        }
    }

    broadcaster.unregister(client_id).await;
    writer.abort();
    tracing::info!("[WS] client disconnected: {}", peer);
    Ok(())
}

/// Parse `{"subscribe":"topic"}` / `{"unsubscribe":"topic"}` — same
/// substring-based parser as Zig (`handleSubscribeMsg`).
async fn handle_subscribe_msg(b: &Broadcaster, client_id: u64, msg: &str) {
    let is_sub = msg.contains("\"subscribe\"");
    let is_unsub = msg.contains("\"unsubscribe\"");
    if !is_sub && !is_unsub {
        return;
    }
    let bit = if msg.contains("\"blocks\"") {
        Topic::BLOCKS
    } else if msg.contains("\"txs\"") {
        Topic::TXS
    } else if msg.contains("\"trades\"") {
        Topic::TRADES
    } else if msg.contains("\"orderbook\"") {
        Topic::ORDERBOOK
    } else if msg.contains("\"oracle\"") {
        Topic::ORACLE
    } else if msg.contains("\"all\"") {
        Topic::ALL
    } else {
        return;
    };
    b.set_subscription(client_id, bit, is_sub).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn start_binds_port() {
        // Use a non-canonical port to avoid clashing with a running node.
        let b = start(0).await; // 0 = OS-assigned; just verifies we don't panic
        // start() returns Ok(...) but binds to 0, which TcpListener handles fine.
        // We won't actually connect; this just exercises the spawn path.
        assert!(b.is_ok());
    }
}
