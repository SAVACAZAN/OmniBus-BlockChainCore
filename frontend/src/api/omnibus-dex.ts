/**
 * omnibus-dex.ts
 *
 * Frontend bindings for OmnibusDEX.sol — the universal ERC-20 escrow used
 * for the EVM side of any OMNI/<token> pair on the OmniBus DEX.
 *
 * Flow:
 *   1. User picks pair (e.g. OMNI/USDC) and clicks Buy.
 *   2. Frontend calls `approveSpend(token, dex, amount)` so the contract
 *      can pull the user's USDC into escrow.
 *   3. Frontend calls `placeBuyOrder(orderId, token, amount, omniRecip, expiresAt)`.
 *      The contract transferFroms USDC into itself and emits OrderPlaced.
 *   4. OmniBus chain (the operator) sees the event, matches against an OMNI
 *      sell, debits the OMNI seller, then calls `settle(orderId, sellerEvm)`
 *      to release the USDC to the seller.
 *
 * The user signs from the BIP-44 slot active in the Header. NO MetaMask —
 * the unlocked OmniBus mnemonic provides the EVM private key at
 * m/44'/60'/0'/0/<slot>.
 *
 * Deployment: addresses live in `chains.ts → CHAINS[id].dexContract`. Empty
 * string until OmnibusDEX is deployed on that chain.
 */

import { Contract, JsonRpcProvider, Wallet, parseUnits, ZeroAddress, type Provider } from "ethers";
import { CHAINS } from "./chains";

/**
 * Minimal inline ABI mirroring core/evm/contracts/OmnibusDEX.sol. Keeping
 * it self-contained (no build-artifact dep) means a contract upgrade still
 * needs an explicit sync, which is the right tradeoff for a money path.
 */
export const OMNIBUS_DEX_ABI = [
  {
    name: "placeBuyOrder",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "orderId",       type: "uint256" },
      { name: "token",         type: "address" },
      { name: "amount",        type: "uint256" },
      { name: "omniRecipient", type: "bytes32" },
      { name: "expiresAt",     type: "uint64"  },
    ],
    outputs: [],
  },
  {
    name: "cancelOrder",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "orderId", type: "uint256" }],
    outputs: [],
  },
  {
    name: "expireRefund",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "orderId", type: "uint256" }],
    outputs: [],
  },
  {
    name: "getOrder",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "orderId", type: "uint256" }],
    outputs: [{
      name: "",
      type: "tuple",
      components: [
        { name: "owner",         type: "address" },
        { name: "token",         type: "address" },
        { name: "amount",        type: "uint256" },
        { name: "omniRecipient", type: "bytes32" },
        { name: "expiresAt",     type: "uint64"  },
        { name: "state",         type: "uint8"   },
      ],
    }],
  },
] as const;

