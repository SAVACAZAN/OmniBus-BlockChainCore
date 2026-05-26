#!/usr/bin/env python3
"""
Test script for OmniBus Exchange REST API Phase 1 (HMAC-SHA512 auth).

Usage:
    python3 test_rest_hmac.py http://localhost:8080/exchange/0

Requires:
    pip install requests
"""
import sys, os, json, base64, hashlib, hmac, time, urllib.parse

try:
    import requests
except ImportError:
    print("pip install requests")
    sys.exit(1)

API_KEY_ID = os.environ.get("OB_API_KEY", "obx_1234567890abcdef12345678")
API_SECRET_B64 = os.environ.get("OB_API_SECRET", "obs_" + "a" * 64)


def kraken_sign(uri_path: str, post_data: dict, secret_b64: str) -> str:
    """
    Kraken-style HMAC-SHA512 signature.
    message = URI-PATH || SHA256(post_data_encoded)
    signature = base64( HMAC-SHA512(message, secret_raw) )
    """
    # The secret is stored as base64-encoded 32 bytes.
    secret_raw = base64.b64decode(secret_b64)

    # Form-encode the post data (no spaces around =, &)
    encoded = urllib.parse.urlencode(post_data)

    # SHA256 of the encoded post data
    post_hash = hashlib.sha256(encoded.encode("utf-8")).digest()

    # message = URI path (raw) + SHA256 hash (raw bytes)
    message = uri_path.encode("utf-8") + post_hash

    # HMAC-SHA512
    sig = hmac.new(secret_raw, message, hashlib.sha512).digest()
    return base64.b64encode(sig).decode("ascii")


def test_public(base: str):
    print("=== Public endpoints ===")
    for ep in ["public/Time", "public/SystemStatus", "public/Assets", "public/AssetPairs"]:
        url = f"{base}/{ep}"
        r = requests.get(url, timeout=10)
        print(f"  GET {ep}: {r.status_code}  len={len(r.text)}")
        if r.status_code == 200:
            try:
                print(f"    -> {json.dumps(r.json(), indent=2)[:200]}...")
            except Exception:
                print(f"    -> (non-json) {r.text[:100]}")

    # Depth
    url = f"{base}/public/Depth?pair=OMNI/USDC&count=5"
    r = requests.get(url, timeout=10)
    print(f"  GET public/Depth: {r.status_code}")


def test_openapi(base: str):
    print("\n=== OpenAPI + Swagger ===")
    url = f"{base}/openapi.json"
    r = requests.get(url, timeout=10)
    print(f"  GET openapi.json: {r.status_code}  len={len(r.text)}")
    if r.status_code == 200:
        spec = r.json()
        print(f"    title={spec.get('info',{}).get('title')}")
        print(f"    paths={list(spec.get('paths',{}).keys())[:5]}")

    url = f"{base}/swagger-ui"
    r = requests.get(url, timeout=10)
    print(f"  GET swagger-ui: {r.status_code}  len={len(r.text)}")


def test_private_balance(base: str):
    print("\n=== Private Balance (HMAC) ===")
    if "localhost" not in base and "127.0.0.1" not in base:
        print("  Skipping private test on non-localhost (needs real keys)")
        return

    # This needs a real API key on the server.
    # We show the signature computation even if the key doesn't exist.
    nonce = str(int(time.time() * 1000))
    post = {"nonce": nonce}
    uri_path = "/exchange/0/private/Balance"
    sig = kraken_sign(uri_path, post, API_SECRET_B64)

    headers = {
        "API-Key": API_KEY_ID,
        "API-Sign": sig,
    }
    url = f"{base}/private/Balance"
    r = requests.post(url, data=post, headers=headers, timeout=10)
    print(f"  POST private/Balance: {r.status_code}")
    print(f"    body: {r.text[:300]}")


def test_private_add_order(base: str):
    print("\n=== Private AddOrder (HMAC) ===")
    if "localhost" not in base and "127.0.0.1" not in base:
        print("  Skipping private test on non-localhost")
        return

    nonce = str(int(time.time() * 1000))
    post = {
        "nonce": nonce,
        "pair": "OMNI/USDC",
        "type": "sell",
        "ordertype": "limit",
        "price": "1500000",
        "volume": "100000000",
    }
    uri_path = "/exchange/0/private/AddOrder"
    sig = kraken_sign(uri_path, post, API_SECRET_B64)

    headers = {
        "API-Key": API_KEY_ID,
        "API-Sign": sig,
    }
    url = f"{base}/private/AddOrder"
    r = requests.post(url, data=post, headers=headers, timeout=10)
    print(f"  POST private/AddOrder: {r.status_code}")
    print(f"    body: {r.text[:300]}")


if __name__ == "__main__":
    base = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080/exchange/0"
    print(f"Base URL: {base}")
    test_public(base)
    test_openapi(base)
    test_private_balance(base)
    test_private_add_order(base)
    print("\nDone.")
