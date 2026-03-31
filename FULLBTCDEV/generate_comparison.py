"""
generate_comparison.py — OmniBus vs Bitcoin Full Component Comparison
Scaneaza core/*.zig si genereaza rapoarte per categorie + summary.

Output:
  OMNIBUS_vs_BITCOIN_FULL_COMPARISON-1-Software.md
  OMNIBUS_vs_BITCOIN_FULL_COMPARISON-2-Blockchain.md
  ...
  OMNIBUS_vs_BITCOIN_FULL_COMPARISON-SUMMARY.md

Usage:
    python generate_comparison.py
"""

import os
import glob
import json
import datetime

CORE_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "core")
SCRIPTS_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "scripts")
FRONTEND_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "frontend")
OUT_DIR = os.path.dirname(__file__)  # FULLBTCDEV/


def scan_zig_files():
    """Scan all .zig files in core/ and return set of filenames."""
    files = set()
    for f in glob.glob(os.path.join(CORE_DIR, "*.zig")):
        files.add(os.path.basename(f))
    return files


def file_has_keyword(filename, keyword):
    """Check if a .zig file contains a keyword."""
    path = os.path.join(CORE_DIR, filename)
    if not os.path.exists(path):
        return False
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
        return keyword.lower() in content.lower()
    except Exception:
        return False


def check_file_exists(filename):
    """Check if file exists in core/."""
    return os.path.exists(os.path.join(CORE_DIR, filename))


def check_any_file(*filenames):
    """Check if any of the files exist."""
    return any(check_file_exists(f) for f in filenames)


# ── Category definitions ─────────────────────────────────────────────────────
# Each item: (name, btc_has, our_file_or_check, notes)

