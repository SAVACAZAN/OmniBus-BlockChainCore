#!/usr/bin/env python3
"""
doc_generator.py - OmniBus API Documentation Generator v2.0

Generează documentație API din codul Zig cu descrieri auto-generate:
  - Extrage comentarii /// (doc comments)
  - Parsează funcții publice, structuri, constante
  - AUTO-GENEREAZĂ descrieri bazate pe context (nume, parametri, modul, corp funcție)
  - Generează markdown și HTML cu TOC, exemple, categorii
  - Creează index navigabil

Usage:
  python tools/DOCUMENTATION/doc_generator.py              # Generează toată docs
  python tools/DOCUMENTATION/doc_generator.py --module wallet  # Doar un modul
  python tools/DOCUMENTATION/doc_generator.py --format html    # Format HTML
  python tools/DOCUMENTATION/doc_generator.py --output ./docs  # Director output
"""

import sys
import re
import json
import argparse
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Dict, Optional, Tuple
from datetime import datetime

ROOT = Path(__file__).parent.parent.parent
CORE = ROOT / "core"
OUTPUT = ROOT / "docs" / "api"

# ── Module descriptions (manually curated for important modules) ──────────────

MODULE_DESCRIPTIONS = {
    "blockchain": "Core blockchain engine — manages the chain, validates blocks, handles reorgs, "
                  "tracks balances per address, and implements difficulty retargeting (Bitcoin-style, every 2016 blocks).",
    "block": "Block data structure — defines a block's fields (index, timestamp, transactions, hash, nonce, "
             "merkle root, difficulty), provides hash calculation and validation.",
    "transaction": "Transaction structure and validation — defines TX fields (from, to, amount, fee, nonce, "
                   "signature), signing via secp256k1, hash integrity checks, and fee calculations.",
    "wallet": "HD Wallet with Post-Quantum support — derives keys from BIP-39 mnemonic via BIP-32 "
              "(HMAC-SHA512), generates 5 PQ address domains (ML-DSA-87, Falcon-512, SLH-DSA-256s, ML-KEM-768), "
              "and creates signed transactions.",
    "secp256k1": "Pure Zig secp256k1 ECDSA implementation — private key to public key derivation, "
                 "ECDSA signing and verification, point arithmetic on the secp256k1 curve. Bitcoin-compatible.",
    "rpc_server": "JSON-RPC 2.0 HTTP server on port 8332 — 39 methods including blockchain queries, "
                  "wallet operations, staking, multisig, payment channels, and mining. Uses ws2_32 on Windows.",
    "p2p": "TCP P2P networking — binary protocol for peer connections, block/TX propagation, "
           "peer discovery, knock-knock duplicate detection, and message broadcasting.",
    "mempool": "Transaction memory pool — FIFO queue with size/time limits, fee-based priority, "
               "duplicate detection, replace-by-nonce, and mineable TX selection.",
    "consensus": "Proof-of-Work consensus engine — SHA256d mining, difficulty validation, "
                 "block verification, and modular design for future PBFT support.",
    "genesis": "Genesis block initialization — creates the first block with network config "
               "(mainnet/testnet), initial balances, and chain parameters.",
    "database": "Persistent storage — binary serialization of blockchain state to omnibus-chain.dat, "
                "atomic write (tmp → rename), append-only block storage.",
    "crypto": "Cryptographic primitives — SHA-256, SHA-256d (double hash), HMAC-SHA256, "
              "AES-256 encryption/decryption for key protection.",
    "pq_crypto": "Post-Quantum cryptography via liboqs C bindings — ML-DSA-87 (Dilithium-5), "
                 "Falcon-512, SLH-DSA-256s (SPHINCS+), ML-KEM-768 (Kyber) key generation, signing, verification.",
    "bip32_wallet": "BIP-32 HD wallet derivation — HMAC-SHA512 master key generation from seed, "
                    "child key derivation (normal and hardened), BIP-44 path support for 5 PQ domains.",
    "ripemd160": "Pure Zig RIPEMD-160 hash function — 193 lines, Bitcoin-compatible, used for "
                 "address generation (RIPEMD160(SHA256(pubkey))).",
    "staking": "Proof-of-Stake validator system — deposit/withdraw stake, slashing for equivocation "
               "and downtime, unbonding period (7 days), minimum stake enforcement.",
    "finality": "Casper FFG finality gadget — checkpoint creation, validator attestations, "
                "supermajority detection (2/3+1), epoch finalization.",
    "governance": "On-chain governance — proposal creation, voting (for/against/abstain), "
                  "quorum (33%), approval threshold (50%), veto threshold (33%), parameter updates.",
    "multisig": "M-of-N multisig — create multisig addresses, collect signatures, "
                "verify threshold, timelock contracts for delayed execution.",
    "schnorr": "BIP-340 Schnorr signatures over secp256k1 — key aggregation, "
               "batch verification, more efficient than ECDSA for multi-party signing.",
    "bls_signatures": "BLS threshold signatures (t-of-n) — aggregate multiple signatures "
                      "into one, verify against aggregate public key, used for consensus efficiency.",
    "kademlia_dht": "Kademlia distributed hash table — XOR-based distance metric, k-bucket routing, "
                    "iterative node lookup, peer discovery without central servers.",
    "sync": "Block synchronization — header-first sync, block download, stall detection, "
            "fork resolution, and chain reorganization.",
    "bootstrap": "Peer discovery and bootstrapping — seed node connections, PEX (Peer Exchange), "
                 "DNS seed resolution, peer persistence to disk.",
    "network": "Network layer — manages peer connections, message routing, broadcast to all peers, "
               "connection lifecycle management.",
    "storage": "Key-value storage engine — in-memory with optional disk persistence, "
               "iterator support, memory-safe deinit.",
    "state_trie": "Merkle Patricia Trie for account state — O(log n) lookups, "
                  "cryptographic proofs, 50MB vs 1.6TB for 1M+ accounts.",
    "light_client": "SPV (Simplified Payment Verification) — header-only sync, Bloom filters, "
                    "Merkle proofs for TX inclusion, mobile-friendly (200B per header).",
    "light_miner": "Lightweight mining client — reduced resource usage, header-only validation, "
                   "connects to full nodes for block templates.",
    "mining_pool": "Mining pool coordination — dynamic miner registration, fair reward distribution, "
                   "share submission, pool statistics.",
    "sub_block": "Sub-block engine — 10 sub-blocks × 100ms = 1 KeyBlock (1s), "
                 "faster confirmation times while maintaining security.",
    "metachain": "EGLD-style metachain coordination — aggregates shard headers, "
                 "cross-shard communication, meta-block finalization.",
    "shard_coordinator": "4-shard routing — assigns addresses to shards, load balancing, "
                         "cross-shard TX routing.",
    "shard_config": "Shard configuration — 7-way sharding parameters, load thresholds, "
                    "shard assignment rules.",
    "payment_channel": "Lightning-style Layer 2 — open/close channels, HTLC (Hash Time-Locked Contracts), "
                       "off-chain payments, cooperative/unilateral close.",
    "oracle": "Price oracle — BID/ASK feeds per exchange, best ask/best bid aggregation, "
              "on-chain price attestations for DeFi.",
    "bridge_relay": "Ethereum bridge relay — lock-and-mint cross-chain transfers, "
                    "refund on expiry, relay verification.",
    "domain_minter": "PQ domain minting — register domains (omnibus.omni, .love, .food, .rent, .vacation), "
                     "ownership transfer, lookup by name/owner.",
    "vault_engine": "Mnemonic vault — BIP-39 seed storage, encryption, secure derivation.",
    "vault_reader": "Vault access — reads mnemonic from SuperVault Named Pipe, "
                    "environment variable, or dev default fallback.",
    "ubi_distributor": "Universal Basic Income — 1 OMNI/day per eligible address, "
                       "epoch-based distribution, built into protocol.",
    "bread_ledger": "Physical redemption system — BreadVoucher QR ledger, "
                    "1 OMNI = 1 bread worldwide, voucher tracking.",
    "guardian": "Account guardians — social recovery, activation delay (20K blocks), "
                "guardian-approved operations for lost keys.",
    "peer_scoring": "Peer reputation system — score peers based on behavior, "
                    "ban misbehaving peers, reward good behavior.",
    "dns_registry": "Decentralized DNS — register human-readable names, renewal periods, "
                    "on-chain resolution.",
    "compact_blocks": "Compact block relay — send only TX short IDs, ~90% bandwidth reduction, "
                      "reconstruct blocks from mempool.",
    "compact_transaction": "SegWit-style compact TX — 161 bytes/TX (63% reduction), "
                           "witness data separation.",
    "witness_data": "Signature witness separation — 95% size reduction for stored signatures, "
                    "backward compatible with full validation.",
    "binary_codec": "Binary serialization — varint encoding, 93% compression ratio, "
                    "block/TX serialization for network and storage.",
    "archive_manager": "Block archival — compress old blocks for long-term storage, "
                       "retrieve archived blocks on demand.",
    "prune_config": "Pruning configuration — configurable retention (max 10K blocks), "
                    "auto-prune old data, reduce disk usage.",
    "key_encryption": "Private key encryption — AES-256 with password-derived key, "
                      "password verification, secure key storage.",
    "chain_config": "Chain configuration — mainnet/testnet/regtest parameters, "
                    "fee estimation, network-specific settings.",
    "cli": "Command-line interface — argument parsing for mode (seed/miner/light), "
           "node-id, host, port, seed-host, seed-port.",
    "node_launcher": "Node orchestration — starts all subsystems in order, "
                     "manages seed/miner mode, initiates mining loop.",
    "miner_genesis": "Genesis miner allocation — initial miner addresses, "
                     "pre-mine distribution for bootstrap.",
    "e2e_mining": "End-to-end mining integration test — full cycle from TX creation "
                  "through mining to block validation.",
    "blockchain_v2": "Enhanced blockchain v2 — sub-block support, sharding integration, "
                     "binary encoding, pruning support.",
    "ws_server": "WebSocket server on port 8334 — push new_block, new_transaction, "
                 "status events to React frontend in real-time.",
    "omni_brain": "AI/ML node intelligence — auto-detect optimal NodeType "
                  "(full/trading/validator/light) based on hardware and network.",
    "spark_invariants": "Formal verification — 17 Ada/SPARK-style compile-time invariants "
                        "for critical blockchain properties.",
    "synapse_priority": "Synapse scheduler — priority queue for internal node operations, "
                        "ensures critical tasks execute first.",
    "os_mode": "OS mode detection — detects bare-metal vs hosted mode, "
               "adjusts behavior for OmniBus OS integration.",
    "tx_receipt": "Transaction receipts — event logs, gas used, status codes, "
                  "Ethereum-compatible receipt format.",
    "hex_utils": "Hex/hash utilities — shared hex encoding/decoding, hash formatting "
                 "functions used across modules.",
    "script": "Transaction scripting engine — Bitcoin-style script opcodes, "
              "P2PKH/P2SH script evaluation, programmable spending conditions.",
    "benchmark": "Performance benchmarks — measure hash rate, TX throughput, "
                 "block validation speed, P2P latency.",
    "miner_wallet": "Miner-specific wallet — coinbase TX creation, reward tracking, "
                    "miner key management.",
}

