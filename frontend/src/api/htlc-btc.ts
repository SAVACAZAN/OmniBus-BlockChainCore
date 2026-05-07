/**
 * Bitcoin HTLC client — atomic swap with the OmniBus chain.
 *
 * This module is intentionally minimal:
 *   1. Calls the Omnibus RPC `htlc_btc_buildScript` to derive the
 *      P2WSH bech32 address + redeem script (hex) for an HTLC output.
 *   2. Exposes helpers to construct UNSIGNED Bitcoin transactions
 *      (funding + claim + refund) as PSBTs *if* `bitcoinjs-lib` is
 *      available. If it's not installed, we fall back to returning
 *      raw inputs/outputs so the caller can hand them to an external
 *      wallet (Electrum, Sparrow, Ledger, Trezor, BlueWallet…).
 *   3. Builds typed `swap_proveSettle` JSON payloads with an SPV
 *      proof shaped as a proper JSON object (not the legacy flat
 *      blob). The legacy flat-string form remains accepted by the
 *      node, but new callers should use `buildBtcSpvProofObject`.
 *
 * No private keys touch this code. No broadcasting either — the user
 * always signs and broadcasts via their own wallet.
 */
import { OmniBusRpcClient } from "./rpc-client";

export type BtcNetwork = "mainnet" | "testnet" | "regtest" | "signet";

export interface HtlcBtcScriptParams {
  /** 33-byte compressed pubkey (hex, 66 chars). Claims with preimage. */
  recipient_pk: string;
  /** 33-byte compressed pubkey (hex, 66 chars). Refunds after timelock. */
  sender_pk: string;
  /** 32-byte SHA256(preimage) (hex, 64 chars). */
  hash_lock: string;
  /** Absolute Bitcoin block height (CLTV). */
  timelock: number;
  /** Bitcoin network for HRP encoding. */
  network: BtcNetwork;
}

export interface HtlcBtcScriptResult {
  redeem_script_hex: string;
  p2wsh_address: string;
  witness_program_hex: string;
  network: BtcNetwork;
  hrp: string;
  timelock: number;
}

export interface FundingInput {
  txid: string;
  vout: number;
  /** UTXO value in satoshis. */
  value: number;
  /** scriptPubKey of the UTXO, as hex. */
  scriptPubKeyHex: string;
}

export interface UnsignedFundingTx {
  /** Hex-encoded unsigned transaction (no witness). */
  txHex: string;
  /** Address the funding goes to (the HTLC P2WSH address). */
  htlcAddress: string;
  /** Funding output amount in satoshis. */
  amountSat: number;
}

export interface UnsignedSpendTx {
  /** Hex-encoded TX with placeholders for witness. Caller must sign + assemble witness. */
  txHex: string;
  /** SHA256 sighash digest the caller's wallet must sign (BIP-143). */
  sighashHex: string;
  /** Hex of the redeem script — needed by the wallet to build the witness. */
  redeemScriptHex: string;
  /** Branch the wallet should construct (`claim` includes preimage; `refund` does not). */
  branch: "claim" | "refund";
}

// ─── Validation helpers ──────────────────────────────────────────────────────

const HEX_RE = /^[0-9a-fA-F]+$/;

function assertHex(name: string, hex: string, expectedBytes: number): void {
  if (typeof hex !== "string" || !HEX_RE.test(hex)) {
    throw new Error(`${name}: not a hex string`);
  }
  if (hex.length !== expectedBytes * 2) {
    throw new Error(
      `${name}: expected ${expectedBytes} bytes (${expectedBytes * 2} hex chars), got ${hex.length}`,
    );
  }
}

function assertCompressedPubkey(name: string, hex: string): void {
  assertHex(name, hex, 33);
  const prefix = hex.slice(0, 2).toLowerCase();
  if (prefix !== "02" && prefix !== "03") {
    throw new Error(`${name}: not a compressed secp256k1 pubkey (must start with 02/03)`);
  }
}

// ─── 1. Build the HTLC script + address via Omnibus RPC ──────────────────────

/**
 * Calls Omnibus RPC `htlc_btc_buildScript` and returns the bech32 P2WSH
 * address plus redeem script. Use the address as the funding output for
 * the Bitcoin TX you'll ask the user's wallet to sign.
 */
export async function buildHtlcScript(
  params: HtlcBtcScriptParams,
  client?: OmniBusRpcClient,
): Promise<HtlcBtcScriptResult> {
  assertCompressedPubkey("recipient_pk", params.recipient_pk);
  assertCompressedPubkey("sender_pk", params.sender_pk);
  assertHex("hash_lock", params.hash_lock, 32);
  if (!Number.isInteger(params.timelock) || params.timelock <= 0 || params.timelock > 0xffffffff) {
    throw new Error("timelock: must be a positive integer ≤ 2^32 - 1");
  }
  const validNets: BtcNetwork[] = ["mainnet", "testnet", "regtest", "signet"];
  if (!validNets.includes(params.network)) {
    throw new Error(`network: must be one of ${validNets.join(", ")}`);
  }

  const rpc = client ?? new OmniBusRpcClient();
  const result = await rpc.request_raw("htlc_btc_buildScript", [
    {
      recipient_pk: params.recipient_pk.toLowerCase(),
      sender_pk: params.sender_pk.toLowerCase(),
      hash_lock: params.hash_lock.toLowerCase(),
      timelock: params.timelock,
      network: params.network,
    },
  ]);

  if (!result || typeof result !== "object") {
    throw new Error("htlc_btc_buildScript: empty/invalid result");
  }
  return result as HtlcBtcScriptResult;
}

