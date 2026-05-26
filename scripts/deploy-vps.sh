#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# OmniBus BlockChainCore — VPS Deployment Script
# ═══════════════════════════════════════════════════════════════════════════════
#
# Wraps the manual SCP + rebuild + restart sequence for multi-service deployment.
# Handles testnet, mainnet, and regtest via systemd services.
#
# Usage:
#   bash scripts/deploy-vps.sh [--testnet|--mainnet|--all] [--build] [--frontend-only]
#
# Examples:
#   # Deploy testnet only (if binary exists, just restart)
#   bash scripts/deploy-vps.sh --testnet
#
#   # Deploy testnet + rebuild
#   bash scripts/deploy-vps.sh --testnet --build
#
#   # Deploy all services
#   bash scripts/deploy-vps.sh --all --build
#
#   # Deploy frontend only (fast, no Zig rebuild)
#   bash scripts/deploy-vps.sh --frontend-only
#
# Environment:
#   VPS_HOST         SSH alias (default: omnibus-vps)
#   VPS_REMOTE_DIR   Remote root directory (default: /root/omnibus-blockchain)
#   ZIG_OPTIMIZE     Build optimization (default: ReleaseSafe for stability)
#   ZIG_OQS          Enable liboqs (default: true on Linux VPS)
#
# Services on VPS:
#   - omnibus-testnet  (testnet chain, RPC on 18332, P2P on 9001)
#   - omnibus-mainnet  (mainnet chain, RPC on 8332, P2P on 9000)
#   - omnibus-regtest  (regtest chain, RPC on 18444, P2P on 19000) [optional]
#
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
readonly VPS_HOST="${VPS_HOST:-omnibus-vps}"
readonly REMOTE_DIR="${VPS_REMOTE_DIR:-/root/omnibus-blockchain}"
readonly ZIG_OPTIMIZE="${ZIG_OPTIMIZE:-ReleaseSafe}"
readonly ZIG_OQS="${ZIG_OQS:-true}"

# Determine build flags for VPS (with liboqs on Linux)
ZIG_BUILD_FLAGS="-Doptimize=${ZIG_OPTIMIZE}"
if [ "${ZIG_OQS}" = "true" ]; then
    ZIG_BUILD_FLAGS="${ZIG_BUILD_FLAGS} -Doqs=true"
fi

# ── Defaults ─────────────────────────────────────────────────────────────────
MODE="testnet"      # testnet | mainnet | all | frontend-only
DO_BUILD=false
DO_SYNC_CORE=false
DO_SYNC_FRONTEND=false

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --testnet)     MODE="testnet"        ; DO_SYNC_CORE=true ; DO_SYNC_FRONTEND=true ; shift ;;
        --mainnet)     MODE="mainnet"        ; DO_SYNC_CORE=true ; DO_SYNC_FRONTEND=true ; shift ;;
        --all)         MODE="all"            ; DO_SYNC_CORE=true ; DO_SYNC_FRONTEND=true ; shift ;;
        --frontend-only) MODE="frontend-only" ; DO_SYNC_FRONTEND=true ; shift ;;
        --build)       DO_BUILD=true         ; shift ;;
        --help|-h)     show_help             ; exit 0 ;;
        *)             echo "Unknown option: $1" >&2 ; exit 1 ;;
    esac
done

# Default: if no flags given, just sync & restart testnet
if [ "$MODE" = "testnet" ] && [ "$DO_SYNC_CORE" = false ]; then
    DO_SYNC_CORE=true
    DO_SYNC_FRONTEND=true
fi

# ── Helper: check SSH connectivity ───────────────────────────────────────────
check_vps() {
    if ! ssh -q "${VPS_HOST}" "exit" 2>/dev/null; then
        echo "ERROR: Cannot connect to ${VPS_HOST}. Check SSH alias or key." >&2
        exit 1
    fi
}

# ── Helper: run command on VPS ───────────────────────────────────────────────
vps_run() {
    ssh "${VPS_HOST}" "cd ${REMOTE_DIR} && $*"
}

# ── Helper: SCP files ────────────────────────────────────────────────────────
scp_to_vps() {
    local src="$1"
    local dst="$2"
    echo "  → SCP $src"
    scp -q "$src" "${VPS_HOST}:${dst}"
}