# ── Smart description generation ──────────────────────────────────────────────

def infer_function_description(func_name: str, params: List[Tuple[str, str]],
                                returns: str, module_name: str, body_lines: List[str]) -> str:
    """Generate a human-readable description from function name, params, and context."""

    # Common patterns
    name = func_name
    param_names = [p[0] for p in params if p[0] != 'self']

    # init/deinit
    if name == "init":
        return "Initialize a new instance. Allocates required memory and sets default values."
    if name == "deinit":
        return "Clean up and free all allocated memory. Must be called when done."

    # get* pattern
    if name.startswith("get"):
        subject = camel_to_words(name[3:])
        if param_names:
            return f"Returns the {subject} for the given {', '.join(param_names)}."
        return f"Returns the current {subject}."

    # set* pattern
    if name.startswith("set"):
        subject = camel_to_words(name[3:])
        return f"Sets the {subject} to the specified value."

    # is*/has* pattern
    if name.startswith("is") or name.startswith("has"):
        subject = camel_to_words(name[2:] if name.startswith("is") else name[3:])
        return f"Checks whether the {subject} condition is true."

    # add* pattern
    if name.startswith("add"):
        subject = camel_to_words(name[3:])
        return f"Adds a new {subject} to the collection."

    # remove*/delete* pattern
    if name.startswith("remove") or name.startswith("delete"):
        prefix_len = 6 if name.startswith("remove") else 6
        subject = camel_to_words(name[prefix_len:])
        return f"Removes the specified {subject}."

    # create* pattern
    if name.startswith("create"):
        subject = camel_to_words(name[6:])
        return f"Creates a new {subject} with the given parameters."

    # validate*/verify* pattern
    if name.startswith("validate") or name.startswith("verify"):
        prefix_len = 8 if name.startswith("validate") else 6
        subject = camel_to_words(name[prefix_len:]) or module_name
        return f"Validates the {subject}. Returns true if valid, false otherwise."

    # process*/handle* pattern
    if name.startswith("process") or name.startswith("handle"):
        prefix_len = 7 if name.startswith("process") else 6
        subject = camel_to_words(name[prefix_len:])
        return f"Processes the incoming {subject} and applies changes to state."

    # broadcast*/send* pattern
    if name.startswith("broadcast"):
        subject = camel_to_words(name[9:])
        return f"Broadcasts {subject} to all connected peers in the network."
    if name.startswith("send"):
        subject = camel_to_words(name[4:])
        return f"Sends {subject} to the specified destination."

    # mine*/mining pattern
    if "mine" in name.lower():
        return f"Executes mining operation — finds valid nonce for the next block."

    # sign/verify
    if name.startswith("sign") or "Sign" in name:
        return f"Cryptographically signs the data using the private key."
    if name == "verify" or name.startswith("verify"):
        return f"Verifies the cryptographic signature against the public key."

    # calculate*/compute* pattern
    if name.startswith("calculate") or name.startswith("compute"):
        prefix_len = 9 if name.startswith("calculate") else 7
        subject = camel_to_words(name[prefix_len:])
        return f"Calculates the {subject} from the current state."

    # serialize/deserialize
    if "serialize" in name.lower():
        if "de" in name.lower():
            return f"Deserializes binary data back into the structured format."
        return f"Serializes the structure into binary format for storage or network transmission."

    # encode/decode
    if "encode" in name.lower():
        if "de" in name.lower():
            return f"Decodes the encoded data back to its original format."
        return f"Encodes the data into the specified format."

    # format/parse
    if name.startswith("format"):
        return f"Formats the data into a human-readable string representation."
    if name.startswith("parse"):
        subject = camel_to_words(name[5:])
        return f"Parses the raw input into a structured {subject} object."

    # update* pattern
    if name.startswith("update"):
        subject = camel_to_words(name[6:])
        return f"Updates the {subject} with new values."

    # find*/lookup*/search* pattern
    if name.startswith("find") or name.startswith("lookup") or name.startswith("search"):
        prefix_len = 4 if name.startswith("find") else (6 if name.startswith("lookup") else 6)
        subject = camel_to_words(name[prefix_len:])
        return f"Searches for {subject} matching the given criteria."

    # load*/save* pattern
    if name.startswith("load"):
        subject = camel_to_words(name[4:])
        return f"Loads {subject} from persistent storage."
    if name.startswith("save"):
        subject = camel_to_words(name[4:])
        return f"Saves {subject} to persistent storage."

    # close*/open* pattern
    if name.startswith("close"):
        subject = camel_to_words(name[5:])
        return f"Closes the {subject} and releases associated resources."
    if name.startswith("open"):
        subject = camel_to_words(name[4:])
        return f"Opens a new {subject} connection or resource."

    # start*/stop* pattern
    if name.startswith("start"):
        subject = camel_to_words(name[5:])
        return f"Starts the {subject} service or process."
    if name.startswith("stop"):
        subject = camel_to_words(name[4:])
        return f"Stops the {subject} service or process."

    # apply* pattern
    if name.startswith("apply"):
        subject = camel_to_words(name[5:])
        return f"Applies the {subject} changes to the current state."

    # count* pattern
    if name.startswith("count"):
        subject = camel_to_words(name[5:])
        return f"Returns the count of {subject}."

    # reset* pattern
    if name.startswith("reset"):
        subject = camel_to_words(name[5:])
        return f"Resets {subject} to initial/default state."

    # register* pattern
    if name.startswith("register"):
        subject = camel_to_words(name[8:])
        return f"Registers a new {subject} in the system."

    # Check body for return patterns
    body_text = '\n'.join(body_lines[:10]) if body_lines else ""
    if "return true" in body_text or "return false" in body_text:
        subject = camel_to_words(name)
        return f"Checks {subject} condition. Returns a boolean result."
    if "return null" in body_text:
        subject = camel_to_words(name)
        return f"Attempts to find {subject}. Returns null if not found."

    # Fallback: make description from function name
    words = camel_to_words(name)
    if words:
        return f"Performs the {words} operation on the {module_name} module."

    return f"Internal function of the {module_name} module."