// ─── 2. Funding TX (unsigned PSBT or fallback) ───────────────────────────────

/**
 * Build an UNSIGNED funding transaction that pays `amountSat` to the HTLC
 * address. The caller signs + broadcasts via an external Bitcoin wallet.
 *
 * If `bitcoinjs-lib` is installed we return a proper base64 PSBT string in
 * `txHex` (so wallets that speak PSBT — Electrum, Sparrow, Ledger Live,
 * BitBox — can import it directly). Otherwise we return a structured
 * description that the caller can hand-build into a TX.
 */
export async function buildFundingPsbt(
  htlcAddress: string,
  amountSat: number,
  inputs: FundingInput[],
  changeAddress: string,
  feeRateSatPerVByte: number,
  network: BtcNetwork,
): Promise<UnsignedFundingTx | { fallback: true; htlcAddress: string; amountSat: number; inputs: FundingInput[]; changeAddress: string; feeRateSatPerVByte: number; network: BtcNetwork }> {
  if (amountSat <= 0) throw new Error("amountSat must be > 0");
  if (!inputs.length) throw new Error("at least one funding input is required");

  let bjs: any;
  try {
    // Lazy import — bitcoinjs-lib is optional. Only loaded when this fn is called.
    // The module name is hidden from TS so we don't need it as a peer dep at type-check time.
    const modName = "bitcoinjs-lib";
    bjs = await (Function("m", "return import(m)") as any)(modName);
  } catch {
    // Fallback: hand the work to whatever flow the caller uses (Electrum URI,
    // hardware-wallet message, manual TX construction, etc.).
    return {
      fallback: true,
      htlcAddress,
      amountSat,
      inputs,
      changeAddress,
      feeRateSatPerVByte,
      network,
    };
  }

  const networks = bjs.networks;
  const net =
    network === "mainnet" ? networks.bitcoin :
    network === "testnet" || network === "signet" ? networks.testnet :
    networks.regtest;

  const hexToBytes = (h: string): Uint8Array => {
    const out = new Uint8Array(h.length / 2);
    for (let i = 0; i < out.length; i++) out[i] = parseInt(h.substr(i * 2, 2), 16);
    return out;
  };

  const psbt = new bjs.Psbt({ network: net });
  let totalIn = 0;
  for (const inp of inputs) {
    psbt.addInput({
      hash: inp.txid,
      index: inp.vout,
      witnessUtxo: {
        script: hexToBytes(inp.scriptPubKeyHex),
        value: inp.value,
      },
    });
    totalIn += inp.value;
  }
  psbt.addOutput({ address: htlcAddress, value: amountSat });

  // Rough vbyte estimate: 10 base + 68/input (P2WPKH) + 31/output. Caller can
  // override the fee rate to compensate.
  const vbytes = 10 + inputs.length * 68 + 2 * 31;
  const fee = Math.ceil(vbytes * feeRateSatPerVByte);
  const change = totalIn - amountSat - fee;
  if (change < 0) throw new Error(`insufficient funds: in=${totalIn} out=${amountSat} fee=${fee}`);
  if (change > 546) {
    psbt.addOutput({ address: changeAddress, value: change });
  }

  return {
    txHex: psbt.toBase64(),
    htlcAddress,
    amountSat,
  };
}

// ─── 3. Claim / Refund TX construction (descriptors only) ────────────────────

/**
 * Describe an UNSIGNED claim transaction that spends an HTLC P2WSH UTXO
 * back to `recipientAddress` using the SHA-256 preimage.
 *
 * This returns a JSON description (NOT a fully-signed TX). The recipient
 * wallet must:
 *   1. Compute the BIP-143 sighash for the input
 *   2. ECDSA-sign with the recipient's private key
 *   3. Build the witness stack: [sig, preimage, 0x01, redeemScript]
 *   4. Broadcast.
 *
 * The Omnibus node deliberately doesn't hold the recipient's keys.
 */
export interface ClaimDescriptor {
  branch: "claim";
  htlcUtxo: { txid: string; vout: number; value: number; scriptPubKeyHex: string };
  redeemScriptHex: string;
  preimageHex: string;
  recipientAddress: string;
  feeSat: number;
  /**
   * Witness stack template — replace `<sig>` with a 71-73 byte DER+sighash
   * signature from the recipient's wallet.
   */
  witnessTemplate: ["<sig>", string /* preimage */, "01", string /* redeemScript */];
}

