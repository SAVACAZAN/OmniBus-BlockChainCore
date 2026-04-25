#!/usr/bin/env bash
# debug-nginx.sh — diagnoza HTTPS RPC stuck pe Nginx
#
# Usage: sudo bash debug-nginx.sh

set -uo pipefail

DOMAIN="omnibusblockchain.cc"

echo "==========================================="
echo " HTTPS Nginx Debug"
echo "==========================================="
echo ""

# 1. Test cu --resolve la 127.0.0.1 (bypass DNS, vedem daca Nginx e blocaj)
echo "=== Test 1: HTTPS la 127.0.0.1:443 cu Host: ${DOMAIN} ==="
curl -v -k -m 7 --resolve "${DOMAIN}:443:127.0.0.1" \
    "https://${DOMAIN}/api-testnet" \
    -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockcount","params":[]}' 2>&1 | tail -25

echo ""
echo "=== Test 2: HTTPS la IP public ${DOMAIN} ==="
curl -v -m 7 "https://${DOMAIN}/api-testnet" \
    -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockcount","params":[]}' 2>&1 | tail -25

echo ""
echo "=== Test 3: HTTPS GET / (Vite) ==="
curl -v -m 7 "https://${DOMAIN}/" 2>&1 | tail -25

echo ""
echo "=== Nginx error log (ultimele 30) ==="
sudo tail -30 /var/log/nginx/error.log

echo ""
echo "=== Nginx access log (ultimele 10) ==="
sudo tail -10 /var/log/nginx/access.log

echo ""
echo "=== Verifica daca exista alt nginx config care intercepteaza :443 ==="
echo "All sites-enabled:"
ls -la /etc/nginx/sites-enabled/
echo ""
echo "All conf.d/:"
ls -la /etc/nginx/conf.d/ 2>/dev/null
echo ""
echo "Cauta listen 443 in toate config-urile:"
sudo grep -rn 'listen.*443' /etc/nginx/ 2>/dev/null | grep -v '#'

echo ""
echo "=== Procese Nginx active (worker count) ==="
ps aux | grep '[n]ginx' | head -10

echo ""
echo "=== Nginx -T (full effective config) — server blocks ==="
sudo nginx -T 2>&1 | grep -E '^\s*(server|server_name|listen|location|proxy_pass)' | head -60
