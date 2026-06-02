#!/usr/bin/env bash
# _build-deploy.sh — Build local, sync core/*.zig to VPS, build remote, restart, health-check.
# Auto-rollback on failure (git stash on remote).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"

VPS_HOST="${VPS_HOST:-omnibus-vps}"
VPS_PATH="${VPS_PATH:-/root/omnibus-blockchain}"
SERVICES=(omnibus-mainnet omnibus-mainnet-miner omnibus-testnet omnibus-regtest)
NO_CONFIRM="${NO_CONFIRM:-0}"
for arg in "$@"; do
    [ "$arg" = "-y" ] || [ "$arg" = "--yes" ] && NO_CONFIRM=1
done

print_header "Build + Deploy"
echo "${C_DIM}local: $ROOT_DIR  →  $VPS_HOST:$VPS_PATH${C_RESET}"

# 1) Local build
echo
echo "${C_BLUE}-- step 1/6: local build --${C_RESET}"
cd "$ROOT_DIR"
build_log=$(zig build 2>&1) && build_rc=0 || build_rc=$?
if [ "$build_rc" -ne 0 ]; then
    echo "${C_RED}local build FAILED:${C_RESET}"
    echo "$build_log" | grep -E "error:|note:" | head -10
    exit 1
fi
echo "  ${C_GREEN}OK${C_RESET} local build clean"

# 2) Determine changed files (vs last successful HEAD)
echo
echo "${C_BLUE}-- step 2/6: detecting changed core/*.zig --${C_RESET}"
CHANGED=$(git -C "$ROOT_DIR" diff --name-only HEAD -- 'core/*.zig' 2>/dev/null || true)
CHANGED_STAGED=$(git -C "$ROOT_DIR" diff --name-only --cached -- 'core/*.zig' 2>/dev/null || true)
ALL_CHANGED=$(printf '%s\n%s\n' "$CHANGED" "$CHANGED_STAGED" | sort -u | grep -v '^$' || true)

if [ -z "$ALL_CHANGED" ]; then
    echo "  ${C_YELLOW}info${C_RESET} no uncommitted core/*.zig — re-uploading all (use -y to skip prompt)"
    ALL_CHANGED=$(ls "$ROOT_DIR/core"/*.zig | sed "s|$ROOT_DIR/||")
fi
echo "$ALL_CHANGED" | sed 's|^|  changed: |'

# 3) Confirm
if [ "$NO_CONFIRM" != "1" ]; then
    echo
    echo "${C_YELLOW}WARNING:${C_RESET} this will rsync to PRODUCTION VPS and restart all services."
    printf "Type 'yes' to continue: "
    read -r confirm
    [ "$confirm" = "yes" ] || { echo "aborted."; exit 0; }
fi

# 4) Snapshot remote (rollback point)
echo
echo "${C_BLUE}-- step 3/6: remote snapshot (git stash) --${C_RESET}"
ssh "$VPS_HOST" "cd $VPS_PATH && git stash push -u -m 'auto-rollback-$(date +%s)' || true" 2>&1 | tail -3
ROLLBACK_REF=$(ssh "$VPS_HOST" "cd $VPS_PATH && git stash list | head -1 | sed -n 's/^\(stash@{[0-9]\+}\).*/\1/p'" 2>/dev/null || echo "")
echo "  rollback ref: ${ROLLBACK_REF:-<none>}"

# 5) Sync files
echo
echo "${C_BLUE}-- step 4/6: scp core/*.zig --${C_RESET}"
while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ ! -f "$ROOT_DIR/$f" ] && continue
    scp -q "$ROOT_DIR/$f" "$VPS_HOST:$VPS_PATH/$f"
    echo "  ${C_GREEN}sent${C_RESET} $f"
done <<< "$ALL_CHANGED"

# 6) Remote build
echo
echo "${C_BLUE}-- step 5/6: remote zig build --${C_RESET}"
remote_out=$(ssh "$VPS_HOST" "cd $VPS_PATH && zig build 2>&1 | tail -5" 2>&1 || true)
echo "$remote_out" | sed 's|^|  |'
if echo "$remote_out" | grep -qE "error:"; then
    echo "${C_RED}remote build FAILED — rolling back${C_RESET}"
    if [ -n "$ROLLBACK_REF" ]; then
        ssh "$VPS_HOST" "cd $VPS_PATH && git stash pop $ROLLBACK_REF" 2>&1 | tail -3
    fi
    exit 1
fi

# 7) Restart services
echo
echo "${C_BLUE}-- step 6/6: restart services --${C_RESET}"
for svc in "${SERVICES[@]}"; do
    ssh "$VPS_HOST" "systemctl restart $svc" || {
        echo "  ${C_RED}FAIL${C_RESET} restart $svc — rolling back"
        [ -n "$ROLLBACK_REF" ] && ssh "$VPS_HOST" "cd $VPS_PATH && git stash pop $ROLLBACK_REF"
        exit 1
    }
    echo "  ${C_GREEN}restarted${C_RESET} $svc"
done

# 8) Post-restart health
echo
echo "${C_BLUE}-- post-deploy health check (5s settle) --${C_RESET}"
sleep 5
if bash "$SCRIPT_DIR/_vps-health.sh" --no-color | tail -3; then
    echo "${C_GREEN}=== DEPLOY SUCCESS ===${C_RESET}"
    if [ -n "$ROLLBACK_REF" ]; then
        ssh "$VPS_HOST" "cd $VPS_PATH && git stash drop $ROLLBACK_REF || true" >/dev/null 2>&1
    fi
    exit 0
else
    echo "${C_RED}post-deploy health FAILED — rolling back${C_RESET}"
    [ -n "$ROLLBACK_REF" ] && ssh "$VPS_HOST" "cd $VPS_PATH && git stash pop $ROLLBACK_REF && zig build && for s in ${SERVICES[*]}; do systemctl restart \$s; done"
    exit 1
fi
