# OmniBus BlockChainCore — DevOps & CI/CD Setup

Complete guide to deployment, CI/CD, Docker, and multi-node federation for OmniBus BlockChainCore.

## Quick Start

### Local Development (Windows/Linux)

```bash
# Build the node
zig build

# Run a seed node
./zig-out/bin/omnibus-node --mode seed --node-id node-1 --port 9000

# In another terminal, run a miner
./zig-out/bin/omnibus-node --mode miner --node-id miner-1 --seed-host 127.0.0.1 --seed-port 9000

# Test RPC
curl -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getblockcount","params":[],"id":1}'
```

### Docker (Local Testnet)

```bash
# Start 3-node testnet (seed + 2 miners)
docker-compose -f docker-compose.testnet.yml up -d

# Check logs
docker-compose -f docker-compose.testnet.yml logs -f seed

# Stop and clean
docker-compose -f docker-compose.testnet.yml down -v
```

### VPS Deployment

```bash
# Deploy testnet to VPS with rebuild
bash scripts/deploy-vps.sh --testnet --build

# Deploy mainnet only
bash scripts/deploy-vps.sh --mainnet

# Deploy all services
bash scripts/deploy-vps.sh --all --build

# Deploy frontend only (fast)
bash scripts/deploy-vps.sh --frontend-only
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        OmniBus BlockChainCore                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐     │
│  │   Seed Node  │◄────►│   Miner-1    │      │   Miner-2    │     │
│  │ (Primary)    │      │ (Mining)     │      │ (Mining)     │     │
│  │ Port: 9000   │      │ Port: 9001   │      │ Port: 9002   │     │
│  └──────────────┘      └──────────────┘      └──────────────┘     │
│        │                      │                      │             │
│        └──────────────────────┴──────────────────────┘             │
│                         P2P Network                                │
│                    (Block sync, Tx gossip)                        │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │  Shared Resources:                                           │ │
│  │  - omnibus-chain.dat (persistent blockchain state)           │ │
│  │  - omnibus-miner.lock (single-instance lock)                 │ │
│  │  - JSON-RPC API (port 8332)                                  │ │
│  │  - WebSocket (port 8334)                                     │ │
│  │  - Mining pool endpoints                                     │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Single-Node Setup (Development)

```bash
./zig-out/bin/omnibus-node --mode seed --node-id dev-1 --port 9000
  ↓
  RPC: http://127.0.0.1:8332
  WS:  ws://127.0.0.1:8334
  P2P: 127.0.0.1:9000
```

### Multi-Node Testnet (3+ nodes)

```
  Docker Compose    or    Kubernetes    or    Systemd Services
   ┌─────────────┐       ┌──────────┐        ┌─────────────┐
   │ seed (9001) │       │ seed pod │        │ omnibus-*   │
   ├─────────────┤       ├──────────┤        │ (systemd)   │
   │ miner-1     │       │ miner-1  │        │ on VPS      │
   ├─────────────┤       ├──────────┤        └─────────────┘
   │ miner-2     │       │ miner-2  │
   └─────────────┘       └──────────┘
```

---

## Deployment Methods

### 1. Local Docker Compose

#### File: `docker-compose.testnet.yml`

**Use when:** Testing multi-node setup locally, CI/CD testing.

**Command:**
```bash
docker-compose -f docker-compose.testnet.yml up -d
```

**What it does:**
- Builds Docker image from Dockerfile
- Starts 1 seed node + 2 miners
- All nodes share a bridge network
- Data persists in Docker volumes

**Ports:**
```
Seed RPC:    127.0.0.1:18332
Seed P2P:    127.0.0.1:9001
Miner-1 RPC: 127.0.0.1:18333
Miner-2 RPC: 127.0.0.1:18334
```

**Clean up:**
```bash
docker-compose -f docker-compose.testnet.yml down -v
```

---

### 2. VPS Deployment (Systemd Services)

#### File: `scripts/deploy-vps.sh`

**Use when:** Deploying to production/staging VPS, updates binaries/frontend.

**Setup (one-time):**

On VPS (`omnibus-vps:/root/omnibus-blockchain`), create systemd service files:

```bash
# /etc/systemd/system/omnibus-testnet.service
[Unit]
Description=OmniBus Blockchain (Testnet)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/omnibus-blockchain
ExecStart=/root/omnibus-blockchain/zig-out/bin/omnibus-node --mode seed --node-id testnet-seed-1 --primary --port 9001 --rpc-port 18332 --ws-port 18334
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```bash
# /etc/systemd/system/omnibus-mainnet.service
[Unit]
Description=OmniBus Blockchain (Mainnet)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/omnibus-blockchain
ExecStart=/root/omnibus-blockchain/zig-out/bin/omnibus-node --mode seed --node-id mainnet-seed-1 --primary --port 9000 --rpc-port 8332 --ws-port 8334
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Then:
```bash
sudo systemctl daemon-reload
sudo systemctl enable omnibus-testnet omnibus-mainnet
sudo systemctl start omnibus-testnet omnibus-mainnet
```

**Deploy updates:**
```bash
# From local machine
bash scripts/deploy-vps.sh --testnet --build

