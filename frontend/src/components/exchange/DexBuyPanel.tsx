/**
 * DexBuyPanel.tsx — Hyperliquid-style on-chain buy flow.
 *
 * Flow (no MetaMask, no preimage):
 *   1. User picks pair (e.g. OMNI/ETH on Sepolia) + amount of quote to spend.
 *   2. Frontend signs a native exchange_placeOrder so the matching engine
 *      knows this user wants to buy — the order shows in the orderbook.
 *   3. Frontend signs an EVM tx from the same BIP-44 slot:
 *        a. approve(dex, amountWei)   (only if allowance is short)
 *        b. placeBuyOrder(orderId, token, amountWei, omniRecipient, expiry)
 *      → funds locked in OmnibusDEX escrow on Sepolia.
 *   4. When the order fills, the chain's dex_settler thread auto-submits
 *      settle(orderId, sellerEvm) and the seller receives the ETH/USDC.
 *
 * If the user clicks Cancel, the cancelOrder() EVM tx refunds escrow
 * immediately — no preimage wait, no HTLC dance.
 *
 * The "OMNI recipient" 32-byte commitment is derived deterministically
 * from the user's OMNI address (keccak256 of the bech32 string). The
 * settler reads this from the OrderPlaced event and pays the OMNI seller
 * inside OmniBus when settling.
 */

import { useEffect, useMemo, useState } from "react";
import { keccak256, toUtf8Bytes, parseEther, formatEther, Contract, Wallet } from "ethers";
import {
  ensureAllowance,
  placeBuyOrderOnDex,
  cancelOrderOnDex,
  dexContractFor,
  providerForChain,
  toTokenWei,
} from "../../api/omnibus-dex";
import { getUnlocked, deriveSlotKey } from "../../api/wallet-keystore";
import { useActiveSlot } from "../../api/use-active-slot";

// Minimal WETH9 ABI — deposit() to wrap ETH, withdraw(amount) to unwrap,
// balanceOf for read-only display.
const WETH_ABI = [
  { name: "deposit",  type: "function", stateMutability: "payable",    inputs: [],                                               outputs: [] },
  { name: "withdraw", type: "function", stateMutability: "nonpayable", inputs: [{ name: "wad", type: "uint256" }],               outputs: [] },
  { name: "balanceOf", type: "function", stateMutability: "view",       inputs: [{ name: "who", type: "address" }],               outputs: [{ name: "", type: "uint256" }] },
] as const;

// ── Pair config —────────────────────────────────────────────────────────
//
// For now we only ship the OMNI/ETH pair on Sepolia (pair_id 6 in the
// matching engine, see CLAUDE.md). Adding more pairs is a matter of
// extending this table — the rest of the component is generic.
type DexPair = {
  pairId: number;
  label: string;
  base: "OMNI";
  quote: "ETH" | "USDC";
  /** EVM chain where the escrow contract lives. */
  chainId: number;
  /** Token address users escrow. ZeroAddress = native ETH (not yet
   *  supported by OmnibusDEX — the contract is ERC-20 only, so for ETH
   *  pairs the user must wrap to WETH first). */
  tokenAddr: `0x${string}`;
  tokenDecimals: number;
  tokenSymbol: string;
};

// WETH on Sepolia — official faucet contract that lets users wrap ETH.
// Anyone can call `deposit()` with ETH and receive 1:1 WETH back.
const WETH_SEPOLIA: `0x${string}` = "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14";

const PAIRS: DexPair[] = [
  {
    pairId: 6,
    label: "OMNI/ETH (Sepolia)",
    base: "OMNI",
    quote: "ETH",
    chainId: 11155111,
    tokenAddr: WETH_SEPOLIA,
    tokenDecimals: 18,
    tokenSymbol: "WETH",
  },
];

// Compute the 32-byte commitment the contract expects for `omniRecipient`.
// Keep it identical with how OmnibusDEX-side validation derives it (chain
// side encodes the bech32 ob1q.. via keccak — same function).
function omniRecipientCommitment(omniAddress: string): `0x${string}` {
  return keccak256(toUtf8Bytes(omniAddress)) as `0x${string}`;
}

