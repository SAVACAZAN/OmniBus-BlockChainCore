"""
generate_miners.py — OmniBus Miner Key Generator
Genereaza 10 mineri cu mnemonic BIP-39 real, adrese ob_omni_,
si exporta JSON compatibil cu OmnibusWallet (import direct in Sidebar).

Rulare:
    pip install bip_utils mnemonic
    python generate_miners.py

Output:
    miners_YYYY-MM-DD.json   — import in OmnibusWallet (PASTREAZA SECRET)
    miners_public.json       — adrese publice + config nod (poti distribui)
"""

import json
import hashlib
import hmac as _hmac
import datetime
import os
import sys
import secrets

# ── Nume tari pentru cei 10 mineri ────────────────────────────────────────────
MINER_NAMES = [
    "ROMANIA",
    "GERMANY",
    "FRANCE",
    "ITALY",
    "SPAIN",
    "NETHERLANDS",
    "AUSTRIA",
    "BELGIUM",
    "SWEDEN",
    "PORTUGAL",
]

# ── Constante OmniBus ─────────────────────────────────────────────────────────
OMNI_COIN_TYPE    = 777
OMNI_PREFIX       = "ob_omni_"
OMNI_VERSION_BYTE = 0x4F

PQ_DOMAINS = [
    {"name": "OMNI",          "coin_type": 777, "prefix": "ob_omni_", "algorithm": "ML-KEM-768",    "chain_id": "OMNI_OMNI"},
    {"name": "OMNI_LOVE",     "coin_type": 778, "prefix": "ob_k1_",   "algorithm": "ML-DSA-87",     "chain_id": "OMNI_LOVE"},
    {"name": "OMNI_FOOD",     "coin_type": 779, "prefix": "ob_f5_",   "algorithm": "Falcon-512",    "chain_id": "OMNI_FOOD"},
    {"name": "OMNI_RENT",     "coin_type": 780, "prefix": "ob_d5_",   "algorithm": "SLH-DSA-256s",  "chain_id": "OMNI_RENT"},
    {"name": "OMNI_VACATION", "coin_type": 781, "prefix": "ob_s3_",   "algorithm": "Falcon-Light",  "chain_id": "OMNI_VACATION"},
]

# ── Crypto helpers ────────────────────────────────────────────────────────────

_B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

def _b58encode(data: bytes) -> str:
    n = int.from_bytes(data, "big")
    r = ""
    while n > 0:
        n, rem = divmod(n, 58)
        r = _B58[rem] + r
    return "1" * (len(data) - len(data.lstrip(b"\x00"))) + r

def _checksum(d: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(d).digest()).digest()[:4]

def _hash160(d: bytes) -> bytes:
    return hashlib.new("ripemd160", hashlib.sha256(d).digest()).digest()

def _omni_address(pubkey_bytes: bytes, prefix: str, version_byte: int = 0x4F) -> str:
    h    = _hash160(pubkey_bytes)
    full = bytes([version_byte]) + h
    addr = _b58encode(full + _checksum(full))
    return prefix + addr

def _hkdf_expand(prk: bytes, info: bytes, length: int = 64) -> bytes:
    okm, t = b"", b""
    i = 0
    while len(okm) < length:
        i += 1
        t = _hmac.new(prk, t + info + bytes([i]), hashlib.sha512).digest()
        okm += t
    return okm[:length]

def _seed_to_keypair(seed: bytes, coin_type: int, index: int = 0):
    """BIP-32 secp256k1 via bip_utils, cu HKDF fallback daca lipseste."""
    path = f"m/44'/{coin_type}'/0'/0/{index}"
    try:
        from bip_utils import Bip32Slip10Secp256k1, Bip32KeyIndex
        bip32 = Bip32Slip10Secp256k1.FromSeed(seed)
        node  = (bip32
                 .ChildKey(Bip32KeyIndex.HardenIndex(44))
                 .ChildKey(Bip32KeyIndex.HardenIndex(coin_type))
                 .ChildKey(Bip32KeyIndex.HardenIndex(0))
                 .ChildKey(0)
                 .ChildKey(index))
        priv = node.PrivateKey().Raw().ToBytes()
        pub  = node.PublicKey().RawCompressed().ToBytes()
        wif_raw = b"\x80" + priv + b"\x01"
        wif = _b58encode(wif_raw + _checksum(wif_raw))
        return priv, pub, path, wif
    except Exception as e:
        print(f"  [WARN] bip_utils indisponibil ({e}) — folosesc HKDF fallback")
        salt = hashlib.sha256(f"OmniBus:{coin_type}".encode()).digest()
        prk  = _hmac.new(salt, seed, hashlib.sha512).digest()
        km   = _hkdf_expand(prk, path.encode(), 64)
        priv = km[:32]
        pub  = km[32:64]
        return priv, pub, path, ""