CATEGORIES = [
    {
        "id": 1,
        "name": "Software & Interfaces",
        "items": [
            ("bitcoind (daemon)", True, "main.zig", "Entry point, single-instance lock"),
            ("Bitcoin-Qt (GUI)", True, None, "We have React frontend instead"),
            ("bitcoin-cli (CLI)", True, "cli.zig", "--mode, --node-id, --port"),
            ("RPC Server (JSON-RPC)", True, "rpc_server.zig", "Port 8332, HTTP"),
            ("REST Interface", True, "rpc_server.zig", "Combined with RPC"),
            ("WebSocket Server", False, "ws_server.zig", "Push events, port 8334 [EXTRA]"),
            ("Mempool", True, "mempool.zig", "FIFO, size/time limits"),
            ("Database / LevelDB", True, "database.zig", "Custom binary, not LevelDB"),
            ("Validation Engine", True, "consensus.zig", "PoW + Casper FFG"),
            ("Full Node", True, "main.zig", "Seed + Miner mode"),
            ("Pruned Node", True, "prune_config.zig", "Configurable pruning"),
            ("Light Client (SPV)", True, "light_client.zig", "Header-only verification"),
            ("Blockchain Explorer", True, None, "React BlockExplorer component"),
            ("Mainnet Config", True, "chain_config.zig", 'Magic: "OMNI"'),
            ("Testnet Config", True, "chain_config.zig", 'Magic: "TEST"'),
            ("Regtest Config", True, "chain_config.zig", 'Magic: "REGT"'),
            ("Signet / Devnet", True, "chain_config.zig", 'Magic: "DEVN"'),
            ("Wallet.dat / DB file", True, "database.zig", "omnibus-chain.dat"),
            ("Chainstate (UTXO/State)", True, "state_trie.zig", "State trie (hybrid)"),
            ("Peer Discovery", True, "bootstrap.zig", "DHT + DNS seeds"),
        ]
    },
    {
        "id": 2,
        "name": "Blockchain Structure",
        "items": [
            ("Genesis Block", True, "genesis.zig", '"26/Mar/2026 OmniBus born"'),
            ("Block Header", True, "block.zig", "prev_hash, merkle_root, nonce"),
            ("Block Body (TX list)", True, "block.zig", "Transaction array"),
            ("Merkle Tree", True, "block.zig", "SHA256d merkle root"),
            ("UTXO Set", True, "state_trie.zig", "Account-based primary, UTXO planned"),
            ("Transaction Structure", True, "transaction.zig", "Full TX with sig, hash, nonce"),
            ("Coinbase Transaction", True, "consensus.zig", "Block reward TX"),
            ("Block Height", True, "blockchain.zig", "Sequential numbering"),
            ("Block Weight / Size", True, "sub_block.zig", "Sub-block weight system"),
            ("Block Time", True, "consensus.zig", "10s (10x0.1s sub-blocks)"),
            ("Difficulty Target", True, "consensus.zig", "Adjustable"),
            ("Difficulty Adjustment", True, "consensus.zig", "Every 2016 blocks"),
            ("Max Supply (21M)", True, "chain_config.zig", "21M OMNI"),
            ("Halving", True, "consensus.zig", "Every 210K blocks"),
            ("Block Reward", True, "consensus.zig", "50 OMNI, halves"),
            ("Sub-block Engine", False, "sub_block.zig", "10 sub-blocks/key block [EXTRA]"),
            ("Sharding (4 shards)", False, "shard_coordinator.zig", "Parallel processing [EXTRA]"),
            ("Metachain", False, "metachain.zig", "Cross-shard coordination [EXTRA]"),
            ("Compact Blocks", True, "binary_codec.zig", "Binary encoding"),
            ("Block Archive", True, "archive_manager.zig", "Historical data"),
        ]
    },
    {
        "id": 3,
        "name": "Cryptography",
        "items": [
            ("SHA-256", True, "crypto.zig", "std.crypto.hash.sha2"),
            ("Double SHA-256 (SHA256d)", True, "transaction.zig", "TX hash, block hash"),
            ("RIPEMD-160", True, "ripemd160.zig", "Pure Zig implementation"),
            ("ECDSA (secp256k1)", True, "secp256k1.zig", "Pure Zig, no FFI"),
            ("Schnorr Signatures", True, "schnorr.zig", "BIP-340 compatible"),
            ("BLS Signatures", False, "bls_signatures.zig", "Aggregate sigs [EXTRA]"),
            ("Multisig (M-of-N)", True, "multisig.zig", "Script-based multisig"),
            ("Hash160", True, "secp256k1.zig", "RIPEMD160(SHA256(x))"),
            ("Base58Check", True, "bip32_wallet.zig", "Full encoder/decoder"),
            ("Bech32 (BIP-173)", True, "bech32.zig", "SegWit v0 addresses"),
            ("Bech32m (BIP-350)", True, "bech32.zig", "Taproot v1 addresses"),
            ("HMAC-SHA256", True, "crypto.zig", "Key derivation"),
            ("HMAC-SHA512", True, "crypto.zig", "BIP-32 master key"),
            ("PBKDF2-HMAC-SHA512", True, "bip32_wallet.zig", "BIP-39 seed, 2048 iter"),
            ("AES-256-GCM", False, "crypto.zig", "Key encryption [EXTRA]"),
            ("ML-DSA-87 (Dilithium)", False, "pq_crypto.zig", "Post-quantum sig [EXTRA]"),
            ("Falcon-512", False, "pq_crypto.zig", "Compact PQ sig [EXTRA]"),
            ("SLH-DSA (SPHINCS+)", False, "pq_crypto.zig", "Hash-based PQ [EXTRA]"),
            ("ML-KEM-768 (Kyber)", False, "pq_crypto.zig", "PQ key encapsulation [EXTRA]"),
            ("Key Compression", True, "secp256k1.zig", "33-byte compressed pubkeys"),
        ]
    },
    {
        "id": 4,
        "name": "Wallet & Key Management",
        "items": [
            ("HD Wallet (BIP-32)", True, "bip32_wallet.zig", "Full HMAC-SHA512 derivation"),
            ("Mnemonic (BIP-39)", True, "bip32_wallet.zig", "PBKDF2, 12 words"),
            ("BIP-44 (Multi-coin)", True, "bip32_wallet.zig", "m/44'/coin'/0'/0/idx"),
            ("BIP-49 (SegWit P2SH)", True, None, "Python script only (partial)"),
            ("BIP-84 (Native SegWit)", True, "bech32.zig", "ob1q... addresses"),
            ("BIP-86 (Taproot)", True, "bech32.zig", "ob1p... encoding ready"),
            ("xpub / xprv", True, "bip32_wallet.zig", "serializeXpub/Xprv"),
            ("WIF (Private Key Format)", True, "bip32_wallet.zig", "encodeWIF()"),
            ("Master Fingerprint", True, "bip32_wallet.zig", "masterFingerprint()"),
            ("Parent Fingerprint", True, "bip32_wallet.zig", "parentFingerprint()"),
            ("Derivation Path String", True, "bip32_wallet.zig", "derivationPathString()"),
            ("Script Pubkey", True, "bip32_wallet.zig", "deriveScriptPubkey()"),
            ("Witness Version", True, "wallet.zig", "0=SegWit, 1=Taproot"),
            ("Address Type Detection", True, "wallet.zig", "NATIVE_SEGWIT, TAPROOT"),
            ("Network (mainnet/testnet)", True, "bip32_wallet.zig", "Network enum"),
            ("Passphrase (25th word)", True, "bip32_wallet.zig", "initFromMnemonicPassphrase"),
            ("Key Encryption", True, "key_encryption.zig", "AES-256-GCM"),
            ("Cold Storage / Vault", True, "vault_reader.zig", "Named Pipe from SuperVault"),
            ("Multi-chain Derivation", False, None, "19 chains from 1 seed [EXTRA]"),
            ("5 PQ Domain Addresses", False, "bip32_wallet.zig", "coin_type 777-781 [EXTRA]"),
        ]
    },
    {
        "id": 5,
        "name": "Transactions & Script",
        "items": [
            ("UTXO Model", True, "utxo.zig", "Full UTXO set + integrated in blockchain.zig"),
            ("Transaction Inputs", True, "transaction.zig", "from_address"),
            ("Transaction Outputs", True, "transaction.zig", "to_address + amount"),
            ("Transaction Fee", True, "transaction.zig", "50% burn + 50% miner"),
            ("Change Address (chain=1)", True, "bip32_wallet.zig", "deriveChangeAddress/deriveChangeKey"),
            ("Satoshi unit (1e9)", True, "transaction.zig", "1 OMNI = 1e9 SAT"),
            ("Bitcoin Script (language)", True, "script.zig", "P2PKH opcodes"),
            ("OP_CHECKSIG", True, "script.zig", "ECDSA verification"),
            ("OP_RETURN (data embed)", True, "transaction.zig", "Max 80 bytes"),
            ("Locktime", True, "transaction.zig", "Block-height timelock"),
            ("Nonce (anti-replay)", True, "transaction.zig", "Nonce field"),
            ("Sequence Number (BIP-125)", True, "transaction.zig", "sequence field for RBF"),
            ("Witness Data (SegWit)", True, "transaction.zig", "script_sig field (partial)"),
            ("Replace-By-Fee (RBF)", True, "transaction.zig", "isRBF/canBeReplacedBy + mempool logic"),
            ("Child-Pays-For-Parent", True, "mempool.zig", "getPackageFee/hasChildBoost"),
            ("vSize / Weight Units", True, "block.zig", "Sub-block weight (partial)"),
            ("Dust Limit", True, "blockchain.zig", "Anti-spam threshold"),
            ("TX Signing (ECDSA)", True, "transaction.zig", "sign() method"),
            ("TX Verification", True, "transaction.zig", "verify() method"),
            ("TX Hash (TXID)", True, "transaction.zig", "SHA256d hash"),
        ]
    },
    {
        "id": 6,
        "name": "Mining & Consensus",
        "items": [
            ("Proof of Work (PoW)", True, "consensus.zig", "SHA256d PoW"),
            ("Nonce Search", True, "consensus.zig", "Brute-force mining"),
            ("Difficulty Target", True, "consensus.zig", "Dynamic target"),
            ("Difficulty Adjustment", True, "consensus.zig", "Every 2016 blocks"),
            ("Block Reward", True, "consensus.zig", "50 OMNI start"),
            ("Halving Schedule", True, "consensus.zig", "Every 210K blocks"),
            ("Coinbase TX Creation", True, "block.zig", "First TX in block"),
            ("Mining Pool Protocol", True, "mining_pool.zig", "Pool coordination"),
            ("Stratum Client", True, None, "miner-client.js (Node.js)"),
            ("Chain Reorganization", True, "blockchain.zig", "Fork resolution"),
            ("Light Miner", False, "light_miner.zig", "Low-resource mining [EXTRA]"),
            ("Sub-block Engine", False, "sub_block.zig", "10x faster finality [EXTRA]"),
            ("Casper FFG Finality", False, "finality.zig", "PoS finality layer [EXTRA]"),
            ("Staking / Validators", False, "staking.zig", "Validator system [EXTRA]"),
            ("Governance Voting", False, "governance.zig", "On-chain governance [EXTRA]"),
        ]
    },
    {
        "id": 7,
        "name": "Network & P2P",
        "items": [
            ("P2P Protocol (TCP)", True, "p2p.zig", "TCP transport"),
            ("Peer Discovery", True, "bootstrap.zig", "DNS seeds + DHT"),
            ("Kademlia DHT", False, "kademlia_dht.zig", "Structured P2P [EXTRA]"),
            ("Block Sync", True, "sync.zig", "Header-first sync"),
            ("Peer Scoring / Reputation", True, "peer_scoring.zig", "Score-based banning"),
            ("DNS Seeds / Registry", True, "dns_registry.zig", "Bootstrap nodes"),
            ("Duplicate Detection", False, "p2p.zig", "Knock-knock system [EXTRA]"),
            ("Gossip TX Propagation", True, "p2p.zig", "TX broadcast"),
            ("Gossip Block Propagation", True, "p2p.zig", "Block broadcast"),
            ("Ban List", True, "peer_scoring.zig", "Via scoring system"),
            ("Inbound/Outbound Peers", True, "p2p.zig", "Configurable"),
            ("Max Connections Limit", True, "p2p.zig", "Peer limit"),
            ("Tor Support (SOCKS5)", True, "tor_proxy.zig", "SOCKS5 proxy, .onion detection"),
            ("I2P Support", True, None, "NOT YET"),
            ("BIP-324 Encrypted P2P", True, "encrypted_p2p.zig", "ECDH + AES-256-GCM encrypted sessions"),
            ("Compact Block Relay", True, "binary_codec.zig", "Binary codec"),
            ("Headers-First Download", True, "sync.zig", "Header-based"),
            ("Fee Filter", True, "mempool.zig", "Min fee filtering (partial)"),
            ("ZMQ / Push Notifications", True, "ws_server.zig", "WebSocket instead of ZMQ"),
            ("User Agent String", True, "p2p.zig", '"OmniBus/1.0"'),
        ]
    },
    {
        "id": 8,
        "name": "Storage & Database",
        "items": [
            ("Block Storage (files)", True, "database.zig", "omnibus-chain.dat"),
            ("Binary Codec", True, "binary_codec.zig", "Compact encoding"),
            ("State Trie", False, "state_trie.zig", "Ethereum-style state [EXTRA]"),
            ("Archive Manager", True, "archive_manager.zig", "Old block management"),
            ("Pruning Configuration", True, "prune_config.zig", "Space-saving"),
            ("Witness Storage", True, "witness.zig", "Segregated witness data"),
            ("Compact Transactions", True, "compact_tx.zig", "Compressed TXs"),
            ("UTXO Index", True, "utxo.zig", "Full UTXO set + address index"),
            ("Blockchain V2 Engine", False, "blockchain_v2.zig", "Next-gen arch [EXTRA]"),
            ("Shard Config", False, "shard_config.zig", "4-shard storage [EXTRA]"),
        ]
    },
    {
        "id": 9,
        "name": "Layer 2 & Extensions",
        "items": [
            ("Payment Channels", True, "payment_channel.zig", "Basic channels"),
            ("Lightning Network", True, "lightning.zig", "Channels, invoices, routing, liquidity"),
            ("HTLC Contracts", True, "htlc.zig", "Hash Time-Locked Contracts + registry"),
            ("Sidechain Support", True, "bridge_relay.zig", "Cross-chain bridge (partial)"),
            ("Bridge Relay", False, "bridge_relay.zig", "Cross-chain bridge [EXTRA]"),
            ("Oracle (Price Feeds)", False, "oracle.zig", "20-chain feeds [EXTRA]"),
            ("Domain Minting (PQ)", False, "domain_minter.zig", "PQ domain system [EXTRA]"),
            ("UBI Distributor", False, "ubi_distributor.zig", "Basic income [EXTRA]"),
            ("Vault Engine", False, "vault_engine.zig", "Smart vaults [EXTRA]"),
            ("Guardian System", False, "guardian.zig", "Network protection [EXTRA]"),
            ("OmniBrain (ML/AI)", False, "omni_brain.zig", "AI integration [EXTRA]"),
            ("WASM Wallet", False, "wasm_exports.zig", "Browser wallet [EXTRA]"),
        ]
    },
    {
        "id": 10,
        "name": "BIP Standards Compliance",
        "items": [
            ("BIP-32 (HD Wallets)", True, "bip32_wallet.zig", "Full implementation"),
            ("BIP-39 (Mnemonic)", True, "bip32_wallet.zig", "12-word, PBKDF2"),
            ("BIP-44 (Multi-coin paths)", True, "bip32_wallet.zig", "m/44'/coin'/0'/0/idx"),
            ("BIP-49 (SegWit P2SH)", True, None, "Python only (partial)"),
            ("BIP-84 (Native SegWit)", True, "bech32.zig", "ob1q... addresses"),
            ("BIP-86 (Taproot paths)", True, "bech32.zig", "ob1p... ready"),
            ("BIP-141 (SegWit)", True, "bech32.zig", "Witness v0/v1"),
            ("BIP-173 (Bech32)", True, "bech32.zig", "Full encoder/decoder"),
            ("BIP-350 (Bech32m)", True, "bech32.zig", "Taproot encoding"),
            ("BIP-340 (Schnorr)", True, "schnorr.zig", "Schnorr signatures"),
            ("BIP-125 (RBF)", True, "transaction.zig", "sequence + opt-in RBF"),
            ("BIP-174 (PSBT)", True, "psbt.zig", "Partially Signed TX, multisig workflow"),
            ("BIP-324 (V2 P2P)", True, "encrypted_p2p.zig", "ECDH + AES-256-GCM"),
            ("BIP-152 (Compact Blocks)", True, "binary_codec.zig", "Binary codec"),
            ("BIP-157/158 (Block Filters)", True, "block_filter.zig", "GCS filters + header chain"),
            ("BIP-199 (HTLC)", True, "htlc.zig", "Hash Time-Locked Contracts"),
        ]
    },
]


