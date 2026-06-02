# OmniBus BlockChainCore — CI/CD Quick Start

**Minimum 5-minute setup to get CI/CD running.**

## What's Been Created

| File | Purpose | Status |
|------|---------|--------|
| `.gitea/workflows/ci.yml` | GitHub Actions–compatible CI (runs on push/PR) | ✓ Ready |
| `docker-compose.testnet.yml` | 3-node testnet (1 seed + 2 miners) | ✓ Ready |
| `scripts/deploy-vps.sh` | VPS deployment wrapper (sync + rebuild + restart) | ✓ Ready |
| `.gitea/PULL_REQUEST_TEMPLATE.md` | Standardized PR format | ✓ Ready |
| `GITEA_ACTIONS_SETUP.md` | Complete Gitea Actions guide | ✓ Reference |
| `DEVOPS_SETUP.md` | Full DevOps reference (all deployment methods) | ✓ Reference |

---

## STEP 1: Enable Gitea Actions (5 min)

### Option A: Using Local Gitea (port 3008)

```bash
# Get runner token
docker exec gitea su git -c "gitea admin actions generate-runner-token"
# Copy the token from output

# Start runner
docker run -d --name gitea-runner \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e GITEA_INSTANCE_URL=http://gitea:3000 \
  -e GITEA_RUNNER_REGISTRATION_TOKEN=<PASTE_TOKEN_HERE> \
  gitea/act_runner:latest

# Verify
docker logs gitea-runner | tail -5
```

Then check Gitea UI:
1. Go to `http://localhost:3008`
2. **Admin** → **Actions** → **Runners**
3. Should see runner with status **Online**

### Option B: Using VPS Gitea (port 3000)

```bash
# SSH to VPS
ssh omnibus-vps

# Get token
docker exec gitea su git -c "gitea admin actions generate-runner-token"
# Copy the token

# Start runner
docker run -d --name gitea-runner \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e GITEA_INSTANCE_URL=http://localhost:3000 \
  -e GITEA_RUNNER_REGISTRATION_TOKEN=<PASTE_TOKEN_HERE> \
  gitea/act_runner:latest
```

---

## STEP 2: Test Locally (2 min)

### Build the Node

```bash
cd C:/Kits\ work/limaje\ de\ programare/1_CORE/BlockChainCore
zig build -Doqs=false

# Should output:
# Build complete! 1234 artifacts in 45s
```

### Run a Testnet (Docker)

```bash
docker-compose -f docker-compose.testnet.yml up -d

# Should see 3 containers starting:
# omnibus-testnet-seed
# omnibus-testnet-miner-1
# omnibus-testnet-miner-2

# Check logs
docker-compose -f docker-compose.testnet.yml logs -f seed
```

---

## STEP 3: Push & Trigger CI (1 min)

```bash
git push origin main
# or
git push origin feat/your-feature
```

**Watch the workflow:**

1. Go to Gitea → **Actions** tab
2. Click the workflow run
3. Watch logs as it builds, tests, and scans inventory

**Expected output:**
```
✓ Zig 0.15.2 compiler
✓ omnibus-node (no PQ)
✓ Test suites (crypto, chain, net, shard, storage, light, econ)
✓ Frontend (npm, tsc, vite build)
✓ Inventory scan (STATUS/INVENTORY.json)
```

**Time: ~15-20 minutes**

---

## STEP 4: Deploy to VPS (if needed)

### First Time Setup

```bash
# SSH to VPS
ssh omnibus-vps

# Create systemd service files (see DEVOPS_SETUP.md for full files)
sudo tee /etc/systemd/system/omnibus-testnet.service > /dev/null <<EOF
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

[Install]
WantedBy=multi-user.target
EOF

# Enable the service
sudo systemctl daemon-reload
sudo systemctl enable omnibus-testnet
sudo systemctl start omnibus-testnet

# Verify it's running
sudo systemctl status omnibus-testnet
```

### Deploy Updates

```bash
# From local machine (in BlockChainCore repo root)
bash scripts/deploy-vps.sh --testnet --build

# Expected output:
# ✓ Synced core/*.zig files
# ✓ Synced frontend/src/
# ✓ Build completed
# ✓ Services restarted
# ✓ Health check: RPC responding, block height: 150
```

---

## STEP 5: Verify Everything Works

### Local

```bash
# Check node is running
pgrep -a omnibus-node

# Check RPC endpoint
curl -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getblockcount","params":[],"id":1}' | jq
# Expected: {"jsonrpc":"2.0","result":150,"id":1}
```

### Docker Testnet