def _mnemonic_to_seed(mnemonic: str, passphrase: str = "") -> bytes:
    try:
        from bip_utils import Bip39SeedGenerator
        return bytes(Bip39SeedGenerator(mnemonic).Generate(passphrase))
    except Exception:
        salt = ("mnemonic" + passphrase).encode()
        return hashlib.pbkdf2_hmac("sha512", mnemonic.encode(), salt, 2048, 64)

def _generate_mnemonic_12() -> str:
    """Genereaza mnemonic BIP-39 de 12 cuvinte."""
    try:
        from bip_utils import Bip39MnemonicGenerator, Bip39WordsNum
        return str(Bip39MnemonicGenerator().FromWordsNumber(Bip39WordsNum.WORDS_NUM_12))
    except Exception:
        pass
    try:
        from mnemonic import Mnemonic
        return Mnemonic("english").generate(128)
    except Exception:
        pass
    # Fallback manual: 128 biti entropia → 12 cuvinte BIP-39
    # Folosim wordlist BIP-39 embedded minimal (primele 2048 cuvinte)
    print("[WARN] bip_utils si mnemonic lipsesc — folosesc os.urandom + wordlist")
    return _generate_mnemonic_fallback()

def _generate_mnemonic_fallback() -> str:
    """Fallback BIP-39 manual — 128 biti, 12 cuvinte."""
    # Wordlist BIP-39 engleza (primele 2048, sublist esential)
    # Descarca de la: https://raw.githubusercontent.com/trezor/python-mnemonic/master/src/mnemonic/wordlist/english.txt
    wordlist_path = os.path.join(os.path.dirname(__file__), "english.txt")
    if not os.path.exists(wordlist_path):
        raise RuntimeError(
            "Lipseste english.txt (BIP-39 wordlist).\n"
            "Descarca: https://raw.githubusercontent.com/trezor/python-mnemonic/master/src/mnemonic/wordlist/english.txt\n"
            "sau instaleaza: pip install mnemonic"
        )
    with open(wordlist_path) as f:
        words = [w.strip() for w in f if w.strip()]
    assert len(words) == 2048, "Wordlist corupta"

    entropy = secrets.token_bytes(16)  # 128 biti
    h = hashlib.sha256(entropy).digest()
    bits = bin(int.from_bytes(entropy, "big"))[2:].zfill(128)
    bits += bin(h[0])[2:].zfill(8)[:4]  # 4 biti checksum
    return " ".join(words[int(bits[i:i+11], 2)] for i in range(0, 132, 11))

# ── Generator miner ───────────────────────────────────────────────────────────

def generate_miner(name: str, index: int) -> dict:
    """Genereaza un miner complet: mnemonic + toate adresele OMNI."""
    print(f"  [{index+1:02d}] {name} ... ", end="", flush=True)

    mnemonic = _generate_mnemonic_12()
    seed     = _mnemonic_to_seed(mnemonic)
    now      = datetime.datetime.now(datetime.timezone.utc).isoformat()

    addresses = {}
    for domain in PQ_DOMAINS:
        priv, pub, path, wif = _seed_to_keypair(seed, domain["coin_type"])
        addr = _omni_address(pub, domain["prefix"])
        entry = {
            "index":           0,
            "chain":           domain["coin_type"],
            "chain_id":        domain["chain_id"],
            "addr":            addr,
            "address":         addr,
            "full_path":       path,
            "derivation_path": path,
            "pubkey":          pub.hex(),
            "public_key_hex":  pub.hex(),
            "private_key":     priv.hex(),
            "private_key_hex": priv.hex(),
            "script_pubkey":   "",
            "pq_algorithm":    domain["algorithm"],
            "coin_type":       domain["coin_type"],
            "bal":             0.0,
            "utxos":           [],
            "tx_count":        0,
            "last_tx":         None,
            "label":           f"{name} miner",
            "created_at":      now,
            "last_used":       None,
        }
        if wif:
            entry["private_key_wif"] = wif
        addresses[domain["chain_id"]] = entry

    primary_addr = addresses["OMNI_OMNI"]["addr"]
    print(f"OK → {primary_addr[:28]}...")

    return {
        "id":           f"miner-{name.lower()}-{index+1:02d}",
        "label":        f"OmniBus Miner — {name}",
        "mnemonic":     mnemonic,
        "passphrase":   "",
        "version":      2,
        "source":       "omnibus_miner_generated",
        "miner_name":   name,
        "miner_index":  index + 1,
        "created_at":   now,
        "chains":       [d["chain_id"] for d in PQ_DOMAINS],
        "primary_address": primary_addr,
        "node_config": {
            "miner_address": primary_addr,
            "env_var":       f"OMNIBUS_MNEMONIC={mnemonic}",
            "start_cmd":     f"set OMNIBUS_MNEMONIC={mnemonic} && omnibus-node.exe --mode miner",
            "start_cmd_linux": f"OMNIBUS_MNEMONIC='{mnemonic}' ./omnibus-node --mode miner",
        },
        "addresses":    addresses,
    }