def infer_struct_description(struct_name: str, fields: List[Tuple[str, str]],
                              module_name: str) -> str:
    """Generate description for a struct based on its name and fields."""
    name = struct_name
    field_names = [f[0] for f in fields[:5]]

    STRUCT_HINTS = {
        "Block": "Represents a single block in the blockchain — contains transactions, hash, nonce, and links to previous block.",
        "Transaction": "A single transaction transferring value between addresses — includes sender, recipient, amount, fee, and cryptographic signature.",
        "Wallet": "User wallet — holds derived keys, addresses across 5 PQ domains, and methods to create signed transactions.",
        "Address": "A blockchain address — includes the algorithm type, public key, and formatted address string.",
        "Blockchain": "The main blockchain state — manages the chain of blocks, validates additions, tracks balances, and handles reorganizations.",
        "Peer": "A network peer — stores connection info (host, port), reputation score, and last seen timestamp.",
        "MempoolEntry": "An entry in the transaction mempool — wraps a transaction with metadata like arrival time and fee rate.",
    }

    if name in STRUCT_HINTS:
        return STRUCT_HINTS[name]

    words = camel_to_words(name)
    if field_names:
        return f"Data structure for {words}. Fields include: {', '.join(field_names[:5])}."
    return f"Data structure representing a {words} in the {module_name} module."