def evaluate_item(item):
    """Evaluate if OmniBus has this component."""
    name, btc_has, our_file, notes = item

    if our_file is None:
        # Check notes for hints
        if "NOT YET" in notes:
            return "N", our_file
        if "partial" in notes.lower():
            return "P", our_file
        if "EXTRA" in notes:
            return "+", our_file
        # Check frontend
        if "React" in notes or "frontend" in notes:
            if os.path.exists(FRONTEND_DIR):
                return "P", "frontend/"
        return "N", our_file

    if check_file_exists(our_file):
        if "[EXTRA]" in notes:
            return "+", our_file
        return "Y", our_file

    # Check scripts/
    script_path = os.path.join(SCRIPTS_DIR, our_file)
    if os.path.exists(script_path):
        return "P", f"scripts/{our_file}"

    return "N", our_file


def generate_category_report(cat):
    """Generate markdown report for one category."""
    lines = []
    cat_id = cat["id"]
    cat_name = cat["name"]

    lines.append(f"# {cat_id}. {cat_name}")
    lines.append("")
    lines.append(f"> OmniBus vs Bitcoin — Category {cat_id}/10")
    lines.append(f"> Generated: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}")
    lines.append("")
    lines.append("| # | Component | BTC | OMNI | File | Notes |")
    lines.append("|:-:|-----------|:---:|:----:|------|-------|")

    y_count = 0
    p_count = 0
    n_count = 0
    extra_count = 0
    total = len(cat["items"])

    for idx, item in enumerate(cat["items"], 1):
        name, btc_has, our_file_orig, notes = item
        status, resolved_file = evaluate_item(item)

        btc_col = "Y" if btc_has else "N"
        file_col = resolved_file or "-"

        global_idx = (cat_id - 1) * 20 + idx

        if status == "Y":
            y_count += 1
        elif status == "P":
            p_count += 1
        elif status == "+":
            extra_count += 1
            y_count += 1  # extras count as having it
        else:
            n_count += 1

        lines.append(f"| {global_idx} | {name} | {btc_col} | {status} | {file_col} | {notes} |")

    lines.append("")
    lines.append("---")
    lines.append("")

    btc_items = sum(1 for item in cat["items"] if item[1])
    pct = int((y_count / btc_items * 100)) if btc_items > 0 else 0

    lines.append(f"**BTC has: {btc_items} items**")
    lines.append(f"**OmniBus: {y_count} implemented, {p_count} partial, {n_count} missing, {extra_count} extras**")
    lines.append(f"**Score: {pct}%** ({y_count}/{btc_items} BTC features" +
                 (f" + {extra_count} unique extras)" if extra_count else ")"))
    lines.append("")

    if n_count > 0:
        lines.append("### Missing (TODO):")
        for item in cat["items"]:
            status, _ = evaluate_item(item)
            if status == "N":
                lines.append(f"- [ ] {item[0]} — {item[3]}")
        lines.append("")

    if extra_count > 0:
        lines.append("### Extras (OmniBus-only):")
        for item in cat["items"]:
            status, _ = evaluate_item(item)
            if status == "+":
                lines.append(f"- {item[0]} — {item[3]}")
        lines.append("")

    return lines, {
        "name": cat_name,
        "btc_items": btc_items,
        "implemented": y_count,
        "partial": p_count,
        "missing": n_count,
        "extras": extra_count,
        "pct": pct,
    }


