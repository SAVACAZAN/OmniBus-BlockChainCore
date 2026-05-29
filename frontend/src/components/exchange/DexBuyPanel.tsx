/**
 * DexBuyPanel.tsx — on-chain buy from active BIP-44 slot using NATIVE ETH.
 *
 * Flow (no MetaMask, no WETH wrap, no preimage):
 *   1. User picks OMNI/ETH pair + amount of ETH to escrow.
 *   2. Frontend signs `placeBuyOrderNative()` on OmnibusDEX with
 *      `{ value: amountWei }`. ETH locked into the contract directly.
 *   3. When the order fills, the chain's dex_settler thread auto-submits
 *      settle(orderId, sellerEvm) and the seller receives the ETH.
 *
 * Cancel button refunds escrow with a single cancelOrder() tx.
 *
 * The OMNI recipient 32-byte commitment is keccak256(bech32 OMNI address),
 * so the settler can credit the OMNI seller inside OmniBus at fill time.
 */

import { useEffect, useMemo, useState } from "react";
import { midTrunc } from "../../utils/fmt";
import { keccak256, toUtf8Bytes, parseEther, formatEther } from "ethers";
import {
  placeBuyOrderNativeOnDex,
  cancelOrderOnDex,
  dexContractFor,
  providerForChain,
} from "../../api/clients/omnibus-dex";
import { getUnlocked, deriveSlotKey } from "../../api/wallet/wallet-keystore";
import { useActiveSlot } from "../../api/hooks/use-active-slot";

// ── Pair config ───────────────────────────────────────────────────────────
//
// Each pair lives on a specific EVM chain whose native gas asset is the
// quote currency. Adding LCX support means a new entry with chainId
// 76847801 (Liberty); the rest of the component is generic.
type DexPair = {
  pairId: number;
  label: string;
  quoteSymbol: string;
  chainId: number;
};

const PAIRS: DexPair[] = [
  { pairId: 6, label: "OMNI/ETH (Sepolia)", quoteSymbol: "ETH", chainId: 11155111 },
];

function omniRecipientCommitment(omniAddress: string): `0x${string}` {
  return keccak256(toUtf8Bytes(omniAddress)) as `0x${string}`;
}

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
  const [busy, setBusy] = useState<"idle" | "place" | "cancel">("idle");
  const [log, setLog] = useState<string[]>([]);
  const [lastOrderId, setLastOrderId] = useState<bigint | null>(null);
  const [escrowedBalance, setEscrowedBalance] = useState<string>("—");
  const [ethBal, setEthBal] = useState<string>("—");

  const pushLog = (s: string) => setLog((l) => [...l, `${new Date().toISOString().slice(11, 19)} ${s}`]);

  useEffect(() => {
    if (!dexAddress || !evmAddress) return;
    let cancelled = false;
    (async () => {
      try {
        const p = providerForChain(pair.chainId);
        const [escrowBal, userEth] = await Promise.all([
          p.getBalance(dexAddress),
          p.getBalance(evmAddress),
        ]);
        if (cancelled) return;
        setEscrowedBalance(`${formatEther(escrowBal)} ${pair.quoteSymbol}`);
        setEthBal(formatEther(userEth));
      } catch {
        if (cancelled) return;
        setEscrowedBalance("?");
      }
    })();
    return () => { cancelled = true; };
  }, [dexAddress, evmAddress, pair.chainId, pair.quoteSymbol, busy, lastOrderId]);

  async function handleBuy() {
    if (!unlocked) { pushLog("Wallet locked."); return; }
    if (!dexAddress) { pushLog(`OmnibusDEX not deployed on chain ${pair.chainId}`); return; }
    if (!amountStr || Number(amountStr) <= 0) { pushLog("Enter an amount > 0"); return; }

    const slotKey = deriveSlotKey(activeSlot);
    if (!slotKey?.evmPrivateKey) {
      pushLog("Cannot derive EVM privkey — wallet must be unlocked with mnemonic.");
      return;
    }

    const amountWei = parseEther(amountStr);
    const orderId = nextOrderId();
    const expiresAt = Math.floor(Date.now() / 1000) + expiryHours * 3600;
    const omniCommit = omniRecipientCommitment(omniAddress);

    try {
      setBusy("place");
      pushLog(`Placing buy order ${orderId} (${amountStr} ${pair.quoteSymbol} native escrow)…`);
      const txHash = await placeBuyOrderNativeOnDex({
        chainId: pair.chainId,
        amountWei,
        orderId,
        omniRecipientHex32: omniCommit,
        expiresAt,
        signerPrivKey: slotKey.evmPrivateKey,
      });
      pushLog(`  ✓ placeBuyOrderNative tx: ${txHash}`);
      pushLog(`  Funds locked. Settler will submit settle() at fill time.`);
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

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
      <div className="flex items-center justify-between mb-3">
        <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          DEX Buy (native escrow)
        </h2>
        <span className="text-[10px] text-mempool-text-dim">
          Slot #{activeSlot} → {midTrunc(evmAddress, 6, 4)}
        </span>
      </div>

      {!dexAddress ? (
        <div className="rounded border border-red-700/40 bg-red-950/20 p-3 text-xs text-red-300">
          OmnibusDEX is not deployed on chain {pair.chainId} yet.
        </div>
      ) : (
        <>
          <div className="text-[11px] text-mempool-text-dim mb-3 space-y-0.5">
            <div>Contract: <span className="font-mono text-mempool-text">{midTrunc(dexAddress, 8, 6)}</span></div>
            <div>Total escrowed: <span className="text-mempool-green">{escrowedBalance}</span></div>
            <div className="pt-1 mt-1 border-t border-mempool-border/60">
              Your slot — {pair.quoteSymbol}: <span className="text-mempool-text">{ethBal}</span>
            </div>
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
                Amount ({pair.quoteSymbol})
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
              {busy === "place" ? "Locking escrow…" : "Place Buy Order"}
            </button>

            {lastOrderId !== null && (
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
