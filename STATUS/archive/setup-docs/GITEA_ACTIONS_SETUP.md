# Gitea Actions Setup Guide

This guide explains how to set up Gitea Actions for OmniBus BlockChainCore CI/CD. The workflow is defined in `.gitea/workflows/ci.yml` and runs automatically on every push and pull request.

## Prerequisites

- **Gitea 1.20+** (supports Actions)
- **Docker** (for action runners)
- **SSH access** to the Gitea server (or local setup)

## What the CI does

The workflow (`.gitea/workflows/ci.yml`) runs on every push to any branch and on PRs to main:

1. **Setup Zig 0.15.2** compiler
2. **Build the node** (`zig build -Doqs=false -Devm=false`)
3. **Run test suites** (crypto, chain, net, shard, storage, light, econ)
4. **Build & lint frontend** (npm install, tsc check, vite build)
5. **Scan inventory** (auto-generates STATUS/INVENTORY.json)
6. **Smoke test** (node startup verification)

Total time: ~15-20 minutes per run.

## Enable Gitea Actions

### Option 1: Local Gitea (port 3008)

If you have a local Gitea running on port 3008:

#### 1. Register a Gitea Actions Runner

```bash
# SSH into the Gitea container (or local machine running Gitea)
ssh localhost -p 3008
# or
docker exec -it gitea bash

# Create a runner registration token
gitea admin actions generate-runner-token

# Output: <TOKEN>
```

#### 2. Start a runner (Docker)

```bash
# Pull Gitea runner image
docker pull gitea/act_runner:latest

# Run the runner
docker run -d \
  --name gitea-runner \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e GITEA_INSTANCE_URL=http://gitea:3000 \
  -e GITEA_RUNNER_REGISTRATION_TOKEN=<TOKEN> \
  gitea/act_runner:latest
```

Or use docker-compose:

```yaml
services:
  gitea-runner:
    image: gitea/act_runner:latest
    environment:
      GITEA_INSTANCE_URL: http://gitea:3000
      GITEA_RUNNER_REGISTRATION_TOKEN: <TOKEN>
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    restart: unless-stopped
```

#### 3. Verify runner is online

In Gitea web UI:
1. Go to **Admin** → **Actions** → **Runners**
2. You should see your runner with status **Online**

---

### Option 2: VPS Gitea (port 3000)

If Gitea is on the VPS at `omnibus-vps:3000`:

#### 1. SSH into VPS

```bash
ssh omnibus-vps
```

#### 2. Gitea is likely in Docker

Check if Gitea is running:

```bash
docker ps | grep gitea
# Output: <container-id>  gitea/gitea:latest  ...
```

#### 3. Generate runner token

```bash
docker exec gitea su git -c "gitea admin actions generate-runner-token"

# Copy the token from output
# Token: <LONG_TOKEN_HERE>
```

#### 4. Start a runner (on VPS)

```bash
# Option A: Docker (if you have docker on VPS)
docker run -d \
  --name gitea-runner \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e GITEA_INSTANCE_URL=http://localhost:3000 \
  -e GITEA_RUNNER_REGISTRATION_TOKEN=<TOKEN> \
  gitea/act_runner:latest

# Option B: Native runner (without Docker)
wget https://github.com/gitea/act_runner/releases/download/v0.x.x/act_runner-linux-amd64
chmod +x act_runner-linux-amd64
./act_runner-linux-amd64 register --name vps-runner-1 \
  --instance-url http://localhost:3000 \
  --registration-token <TOKEN> \
  --no-interactive
./act_runner-linux-amd64 daemon
```

#### 5. Verify in Gitea web UI

```
https://omnibus-vps:3000 → Admin → Actions → Runners
```

---

## Trigger a Workflow

Once the runner is online, workflows trigger automatically:

### On Push

```bash
git push origin feat/my-feature
```

The CI will run on your branch.

### On Pull Request

```bash
git push origin feat/my-feature
# Then create PR in Gitea web UI
# CI runs automatically
```

### Manual Trigger (if supported)

In Gitea web UI, go to **Actions** → **CI** → **Run workflow**

---

## Monitor Workflow Runs

### In Gitea Web UI

1. Go to your repo → **Actions** tab
2. Click on a workflow run to see details
3. Click on a job to see logs

### Via CLI (if Gitea has API)

```bash
# List recent runs
gitea api /repos/{owner}/{repo}/actions/runs

# Get run logs
gitea api /repos/{owner}/{repo}/actions/runs/{run_id}/logs
```

---

## Troubleshooting

### Runner shows "Offline"

