#!/usr/bin/env node
/**
 * _wallet-pool.mjs — shared helpers for the multi-wallet flow scripts (23-30).
 *
 * Generates a deterministic pool of 10 wallets from a fixed seed array, signs
 * raw OmniBus transactions client-side, and submits them via `sendrawtransaction`.
 *
 * Pure ESM. Requires the noble/scure packages installed in the project's
 * `frontend/node_modules` — we add that path to NODE_PATH at boot.
 *
 *   readFile(./wallet-pool.json)  ↔  saveFile(./wallet-pool.json)
 *
 * Public surface:
 *   SEEDS                         — 10 BIP-39 mnemonics
 *   RPC_URLS                      — chain → URL map
 *   parseArgs(argv)               — CHAIN/RPC_URL/TOKEN/DRY_RUN flags
 *   rpc(url, token, m, p)         — JSON-RPC POST helper
 *   derive(seed, index=0)         — { privKey, pubKey, address, evm } @ m/44'/777'/0'/0/index
 *   makePool()                    — derive 10 wallets from SEEDS
 *   loadPool(file?)               — read pool from disk (fallback: makePool)
 *   savePool(pool, file?)         — write pool snapshot to disk
 *   buildTx(args)                 — build Transaction { id, from, to, amount, fee, ts, nonce, hash, sig, pub }
 *   submitTx(rpcCtx, signedTx)    — POST sendrawtransaction
 *   getBalance(rpcCtx, addr)      — wrapper (returns SAT u64)
 *   getNonce(rpcCtx, addr)        — wrapper (returns u64)
 *   waitForBlock(rpcCtx, h)       — block-poll until tip ≥ h (15s timeout default)
 *   sleep(ms)                     — Promise<void>
 */

import { mnemonicToSeedSync } from "@scure/bip39";
import { HDKey }              from "@scure/bip32";
import { sha256 }             from "@noble/hashes/sha2.js";
import { ripemd160 }          from "@noble/hashes/legacy.js";
import { keccak_256 }         from "@noble/hashes/sha3.js";
import { secp256k1 }          from "@noble/curves/secp256k1.js";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath }      from "node:url";

// ── Path bootstrap — vendored deps live in frontend/node_modules ────────────

const __filename = fileURLToPath(import.meta.url);
const __dirname  = dirname(__filename);
export const POOL_FILE_DEFAULT = join(__dirname, "wallet-pool.json");

// ── Constants ───────────────────────────────────────────────────────────────

export const SEEDS = [
  "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
  "test test test test test test test test test test test junk",
  "legal winner thank year wave sausage worth useful legal winner thank yellow",
  "letter advice cage absurd amount doctor acoustic avoid letter advice cage above",
  "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong",
  "army van defense carry jealous true garbage claim echo media make crunch",
  "vessel ladder alter error federal sibling chat ability sun glass valve picture",
  "scheme spot photo card baby mountain device kick cradle pact join borrow",
  "pride cool lion squirrel village inhale gravity remind brick wedding seat oxygen",
  "panda eyebrow bullet gorilla call smoke muffin taste mesh discover soft ostrich",
];

export const RPC_URLS = {
  mainnet: "https://omnibusblockchain.cc:8443/api-mainnet",
  testnet: "https://omnibusblockchain.cc:8443/api-testnet",
  regtest: "https://omnibusblockchain.cc:8443/api-regtest",
  "local-mainnet": "http://127.0.0.1:8332",
  "local-testnet": "http://127.0.0.1:18332",
  "local-regtest": "http://127.0.0.1:28332",
};

export const SAT_PER_OMNI = 1_000_000_000n;

// ── Tiny utils ──────────────────────────────────────────────────────────────

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export const bytesToHex = (b) =>
  Array.from(b).map((x) => x.toString(16).padStart(2, "0")).join("");

export function hexToBytes(hex) {
  if (hex.startsWith("0x")) hex = hex.slice(2);
  if (hex.length % 2 !== 0) throw new Error("odd-length hex");
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
  return out;
}

