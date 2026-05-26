/**
 * htlc-eth.ts
 *
 * TypeScript bindings for OmnibusHTLC.sol on EVM chains.
 * Uses ethers v6 (installed as a dependency in package.json).
 *
 * Deployment note: deploy evm/contracts/OmnibusHTLC.sol with your preferred
 * toolchain (Hardhat, Foundry, Remix) and update HTLC_CONTRACTS addresses below.
 *
 * Compile requirement: solc ^0.8.24 with optimizer enabled is recommended.
 */

import {
  Contract,
  ContractTransactionReceipt,
  ContractTransactionResponse,
  JsonRpcSigner,
  Provider,
} from "ethers";

// ---------------------------------------------------------------------------
// Deployed contract addresses (per chain) — update after deployment
// ---------------------------------------------------------------------------

export const HTLC_CONTRACTS: Record<number, string> = {
  1:        "0x0000000000000000000000000000000000000000", // Ethereum mainnet — TBD
  8453:     "0x0000000000000000000000000000000000000000", // Base mainnet — TBD
  84532:    "0x0000000000000000000000000000000000000000", // Base Sepolia — no ETH for deploy
  11155111: "0xC95cAED3179B8D2899acAC193411CC65759cEC81", // Sepolia — deployed 2026-05-09
  56:       "0x0000000000000000000000000000000000000000", // BNB Chain — TBD
  137:      "0x0000000000000000000000000000000000000000", // Polygon — TBD
};

// ---------------------------------------------------------------------------
// Inline ABI (self-contained — no build artifact dependency)
// ---------------------------------------------------------------------------

export const HTLC_ABI = [
  // ---- state-changing functions ----
  {
    name: "init",
    type: "function",
    stateMutability: "payable",
    inputs: [
      { name: "recipient", type: "address" },
      { name: "hashLock",  type: "bytes32" },
      { name: "timelock",  type: "uint256" },
    ],
    outputs: [{ name: "id", type: "bytes32" }],
  },
  {
    name: "claim",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "id",       type: "bytes32" },
      { name: "preimage", type: "bytes32" },
    ],
    outputs: [],
  },
  {
    name: "refund",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [],
  },
  // ---- view functions ----
  {
    name: "getLock",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "sender",    type: "address" },
          { name: "recipient", type: "address" },
          { name: "amount",    type: "uint256" },
          { name: "hashLock",  type: "bytes32" },
          { name: "timelock",  type: "uint256" },
          { name: "claimed",   type: "bool"    },
          { name: "refunded",  type: "bool"    },
        ],
      },
    ],
  },
  {
    name: "locks",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [
      { name: "sender",    type: "address" },
      { name: "recipient", type: "address" },
      { name: "amount",    type: "uint256" },
      { name: "hashLock",  type: "bytes32" },
      { name: "timelock",  type: "uint256" },
      { name: "claimed",   type: "bool"    },
      { name: "refunded",  type: "bool"    },
    ],
  },
  // ---- events ----
  {
    name: "HTLCInit",
    type: "event",
    inputs: [
      { name: "id",        type: "bytes32", indexed: true  },
      { name: "sender",    type: "address", indexed: true  },
      { name: "recipient", type: "address", indexed: true  },
      { name: "amount",    type: "uint256", indexed: false },
      { name: "hashLock",  type: "bytes32", indexed: false },
      { name: "timelock",  type: "uint256", indexed: false },
    ],
  },
  {
    name: "HTLCClaim",
    type: "event",
    inputs: [
      { name: "id",       type: "bytes32", indexed: true  },
      { name: "preimage", type: "bytes32", indexed: false },
    ],
  },
  {
    name: "HTLCRefund",
    type: "event",
    inputs: [
      { name: "id", type: "bytes32", indexed: true },
    ],
  },
] as const;

// ---------------------------------------------------------------------------
// TypeScript mirror of the Solidity Lock struct
// ---------------------------------------------------------------------------

