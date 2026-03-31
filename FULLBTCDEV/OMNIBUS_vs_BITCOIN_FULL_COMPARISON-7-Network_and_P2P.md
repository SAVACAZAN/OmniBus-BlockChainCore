# 7. Network & P2P

> OmniBus vs Bitcoin — Category 7/10
> Generated: 2026-03-31 19:42

| # | Component | BTC | OMNI | File | Notes |
|:-:|-----------|:---:|:----:|------|-------|
| 121 | P2P Protocol (TCP) | Y | Y | p2p.zig | TCP transport |
| 122 | Peer Discovery | Y | Y | bootstrap.zig | DNS seeds + DHT |
| 123 | Kademlia DHT | N | + | kademlia_dht.zig | Structured P2P [EXTRA] |
| 124 | Block Sync | Y | Y | sync.zig | Header-first sync |
| 125 | Peer Scoring / Reputation | Y | Y | peer_scoring.zig | Score-based banning |
| 126 | DNS Seeds / Registry | Y | Y | dns_registry.zig | Bootstrap nodes |
| 127 | Duplicate Detection | N | + | p2p.zig | Knock-knock system [EXTRA] |
| 128 | Gossip TX Propagation | Y | Y | p2p.zig | TX broadcast |
| 129 | Gossip Block Propagation | Y | Y | p2p.zig | Block broadcast |
| 130 | Ban List | Y | Y | peer_scoring.zig | Via scoring system |
| 131 | Inbound/Outbound Peers | Y | Y | p2p.zig | Configurable |
| 132 | Max Connections Limit | Y | Y | p2p.zig | Peer limit |
| 133 | Tor Support (SOCKS5) | Y | Y | tor_proxy.zig | SOCKS5 proxy, .onion detection |
| 134 | I2P Support | Y | N | - | NOT YET |
| 135 | BIP-324 Encrypted P2P | Y | Y | encrypted_p2p.zig | ECDH + AES-256-GCM encrypted sessions |
| 136 | Compact Block Relay | Y | Y | binary_codec.zig | Binary codec |
| 137 | Headers-First Download | Y | Y | sync.zig | Header-based |
| 138 | Fee Filter | Y | Y | mempool.zig | Min fee filtering (partial) |
| 139 | ZMQ / Push Notifications | Y | Y | ws_server.zig | WebSocket instead of ZMQ |
| 140 | User Agent String | Y | Y | p2p.zig | "OmniBus/1.0" |

---

**BTC has: 18 items**
**OmniBus: 19 implemented, 0 partial, 1 missing, 2 extras**
**Score: 105%** (19/18 BTC features + 2 unique extras)

### Missing (TODO):
- [ ] I2P Support — NOT YET

### Extras (OmniBus-only):
- Kademlia DHT — Structured P2P [EXTRA]
- Duplicate Detection — Knock-knock system [EXTRA]