// ── Bech32 (HRP "ob") ───────────────────────────────────────────────────────

const BECH32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
function bech32Polymod(values) {
  const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let chk = 1;
  for (const v of values) {
    const top = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (let i = 0; i < 5; i++) if ((top >> i) & 1) chk ^= GEN[i];
  }
  return chk;
}
function bech32Encode(hrp, data) {
  const hrpExpand = [...hrp].map((c) => c.charCodeAt(0) >> 5)
    .concat([0], [...hrp].map((c) => c.charCodeAt(0) & 31));
  const checksum = bech32Polymod([...hrpExpand, ...data, 0, 0, 0, 0, 0, 0]) ^ 1;
  const cs = Array.from({ length: 6 }, (_, i) => (checksum >> (5 * (5 - i))) & 31);
  return hrp + "1" + [...data, ...cs].map((d) => BECH32[d]).join("");
}
function convertBits(data, fromBits, toBits, pad = true) {
  let acc = 0, bits = 0;
  const out = [];
  const max = (1 << toBits) - 1;
  for (const v of data) {
    acc = (acc << fromBits) | v;
    bits += fromBits;
    while (bits >= toBits) { bits -= toBits; out.push((acc >> bits) & max); }
  }
  if (pad && bits > 0) out.push((acc << (toBits - bits)) & max);
  return out;
}

function obAddressFromPub(pubCompressed) {
  const h160 = ripemd160(sha256(pubCompressed));
  const data = [0, ...convertBits(Array.from(h160), 8, 5, true)];
  return bech32Encode("ob", data);
}

function evmAddressFromPriv(privBytes) {
  // Get uncompressed pubkey straight from the privkey — works on every
  // version of noble/curves and avoids the Point class API drift.
  const pubFull = secp256k1.getPublicKey(privBytes, false); // 65 bytes 0x04||X||Y
  const hash = keccak_256(pubFull.slice(1));
  return "0x" + bytesToHex(hash.slice(12));
}

// ── Wallet derivation ───────────────────────────────────────────────────────

/**
 * Derive a single OMNI wallet from a BIP-39 mnemonic at m/44'/777'/0'/0/<index>.
 * Returns the privkey/pubkey/ob1q address + the matching EVM address.
 */
export function derive(mnemonic, index = 0) {
  const seed = mnemonicToSeedSync(mnemonic.trim().toLowerCase());
  const root = HDKey.fromMasterSeed(seed);
  const child = root.derive(`m/44'/777'/0'/0/${index}`);
  if (!child.privateKey) throw new Error("derivation produced no private key");
  const pub = secp256k1.getPublicKey(child.privateKey, true); // 33 bytes
  return {
    privKey: bytesToHex(child.privateKey),
    pubKey:  bytesToHex(pub),
    address: obAddressFromPub(pub),
    evm:     evmAddressFromPriv(child.privateKey),
    path:    `m/44'/777'/0'/0/${index}`,
  };
}

/**
 * Build the deterministic 10-wallet pool from SEEDS.
 * One mnemonic per wallet, each derived at index 0 (path m/44'/777'/0'/0/0).
 */
export function makePool() {
  return SEEDS.map((mnemonic, i) => {
    const w = derive(mnemonic, 0);
    return {
      i,
      label: `wallet${i}`,
      mnemonic,
      ...w,
    };
  });
}

export function loadPool(file = POOL_FILE_DEFAULT) {
  if (!existsSync(file)) {
    const pool = makePool();
    return pool;
  }
  try {
    const json = JSON.parse(readFileSync(file, "utf-8"));
    // Re-derive on load — the JSON only stores public material; privkeys are
    // recomputed from the mnemonic so they never sit on disk in plaintext form
    // unless the caller explicitly wrote them. Even so, we trust derive() over
    // any cached privKey.
    return json.wallets.map((w) => {
      const derived = derive(w.mnemonic, w.index ?? 0);
      return { i: w.i, label: w.label, mnemonic: w.mnemonic, ...derived };
    });
  } catch {
    return makePool();
  }
}