```bash
# Check containers
docker-compose -f docker-compose.testnet.yml ps

# Check RPC
docker-compose -f docker-compose.testnet.yml exec seed \
  curl -X POST http://localhost:8332 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"getblockcount","params":[],"id":1}' | jq
```

### VPS

```bash
# Check service status
ssh omnibus-vps systemctl status omnibus-testnet

# Check RPC
ssh omnibus-vps curl -X POST http://localhost:18332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getblockcount","params":[],"id":1}' | jq
```

---

## Commands Reference

### CI/CD

```bash
# Trigger CI (push to any branch)
git push origin main

# View CI results
# Gitea UI → Actions tab → click run

# View runner status
# Gitea UI → Admin → Actions → Runners
```

### Local Build & Test

```bash
# Build without PQ (CI mode, faster)
zig build -Doqs=false

# Run tests
zig build test-crypto -Doqs=false
zig build test-chain -Doqs=false
zig build test

# Frontend
cd frontend && npm install && npm run build && cd ..
```

### Docker Testnet

```bash
# Start
docker-compose -f docker-compose.testnet.yml up -d

# View logs
docker-compose -f docker-compose.testnet.yml logs -f

# Stop & clean
docker-compose -f docker-compose.testnet.yml down -v
```

### VPS Deployment

```bash
# Deploy testnet with rebuild
bash scripts/deploy-vps.sh --testnet --build

# Deploy mainnet only
bash scripts/deploy-vps.sh --mainnet

# Deploy all services
bash scripts/deploy-vps.sh --all --build

# Deploy frontend only (fast)
bash scripts/deploy-vps.sh --frontend-only

# Check status
ssh omnibus-vps systemctl status omnibus-testnet
ssh omnibus-vps journalctl -u omnibus-testnet -f
```

---

## Architecture

```
Your Local Machine (Windows)
├── zig build -Doqs=false
├── docker-compose -f docker-compose.testnet.yml up
└── git push origin main
    ↓
Gitea (local or VPS)
├── CI Workflow starts (.gitea/workflows/ci.yml)
├── Zig 0.15.2 compiler installed
├── Build omnibus-node
├── Run test suites (15-20 min)
├── Build frontend
├── Scan inventory
├── Commit STATUS/INVENTORY.json (if changed)
└── Workflow complete ✓
    ↓
VPS Deployment (optional)
├── bash scripts/deploy-vps.sh --testnet --build
├── Syncs core/*.zig + frontend/src
├── Rebuilds with liboqs on VPS
├── Restarts omnibus-testnet service
└── Health check: RPC responding
```

---

## Troubleshooting

### Runner shows "Offline"

```bash
# Check runner is running
docker ps | grep act_runner

# Check logs
docker logs gitea-runner | tail -20

# Restart
docker restart gitea-runner
```

### Workflow fails with "no runners available"

1. Check runner is online: Gitea UI → Admin → Actions → Runners
2. Check runner has tag `ubuntu-latest`: edit runner in UI, add tag if missing
3. Restart runner: `docker restart gitea-runner`

### Build fails ("Zig not found")

The workflow downloads Zig automatically. If it fails:
1. Check network connectivity on runner
2. Manually install Zig on runner:
   ```bash
   docker exec gitea-runner bash -c "
     wget https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz
     tar xf zig-linux-x86_64-0.15.2.tar.xz
     mv zig-linux-x86_64-0.15.2 /opt/zig
     ln -s /opt/zig/zig /usr/local/bin/zig
   "
   ```

### Node won't start on VPS

```bash
ssh omnibus-vps
journalctl -u omnibus-testnet -f  # Check logs
sudo systemctl restart omnibus-testnet
sudo systemctl status omnibus-testnet
```

---

## Next: Full Reference Docs

For more detailed information, see:

- **`.gitea/workflows/ci.yml`** — CI workflow configuration
- **`docker-compose.testnet.yml`** — Docker Compose (3-node testnet)
- **`scripts/deploy-vps.sh`** — VPS deployment with systemd
- **`GITEA_ACTIONS_SETUP.md`** — Complete Gitea Actions guide
- **`DEVOPS_SETUP.md`** — Full DevOps reference (architecture, flags, monitoring)
- **`.gitea/PULL_REQUEST_TEMPLATE.md`** — PR template with test plan

---

## What's Next?

1. ✓ CI/CD configured
2. ✓ Docker testnet ready
3. ✓ VPS deployment scripted
4. Next: Configure Gitea runner + push test commit
5. Then: Monitor first CI run
6. Finally: Deploy to VPS via script

**Total time to running CI: ~30 minutes (one-time setup)**

**Time per deploy: ~20 minutes (CI) + 5 minutes (VPS restart)**