def camel_to_words(name: str) -> str:
    """Convert camelCase or PascalCase to readable words."""
    if not name:
        return ""
    # Insert space before uppercase letters
    result = re.sub(r'([A-Z])', r' \1', name)
    # Handle consecutive uppercase (e.g., "DHT" -> "DHT")
    result = re.sub(r'([A-Z]+)([A-Z][a-z])', r'\1 \2', result)
    return result.strip().lower()


# ── Data classes ──────────────────────────────────────────────────────────────

@dataclass
class FunctionDoc:
    name: str
    signature: str
    description: str
    params: List[Tuple[str, str]] = field(default_factory=list)
    returns: str = ""
    examples: List[str] = field(default_factory=list)
    line: int = 0
    body_preview: List[str] = field(default_factory=list)

@dataclass
class StructDoc:
    name: str
    description: str
    fields: List[Tuple[str, str, str]] = field(default_factory=list)
    line: int = 0

@dataclass
class ModuleDoc:
    name: str
    description: str = ""
    functions: List[FunctionDoc] = field(default_factory=list)
    structs: List[StructDoc] = field(default_factory=list)
    constants: List[Tuple[str, str, str]] = field(default_factory=list)
    line_count: int = 0
    test_count: int = 0


def extract_doc_comments(content: str, start_line: int) -> str:
    """Extract consecutive /// comments before a line."""
    lines = content.split('\n')
    comments = []
    for i in range(start_line - 2, -1, -1):
        line = lines[i].strip()
        if line.startswith('///'):
            comments.insert(0, line[3:].strip())
        elif line and not line.startswith('//'):
            break
    return '\n'.join(comments)


def extract_body_lines(content: str, start_line: int, max_lines: int = 15) -> List[str]:
    """Extract the first N lines of a function body for context."""
    lines = content.split('\n')
    body = []
    brace_depth = 0
    started = False
    for i in range(start_line - 1, min(len(lines), start_line + max_lines)):
        line = lines[i]
        if '{' in line:
            brace_depth += line.count('{')
            started = True
        if started:
            body.append(line.strip())
        if '}' in line:
            brace_depth -= line.count('}')
            if brace_depth <= 0 and started:
                break
    return body


def extract_struct_fields(content: str, start_line: int) -> List[Tuple[str, str]]:
    """Extract fields from a struct definition."""
    lines = content.split('\n')
    fields = []
    brace_depth = 0
    started = False
    for i in range(start_line - 1, min(len(lines), start_line + 50)):
        line = lines[i].strip()
        if '{' in line:
            brace_depth += line.count('{')
            started = True
            continue
        if '}' in line:
            brace_depth -= line.count('}')
            if brace_depth <= 0 and started:
                break
        if started and brace_depth == 1 and ':' in line and not line.startswith('//'):
            # Match: field_name: Type,
            m = re.match(r'(\w+)\s*:\s*([^,=]+)', line)
            if m and not m.group(1).startswith('pub') and m.group(1) != 'fn':
                fields.append((m.group(1), m.group(2).strip().rstrip(',')))
    return fields