def generate_summary(stats_list):
    """Generate the summary report."""
    lines = []
    lines.append("# OmniBus vs Bitcoin — SUMMARY")
    lines.append("")
    lines.append(f"> Generated: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}")
    lines.append(f"> Core modules scanned: {len(scan_zig_files())}")
    lines.append("")
    lines.append("| # | Category | BTC Has | OMNI Has | Extras | Score |")
    lines.append("|:-:|----------|:-------:|:--------:|:------:|:-----:|")

    total_btc = 0
    total_omni = 0
    total_extras = 0

    for i, s in enumerate(stats_list, 1):
        score_str = f"{s['pct']}%"
        if s['extras'] > 0:
            score_str += f" +{s['extras']}"
        lines.append(f"| {i} | {s['name']} | {s['btc_items']} | {s['implemented']} | {s['extras']} | {score_str} |")
        total_btc += s['btc_items']
        total_omni += s['implemented']
        total_extras += s['extras']

    total_pct = int(total_omni / total_btc * 100) if total_btc > 0 else 0
    lines.append(f"| | **TOTAL** | **{total_btc}** | **{total_omni}** | **{total_extras}** | **{total_pct}%** |")
    lines.append("")

    lines.append("---")
    lines.append("")
    lines.append(f"## Overall: {total_pct}% Bitcoin parity + {total_extras} unique OmniBus features")
    lines.append("")

    # Top missing
    lines.append("### TOP MISSING (Priority)")
    lines.append("")
    all_missing = []
    for cat in CATEGORIES:
        for item in cat["items"]:
            status, _ = evaluate_item(item)
            if status == "N":
                all_missing.append((cat["name"], item[0], item[3]))

    for cat_name, name, notes in all_missing[:15]:
        lines.append(f"- [ ] **{name}** ({cat_name}) — {notes}")

    lines.append("")

    # Top extras
    lines.append("### TOP EXTRAS (OmniBus-only)")
    lines.append("")
    all_extras = []
    for cat in CATEGORIES:
        for item in cat["items"]:
            status, _ = evaluate_item(item)
            if status == "+":
                all_extras.append((cat["name"], item[0], item[3]))

    for cat_name, name, notes in all_extras:
        lines.append(f"- **{name}** ({cat_name}) — {notes}")

    lines.append("")
    lines.append("---")
    lines.append(f"*{len(scan_zig_files())} Zig modules | {total_omni}/{total_btc} BTC features | {total_extras} extras*")

    return lines