export function savePool(pool, file = POOL_FILE_DEFAULT) {
  // Persist pubkey + address + mnemonic (test vectors only — never use SEEDS
  // for real funds). Privkey omitted: re-derived on load from the mnemonic.
  const out = {
    generated_at: new Date().toISOString(),
    note: "Test wallets only. Mnemonics are public test vectors — DO NOT use for real funds.",
    wallets: pool.map((w) => ({
      i: w.i,
      label: w.label,
      mnemonic: w.mnemonic,
      address: w.address,
      pubKey: w.pubKey,
      evm: w.evm,
      path: w.path,
    })),
  };
  writeFileSync(file, JSON.stringify(out, null, 2));
  return resolve(file);
}

// ── CLI argv parsing ────────────────────────────────────────────────────────

/**
 * Parse common --chain / --rpc / --token / --dry-run / --write flags.
 * Default chain is `testnet` for write scripts (per the task brief).
 */
export function parseArgs(argv, defaults = {}) {
  const args = argv.slice(2);
  const get = (name, fb) => {
    const i = args.indexOf(name);
    return i >= 0 && args[i + 1] ? args[i + 1] : fb;
  };
  const has = (name) => args.includes(name);

  const chain = get("--chain", process.env.CHAIN || defaults.chain || "testnet");
  const rpcUrl = get("--rpc", process.env.RPC_URL) || RPC_URLS[chain] || RPC_URLS.testnet;
  const token = get("--token", process.env.OMNIBUS_RPC_TOKEN || "");
  const dryRun = has("--dry-run") && !has("--write");
  const write  = has("--write");
  return { chain, rpcUrl, token, dryRun, write, args };
}

// ── RPC ─────────────────────────────────────────────────────────────────────

export async function rpc(url, token, method, params = []) {
  const headers = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  const r = await fetch(url, {
    method: "POST",
    headers,
    body: JSON.stringify({ jsonrpc: "2.0", id: Date.now(), method, params }),
  });
  const j = await r.json().catch(() => ({ error: { message: "non-JSON response", code: -32700 } }));
  if (j.error) {
    const msg = j.error.message ?? JSON.stringify(j.error);
    const skip = /method not found|unknown method|not implemented/i.test(msg);
    const err = new Error(msg);
    err.skip = skip;
    err.code = j.error.code;
    throw err;
  }
  return j.result;
}

/**
 * Convenience: a "context" object so callers don't repeat (url, token).
 *   const ctx = mkRpc({ rpcUrl, token });
 *   await ctx.call("getblockcount");
 */
export function mkRpc({ rpcUrl, token }) {
  return {
    url: rpcUrl,
    token,
    call: (method, params) => rpc(rpcUrl, token, method, params),
  };
}

// ── Read-only helpers ───────────────────────────────────────────────────────

export async function getBalance(ctx, address) {
  // The chain has both `getbalance` (object-form) and `getaddressbalance`
  // (positional). Try getbalance first; fall back as needed.
  try {
    const r = await ctx.call("getbalance", [{ address }]);
    if (typeof r === "object" && r !== null) {
      // {balanceOMNI: "1.5", balanceSat: 1500000000}
      if (typeof r.balanceSat === "number" || typeof r.balanceSat === "string") {
        return BigInt(r.balanceSat);
      }
      if (r.balanceOMNI) {
        const n = parseFloat(r.balanceOMNI);
        return BigInt(Math.round(n * 1e9));
      }
    }
    if (typeof r === "number") return BigInt(Math.round(r * 1e9));
    return 0n;
  } catch {
    try {
      const r = await ctx.call("getaddressbalance", [address]);
      if (typeof r === "number") return BigInt(r);
      if (typeof r === "object" && r?.balance) return BigInt(r.balance);
    } catch { /* fall through */ }
    return 0n;
  }
}

export async function getNonce(ctx, address) {
  try {
    const r = await ctx.call("getnonce", [address]);
    if (typeof r === "number") return BigInt(r);
    if (typeof r === "object" && r?.nonce !== undefined) return BigInt(r.nonce);
  } catch { /* fall through */ }
  return 0n;
}