# Or specific service
bash scripts/deploy-vps.sh --mainnet

# Or all services
bash scripts/deploy-vps.sh --all --build
```

**Check status:**
```bash
ssh omnibus-vps systemctl status omnibus-testnet
ssh omnibus-vps journalctl -u omnibus-testnet -f
```

---

### 3. Gitea Actions CI/CD

#### File: `.gitea/workflows/ci.yml`

**Use when:** Automated testing on every push/PR.

**Triggers:**
- Push to any branch
- PR to main

**What it does:**
1. Installs Zig 0.15.2
2. Builds node (`-Doqs=false`)
3. Runs test suites (crypto, chain, net, shard, storage, light, econ)
4. Builds frontend (TypeScript, Vite)
5. Scans inventory (generates STATUS/INVENTORY.json)
6. Smoke tests node startup

**Time:** ~15-20 minutes per run

**Setup:**
See [GITEA_ACTIONS_SETUP.md](GITEA_ACTIONS_SETUP.md)

**View results:**
- Gitea UI → **Actions** tab
- Click workflow run → view logs

---

## Port Reference

| Port | Service | Node Type | Protocol |
|------|---------|-----------|----------|
| 8332 | JSON-RPC (mainnet) | All | HTTP |
| 8334 | WebSocket (mainnet) | All | WS |
| 9000 | P2P (mainnet) | Seed | TCP |
| 18332 | JSON-RPC (testnet) | All | HTTP |
| 18334 | WebSocket (testnet) | All | WS |
| 9001 | P2P (testnet) | Seed | TCP |
| 18444 | JSON-RPC (regtest) | All | HTTP |
| 19000 | P2P (regtest) | Seed | TCP |

---

## Build System

### Flags

| Flag | Purpose | Default |
|------|---------|---------|
| `-Doqs=false` | Disable liboqs (PQ crypto) | true (on Linux), false (Windows) |
| `-Doqs=true` | Enable liboqs | (requires build at `/root/liboqs-src/build/`) |
| `-Devm=false` | Disable EVM support | true |
| `-Doptimize=ReleaseFast` | Fast release build | ReleaseSafe |
| `-Doptimize=ReleaseSafe` | Safe release (bounds checks) | default |
| `-Doptimize=Debug` | Debug mode (slow) | no default |

### Examples

```bash
# Development (no PQ, fast)
zig build -Doqs=false

# Production (with PQ, on Linux/VPS)
zig build -Doqs=true -Doptimize=ReleaseSafe

# CI (no PQ, no EVM — fastest)
zig build -Doqs=false -Devm=false

# Benchmarks
zig build bench
```

---

## Testing

### Test Groups

| Command | What | Time |
|---------|------|------|
| `zig build test-crypto` | Cryptography | 1-2 min |
| `zig build test-chain` | Blockchain core | 5-10 min |
| `zig build test-net` | Networking | 3-5 min |
| `zig build test-shard` | Sharding | 1-2 min |
| `zig build test-storage` | Storage | 2-3 min |
| `zig build test-light` | Light client | 1-2 min |
| `zig build test-econ` | Economic modules | 1-2 min |
| `zig build test` | All (no PQ) | 15-20 min |
| `zig build test-wallet` | Wallet (needs liboqs) | 5 min |

### Frontend Testing

```bash
cd frontend

# Install deps
npm install

# Type check
npx tsc --noEmit

# Build
npm run build

# Run dev server
npm run dev
```

---

## Monitoring & Health Checks

### RPC Health

```bash
# Check block height
curl -s -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getblockcount","params":[],"id":1}' | jq

# Check peer count
curl -s -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getpeerinfo","params":[],"id":1}' | jq