// Order id: 64-bit nonce. The chain assigns these on the OmniBus side;
// here we use a unix ms epoch ID so duplicates from the same client are
// near-impossible. The contract refuses duplicates anyway.
function nextOrderId(): bigint {
  return BigInt(Date.now()) * 1000n + BigInt(Math.floor(Math.random() * 1000));
}

export function DexBuyPanel() {
  const unlocked = getUnlocked();
  const activeSlot = useActiveSlot();
  const slotRow = unlocked?.allAddresses?.find((a) => a.index === activeSlot);
  const omniAddress = slotRow?.address ?? unlocked?.address ?? "";
  const evmAddress = slotRow?.evmAddress ?? "";

  const [pairId, setPairId] = useState<number>(PAIRS[0].pairId);
  const pair = useMemo(() => PAIRS.find((p) => p.pairId === pairId)!, [pairId]);
  const dexAddress = dexContractFor(pair.chainId);

  const [amountStr, setAmountStr] = useState<string>("");
  const [expiryHours, setExpiryHours] = useState<number>(24);
  const [busy, setBusy] = useState<"idle" | "approve" | "place" | "cancel" | "wrap">("idle");
  const [log, setLog] = useState<string[]>([]);
  const [lastOrderId, setLastOrderId] = useState<bigint | null>(null);
  const [escrowedBalance, setEscrowedBalance] = useState<string>("—");
  // ETH + WETH balances for the active slot so the user can see whether
  // they have enough to wrap and place an order without leaving the panel.
  const [ethBal, setEthBal] = useState<string>("—");
  const [wethBal, setWethBal] = useState<string>("—");
  const [wrapAmount, setWrapAmount] = useState<string>("0.01");

  const pushLog = (s: string) => setLog((l) => [...l, `${new Date().toISOString().slice(11, 19)} ${s}`]);

  // Pull the deployer's view of the contract operator, mostly so the
  // user can sanity-check we're talking to the right deployment.
  // Also fetch the active slot's ETH + WETH balance so the user sees at
  // a glance whether they have funds to wrap/trade.
  useEffect(() => {
    if (!dexAddress || !evmAddress) return;
    let cancelled = false;
    (async () => {
      try {
        const p = providerForChain(pair.chainId);
        const [escrowBal, userEth, weth] = await Promise.all([
          p.getBalance(dexAddress),
          p.getBalance(evmAddress),
          (async () => {
            try {
              const c = new Contract(pair.tokenAddr, WETH_ABI, p);
              return await c.balanceOf(evmAddress) as bigint;
            } catch { return 0n; }
          })(),
        ]);
        if (cancelled) return;
        setEscrowedBalance(`${formatEther(escrowBal)} ETH`);
        setEthBal(formatEther(userEth));
        setWethBal(formatEther(weth));
      } catch {
        if (cancelled) return;
        setEscrowedBalance("?");
      }
    })();
    return () => { cancelled = true; };
  }, [dexAddress, evmAddress, pair.chainId, pair.tokenAddr, busy, lastOrderId]);

  // ── Wrap ETH→WETH ─────────────────────────────────────────────────────
  async function handleWrap() {
    if (!unlocked) { pushLog("Wallet locked."); return; }
    if (!wrapAmount || Number(wrapAmount) <= 0) { pushLog("Enter wrap amount > 0"); return; }
    const slotKey = deriveSlotKey(activeSlot);
    if (!slotKey?.evmPrivateKey) { pushLog("Cannot derive EVM privkey."); return; }
    try {
      setBusy("wrap");
      pushLog(`Wrapping ${wrapAmount} ETH → WETH…`);
      const provider = providerForChain(pair.chainId);
      const w = new Wallet("0x" + slotKey.evmPrivateKey.replace(/^0x/, ""), provider);
      const weth = new Contract(pair.tokenAddr, WETH_ABI, w);
      // WETH9 deposit is `deposit() payable` — call with value = wrapAmount.
      const tx = await weth.deposit({ value: parseEther(wrapAmount) });
      pushLog(`  tx: ${tx.hash}`);
      await tx.wait();
      pushLog(`  ✓ wrapped — refreshing balances`);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      pushLog(`✗ wrap failed: ${msg}`);
    } finally {
      setBusy("idle");
    }
  }

  // ── Submit ────────────────────────────────────────────────────────────

  async function handleBuy() {
    if (!unlocked) { pushLog("Wallet locked."); return; }
    if (!dexAddress) { pushLog(`OmnibusDEX not deployed on chain ${pair.chainId}`); return; }
    if (!amountStr || Number(amountStr) <= 0) { pushLog("Enter an amount > 0"); return; }

    const slotKey = deriveSlotKey(activeSlot);
    if (!slotKey?.evmPrivateKey) {
      pushLog("Cannot derive EVM privkey — wallet must be unlocked with mnemonic.");
      return;
    }

    const amountWei = pair.tokenDecimals === 18
      ? parseEther(amountStr)
      : toTokenWei(amountStr, pair.tokenDecimals);
    const orderId = nextOrderId();
    const expiresAt = Math.floor(Date.now() / 1000) + expiryHours * 3600;
    const omniCommit = omniRecipientCommitment(omniAddress);

    try {
      setBusy("approve");
      pushLog(`Approving ${amountStr} ${pair.tokenSymbol} for OmnibusDEX…`);
      const allowResp = await ensureAllowance({
        chainId: pair.chainId,
        token: pair.tokenAddr,
        amountWei,
        signerPrivKey: slotKey.evmPrivateKey,
      });
      if (allowResp.approved) {
        pushLog(`  approve tx: ${allowResp.txHash}`);
      } else {
        pushLog("  allowance already sufficient — skipping approve");
      }

      setBusy("place");
      pushLog(`Placing buy order ${orderId} (${amountStr} ${pair.tokenSymbol} escrow)…`);
      const txHash = await placeBuyOrderOnDex({
        chainId: pair.chainId,
        token: pair.tokenAddr,
        amountWei,
        orderId,
        omniRecipientHex32: omniCommit,
        expiresAt,
        signerPrivKey: slotKey.evmPrivateKey,
      });
      pushLog(`  ✓ placeBuyOrder tx: ${txHash}`);
      pushLog(`  Funds locked in escrow. Settler will submit settle() at fill time.`);
      setLastOrderId(orderId);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      pushLog(`✗ ${msg}`);
    } finally {
      setBusy("idle");
    }
  }

  async function handleCancel() {
    if (!lastOrderId) return;
    const slotKey = deriveSlotKey(activeSlot);
    if (!slotKey?.evmPrivateKey) { pushLog("Locked."); return; }

    try {
      setBusy("cancel");
      pushLog(`Cancelling order ${lastOrderId}…`);
      const tx = await cancelOrderOnDex(pair.chainId, lastOrderId, slotKey.evmPrivateKey);
      pushLog(`  ✓ cancel tx: ${tx}`);
      pushLog(`  Escrow refunded.`);
      setLastOrderId(null);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      pushLog(`✗ ${msg}`);
    } finally {
      setBusy("idle");
    }
  }

  // ── Render ────────────────────────────────────────────────────────────

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
      <div className="flex items-center justify-between mb-3">
        <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          DEX Buy (on-chain escrow)
        </h2>
        <span className="text-[10px] text-mempool-text-dim">
          Slot #{activeSlot} → {evmAddress.slice(0, 6)}…{evmAddress.slice(-4)}
        </span>
      </div>

      {!dexAddress ? (
        <div className="rounded border border-red-700/40 bg-red-950/20 p-3 text-xs text-red-300">
          OmnibusDEX is not deployed on chain {pair.chainId} yet.
        </div>
      ) : (
        <>
          <div className="text-[11px] text-mempool-text-dim mb-3 space-y-0.5">
            <div>Contract: <span className="font-mono text-mempool-text">{dexAddress.slice(0, 8)}…{dexAddress.slice(-6)}</span></div>
            <div>Total ETH escrowed: <span className="text-mempool-green">{escrowedBalance}</span></div>
            <div className="pt-1 mt-1 border-t border-mempool-border/60">
              Your slot — ETH: <span className="text-mempool-text">{ethBal}</span>{"  "}
              WETH: <span className="text-mempool-text">{wethBal}</span>
            </div>
          </div>

          {/* Wrap ETH → WETH (Sepolia WETH9 deposit()). The DEX contract
              only escrows ERC-20, so users need WETH before placeBuyOrder. */}
          <div className="flex items-end gap-2 mb-3 p-2 rounded bg-mempool-bg/60 border border-mempool-border">
            <div className="flex-1">
              <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim block mb-1">
                Wrap ETH → WETH
              </label>
              <input
                type="number"
                step="0.001"
                min="0"
                value={wrapAmount}
                onChange={(e) => setWrapAmount(e.target.value)}
                className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
              />
            </div>
            <button
              onClick={handleWrap}
              disabled={busy !== "idle" || !wrapAmount}
              className="px-3 py-1.5 rounded text-xs uppercase tracking-wider font-semibold border border-blue-500/40 text-blue-300 hover:bg-blue-950/20 disabled:opacity-40 disabled:cursor-not-allowed"
            >
              {busy === "wrap" ? "Wrapping…" : "Wrap"}
            </button>
          </div>

          <div className="space-y-2">
            <div>
              <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim block mb-1">Pair</label>
              <select
                value={pairId}
                onChange={(e) => setPairId(Number(e.target.value))}
                className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs text-mempool-text"
              >
                {PAIRS.map((p) => (
                  <option key={p.pairId} value={p.pairId}>{p.label}</option>
                ))}
              </select>
            </div>

            <div>
              <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim block mb-1">
                Amount ({pair.tokenSymbol})
              </label>
              <input
                type="number"
                step="0.0001"
                min="0"
                value={amountStr}
                onChange={(e) => setAmountStr(e.target.value)}
                placeholder="0.01"
                className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
              />
            </div>

            <div>
              <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim block mb-1">
                Expiry ({expiryHours}h)
              </label>
              <input
                type="range"
                min={1}
                max={168}
                value={expiryHours}
                onChange={(e) => setExpiryHours(Number(e.target.value))}
                className="w-full"
              />
              <div className="text-[10px] text-mempool-text-dim">
                After this, you can self-refund without the operator's signature.
              </div>
            </div>

            <button
              onClick={handleBuy}
              disabled={busy !== "idle" || !amountStr}
              className="w-full px-3 py-2 rounded text-xs uppercase tracking-wider font-semibold bg-mempool-green text-black hover:opacity-90 disabled:opacity-40 disabled:cursor-not-allowed"
            >
              {busy === "approve" ? "Approving…" :
               busy === "place"   ? "Locking escrow…" :
               "Place Buy Order"}
            </button>

            {lastOrderId && (
              <button
                onClick={handleCancel}
                disabled={busy !== "idle"}
                className="w-full px-3 py-1.5 rounded text-xs uppercase tracking-wider font-semibold border border-red-700/40 text-red-300 hover:bg-red-950/20 disabled:opacity-40"
              >
                {busy === "cancel" ? "Cancelling…" : `Cancel order ${lastOrderId.toString()}`}
              </button>
            )}
          </div>

          {log.length > 0 && (
            <div className="mt-3 p-2 rounded bg-mempool-bg border border-mempool-border max-h-40 overflow-y-auto">
              {log.map((line, i) => (
                <div key={i} className="text-[10px] font-mono text-mempool-text-dim whitespace-pre-wrap break-all">
                  {line}
                </div>
              ))}
            </div>
          )}
        </>
      )}
    </div>
  );
}