# ── Step 1: Sync source files ────────────────────────────────────────────────
sync_core() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 1: Sync core/*.zig files"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Create core/ directory on VPS if not exists
    vps_run "mkdir -p core"

    # SCP all .zig files from core/
    for file in core/*.zig; do
        if [ -f "$file" ]; then
            scp_to_vps "$file" "${REMOTE_DIR}/core/"
        fi
    done

    # Also sync build.zig
    if [ -f "build.zig" ]; then
        scp_to_vps "build.zig" "${REMOTE_DIR}/"
    fi

    echo "  ✓ Synced $(find core -name '*.zig' | wc -l) .zig files"
}

# ── Step 2: Sync frontend files ──────────────────────────────────────────────
sync_frontend() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 2: Sync frontend/src files"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Create frontend/src directory on VPS if not exists
    vps_run "mkdir -p frontend/src"

    # Use rsync if available (faster), fall back to scp
    if command -v rsync &> /dev/null; then
        echo "  → rsync frontend/src/ to VPS"
        rsync -az --delete -e ssh frontend/src/ "${VPS_HOST}:${REMOTE_DIR}/frontend/src/" || {
            echo "  ⚠ rsync failed, falling back to scp"
            scp -qr frontend/src/* "${VPS_HOST}:${REMOTE_DIR}/frontend/src/" 2>/dev/null || true
        }
    else
        echo "  → scp frontend/src/ to VPS"
        scp -qr frontend/src/* "${VPS_HOST}:${REMOTE_DIR}/frontend/src/" 2>/dev/null || true
    fi

    # Also sync package.json, tsconfig.json, vite.config.ts if they exist
    for file in package.json package-lock.json tsconfig.json vite.config.ts; do
        if [ -f "frontend/$file" ]; then
            scp_to_vps "frontend/$file" "${REMOTE_DIR}/frontend/"
        fi
    done

    echo "  ✓ Synced frontend/src/"
}

# ── Step 3: Rebuild Zig binary on VPS ────────────────────────────────────────
rebuild_zig() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 3: Build omnibus-node on VPS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    echo "  → Building with: zig build ${ZIG_BUILD_FLAGS}"
    vps_run "zig build ${ZIG_BUILD_FLAGS} 2>&1" | tail -20 || {
        echo "ERROR: Build failed on VPS" >&2
        exit 1
    }
    echo "  ✓ Build completed"
}

# ── Step 4: Restart services ─────────────────────────────────────────────────
restart_services() {
    local services=()

    case "$MODE" in
        testnet)     services=("omnibus-testnet") ;;
        mainnet)     services=("omnibus-mainnet") ;;
        all)         services=("omnibus-testnet" "omnibus-mainnet") ;;
        frontend-only) services=() ;;
    esac

    if [ ${#services[@]} -eq 0 ]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Step 4: Restart services (SKIPPED — frontend-only mode)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 4: Restart systemd services"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    for service in "${services[@]}"; do
        echo "  → Restarting ${service}..."
        vps_run "sudo systemctl restart ${service}" || {
            echo "⚠ Failed to restart ${service} (may not exist yet, or needs sudo)" >&2
        }
    done

    echo "  ✓ Services restarted"
}

# ── Step 5: Health checks ────────────────────────────────────────────────────
health_check() {
    local services=()

    case "$MODE" in
        testnet)     services=("omnibus-testnet") ;;
        mainnet)     services=("omnibus-mainnet") ;;
        all)         services=("omnibus-testnet" "omnibus-mainnet") ;;
        frontend-only) services=() ;;
    esac

    if [ ${#services[@]} -eq 0 ]; then
        return 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 5: Health check"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Map service name to RPC port
    declare -A service_ports=(
        ["omnibus-testnet"]="18332"
        ["omnibus-mainnet"]="8332"
        ["omnibus-regtest"]="18444"
    )

    for service in "${services[@]}"; do
        local port="${service_ports[$service]:-8332}"
        echo ""
        echo "  Checking ${service} (port ${port})..."

        vps_run "
            # Wait up to 30 seconds for RPC to be ready
            for i in {1..30}; do
                RESULT=\$(curl -s -X POST http://localhost:${port} \
                    -H 'Content-Type: application/json' \
                    -d '{\"jsonrpc\":\"2.0\",\"method\":\"getblockcount\",\"params\":[],\"id\":1}' 2>/dev/null || echo '')
                if echo \"\$RESULT\" | grep -q 'result'; then
                    HEIGHT=\$(echo \"\$RESULT\" | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r.get(\"result\", \"N/A\"))' 2>/dev/null || echo 'unknown')
                    echo \"    ✓ RPC responding, block height: \$HEIGHT\"
                    break
                fi
                sleep 1
            done

            # Check service status
            STATUS=\$(sudo systemctl is-active ${service} 2>/dev/null || echo 'unknown')
            echo \"    ✓ Service status: \$STATUS\"
        " || {
            echo "    ⚠ Health check failed (service may not be running yet)"
        }
    done

    echo ""
}

# ── Main execution ───────────────────────────────────────────────────────────
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════════════╗"
    echo "║           OmniBus BlockChainCore — VPS Deployment Script                     ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Configuration:"
    echo "  VPS Host:       ${VPS_HOST}"
    echo "  Remote Dir:     ${REMOTE_DIR}"
    echo "  Mode:           ${MODE}"
    echo "  Build:          ${DO_BUILD}"
    echo "  Zig Flags:      ${ZIG_BUILD_FLAGS}"
    echo ""

    # Check SSH connectivity
    check_vps

    # Conditional steps
    [ "${DO_SYNC_CORE}" = "true" ] && sync_core
    [ "${DO_SYNC_FRONTEND}" = "true" ] && sync_frontend
    [ "${DO_BUILD}" = "true" ] && rebuild_zig

    # Always restart on full deploy
    if [ "${MODE}" != "frontend-only" ] && [ "${DO_SYNC_CORE}" = "true" ]; then
        restart_services
    fi

    # Health checks
    health_check

    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                   ✓ Deployment completed successfully                        ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Next steps:"
    case "$MODE" in
        testnet)
            echo "  • Testnet RPC:  http://${VPS_HOST}:18332"
            echo "  • Testnet P2P:  ${VPS_HOST}:9001"
            echo "  • Check status: ssh ${VPS_HOST} systemctl status omnibus-testnet"
            ;;
        mainnet)
            echo "  • Mainnet RPC:  http://${VPS_HOST}:8332"
            echo "  • Mainnet P2P:  ${VPS_HOST}:9000"
            echo "  • Check status: ssh ${VPS_HOST} systemctl status omnibus-mainnet"
            ;;
        all)
            echo "  • Testnet RPC:  http://${VPS_HOST}:18332"
            echo "  • Mainnet RPC:  http://${VPS_HOST}:8332"
            echo "  • Check status: ssh ${VPS_HOST} systemctl status omnibus-{testnet,mainnet}"
            ;;
        frontend-only)
            echo "  • Frontend synced, no services restarted"
            ;;
    esac
    echo ""
}

main "$@"