def parse_function(line: str) -> Optional[Tuple[str, str, List[Tuple[str, str]]]]:
    """Parse a function signature."""
    match = re.match(r'(?:pub\s+)?(?:export\s+)?fn\s+(\w+)\s*\(([^)]*)\)\s*(!?[^\{]+)?', line)
    if not match:
        return None
    name = match.group(1)
    params_str = match.group(2).strip()
    returns = match.group(3).strip() if match.group(3) else "void"
    params = []
    if params_str:
        for param in params_str.split(','):
            param = param.strip()
            if ':' in param:
                pname, ptype = param.split(':', 1)
                params.append((pname.strip(), ptype.strip()))
    return name, returns, params


def parse_struct(line: str) -> Optional[str]:
    """Parse struct name."""
    match = re.match(r'(?:pub\s+)?const\s+(\w+)\s*=\s*(?:extern\s+)?struct', line)
    if match:
        return match.group(1)
    return None


def parse_module(filepath: Path) -> ModuleDoc:
    """Parse a Zig module and extract documentation with smart descriptions."""
    content = filepath.read_text(encoding='utf-8', errors='replace')
    lines = content.split('\n')

    module = ModuleDoc(name=filepath.stem)
    module.line_count = len(lines)
    module.test_count = content.count('test "')

    # Module description: use curated if available, otherwise from top comments
    if filepath.stem in MODULE_DESCRIPTIONS:
        module.description = MODULE_DESCRIPTIONS[filepath.stem]
    else:
        module_desc = []
        for line in lines:
            stripped = line.strip()
            if stripped.startswith('//!'):
                module_desc.append(stripped[3:].strip())
            elif stripped and not stripped.startswith('//'):
                break
        module.description = '\n'.join(module_desc) if module_desc else f"Module for {camel_to_words(filepath.stem)} functionality."

    for i, line in enumerate(lines, 1):
        stripped = line.strip()

        # Parse pub functions
        if re.match(r'pub\s+(?:export\s+)?fn\s+\w+', stripped):
            func_info = parse_function(stripped)
            if func_info:
                name, returns, params = func_info
                doc = extract_doc_comments(content, i)
                body = extract_body_lines(content, i)

                # Auto-generate description if none from comments
                if not doc:
                    doc = infer_function_description(name, params, returns,
                                                     filepath.stem, body)

                func_doc = FunctionDoc(
                    name=name,
                    signature=stripped,
                    description=doc,
                    params=params,
                    returns=returns,
                    line=i,
                    body_preview=body[:5],
                )
                module.functions.append(func_doc)

        # Parse structs
        if 'struct' in stripped and 'const' in stripped:
            struct_name = parse_struct(stripped)
            if struct_name:
                doc = extract_doc_comments(content, i)
                fields = extract_struct_fields(content, i)

                if not doc:
                    doc = infer_struct_description(struct_name, fields, filepath.stem)

                module.structs.append(StructDoc(
                    name=struct_name,
                    description=doc,
                    fields=fields,
                    line=i,
                ))

        # Parse pub constants
        if re.match(r'pub\s+const\s+\w+\s*[:=]', stripped) and 'struct' not in stripped and 'fn' not in stripped:
            match = re.match(r'pub\s+const\s+(\w+)\s*[:=]\s*([^;]+)', stripped)
            if match:
                name = match.group(1)
                value = match.group(2).strip()
                module.constants.append((name, "auto", value))

    return module


# ── Markdown generation ───────────────────────────────────────────────────────

def generate_markdown(module: ModuleDoc) -> str:
    """Generate rich markdown documentation for a module."""
    md = f"# Module: `{module.name}`\n\n"

    if module.description:
        md += f"> {module.description}\n\n"

    # Stats
    md += f"**Source:** `core/{module.name}.zig` | "
    md += f"**Lines:** {module.line_count} | "
    md += f"**Functions:** {len(module.functions)} | "
    md += f"**Structs:** {len(module.structs)} | "
    md += f"**Tests:** {module.test_count}\n\n"

    # Table of contents
    md += "---\n\n## Contents\n\n"
    if module.structs:
        md += "### Structs\n"
        for s in module.structs:
            md += f"- [`{s.name}`](#{s.name.lower()}) — {s.description[:80]}{'...' if len(s.description) > 80 else ''}\n"
        md += "\n"
    if module.constants:
        md += "### Constants\n"
        md += f"- [{len(module.constants)} constants defined](#constants)\n\n"
    if module.functions:
        md += "### Functions\n"
        for f in module.functions:
            md += f"- [`{f.name}()`](#{f.name.lower()}) — {f.description[:70]}{'...' if len(f.description) > 70 else ''}\n"
        md += "\n"

    md += "---\n\n"

    # Structs
    if module.structs:
        md += "## Structs\n\n"
        for s in module.structs:
            md += f"### `{s.name}`\n\n"
            md += f"{s.description}\n\n"
            if s.fields:
                md += "| Field | Type | Description |\n"
                md += "|-------|------|-------------|\n"
                for fname, ftype in s.fields[:20]:
                    desc = camel_to_words(fname).capitalize()
                    md += f"| `{fname}` | `{ftype}` | {desc} |\n"
                md += "\n"
            md += f"*Defined at line {s.line}*\n\n---\n\n"

    # Constants
    if module.constants:
        md += "## Constants\n\n"
        md += "| Name | Value | Description |\n"
        md += "|------|-------|-------------|\n"
        for name, typ, value in module.constants[:30]:
            desc = camel_to_words(name).capitalize()
            val_display = value[:60] + ('...' if len(value) > 60 else '')
            md += f"| `{name}` | `{val_display}` | {desc} |\n"
        md += "\n---\n\n"

    # Functions
    if module.functions:
        md += "## Functions\n\n"
        for f in module.functions:
            md += f"### `{f.name}()`\n\n"
            md += f"{f.description}\n\n"

            md += "```zig\n"
            md += f"{f.signature}\n"
            md += "```\n\n"

            if f.params:
                md += "| Parameter | Type | Description |\n"
                md += "|-----------|------|-------------|\n"
                for pname, ptype in f.params:
                    desc = camel_to_words(pname).capitalize() if pname != 'self' else 'The instance'
                    md += f"| `{pname}` | `{ptype}` | {desc} |\n"
                md += "\n"

            if f.returns and f.returns != "void":
                md += f"**Returns:** `{f.returns}`\n\n"

            md += f"*Defined at line {f.line}*\n\n---\n\n"

    # Footer
    md += f"\n---\n\n*Generated by OmniBus Doc Generator v2.0 — {datetime.now().strftime('%Y-%m-%d %H:%M')}*\n"

    return md


