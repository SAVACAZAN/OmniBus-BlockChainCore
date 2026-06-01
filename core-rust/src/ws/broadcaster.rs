//! broadcaster.rs — fan-out events to all connected WS clients.
//!
//! Each client is represented by an `mpsc::UnboundedSender<Message>` half;
//! the receiver half is owned by the per-connection task in `server.rs`
//! which actually writes to the `WebSocketStream`. This way the broadcaster
//! holds zero locks on the IO half, dead clients get reaped automatically
//! when the send fails (channel closed = task gone), and we never block
//! one slow client behind another.
//!
//! `Arc<RwLock<Vec<ClientHandle>>>` is the canonical pattern asked for in
//! the spec; clients carry their own topic subscription bitmask so the
//! broadcaster can filter without touching the underlying stream.

use std::sync::Arc;
use tokio::sync::{mpsc, RwLock};
use tokio_tungstenite::tungstenite::Message;

use super::events::{Event, Topic};

/// One handle per connected client. Lives inside the broadcaster.
pub struct ClientHandle {
    pub id: u64,
    /// Subscription bitmask — defaults to `Topic::ALL`.
    pub subscriptions: u8,
    /// Send half of the per-client outbound channel.
    pub tx: mpsc::UnboundedSender<Message>,
}

#[derive(Clone)]
pub struct Broadcaster {
    inner: Arc<RwLock<Vec<ClientHandle>>>,
    next_id: Arc<std::sync::atomic::AtomicU64>,
}

impl Default for Broadcaster {
    fn default() -> Self {
        Self::new()
    }
}

impl Broadcaster {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(RwLock::new(Vec::new())),
            next_id: Arc::new(std::sync::atomic::AtomicU64::new(1)),
        }
    }

    /// Register a fresh client. Returns the client id + the receiver half
    /// the per-connection task should pump into the WebSocket stream.
    pub async fn register(&self) -> (u64, mpsc::UnboundedReceiver<Message>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let id = self
            .next_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let mut g = self.inner.write().await;
        g.push(ClientHandle {
            id,
            subscriptions: Topic::ALL,
            tx,
        });
        (id, rx)
    }

    /// Unregister — called by the per-connection task on disconnect or
    /// proactively by reap_dead.
    pub async fn unregister(&self, id: u64) {
        let mut g = self.inner.write().await;
        g.retain(|c| c.id != id);
    }

    /// Update a client's subscription bitmask in response to a subscribe /
    /// unsubscribe text frame.
    pub async fn set_subscription(&self, id: u64, bit: u8, subscribe: bool) {
        let mut g = self.inner.write().await;
        if let Some(c) = g.iter_mut().find(|c| c.id == id) {
            if subscribe {
                c.subscriptions |= bit;
            } else {
                c.subscriptions &= !bit;
            }
        }
    }

    /// Broadcast an event. Filters by the event's topic (a topic of 0
    /// means "ignore subscriptions, push to everybody"). Returns the
    /// number of clients the message actually reached.
    pub async fn broadcast(&self, event: &Event) -> usize {
        let topic = event.topic();
        let payload = event.to_json();
        let msg = Message::Text(payload);
        let mut delivered = 0usize;
        let mut dead: Vec<u64> = Vec::new();

        {
            let g = self.inner.read().await;
            for c in g.iter() {
                let matches = topic == Topic::BROADCAST_ALL || (c.subscriptions & topic) != 0;
                if !matches {
                    continue;
                }
                match c.tx.send(msg.clone()) {
                    Ok(()) => delivered += 1,
                    Err(_) => dead.push(c.id),
                }
            }
        }

        if !dead.is_empty() {
            let mut g = self.inner.write().await;
            g.retain(|c| !dead.contains(&c.id));
        }
        delivered
    }

    /// Heartbeat helper (called by the server's heartbeat task every 25 s).
    pub async fn heartbeat(&self) -> usize {
        let now = chrono_now_secs();
        self.broadcast(&Event::Heartbeat { timestamp: now }).await
    }

    /// Reap clients whose mpsc channel has been closed by the consumer
    /// (peer disconnect or per-conn task panic). Cheap; safe to call
    /// periodically.
    pub async fn reap_dead(&self) -> usize {
        let mut g = self.inner.write().await;
        let before = g.len();
        g.retain(|c| !c.tx.is_closed());
        before - g.len()
    }

    /// Current connected client count.
    pub async fn len(&self) -> usize {
        self.inner.read().await.len()
    }
}

/// Cheap unix-seconds timestamp without pulling in `chrono`.
fn chrono_now_secs() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn register_then_broadcast_delivers() {
        let b = Broadcaster::new();
        let (_id, mut rx) = b.register().await;
        let n = b
            .broadcast(&Event::ChainHead {
                height: 1,
                hash: "h".into(),
                timestamp: 0,
            })
            .await;
        assert_eq!(n, 1);
        let m = rx.recv().await.unwrap();
        match m {
            Message::Text(s) => assert!(s.contains("chain_head")),
            _ => panic!("expected text"),
        }
    }

    #[tokio::test]
    async fn unsubscribe_filters_event() {
        let b = Broadcaster::new();
        let (id, mut rx) = b.register().await;
        // Turn off BLOCKS only — chain_head is topic BLOCKS.
        b.set_subscription(id, Topic::BLOCKS, false).await;
        let n = b
            .broadcast(&Event::ChainHead {
                height: 1,
                hash: "h".into(),
                timestamp: 0,
            })
            .await;
        assert_eq!(n, 0);
        // But broadcast-all events (heartbeat) still arrive.
        let n2 = b.heartbeat().await;
        assert_eq!(n2, 1);
        let _ = rx.recv().await.unwrap();
    }

    #[tokio::test]
    async fn reap_dead_after_drop() {
        let b = Broadcaster::new();
        let (_id, rx) = b.register().await;
        assert_eq!(b.len().await, 1);
        drop(rx);
        let reaped = b.reap_dead().await;
        assert_eq!(reaped, 1);
        assert_eq!(b.len().await, 0);
    }
}