export async function getTip(ctx) {
  try {
    const r = await ctx.call("getblockcount", []);
    return typeof r === "number" ? r : Number(r);
  } catch {
    try {
      const r = await ctx.call("getblockchaininfo", []);
      return r?.blocks ?? 0;
    } catch { return 0; }
  }
}

export async function waitForBlock(ctx, target, timeoutMs = 30_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const tip = await getTip(ctx);
    if (tip >= target) return tip;
    await sleep(1000);
  }
  return getTip(ctx);
}

export async function waitNewBlocks(ctx, count, timeoutMs = 30_000) {
  const start = await getTip(ctx);
  return waitForBlock(ctx, start + count, timeoutMs);
}

// ── Transaction signing — mirrors core/transaction.zig:Transaction.calculateHash ──
//
// Hash format (single SHA256, then SHA256 again — Bitcoin "SHA256d"):
//   id ":" from ":" to ":" amount ":" timestamp ":" nonce
//   [":SC:" scheme] (only when scheme != 0)
//   [":PK:" pubkey-bytes] (only when public_key non-empty — PQ)
//   [":" fee] (only when fee > 0)
//   [":lt" locktime] (only when locktime > 0)
//   [":OP:" op_return] (only when op_return non-empty)
//
// Phase-2A typed tx fields (tt/data) and Phase-C in/out arrays are NOT needed
// for plain ECDSA transfers — those branches don't fire when tx_type=transfer
// and inputs/outputs are empty (which is the case for our test scripts).

let g_txCounter = (Date.now() & 0x7fffffff);
export function nextTxId() {
  g_txCounter = (g_txCounter + 1) & 0x7fffffff;
  return g_txCounter;
}

/**
 * Build, hash, and sign a plain ECDSA OmniBus transaction. The returned
 * object is the JSON body for `sendrawtransaction` (positional or named).
 *
 * @param {object} args
 * @param {{privKey:string, pubKey:string, address:string}} args.from
 * @param {string} args.to            — destination ob1q address
 * @param {bigint|number} args.amount — SAT
 * @param {bigint|number} [args.fee]  — SAT (default: TX_MIN_FEE_SAT = 1000)
 * @param {bigint|number} args.nonce
 * @param {string} [args.opReturn]   — ≤ 80 byte memo
 * @param {bigint|number} [args.timestamp] — unix seconds (default: now)
 * @param {number} [args.id]         — TX id (default: monotonic counter)
 */
export function buildTx(args) {
  const id = args.id ?? nextTxId();
  const fromAddr = args.from.address;
  const toAddr   = args.to;
  const amount   = BigInt(args.amount);
  const fee      = BigInt(args.fee ?? 1000n);
  const ts       = BigInt(args.timestamp ?? Math.floor(Date.now() / 1000));
  const nonce    = BigInt(args.nonce ?? 0n);
  const op       = args.opReturn ?? "";

  // Build the canonical hash input — match calculateHash() exactly.
  // We assemble as a string then UTF-8 encode (all components stringify
  // as ASCII decimal digits / bech32 base32 / hex / printable bytes so
  // the encoding is deterministic).
  const enc = new TextEncoder();
  const parts = [];
  parts.push(enc.encode(`${id}`));
  parts.push(enc.encode(":"));
  parts.push(enc.encode(fromAddr));
  parts.push(enc.encode(":"));
  parts.push(enc.encode(toAddr));
  parts.push(enc.encode(":"));
  parts.push(enc.encode(`${amount}`));
  parts.push(enc.encode(":"));
  parts.push(enc.encode(`${ts}`));
  parts.push(enc.encode(":"));
  parts.push(enc.encode(`${nonce}`));
  // scheme=0 (omni_ecdsa) — not mixed in (the Zig code skips when ==0).
  // public_key: empty for ECDSA — not mixed in.
  if (fee > 0n) {
    parts.push(enc.encode(":"));
    parts.push(enc.encode(`${fee}`));
  }
  // locktime=0 — not mixed in.
  if (op.length > 0) {
    parts.push(enc.encode(":OP:"));
    parts.push(enc.encode(op));
  }

  let total = 0;
  for (const p of parts) total += p.length;
  const buf = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { buf.set(p, off); off += p.length; }

  const h1 = sha256(buf);
  const h2 = sha256(h1);                       // SHA256d
  const sig = secp256k1.sign(h2, hexToBytes(args.from.privKey), { lowS: true });
  const sigBytes = sig.toCompactRawBytes();    // 64 bytes (r||s)

  return {
    id,
    from:      fromAddr,
    to:        toAddr,
    amount:    Number(amount),
    fee:       Number(fee),
    timestamp: Number(ts),
    nonce:     Number(nonce),
    publicKey: args.from.pubKey,
    signature: bytesToHex(sigBytes),
    hash:      bytesToHex(h2),
    opReturn:  op,
  };
}