export interface HTLCLock {
  sender:    string;   // address
  recipient: string;   // address
  amount:    bigint;   // uint256, in wei
  hashLock:  string;   // bytes32 hex string (0x...)
  timelock:  bigint;   // uint256, block number
  claimed:   boolean;
  refunded:  boolean;
}

// ---------------------------------------------------------------------------
// Parameter types
// ---------------------------------------------------------------------------

export interface LockEthParams {
  contractAddr: string;
  recipient:    string;
  hashLock:     string;   // bytes32 hex (sha256 of preimage), 0x-prefixed
  timelock:     bigint;   // block number after which refund is allowed
  amountWei:    bigint;   // amount to lock in wei
  signer:       JsonRpcSigner;
}

export interface ClaimEthParams {
  contractAddr: string;
  htlcId:       string;   // bytes32 returned from lockEth
  preimage:     string;   // bytes32 hex, 0x-prefixed
  signer:       JsonRpcSigner;
}

export interface RefundEthParams {
  contractAddr: string;
  htlcId:       string;
  signer:       JsonRpcSigner;
}

export interface GetLockEthParams {
  contractAddr: string;
  htlcId:       string;
  provider:     Provider;
}

// ---------------------------------------------------------------------------
// Internal helper: extract HTLC id from HTLCInit event log
// ---------------------------------------------------------------------------

async function extractHtlcId(
  receipt: ContractTransactionReceipt,
  contract: Contract,
): Promise<string> {
  const iface = contract.interface;
  for (const log of receipt.logs) {
    try {
      const parsed = iface.parseLog({ topics: [...log.topics], data: log.data });
      if (parsed && parsed.name === "HTLCInit") {
        return parsed.args[0] as string;
      }
    } catch {
      // not from this contract — skip
    }
  }
  throw new Error("HTLCInit event not found in transaction receipt");
}

// ---------------------------------------------------------------------------
// lockEth — create a new HTLC, lock ETH to recipient behind hashLock
// ---------------------------------------------------------------------------

export async function lockEth(params: LockEthParams): Promise<{ txHash: string; htlcId: string }> {
  const { contractAddr, recipient, hashLock, timelock, amountWei, signer } = params;
  const contract = new Contract(contractAddr, HTLC_ABI, signer);

  const tx: ContractTransactionResponse = await contract.init(
    recipient,
    hashLock,
    timelock,
    { value: amountWei },
  );

  const receipt = await tx.wait();
  if (!receipt) throw new Error("Transaction receipt is null");

  const htlcId = await extractHtlcId(receipt, contract);
  return { txHash: tx.hash, htlcId };
}

// ---------------------------------------------------------------------------
// claimEth — recipient reveals preimage to collect locked ETH
// ---------------------------------------------------------------------------

export async function claimEth(params: ClaimEthParams): Promise<string> {
  const { contractAddr, htlcId, preimage, signer } = params;
  const contract = new Contract(contractAddr, HTLC_ABI, signer);

  const tx: ContractTransactionResponse = await contract.claim(htlcId, preimage);
  await tx.wait();
  return tx.hash;
}

// ---------------------------------------------------------------------------
// refundEth — sender reclaims ETH after timelock expiry
// ---------------------------------------------------------------------------

export async function refundEth(params: RefundEthParams): Promise<string> {
  const { contractAddr, htlcId, signer } = params;
  const contract = new Contract(contractAddr, HTLC_ABI, signer);

  const tx: ContractTransactionResponse = await contract.refund(htlcId);
  await tx.wait();
  return tx.hash;
}

// ---------------------------------------------------------------------------
// getLockEth — read-only fetch of a Lock struct from the contract
// ---------------------------------------------------------------------------

