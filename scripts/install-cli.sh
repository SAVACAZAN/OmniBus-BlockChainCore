#!/usr/bin/env bash
# install-cli.sh — installer for omnibus-cli
#
# Detects OS (Linux/macOS/WSL), builds via `zig build`, copies the binary,
# installs the man page, the bash/zsh/fish completion that matches the
# user's shell, and creates a ~/.omnibus/cli.conf template.
#
# Usage:
#   ./scripts/install-cli.sh [--prefix /path] [--user]
#
#   --prefix DIR    Install root (default: /usr/local; --user → ~/.local)
#   --user          Install into ~/.local without sudo
#   --no-build      Skip `zig build` (use existing zig-out/bin/omnibus-cli)
#   --no-completion Skip shell completion install
#   -h, --help      Show this help

set -euo pipefail

# ─── parse args ──────────────────────────────────────────────────────────────
PREFIX=/usr/local
USER_INSTALL=0
DO_BUILD=1
DO_COMPLETION=1

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --user) USER_INSTALL=1; PREFIX="$HOME/.local"; shift ;;
        --no-build) DO_BUILD=0; shift ;;
        --no-completion) DO_COMPLETION=0; shift ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ─── detect environment ──────────────────────────────────────────────────────
OS_NAME="unknown"
case "$(uname -s)" in
    Linux*)
        if grep -qi microsoft /proc/version 2>/dev/null; then OS_NAME="wsl"
        else OS_NAME="linux"; fi ;;
    Darwin*) OS_NAME="macos" ;;
    MINGW*|CYGWIN*|MSYS*) OS_NAME="windows" ;;
esac
echo "==> Detected OS: $OS_NAME"

# ─── locate repo root ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
echo "==> Repo: $REPO"

# ─── build ────────────────────────────────────────────────────────────────────
if [ "$DO_BUILD" -eq 1 ]; then
    if ! command -v zig >/dev/null; then
        echo "ERROR: zig not in PATH. Install Zig 0.15.2+ from https://ziglang.org/download/" >&2
        exit 1
    fi
    echo "==> Building (zig build install)..."
    (cd "$REPO" && zig build install)
fi

BIN_SRC="$REPO/zig-out/bin/omnibus-cli"
[ "$OS_NAME" = "windows" ] && BIN_SRC="${BIN_SRC}.exe"

if [ ! -x "$BIN_SRC" ] && [ ! -f "$BIN_SRC" ]; then
    echo "ERROR: $BIN_SRC not found. Run with --no-build only after a successful build." >&2
    exit 1
fi