/// Minimal ERC-20 ABI for the allowance dance.
export const ERC20_ABI = [
  {
    name: "approve",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount",  type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "allowance",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "owner",   type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "who", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

export type PlaceBuyOrderArgs = {
  /** Chain id of the EVM network this DEX lives on (e.g. 11155111 Sepolia) */
  chainId: number;
  /** ERC-20 token contract address (USDC, EURC, etc.) the user is spending. */
  token: `0x${string}`;
  /** Amount in token's smallest unit (e.g. 1 USDC at 6 decimals = 1_000_000). */
  amountWei: bigint;
  /** Unique order id assigned by the OmniBus chain. */
  orderId: bigint;
  /** OmniBus seller's address as raw 32 bytes — chain encodes ob1q.. as keccak. */
  omniRecipientHex32: `0x${string}`;
  /** Unix-seconds expiry past which the user can self-refund. */
  expiresAt: number;
  /** EVM private key hex (no 0x prefix) for the BIP-44 slot signing this tx. */
  signerPrivKey: string;
};

/**
 * Build a provider for the given chain id by reading the RPC URL from
 * `chains.ts`. Throws if the chain isn't in the registry or has no RPC.
 */
export function providerForChain(chainId: number): Provider {
  const chain = CHAINS.find((c) => c.chainId === chainId);
  if (!chain) throw new Error(`Unknown chain id: ${chainId}`);
  if (!chain.rpc) throw new Error(`No rpc configured for chain ${chainId}`);
  return new JsonRpcProvider(chain.rpc, chainId);
}

/**
 * Look up the OmnibusDEX deployment for a chain. Returns null when the
 * contract hasn't been deployed yet (Buy flow must abort with a clear msg).
 */
export function dexContractFor(chainId: number): `0x${string}` | null {
  const chain = CHAINS.find((c) => c.chainId === chainId);
  if (!chain) return null;
  const addr = chain.dexContract;
  if (!addr || addr === ZeroAddress || addr === "") return null;
  return addr as `0x${string}`;
}

/**
 * Step 1: ensure the OmnibusDEX contract has allowance to pull `amountWei`
 * of `token` from the user. Returns true on the actual `approve` submit,
 * false when the existing allowance was already sufficient.
 *
 * Important: we don't bump allowance to infinity. The pattern of approving
 * the exact amount per order is safer — the contract can never pull more
 * than the user explicitly authorised for this single fill.
 */
export async function ensureAllowance(args: {
  chainId: number;
  token: `0x${string}`;
  amountWei: bigint;
  signerPrivKey: string;
}): Promise<{ approved: boolean; txHash?: string }> {
  const dex = dexContractFor(args.chainId);
  if (!dex) throw new Error(`OmnibusDEX not deployed on chain ${args.chainId}`);

  const provider = providerForChain(args.chainId);
  const wallet = new Wallet(args.signerPrivKey.startsWith("0x") ? args.signerPrivKey : "0x" + args.signerPrivKey, provider);
  const erc20 = new Contract(args.token, ERC20_ABI, wallet);

  const current: bigint = await erc20.allowance(wallet.address, dex);
  if (current >= args.amountWei) return { approved: false };

  const tx = await erc20.approve(dex, args.amountWei);
  const r = await tx.wait();
  return { approved: true, txHash: r?.hash };
}

/**
 * Step 2: lock the tokens into escrow on OmnibusDEX. The `omniRecipientHex32`
 * is the 32-byte commitment the chain hands you when the order is created
 * (chain encodes the ob1q.. address via keccak256 since EVM has no bech32).
 */
export async function placeBuyOrderOnDex(args: PlaceBuyOrderArgs): Promise<string> {
  const dex = dexContractFor(args.chainId);
  if (!dex) throw new Error(`OmnibusDEX not deployed on chain ${args.chainId}`);

  const provider = providerForChain(args.chainId);
  const wallet = new Wallet(args.signerPrivKey.startsWith("0x") ? args.signerPrivKey : "0x" + args.signerPrivKey, provider);
  const c = new Contract(dex, OMNIBUS_DEX_ABI, wallet);

  const tx = await c.placeBuyOrder(
    args.orderId,
    args.token,
    args.amountWei,
    args.omniRecipientHex32,
    args.expiresAt,
  );
  const r = await tx.wait();
  if (!r) throw new Error("placeBuyOrder: no receipt");
  return r.hash;
}

/**
 * Cancel an open order — refunds the escrowed tokens to the user. Allowed
 * any time before settle; the chain treats the OrderCancelled event as
 * authoritative once seen.
 */
export async function cancelOrderOnDex(
  chainId: number,
  orderId: bigint,
  signerPrivKey: string,
): Promise<string> {
  const dex = dexContractFor(chainId);
  if (!dex) throw new Error(`OmnibusDEX not deployed on chain ${chainId}`);
  const provider = providerForChain(chainId);
  const wallet = new Wallet(signerPrivKey.startsWith("0x") ? signerPrivKey : "0x" + signerPrivKey, provider);
  const c = new Contract(dex, OMNIBUS_DEX_ABI, wallet);
  const tx = await c.cancelOrder(orderId);
  const r = await tx.wait();
  if (!r) throw new Error("cancelOrder: no receipt");
  return r.hash;
}

/**
 * Read-only fetch of an order's current state.
 * state encoding: 0=empty 1=open 2=settled 3=cancelled
 */
export async function getOrderFromDex(chainId: number, orderId: bigint) {
  const dex = dexContractFor(chainId);
  if (!dex) throw new Error(`OmnibusDEX not deployed on chain ${chainId}`);
  const provider = providerForChain(chainId);
  const c = new Contract(dex, OMNIBUS_DEX_ABI, provider);
  return c.getOrder(orderId) as Promise<{
    owner: string;
    token: string;
    amount: bigint;
    omniRecipient: string;
    expiresAt: bigint;
    state: bigint;
  }>;
}

/**
 * Convenience: parse a human amount like "100" into the token's smallest
 * unit given its decimals. Caller passes decimals — there's no on-chain
 * read here so a typo in decimals can cost real money; UI must source
 * decimals from a verified token list.
 */
export function toTokenWei(humanAmount: string, decimals: number): bigint {
  return parseUnits(humanAmount, decimals);
}