export async function getLockEth(params: GetLockEthParams): Promise<HTLCLock> {
  const { contractAddr, htlcId, provider } = params;
  const contract = new Contract(contractAddr, HTLC_ABI, provider);

  const raw = await contract.getLock(htlcId) as {
    sender: string; recipient: string; amount: bigint;
    hashLock: string; timelock: bigint; claimed: boolean; refunded: boolean;
  };

  return {
    sender:    raw.sender,
    recipient: raw.recipient,
    amount:    BigInt(raw.amount),
    hashLock:  raw.hashLock,
    timelock:  BigInt(raw.timelock),
    claimed:   raw.claimed,
    refunded:  raw.refunded,
  };
}

// ---------------------------------------------------------------------------
// currentChainHtlcContract — looks up deployed address by chainId
// Returns null if chain is not configured or address is still placeholder.
// ---------------------------------------------------------------------------

const ZERO_ADDR = "0x0000000000000000000000000000000000000000";

export function currentChainHtlcContract(chainId: number): string | null {
  const addr = HTLC_CONTRACTS[chainId];
  if (!addr || addr === ZERO_ADDR) return null;
  return addr;
}

// ---------------------------------------------------------------------------
// swap_proveSettle JSON builder (new structured shape)
// ---------------------------------------------------------------------------

/**
 * ETH SPV proof object as accepted by the new (post-2026-05) shape of
 * `swap_proveSettle.spv_proof_blob`. The OmniBus node detects this object
 * shape via JSON parsing and falls back to the legacy flat key=value blob
 * (with `tx_index_rlp_hex`, `receipt_rlp_hex`, pipe-separated
 * `receipt_proof_hex`) if the field is a string instead.
 *
 * Notes:
 *   * `tx_index_rlp` is the RLP-encoded transaction index — the trie key
 *     of the MPT keyed by tx index inside `receiptsRoot`.
 *   * `receipt_rlp` is the RLP-encoded receipt — the trie value.
 *   * `receipt_proof` is an ordered list of trie nodes from root → leaf,
 *     each item is the RLP-encoded node bytes as a hex string.
 *   * `chain_id` is optional; defaults to "1" (mainnet) on the node.
 */
export interface EthSpvProofObject {
  chain: "eth";
  chain_id?: string;
  block_height: number;
  tx_hash: string;
  tx_index_rlp: string;
  receipt_rlp: string;
  receipt_proof: string[];
}

const HEX_RE = /^[0-9a-fA-F]+$/;

function ensureHex(label: string, hex: string): void {
  const stripped = hex.startsWith("0x") || hex.startsWith("0X") ? hex.slice(2) : hex;
  if (!HEX_RE.test(stripped) || stripped.length === 0 || stripped.length % 2 !== 0) {
    throw new Error(`${label}: not a valid even-length hex string`);
  }
}

export function buildEthSpvProofObject(opts: {
  chainId?: number | string;
  blockHeight: number;
  txHash: string;
  txIndexRlp: string;
  receiptRlp: string;
  receiptProof: string[];
}): EthSpvProofObject {
  if (!Number.isInteger(opts.blockHeight) || opts.blockHeight < 0) {
    throw new Error("block_height must be a non-negative integer");
  }
  ensureHex("tx_hash", opts.txHash);
  ensureHex("tx_index_rlp", opts.txIndexRlp);
  ensureHex("receipt_rlp", opts.receiptRlp);
  if (!Array.isArray(opts.receiptProof) || opts.receiptProof.length === 0) {
    throw new Error("receipt_proof must be a non-empty array of RLP-hex node strings");
  }
  for (const n of opts.receiptProof) ensureHex("receipt_proof[i]", n);
  const out: EthSpvProofObject = {
    chain: "eth",
    block_height: opts.blockHeight,
    tx_hash: opts.txHash,
    tx_index_rlp: opts.txIndexRlp,
    receipt_rlp: opts.receiptRlp,
    receipt_proof: opts.receiptProof,
  };
  if (opts.chainId !== undefined) {
    out.chain_id = typeof opts.chainId === "number" ? String(opts.chainId) : opts.chainId;
  }
  return out;
}