def main():
    print(f"\n{'='*60}")
    print(f"  OmniBus vs Bitcoin — Full Comparison Generator")
    print(f"{'='*60}\n")

    zig_files = scan_zig_files()
    print(f"Scanned {len(zig_files)} .zig files in core/\n")

    stats_list = []

    for cat in CATEGORIES:
        cat_id = cat["id"]
        cat_name = cat["name"]
        safe_name = cat_name.replace(" ", "_").replace("&", "and").replace("/", "_")

        report_lines, stats = generate_category_report(cat)
        stats_list.append(stats)

        filename = f"OMNIBUS_vs_BITCOIN_FULL_COMPARISON-{cat_id}-{safe_name}.md"
        filepath = os.path.join(OUT_DIR, filename)
        with open(filepath, "w", encoding="utf-8") as f:
            f.write("\n".join(report_lines) + "\n")

        pct = stats["pct"]
        extras = stats["extras"]
        bar = "#" * (pct // 5) + "." * (20 - pct // 5)
        extra_str = f" +{extras} extras" if extras else ""
        print(f"  [{cat_id:2d}] {cat_name:25s} [{bar}] {pct:3d}%{extra_str}  -> {filename}")

    # Summary
    summary_lines = generate_summary(stats_list)
    summary_path = os.path.join(OUT_DIR, "OMNIBUS_vs_BITCOIN_FULL_COMPARISON-SUMMARY.md")
    with open(summary_path, "w", encoding="utf-8") as f:
        f.write("\n".join(summary_lines) + "\n")

    total_btc = sum(s["btc_items"] for s in stats_list)
    total_omni = sum(s["implemented"] for s in stats_list)
    total_extras = sum(s["extras"] for s in stats_list)
    total_pct = int(total_omni / total_btc * 100) if total_btc > 0 else 0

    print(f"\n{'='*60}")
    print(f"  RESULT: {total_pct}% BTC parity ({total_omni}/{total_btc}) + {total_extras} extras")
    print(f"  Files saved in: FULLBTCDEV/")
    print(f"{'='*60}\n")


if __name__ == "__main__":
    main()