/**
 * Convenience: build & submit a TX, automatically fetching the next nonce.
 * Returns { ok:true, txid } on success or { ok:false, error } on failure.
 */
export async function submitTx(ctx, fromWallet, params) {
  // params: { to, amount, fee?, opReturn?, nonce? }
  const nonce = params.nonce !== undefined
    ? BigInt(params.nonce)
    : await getNonce(ctx, fromWallet.address);
  const signed = buildTx({
    from:     fromWallet,
    to:       params.to,
    amount:   params.amount,
    fee:      params.fee,
    nonce,
    opReturn: params.opReturn ?? "",
  });
  try {
    const r = await ctx.call("sendrawtransaction", [signed]);
    return { ok: true, txid: r?.txid ?? signed.hash, response: r, signed };
  } catch (e) {
    return { ok: false, error: e.message, code: e.code, signed };
  }
}

/**
 * Fire a fee-free op_return TX (amount=0, opReturn set). Used for NS register,
 * stake/unstake, agent_register, etc. — anywhere the chain reads memo data.
 */
export async function submitMemoTx(ctx, fromWallet, params) {
  // params: { to, opReturn, fee?, amount?, nonce? }
  // Many memo flows still want a non-zero amount (the register fee) — caller
  // sets that. Default amount = 1 SAT is enough to make the TX valid when
  // op_return is also empty (which we never do here).
  return submitTx(ctx, fromWallet, {
    to:       params.to ?? fromWallet.address,
    amount:   params.amount ?? 1,
    fee:      params.fee,
    opReturn: params.opReturn,
    nonce:    params.nonce,
  });
}

// ── Pretty printers ─────────────────────────────────────────────────────────

export function fmtSat(sat) {
  const s = typeof sat === "bigint" ? sat : BigInt(sat);
  const omni = Number(s) / 1e9;
  return `${omni.toFixed(6).replace(/0+$/, "").replace(/\.$/, "")} OMNI`;
}

export function fmtAddr(a) {
  if (!a) return "(none)";
  if (a.length <= 24) return a;
  return a.slice(0, 12) + "…" + a.slice(-8);
}

export function header(title, ctx) {
  console.log("=".repeat(70));
  console.log(`  ${title}`);
  console.log("=".repeat(70));
  if (ctx) {
    console.log(`  RPC:   ${ctx.url}`);
    console.log(`  Auth:  ${ctx.token ? "Bearer (set)" : "none"}`);
  }
  console.log("");
}

export function section(title) {
  console.log("");
  console.log(`── ${title} ${"─".repeat(Math.max(1, 65 - title.length))}`);
}

// ── Self-test (run with `node _wallet-pool.mjs`) ────────────────────────────

if (import.meta.url === `file://${process.argv[1].replace(/\\/g, "/")}` ||
    process.argv[1]?.endsWith("_wallet-pool.mjs")) {
  // Print the pool addresses.
  const pool = makePool();
  console.log("Wallet pool (deterministic, 10 wallets):");
  for (const w of pool) {
    console.log(`  ${w.label.padEnd(8)} ${w.address}   ${w.evm}`);
  }
}