# ─── helper: maybe-sudo ──────────────────────────────────────────────────────
SUDO=""
if [ "$USER_INSTALL" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

# ─── install binary ──────────────────────────────────────────────────────────
BIN_DIR="$PREFIX/bin"
echo "==> Installing binary → $BIN_DIR/omnibus-cli"
$SUDO mkdir -p "$BIN_DIR"
$SUDO install -m 0755 "$BIN_SRC" "$BIN_DIR/omnibus-cli"

# ─── install man page ────────────────────────────────────────────────────────
MAN_SRC="$REPO/docs/cli/omnibus-cli.1"
MAN_DIR="$PREFIX/share/man/man1"
if [ -f "$MAN_SRC" ]; then
    echo "==> Installing man page → $MAN_DIR/omnibus-cli.1"
    $SUDO mkdir -p "$MAN_DIR"
    $SUDO install -m 0644 "$MAN_SRC" "$MAN_DIR/omnibus-cli.1"
    if command -v mandb >/dev/null; then $SUDO mandb -q || true; fi
fi

# ─── install completion (best match for $SHELL) ──────────────────────────────
if [ "$DO_COMPLETION" -eq 1 ]; then
    SHELL_BASE="$(basename "${SHELL:-bash}")"
    case "$SHELL_BASE" in
        bash)
            if [ "$USER_INSTALL" -eq 1 ]; then
                DEST="$HOME/.local/share/bash-completion/completions"
            else
                DEST="$PREFIX/share/bash-completion/completions"
            fi
            echo "==> Installing bash completion → $DEST/omnibus-cli"
            $SUDO mkdir -p "$DEST"
            $SUDO install -m 0644 "$REPO/scripts/completion/omnibus-cli.bash" \
                "$DEST/omnibus-cli"
            ;;
        zsh)
            if [ "$USER_INSTALL" -eq 1 ]; then
                DEST="$HOME/.zsh/completions"
            else
                DEST="$PREFIX/share/zsh/site-functions"
            fi
            echo "==> Installing zsh completion → $DEST/_omnibus-cli"
            $SUDO mkdir -p "$DEST"
            $SUDO install -m 0644 "$REPO/scripts/completion/omnibus-cli.zsh" \
                "$DEST/_omnibus-cli"
            if [ "$USER_INSTALL" -eq 1 ]; then
                echo "    (add 'fpath+=$DEST; autoload -U compinit && compinit' to ~/.zshrc)"
            fi
            ;;
        fish)
            DEST="$HOME/.config/fish/completions"
            echo "==> Installing fish completion → $DEST/omnibus-cli.fish"
            mkdir -p "$DEST"
            install -m 0644 "$REPO/scripts/completion/omnibus-cli.fish" \
                "$DEST/omnibus-cli.fish"
            ;;
        *)
            echo "==> Skipping completion (unknown shell: $SHELL_BASE)"
            ;;
    esac
fi

# ─── ~/.omnibus/cli.conf template ────────────────────────────────────────────
CONF_DIR="$HOME/.omnibus"
CONF="$CONF_DIR/cli.conf"
if [ ! -f "$CONF" ]; then
    echo "==> Creating config template → $CONF"
    mkdir -p "$CONF_DIR"
    cat > "$CONF" <<EOF
# omnibus-cli configuration (read by shell wrappers, not by the binary itself).
# Uncomment and edit as needed.

#OMNIBUS_RPC_URL=http://127.0.0.1:8332
#OMNIBUS_CHAIN=mainnet
#OMNIBUS_RPC_TOKEN=

# Public testnet shortcut:
#OMNIBUS_RPC_URL=https://omnibusblockchain.cc:8443/api-testnet
#OMNIBUS_CHAIN=testnet
EOF
    chmod 600 "$CONF"
fi

# ─── ~/.omnibus/known_addresses template ─────────────────────────────────────
KA="$CONF_DIR/known_addresses"
if [ ! -f "$KA" ]; then
    cat > "$KA" <<EOF
# One bech32 OmniBus address per line (used by shell completion).
# Lines starting with '#' are ignored.
ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0
EOF
fi

# ─── ~/.ssh/config alias for omnibus-vps (commented stub) ────────────────────
SSHCFG="$HOME/.ssh/config"
if [ ! -f "$SSHCFG" ] || ! grep -q "Host omnibus-vps" "$SSHCFG" 2>/dev/null; then
    mkdir -p "$HOME/.ssh"
    cat >> "$SSHCFG" <<'EOF'

# OmniBus VPS — uncomment and adjust to fit your deployment.
#Host omnibus-vps
#    HostName omnibusblockchain.cc
#    User root
#    IdentityFile ~/.ssh/id_ed25519
#    ServerAliveInterval 30
EOF
    chmod 600 "$SSHCFG"
    echo "==> Added omnibus-vps SSH stub to $SSHCFG"
fi

# ─── final report ────────────────────────────────────────────────────────────
echo
echo "==> Done."
echo "    Binary:      $BIN_DIR/omnibus-cli"
[ -f "$MAN_SRC" ] && echo "    Man page:    man omnibus-cli"
echo "    Config:      $CONF"
echo "    Addresses:   $KA"
echo
echo "Quick test:"
echo "    omnibus-cli --remote --chain testnet health"