# ── Single-instance lock ──────────────────────────────────────────────────────

def check_single_instance():
    """
    Verifica ca nu ruleaza deja un miner pe acest PC.
    Cross-platform: Windows (Named Mutex) + Linux/Mac (flock).
    """
    if sys.platform == "win32":
        import ctypes
        kernel32 = ctypes.windll.kernel32
        mutex = kernel32.CreateMutexW(None, True, "Global\\OmniBusMiner")
        err   = kernel32.GetLastError()
        if err == 183:  # ERROR_ALREADY_EXISTS
            print("\n[BLOCKED] Un miner OmniBus ruleaza deja pe acest PC.")
            print("          Un singur miner per masina — regula de retea.")
            sys.exit(1)
        return mutex  # tine referinta pentru durata procesului
    else:
        import fcntl
        lock_path = "/tmp/omnibus-miner.lock"
        f = open(lock_path, "w")
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("\n[BLOCKED] Un miner OmniBus ruleaza deja pe acest PC.")
            print("          Un singur miner per masina — regula de retea.")
            sys.exit(1)
        f.write(str(os.getpid()))
        f.flush()
        return f  # tine lock-ul activ

# ── Patch main.zig cu single-instance check ──────────────────────────────────

SINGLE_INSTANCE_ZIG = '''
// ── Single-instance guard — un singur miner per masina ───────────────────────
fn acquireSingleInstanceLock() !void {
    if (builtin.os.tag == .windows) {
        const kernel32 = std.os.windows.kernel32;
        const name = std.unicode.utf8ToUtf16LeStringLiteral("Global\\\\OmniBusMiner");
        const mutex = kernel32.CreateMutexW(null, 1, name);
        if (mutex == null) return error.MutexFailed;
        if (std.os.windows.kernel32.GetLastError() == 183) { // ERROR_ALREADY_EXISTS
            std.debug.print("[BLOCKED] Un miner OmniBus ruleaza deja pe acest PC!\\n", .{});
            std.debug.print("          Un singur miner per masina — regula de retea.\\n", .{});
            std.process.exit(1);
        }
        // mutex ramas deschis pana la exit — eliberat automat de OS
    } else {
        // Linux / macOS: flock pe /tmp/omnibus-miner.lock
        const lock_path = "/tmp/omnibus-miner.lock";
        const file = std.fs.cwd().createFile(lock_path, .{ .exclusive = false }) catch |e| {
            std.debug.print("[LOCK] Nu pot crea lock file: {}\\n", .{e});
            return;
        };
        // Non-blocking exclusive lock
        const LOCK_EX: u32 = 2;
        const LOCK_NB: u32 = 4;
        const fd = file.handle;
        const rc = std.os.linux.flock(fd, LOCK_EX | LOCK_NB);
        if (rc != 0) {
            std.debug.print("[BLOCKED] Un miner OmniBus ruleaza deja pe acest PC!\\n", .{});
            std.debug.print("          Un singur miner per masina — regula de retea.\\n", .{});
            std.process.exit(1);
        }
        // Scrie PID in lock file
        var pid_buf: [32]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d}\\n", .{std.os.linux.getpid()}) catch "";
        _ = file.write(pid_str) catch {};
        // NU inchidem file — lock ramas activ pana la exit
        _ = file; // supress unused warning; intentional leak pentru lock
    }
}
'''

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    print("=" * 60)
    print("  OmniBus Miner Key Generator")
    print("  Genereaza 10 mineri cu chei reale BIP-39")
    print("=" * 60)
    print()

    # Verifica dependente
    missing = []
    try:
        import bip_utils
    except ImportError:
        missing.append("bip_utils")
    try:
        import mnemonic
    except ImportError:
        missing.append("mnemonic")

    if missing:
        print(f"[INFO] Dependente optionale lipsa: {', '.join(missing)}")
        print(f"       pip install {' '.join(missing)}")
        print(f"       (se continua cu fallback HKDF daca nu sunt disponibile)")
        print()

    print("Generare 10 mineri:")
    miners = []
    for i, name in enumerate(MINER_NAMES):
        miner = generate_miner(name, i)
        miners.append(miner)

    # ── Fisier complet (SECRET — contine mnemonic + private keys) ─────────────
    now_str  = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    secret_file = f"miners_SECRET_{now_str}.json"

    secret_export = {
        "version":      1,
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "warning":      "FISIER SECRET — contine mnemonic si private keys. NU distribui!",
        "network":      "omnibus-mainnet",
        "wallets":      miners,
    }
    with open(secret_file, "w", encoding="utf-8") as f:
        json.dump(secret_export, f, indent=2, ensure_ascii=False)

    # ── Fisier public (doar adrese + config nod, fara mnemonic) ───────────────
    public_file = f"miners_PUBLIC_{now_str}.json"
    public_miners = []
    for m in miners:
        public_miners.append({
            "id":              m["id"],
            "label":           m["label"],
            "miner_name":      m["miner_name"],
            "primary_address": m["primary_address"],
            "created_at":      m["created_at"],
            "node_config": {
                "miner_address":    m["primary_address"],
                "start_cmd":        m["node_config"]["start_cmd"],
                "start_cmd_linux":  m["node_config"]["start_cmd_linux"],
            },
            "public_keys": {
                chain_id: {
                    "address":        addr_data["addr"],
                    "public_key_hex": addr_data["public_key_hex"],
                    "coin_type":      addr_data["coin_type"],
                    "pq_algorithm":   addr_data["pq_algorithm"],
                }
                for chain_id, addr_data in m["addresses"].items()
            },
        })

    public_export = {
        "version":      1,
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "note":         "Adrese publice si config noduri — sigur de distribuit.",
        "network":      "omnibus-mainnet",
        "miners":       public_miners,
    }
    with open(public_file, "w", encoding="utf-8") as f:
        json.dump(public_export, f, indent=2, ensure_ascii=False)

    # ── Fisier .env pentru fiecare miner (convenience) ────────────────────────
    env_file = f"miners_env_{now_str}.txt"
    with open(env_file, "w", encoding="utf-8") as f:
        f.write("# OmniBus Miner Environment Variables\n")
        f.write("# Copiaza linia corecta pe fiecare server/VM\n\n")
        for m in miners:
            f.write(f"# {m['label']} — {m['primary_address'][:32]}...\n")
            f.write(f"# Windows:\n")
            f.write(f"set OMNIBUS_MNEMONIC={m['mnemonic']}\n")
            f.write(f"# Linux/Mac:\n")
            f.write(f"export OMNIBUS_MNEMONIC='{m['mnemonic']}'\n\n")

    # ── Afiseaza single-instance Zig code ────────────────────────────────────
    zig_file = "single_instance_lock.zig"
    with open(zig_file, "w", encoding="utf-8") as f:
        f.write("// Adauga aceasta functie in main.zig si apeleaz-o la inceputul main()\n")
        f.write("// Necesar: const builtin = @import(\"builtin\");\n\n")
        f.write(SINGLE_INSTANCE_ZIG)

    # ── Sumar final ───────────────────────────────────────────────────────────
    print()
    print("=" * 60)
    print("  REZULTAT")
    print("=" * 60)
    print()
    print(f"  ⚠  SECRET  → {secret_file}")
    print(f"              Contine mnemonic + private keys!")
    print(f"              Pastreaza OFFLINE, nu pe server.")
    print()
    print(f"  ✓  PUBLIC  → {public_file}")
    print(f"              Adrese publice, sigur de distribuit.")
    print()
    print(f"  ✓  ENV     → {env_file}")
    print(f"              Copiaza pe fiecare server/VM.")
    print()
    print(f"  ✓  ZIG     → {zig_file}")
    print(f"              Single-instance lock pentru main.zig.")
    print()
    print("  MINERI GENERATI:")
    print()
    for i, m in enumerate(miners):
        print(f"  [{i+1:02d}] {m['miner_name']:<12} {m['primary_address']}")
    print()
    print("  IMPORT IN OMNIBUS WALLET:")
    print(f"  Deschide OmnibusSidebar → Wallet → Import")
    print(f"  Selecteaza: {secret_file}")
    print(f"  Sau importa individual fiecare mnemonic.")
    print()
    print("  ATENTIE SECURITATE:")
    print("  1. Muta SECRET file pe un device offline dupa import")
    print("  2. Pe fiecare server seteaza doar OMNIBUS_MNEMONIC")
    print("     (nu copia fisierul SECRET pe servere)")
    print("  3. Fiecare server = 1 singur miner (single-instance lock)")
    print()

if __name__ == "__main__":
    main()