# Check mining info
curl -s -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getmininginfo","params":[],"id":1}' | jq
```

### Process Health

```bash
# Local
pgrep -a omnibus-node

# Docker
docker-compose -f docker-compose.testnet.yml ps

# VPS
ssh omnibus-vps systemctl status omnibus-testnet omnibus-mainnet
ssh omnibus-vps journalctl -u omnibus-testnet -f
```

### Metrics to Monitor

- **Block height:** Should increase every 10s
- **Peer count:** Should be > 0 for miners, stable for seeds
- **Mempool size:** Should not grow unboundedly
- **Hash rate:** Should be non-zero for mining nodes
- **Disk usage:** omnibus-chain.dat grows ~1KB per block

---

## Troubleshooting

### Node won't start

```bash
# Check logs
docker logs omnibus-testnet-seed
# or
journalctl -u omnibus-testnet -f

# Common issues:
# 1. Port already in use: kill old process or change port
# 2. Missing omnibus-chain.dat: node creates on first run
# 3. Corrupted chain state: delete omnibus-chain.dat and resync
```

### Node stuck syncing

```bash
# Check peer count
curl -s -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getpeerinfo","params":[],"id":1}' | jq '.result | length'

# If 0 peers, node can't sync. Restart with correct seed host.
```

### High CPU during mining

Mining uses 1 CPU core by default. If CPU is high:
- Check if multiple nodes running: `pgrep -c omnibus-node`
- Check if benchmarks running in background: `pgrep -a benchmark`
- Increase hardware or reduce concurrency

### Docker build fails

```bash
# Rebuild without cache
docker-compose -f docker-compose.testnet.yml build --no-cache

# Check Dockerfile (uses -Doqs=false on Linux)
cat Dockerfile | grep "zig build"
```

---

## CI/CD Integration Points

### GitHub Actions (if used)

To use GitHub Actions (instead of Gitea):

1. Copy `.gitea/workflows/ci.yml` → `.github/workflows/ci.yml`
2. Update any Gitea-specific syntax
3. Push to GitHub

GitHub Actions are compatible with Gitea Actions YAML syntax.

### Local CI (before push)

```bash
#!/bin/bash
# Run CI locally before pushing
set -e
echo "Building..."
zig build -Doqs=false

echo "Testing crypto..."
zig build test-crypto -Doqs=false

echo "Testing chain..."
zig build test-chain -Doqs=false

echo "Building frontend..."
cd frontend && npm install && npm run build && cd ..

echo "All checks passed ✓"
```

---

## Inventory Tracking

The CI auto-scans the codebase and generates:

**File:** `STATUS/INVENTORY.json`

**Auto-updated on:** Every push to main (if changed)

**Contents:**
- All core/*.zig modules (line count, deps)
- Test coverage by group
- Frontend modules
- Build configuration
- Dependency graph

**Usage:**
- Read before sessions: `python tools/inventory-scan.py --md`
- Audit drift: `python tools/audit-pq-conventions.py`
- Manual scan: `python tools/inventory-scan.py --json --out STATUS/INVENTORY.json`

---

## Next Steps

1. **Enable Gitea Actions** (see [GITEA_ACTIONS_SETUP.md](GITEA_ACTIONS_SETUP.md))
2. **Set up VPS services** (create systemd files above)
3. **Test Docker compose locally:**
   ```bash
   docker-compose -f docker-compose.testnet.yml up -d
   docker-compose -f docker-compose.testnet.yml ps
   ```
4. **Try a deploy:**
   ```bash
   bash scripts/deploy-vps.sh --testnet
   ```
5. **Monitor logs:**
   ```bash
   ssh omnibus-vps journalctl -u omnibus-testnet -f
   ```

---

## Reference Files

- **CI Workflow:** `.gitea/workflows/ci.yml`
- **Docker (testnet):** `docker-compose.testnet.yml`
- **Deploy script:** `scripts/deploy-vps.sh`
- **PR template:** `.gitea/PULL_REQUEST_TEMPLATE.md`
- **Gitea setup:** `GITEA_ACTIONS_SETUP.md`
- **Build config:** `build.zig`
- **Dockerfile:** `Dockerfile`

---

## Support

For issues, refer to:
- **Build problems:** `build.zig`, check Zig version
- **Network issues:** Check ports, firewall, P2P connectivity
- **CI/CD failures:** See `.gitea/workflows/ci.yml` logs, runner status
- **VPS deployment:** Check systemd status, SSH access, disk space