export function describeClaim(
  htlcUtxo: { txid: string; vout: number; value: number; scriptPubKeyHex: string },
  redeemScriptHex: string,
  preimageHex: string,
  recipientAddress: string,
  feeSat: number,
): ClaimDescriptor {
  assertHex("preimageHex", preimageHex, 32);
  if (feeSat < 0 || feeSat >= htlcUtxo.value) {
    throw new Error("feeSat must be ≥ 0 and < UTXO value");
  }
  return {
    branch: "claim",
    htlcUtxo,
    redeemScriptHex,
    preimageHex: preimageHex.toLowerCase(),
    recipientAddress,
    feeSat,
    witnessTemplate: ["<sig>", preimageHex.toLowerCase(), "01", redeemScriptHex.toLowerCase()],
  };
}

export interface RefundDescriptor {
  branch: "refund";
  htlcUtxo: { txid: string; vout: number; value: number; scriptPubKeyHex: string };
  redeemScriptHex: string;
  senderAddress: string;
  feeSat: number;
  /** Required by CLTV. The spending TX must set nLockTime ≥ this and nSequence < 0xffffffff. */
  timelock: number;
  witnessTemplate: ["<sig>", "" /* empty selects ELSE branch */, string /* redeemScript */];
}

export function describeRefund(
  htlcUtxo: { txid: string; vout: number; value: number; scriptPubKeyHex: string },
  redeemScriptHex: string,
  senderAddress: string,
  feeSat: number,
  timelock: number,
): RefundDescriptor {
  if (feeSat < 0 || feeSat >= htlcUtxo.value) {
    throw new Error("feeSat must be ≥ 0 and < UTXO value");
  }
  if (!Number.isInteger(timelock) || timelock <= 0) {
    throw new Error("timelock must be a positive integer block height");
  }
  return {
    branch: "refund",
    htlcUtxo,
    redeemScriptHex,
    senderAddress,
    feeSat,
    timelock,
    witnessTemplate: ["<sig>", "", redeemScriptHex.toLowerCase()],
  };
}

// ─── 4. Convenience: full atomic-swap setup ──────────────────────────────────

/**
 * One-shot helper for a Bitcoin-side HTLC setup:
 *   - Calls the node to derive the address.
 *   - Returns address + script + ready-to-use claim/refund descriptors that
 *     the caller can fill in with UTXO data later.
 */
export async function setupBitcoinHtlc(
  params: HtlcBtcScriptParams,
  client?: OmniBusRpcClient,
): Promise<HtlcBtcScriptResult> {
  return buildHtlcScript(params, client);
}

// ─── 5. swap_proveSettle JSON builder (new structured shape) ─────────────────

/**
 * BTC SPV proof object as accepted by the new (post-2026-05) shape of
 * `swap_proveSettle.spv_proof_blob`. The OmniBus node detects this object
 * shape via JSON parsing and falls back to the legacy flat key=value blob
 * if the field is a string instead.
 *
 * Field semantics:
 *   * `chain` — must be "btc"
 *   * `block_height` — Bitcoin block containing the spending TX
 *   * `tx_hash` — 32-byte hex (with or without 0x prefix)
 *   * `merkle_proof` — sibling hashes from leaf → root, each 32-byte hex
 *   * `indices` — one bit per merkle level: 0 = TX is left child, 1 = right
 *   * `merkle_root` — OPTIONAL. Only used when the node's recorded BTC
 *                     anchor was stored without a raw header (legacy
 *                     anchors). Modern anchors carry merkle_root and
 *                     ignore this field for security.
 */
export interface BtcSpvProofObject {
  chain: "btc";
  block_height: number;
  tx_hash: string;
  merkle_proof: string[];
  indices: (0 | 1)[];
  merkle_root?: string;
}

/** Type-tagged builder. Returns the object shape; callers stringify by passing it as a JSON value. */
export function buildBtcSpvProofObject(opts: {
  blockHeight: number;
  txHash: string;
  merkleProof: string[];
  indices: (0 | 1)[];
  merkleRoot?: string;
}): BtcSpvProofObject {
  if (!Number.isInteger(opts.blockHeight) || opts.blockHeight < 0) {
    throw new Error("block_height must be a non-negative integer");
  }
  assertHex("tx_hash", opts.txHash.replace(/^0x/i, ""), 32);
  if (!Array.isArray(opts.merkleProof)) {
    throw new Error("merkle_proof must be an array of hex siblings");
  }
  for (const sib of opts.merkleProof) assertHex("merkle_proof[i]", sib.replace(/^0x/i, ""), 32);
  if (opts.indices.length !== opts.merkleProof.length) {
    throw new Error("indices/merkle_proof length mismatch");
  }
  for (const b of opts.indices) {
    if (b !== 0 && b !== 1) throw new Error("indices must be 0/1");
  }
  if (opts.merkleRoot !== undefined) {
    assertHex("merkle_root", opts.merkleRoot.replace(/^0x/i, ""), 32);
  }
  const out: BtcSpvProofObject = {
    chain: "btc",
    block_height: opts.blockHeight,
    tx_hash: opts.txHash,
    merkle_proof: opts.merkleProof,
    indices: opts.indices,
  };
  if (opts.merkleRoot !== undefined) out.merkle_root = opts.merkleRoot;
  return out;
}