1. Check runner process:
   ```bash
   docker ps | grep act_runner
   # or
   pgrep -f act_runner
   ```

2. Check logs:
   ```bash
   docker logs gitea-runner
   # or
   journalctl -u act_runner
   ```

3. Verify network connectivity:
   ```bash
   docker exec gitea-runner curl http://gitea:3000
   # or
   curl http://localhost:3000 (if local)
   ```

4. Restart runner:
   ```bash
   docker restart gitea-runner
   # or
   systemctl restart act_runner
   ```

### Workflow fails with "no runners available"

1. Check runner is registered:
   ```bash
   Gitea UI → Admin → Actions → Runners
   ```

2. Check runner has required tags:
   ```
   Gitea UI → Runners → click runner → view tags (should include "ubuntu-latest")
   ```

3. Add runner tag if missing:
   - In Gitea UI, edit runner
   - Add tag: `ubuntu-latest`

### Build fails (Zig not found)

The workflow downloads Zig 0.15.2 automatically via:
```yaml
- uses: goto-bus-stop/setup-zig@v2
  with:
    version: 0.15.2
```

If this action fails:
- Check internet connectivity on runner
- Manually install Zig on runner:
  ```bash
  wget https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz
  tar xf zig-linux-x86_64-0.15.2.tar.xz
  sudo mv zig-linux-x86_64-0.15.2 /opt/zig
  sudo ln -s /opt/zig/zig /usr/local/bin/zig
  ```

### Build times out (>60 min)

The default timeout is 60 minutes. If builds exceed this:

1. Optimize build:
   ```bash
   zig build -Doqs=false -Devm=false -Doptimize=ReleaseFast
   ```

2. Increase timeout in `.gitea/workflows/ci.yml`:
   ```yaml
   build-and-test:
     timeout-minutes: 120  # Increase from 60
   ```

3. Use build caching (already enabled):
   ```yaml
   - uses: actions/cache@v3
     with:
       path: .zig-cache
       key: zig-cache-${{ runner.os }}-${{ hashFiles('build.zig', 'core/**/*.zig') }}
   ```

---

## Cache Strategy

The workflow caches:

1. **`.zig-cache`** — Compiled Zig artifacts
   - **Hit rate:** ~80% (cache key includes build.zig + core/*.zig)
   - **Save time:** ~5-10 minutes

2. **`frontend/node_modules`** — npm dependencies
   - **Hit rate:** ~95% (cache key is package-lock.json)
   - **Save time:** ~2-3 minutes

Caches are **per-branch** and automatically **purged after 7 days** of no use.

### Clear cache manually (if needed)

In Gitea UI:
1. **Settings** → **Actions** → **Caches**
2. Click **Delete** next to the cache
3. Next run will rebuild from scratch

---

## Next Steps

1. **Enable Actions in Gitea settings:**
   - Go to **Admin** → **Configuration** → **Settings**
   - Set `ACTIONS_ENABLED = true`
   - (May already be enabled)

2. **Register a runner** (see Option 1 or 2 above)

3. **Make a test push:**
   ```bash
   git push origin main
   ```

4. **Monitor the workflow:**
   - Go to **Actions** tab
   - Click the workflow run
   - Wait for completion (~15-20 min)

5. **On success:**
   - STATUS/INVENTORY.json is auto-updated
   - A commit is created (on main branch only)
   - Binaries are available for download (if artifacts are enabled)

---

## Integration with VPS Deployment

Once CI passes, deploy to VPS:

```bash
# Option 1: Full deployment with rebuild
bash scripts/deploy-vps.sh --testnet --build

# Option 2: Frontend only (fast)
bash scripts/deploy-vps.sh --frontend-only

# Option 3: All services
bash scripts/deploy-vps.sh --all --build
```

---

## CI Secrets (if needed later)

To add secrets (e.g., API keys, SSH keys):

1. Go to **Settings** → **Actions Secrets**
2. Click **New Secret**
3. Name: `DEPLOYMENT_KEY`, Value: `<ssh-key>`
4. Use in workflow:
   ```yaml
   - name: Deploy
     env:
       SSH_KEY: ${{ secrets.DEPLOYMENT_KEY }}
     run: |
       echo "$SSH_KEY" > ~/.ssh/id_rsa
       chmod 600 ~/.ssh/id_rsa
       ssh omnibus-vps "..."
   ```

---

## References

- [Gitea Actions Documentation](https://docs.gitea.io/en-us/actions/)
- [Act Runner Setup](https://github.com/gitea/act_runner)
- [GitHub Actions (syntax reference, compatible with Gitea)](https://docs.github.com/en/actions)
