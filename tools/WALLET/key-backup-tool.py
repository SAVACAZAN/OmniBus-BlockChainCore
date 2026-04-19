#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Key Backup Tool

Encrypted backup/restore for wallet keys using AES-256-GCM + PBKDF2.
"""

import argparse
import base64
import getpass
import json
import os
import sys
from typing import Any, Dict

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
    from cryptography.hazmat.primitives import hashes
    HAS_CRYPTO = True
except ImportError:
    HAS_CRYPTO = False
    cprint(YELLOW, "cryptography library not installed. Using stub crypto (NOT for production).")


def _derive_key(password: str, salt: bytes) -> bytes:
    if HAS_CRYPTO:
        kdf = PBKDF2HMAC(
            algorithm=hashes.SHA256(),
            length=32,
            salt=salt,
            iterations=100_000,
        )
        return kdf.derive(password.encode())
    else:
        import hashlib
        return hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 100_000, 32)


def encrypt(plaintext: bytes, password: str) -> Dict[str, str]:
    salt = os.urandom(16)
    nonce = os.urandom(12)
    key = _derive_key(password, salt)
    if HAS_CRYPTO:
        aesgcm = AESGCM(key)
        ciphertext = aesgcm.encrypt(nonce, plaintext, None)
    else:
        import hmac
        ciphertext = bytes(b ^ key[i % len(key)] for i, b in enumerate(plaintext))
        ciphertext = nonce + ciphertext  # stub
    return {
        "salt": base64.b64encode(salt).decode(),
        "nonce": base64.b64encode(nonce).decode(),
        "ciphertext": base64.b64encode(ciphertext).decode(),
    }


def decrypt(payload: Dict[str, str], password: str) -> bytes:
    salt = base64.b64decode(payload["salt"])
    nonce = base64.b64decode(payload["nonce"])
    ciphertext = base64.b64decode(payload["ciphertext"])
    key = _derive_key(password, salt)
    if HAS_CRYPTO:
        aesgcm = AESGCM(key)
        return aesgcm.decrypt(nonce, ciphertext, None)
    else:
        return bytes(b ^ key[i % len(key)] for i, b in enumerate(ciphertext[12:]))


def backup(key_file: str, password: str, out_file: str) -> bool:
    with open(key_file, "rb") as f:
        plaintext = f.read()
    enc = encrypt(plaintext, password)
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(enc, f, indent=2)
    cprint(GREEN, f"Encrypted backup saved to {out_file}")
    return True


def restore(backup_file: str, password: str, out_file: str) -> bool:
    with open(backup_file, "r", encoding="utf-8") as f:
        payload = json.load(f)
    plaintext = decrypt(payload, password)
    with open(out_file, "wb") as f:
        f.write(plaintext)
    cprint(GREEN, f"Restored key to {out_file}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Encrypted wallet key backup/restore")
    parser.add_argument("action", choices=["backup", "restore"], help="Action to perform")
    parser.add_argument("--input", required=True, help="Input file (key or backup)")
    parser.add_argument("--output", required=True, help="Output file")
    parser.add_argument("--password", help="Password (prompt if omitted)")
    args = parser.parse_args()

    password = args.password or getpass.getpass("Password: ")

    cprint(GREEN, f"=== OmniBus Key Backup Tool ({args.action}) ===")
    if args.action == "backup":
        return 0 if backup(args.input, password, args.output) else 1
    else:
        return 0 if restore(args.input, password, args.output) else 1


if __name__ == "__main__":
    sys.exit(main())
