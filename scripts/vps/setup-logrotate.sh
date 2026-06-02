#!/usr/bin/env bash
# setup-logrotate.sh — install daily logrotate config for OmniBus VPS logs.
# Run once on VPS:  sudo bash setup-logrotate.sh

set -euo pipefail

cat | sudo tee /etc/logrotate.d/omnibus > /dev/null <<'EOF'
/var/log/omnibus/*.log {
    daily
    rotate 7
    size 100M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    dateext
}
EOF

echo "[logrotate] /etc/logrotate.d/omnibus installed"
echo "Daily rotation, keep 7 days, force-rotate at 100M, compress old."
sudo logrotate -d /etc/logrotate.d/omnibus 2>&1 | tail -10