# ── HTML generation ───────────────────────────────────────────────────────────

def generate_html_index(modules: List[ModuleDoc]) -> str:
    """Generate HTML index page with categories."""

    # Categorize modules
    categories = {
        "Blockchain & Consensus": ["blockchain", "block", "transaction", "consensus", "genesis",
                                   "finality", "governance", "staking", "sub_block", "blockchain_v2",
                                   "e2e_mining"],
        "Cryptography": ["crypto", "secp256k1", "pq_crypto", "bip32_wallet", "ripemd160",
                         "schnorr", "bls_signatures", "multisig", "key_encryption", "hex_utils"],
        "Networking & P2P": ["p2p", "network", "sync", "bootstrap", "kademlia_dht",
                             "peer_scoring", "rpc_server", "ws_server", "compact_blocks"],
        "Storage & Data": ["database", "storage", "state_trie", "binary_codec",
                           "archive_manager", "prune_config", "compact_transaction",
                           "witness_data", "tx_receipt"],
        "Wallet & Identity": ["wallet", "miner_wallet", "vault_engine", "vault_reader",
                              "miner_genesis", "mining_pool", "light_miner", "light_client"],
        "Sharding & Scaling": ["metachain", "shard_coordinator", "shard_config",
                               "payment_channel", "bridge_relay"],
        "Economic & Governance": ["bread_ledger", "ubi_distributor", "domain_minter",
                                  "oracle", "guardian", "dns_registry"],
        "Node & Infrastructure": ["main", "cli", "node_launcher", "chain_config",
                                  "os_mode", "omni_brain", "spark_invariants",
                                  "synapse_priority", "benchmark", "mempool", "script"],
    }

    modules_by_name = {m.name: m for m in modules}

    category_html = ""
    for cat_name, cat_modules in categories.items():
        items = ""
        for mname in cat_modules:
            if mname in modules_by_name:
                m = modules_by_name[mname]
                desc = m.description[:100] + ('...' if len(m.description) > 100 else '')
                items += f'''<a href="{m.name}.html" class="module-card">
                    <div class="module-name">{m.name}.zig</div>
                    <div class="module-desc">{desc}</div>
                    <div class="module-stats">{len(m.functions)} functions &bull; {len(m.structs)} structs &bull; {m.line_count} lines</div>
                </a>\n'''

        if items:
            category_html += f'<h2 class="category">{cat_name}</h2>\n<div class="module-grid">{items}</div>\n'

    # Uncategorized
    all_categorized = set()
    for mods in categories.values():
        all_categorized.update(mods)
    uncategorized = [m for m in modules if m.name not in all_categorized]
    if uncategorized:
        items = ""
        for m in uncategorized:
            desc = m.description[:100] + ('...' if len(m.description) > 100 else '')
            items += f'''<a href="{m.name}.html" class="module-card">
                <div class="module-name">{m.name}.zig</div>
                <div class="module-desc">{desc}</div>
                <div class="module-stats">{len(m.functions)} functions &bull; {len(m.structs)} structs</div>
            </a>\n'''
        category_html += f'<h2 class="category">Other Modules</h2>\n<div class="module-grid">{items}</div>\n'

    total_funcs = sum(len(m.functions) for m in modules)
    total_structs = sum(len(m.structs) for m in modules)
    total_lines = sum(m.line_count for m in modules)
    total_tests = sum(m.test_count for m in modules)

    html = f"""<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>OmniBus Blockchain — API Documentation</title>
<style>
:root {{ --bg: #0a0e17; --surface: #111827; --border: #1e293b; --accent: #22d3ee; --green: #34d399; --text: #e2e8f0; --muted: #94a3b8; }}
* {{ margin: 0; padding: 0; box-sizing: border-box; }}
body {{ font-family: 'JetBrains Mono', 'Fira Code', monospace; background: var(--bg); color: var(--text); padding: 40px 20px; }}
.container {{ max-width: 1200px; margin: 0 auto; }}
h1 {{ color: var(--accent); font-size: 2rem; margin-bottom: 8px; }}
.subtitle {{ color: var(--muted); margin-bottom: 30px; }}
.stats-bar {{ display: flex; gap: 30px; flex-wrap: wrap; margin-bottom: 40px; padding: 20px; background: var(--surface); border: 1px solid var(--border); border-radius: 12px; }}
.stat {{ text-align: center; }}
.stat-value {{ font-size: 1.5rem; font-weight: 700; color: var(--accent); }}
.stat-label {{ font-size: 0.75rem; color: var(--muted); text-transform: uppercase; letter-spacing: 1px; }}
.category {{ color: var(--green); font-size: 1.1rem; margin: 30px 0 15px; padding-bottom: 8px; border-bottom: 1px solid var(--border); }}
.module-grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 12px; margin-bottom: 20px; }}
.module-card {{ display: block; background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 16px; text-decoration: none; color: var(--text); transition: border-color 0.2s; }}
.module-card:hover {{ border-color: var(--accent); }}
.module-name {{ font-weight: 700; color: var(--accent); margin-bottom: 6px; }}
.module-desc {{ font-size: 0.8rem; color: var(--muted); line-height: 1.4; margin-bottom: 8px; min-height: 2.8em; }}
.module-stats {{ font-size: 0.7rem; color: #64748b; }}
.footer {{ text-align: center; margin-top: 60px; color: var(--muted); font-size: 0.8rem; }}
a {{ color: var(--accent); }}
</style>
</head><body>
<div class="container">
<h1>OmniBus Blockchain — API Documentation</h1>
<p class="subtitle">Complete reference for all {len(modules)} core modules &bull; Generated {datetime.now().strftime('%Y-%m-%d %H:%M')}</p>

<div class="stats-bar">
<div class="stat"><div class="stat-value">{len(modules)}</div><div class="stat-label">Modules</div></div>
<div class="stat"><div class="stat-value">{total_funcs}</div><div class="stat-label">Functions</div></div>
<div class="stat"><div class="stat-value">{total_structs}</div><div class="stat-label">Structs</div></div>
<div class="stat"><div class="stat-value">{total_lines:,}</div><div class="stat-label">Lines of Code</div></div>
<div class="stat"><div class="stat-value">{total_tests}</div><div class="stat-label">Tests</div></div>
</div>

{category_html}

<div class="footer">
<p>OmniBus BlockChain Core — Post-Quantum Hybrid Blockchain</p>
<p style="margin-top:8px"><a href="https://github.com/SAVACAZAN/OmniBus-BlockChainCore">GitHub</a> &bull; Built with Zig &bull; Generated by doc_generator v2.0</p>
</div>
</div>
</body></html>"""

    return html


def generate_html(module: ModuleDoc) -> str:
    """Generate HTML documentation for a module."""

    struct_sections = ""
    for s in module.structs:
        fields_html = ""
        if s.fields:
            rows = "".join(f"<tr><td><code>{f[0]}</code></td><td><code>{f[1]}</code></td><td>{camel_to_words(f[0]).capitalize()}</td></tr>" for f in s.fields[:20])
            fields_html = f"<table><tr><th>Field</th><th>Type</th><th>Description</th></tr>{rows}</table>"

        struct_sections += f"""
        <div class="section">
            <h3><code>{s.name}</code></h3>
            <p>{s.description}</p>
            {fields_html}
            <p class="line">Line: {s.line}</p>
        </div>"""

    func_sections = ""
    for f in module.functions:
        params_html = ""
        if f.params:
            rows = "".join(f"<tr><td><code>{p[0]}</code></td><td><code>{p[1]}</code></td><td>{camel_to_words(p[0]).capitalize() if p[0] != 'self' else 'The instance'}</td></tr>" for p in f.params)
            params_html = f"<table><tr><th>Parameter</th><th>Type</th><th>Description</th></tr>{rows}</table>"

        returns_html = f'<p class="returns"><strong>Returns:</strong> <code>{f.returns}</code></p>' if f.returns and f.returns != "void" else ""

        func_sections += f"""
        <div class="section">
            <h3><code>{f.name}()</code></h3>
            <p class="desc">{f.description}</p>
            <pre><code>{f.signature}</code></pre>
            {params_html}
            {returns_html}
            <p class="line">Line: {f.line}</p>
        </div>"""

    const_rows = ""
    if module.constants:
        for name, typ, value in module.constants[:30]:
            val = value[:60] + ('...' if len(value) > 60 else '')
            const_rows += f"<tr><td><code>{name}</code></td><td><code>{val}</code></td><td>{camel_to_words(name).capitalize()}</td></tr>"

    html = f"""<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{module.name} — OmniBus API</title>
<style>
:root {{ --bg: #0a0e17; --surface: #111827; --border: #1e293b; --accent: #22d3ee; --green: #34d399; --purple: #a78bfa; --orange: #fb923c; --text: #e2e8f0; --muted: #94a3b8; }}
* {{ margin: 0; padding: 0; box-sizing: border-box; }}
body {{ font-family: 'JetBrains Mono', 'Fira Code', monospace; background: var(--bg); color: var(--text); padding: 30px 20px; }}
.container {{ max-width: 900px; margin: 0 auto; }}
h1 {{ color: var(--accent); font-size: 1.5rem; }}
h2 {{ color: var(--green); font-size: 1.1rem; margin: 30px 0 15px; padding-bottom: 8px; border-bottom: 1px solid var(--border); }}
h3 {{ color: var(--orange); font-size: 1rem; margin-bottom: 8px; }}
.desc {{ color: var(--text); margin-bottom: 12px; line-height: 1.5; }}
.module-desc {{ color: var(--muted); margin: 8px 0 20px; line-height: 1.5; font-size: 0.9rem; }}
.stats {{ font-size: 0.8rem; color: var(--muted); margin-bottom: 20px; }}
code {{ background: #1e293b; padding: 2px 6px; border-radius: 4px; }}
pre {{ background: #0f172a; padding: 14px; border-radius: 8px; overflow-x: auto; margin: 10px 0; border: 1px solid var(--border); }}
pre code {{ background: none; padding: 0; color: var(--accent); }}
table {{ width: 100%; border-collapse: collapse; margin: 10px 0; font-size: 0.85rem; }}
th {{ background: #0f172a; color: var(--accent); padding: 8px 12px; text-align: left; }}
td {{ padding: 6px 12px; border-bottom: 1px solid var(--border); }}
.section {{ background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 20px; margin: 12px 0; }}
.line {{ color: #4b5563; font-size: 0.75rem; margin-top: 10px; }}
.returns {{ color: var(--purple); margin-top: 8px; }}
a {{ color: var(--accent); text-decoration: none; }}
a:hover {{ text-decoration: underline; }}
.back {{ display: inline-block; margin-bottom: 20px; font-size: 0.9rem; }}
.footer {{ text-align: center; margin-top: 40px; color: #4b5563; font-size: 0.75rem; }}
</style>
</head><body>
<div class="container">
<a href="index.html" class="back">&larr; Back to Index</a>
<h1>Module: <code>{module.name}</code></h1>
<p class="module-desc">{module.description}</p>
<p class="stats">Source: core/{module.name}.zig &bull; {module.line_count} lines &bull; {len(module.functions)} functions &bull; {len(module.structs)} structs &bull; {module.test_count} tests</p>

{"<h2>Structs (" + str(len(module.structs)) + ")</h2>" + struct_sections if module.structs else ""}

{"<h2>Constants (" + str(len(module.constants)) + ")</h2><div class='section'><table><tr><th>Name</th><th>Value</th><th>Description</th></tr>" + const_rows + "</table></div>" if const_rows else ""}

{"<h2>Functions (" + str(len(module.functions)) + ")</h2>" + func_sections if module.functions else ""}

<div class="footer">Generated by OmniBus Doc Generator v2.0 &bull; {datetime.now().strftime('%Y-%m-%d %H:%M')}</div>
</div>
</body></html>"""

    return html


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="OmniBus API Documentation Generator v2.0")
    parser.add_argument("--module", help="Generate docs for specific module")
    parser.add_argument("--format", choices=["md", "html", "both"], default="both", help="Output format (default: both)")
    parser.add_argument("--output", type=Path, default=OUTPUT, help="Output directory")
    args = parser.parse_args()

    print("\n" + "=" * 60)
    print("  OmniBus API Documentation Generator v2.0")
    print("  Smart descriptions + categorized index")
    print("=" * 60)

    args.output.mkdir(parents=True, exist_ok=True)

    if args.module:
        filepath = CORE / f"{args.module}.zig"
        if not filepath.exists():
            print(f"ERROR: Module not found: {filepath}")
            sys.exit(1)

        print(f"\nParsing: {filepath.name}")
        module = parse_module(filepath)

        if args.format in ("md", "both"):
            output = args.output / f"{module.name}.md"
            output.write_text(generate_markdown(module), encoding='utf-8')
            print(f"  MD:   {output}")
        if args.format in ("html", "both"):
            output = args.output / f"{module.name}.html"
            output.write_text(generate_html(module), encoding='utf-8')
            print(f"  HTML: {output}")

    else:
        zig_files = sorted(CORE.glob("*.zig"))
        modules = []

        print(f"\nParsing {len(zig_files)} modules...\n")

        for i, filepath in enumerate(zig_files):
            print(f"  [{i+1}/{len(zig_files)}] {filepath.name:<40}", end='\r')
            module = parse_module(filepath)
            modules.append(module)

            if args.format in ("md", "both"):
                output = args.output / f"{module.name}.md"
                output.write_text(generate_markdown(module), encoding='utf-8')
            if args.format in ("html", "both"):
                output = args.output / f"{module.name}.html"
                output.write_text(generate_html(module), encoding='utf-8')

        print(" " * 60, end='\r')

        # Generate index
        if args.format in ("html", "both"):
            index_path = args.output / "index.html"
            index_path.write_text(generate_html_index(modules), encoding='utf-8')
            print(f"\n  Index: {index_path}")

        # Summary
        total_funcs = sum(len(m.functions) for m in modules)
        total_structs = sum(len(m.structs) for m in modules)
        total_lines = sum(m.line_count for m in modules)
        total_tests = sum(m.test_count for m in modules)
        described = sum(1 for m in modules if m.name in MODULE_DESCRIPTIONS)

        print(f"\n{'='*60}")
        print(f"  Generated {len(modules)} module docs (MD + HTML)")
        print(f"  Total functions:  {total_funcs}")
        print(f"  Total structs:    {total_structs}")
        print(f"  Total lines:      {total_lines:,}")
        print(f"  Total tests:      {total_tests}")
        print(f"  Curated descriptions: {described}/{len(modules)}")
        print(f"  Auto-generated descriptions: {len(modules) - described}/{len(modules)}")
        print(f"  Output: {args.output}")
        print(f"{'='*60}\n")


if __name__ == "__main__":
    main()
