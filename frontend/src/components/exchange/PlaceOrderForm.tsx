import { useState, useEffect } from "react";
import { parseEther, keccak256, toUtf8Bytes } from "ethers";
import OmniBusRpcClient, { ExchangeBalance } from "../../api/rpc-client";
import { signPlaceOrderPayload } from "../../api/exchange-sign";
import { getUnlocked, nextNonce, subscribeWallet, deriveSlotKey } from "../../api/wallet-keystore";
import { useActiveSlot, setActiveSlot } from "../../api/use-active-slot";
import { useAllSlotsBalance } from "../../api/use-all-slots-balance";
import { useTraderMode } from "./TraderModeToggle";
import { SAT_PER_OMNI, MICRO_PER_USD, midTrunc } from "../../utils/fmt";
import { TradePairBalances } from "./TradePairBalances";
import { fetchUsdcBalance, fetchEurcBalance, fetchEvmBalance, fetchSolanaBalance, fetchXrpBalance } from "../../api/multichain-balances";
import { placeBuyOrderNativeOnDex, placeBuyOrderOnDex, ensureAllowance } from "../../api/omnibus-dex";
import { USDC_CONTRACT } from "../../api/multichain-balances";

const rpc = new OmniBusRpcClient();


// All taker chains where quote asset can come from
// quote = USDC → EVM chains; quote = ETH → Sepolia/Base; quote = LCX → Liberty
interface TakerChain {
  key: string;
  label: string;
  chainId: number;
  rpc: string;
  symbol: string;
  isUsdc?: boolean;
  isEurc?: boolean;
  isSol?: boolean;
  isXrp?: boolean;
}

const TAKER_CHAINS_FOR: Record<string, TakerChain[]> = {
  USDC: [
    { key: "SEPOLIA",      label: "Sepolia",     chainId: 11155111, rpc: "https://sepolia.drpc.org",                       symbol: "USDC", isUsdc: true },
    { key: "BASE_SEPOLIA", label: "Base Sep",    chainId: 84532,    rpc: "https://sepolia.base.org",                       symbol: "USDC", isUsdc: true },
    { key: "ARB_SEPOLIA",  label: "Arb Sep",     chainId: 421614,   rpc: "https://sepolia-rollup.arbitrum.io/rpc",         symbol: "USDC", isUsdc: true },
    { key: "OP_SEPOLIA",   label: "OP Sep",      chainId: 11155420, rpc: "https://sepolia.optimism.io",                    symbol: "USDC", isUsdc: true },
    { key: "POLYGON_AMOY", label: "Amoy",        chainId: 80002,    rpc: "https://rpc-amoy.polygon.technology",            symbol: "USDC", isUsdc: true },
    { key: "AVAX_FUJI",    label: "Fuji",        chainId: 43113,    rpc: "https://api.avax-test.network/ext/bc/C/rpc",     symbol: "USDC", isUsdc: true },
  ],
  EURC: [
    { key: "SEPOLIA",      label: "Sepolia",     chainId: 11155111, rpc: "https://sepolia.drpc.org",   symbol: "EURC", isEurc: true },
    { key: "BASE_SEPOLIA", label: "Base Sep",    chainId: 84532,    rpc: "https://sepolia.base.org",   symbol: "EURC", isEurc: true },
  ],
  ETH: [
    { key: "SEPOLIA",      label: "Sepolia",     chainId: 11155111, rpc: "https://sepolia.drpc.org",   symbol: "ETH" },
    { key: "BASE_SEPOLIA", label: "Base Sep",    chainId: 84532,    rpc: "https://sepolia.base.org",   symbol: "ETH" },
  ],
  LCX: [
    { key: "LIBERTY",      label: "LCX Liberty", chainId: 76847801, rpc: "https://rpc.testnet.lcx.com", symbol: "LCX" },
  ],
  SOL: [
    { key: "SOL_DEVNET",   label: "Sol Devnet",  chainId: 0,        rpc: "https://api.devnet.solana.com", symbol: "SOL", isSol: true },
  ],
  XRP: [
    { key: "XRP_TESTNET",  label: "XRP Testnet", chainId: 0,        rpc: "https://omnibusblockchain.cc:8443/xrp-testnet/", symbol: "XRP", isXrp: true },
  ],
};

interface Props {
  pairId: number;
  pairLabel: string;
  base: string;
  quote: string;
  exchBalances: ExchangeBalance[];
  onPlaced?: () => void;
}

export function PlaceOrderForm({ pairId, pairLabel, base, quote, exchBalances, onPlaced }: Props) {
  const [, force] = useState(0);
  useEffect(() => subscribeWallet(() => force((n) => n + 1)), []);
  const [traderMode] = useTraderMode();

  const [side, setSide] = useState<"buy" | "sell">("buy");
  const [priceStr, setPriceStr] = useState("");
  const [amountStr, setAmountStr] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  // Taker chain selection (for BUY — user pays quote asset from chosen chain)
  const takerChains = TAKER_CHAINS_FOR[quote] ?? [];
  const [selectedChainKey, setSelectedChainKey] = useState<string>(takerChains[0]?.key ?? "");
  const [chainBalances, setChainBalances] = useState<Record<string, string>>({});

  const u = getUnlocked();
  // Active slot driven by the global Header dropdown — the user can switch
  // between BIP-44 indices 0..18 and every page (Trade / Stake / Wallet)
  // reads from the same singleton (see use-active-slot.ts). Old code
  // hardcoded [0] which meant every trade used slot 0 regardless of what
  // MultiWalletBalances showed as the user's selection.
  const activeSlot = useActiveSlot();
  const allSlots   = useAllSlotsBalance(); // for showing OMNI balance next to each slot in the inline picker
  const activeRow = u?.allAddresses?.[activeSlot] ?? u?.allAddresses?.[0];
  const omniAddr   = activeRow?.address ?? u?.address ?? "";
  const evmAddr = activeRow?.evmAddress
    ?? u?.multichainAddresses?.find(a => a.chain === "ETH")?.address ?? "";
  const solAddr = activeRow?.solAddress
    ?? u?.multichainAddresses?.find(a => a.chain === "SOL")?.address ?? "";
  const xrpAddr = activeRow?.xrpAddress
    ?? u?.multichainAddresses?.find(a => a.chain === "XRP")?.address ?? "";

  // Fetch balances for all taker chains
  useEffect(() => {
    if (takerChains.length === 0) return;
    let cancelled = false;
    for (const c of takerChains) {
      let fetchPromise: Promise<{ native: string } | null>;
      if (c.isSol) {
        if (!solAddr) { setChainBalances(prev => ({ ...prev, [c.key]: "0" })); continue; }
        fetchPromise = fetchSolanaBalance(solAddr, "devnet");
      } else if (c.isXrp) {
        if (!xrpAddr) { setChainBalances(prev => ({ ...prev, [c.key]: "0" })); continue; }
        fetchPromise = fetchXrpBalance(xrpAddr, "testnet");
      } else if (c.isEurc) {
        if (!evmAddr) { setChainBalances(prev => ({ ...prev, [c.key]: "0" })); continue; }
        fetchPromise = fetchEurcBalance(c.key, evmAddr);
      } else if (c.isUsdc) {
        if (!evmAddr) { setChainBalances(prev => ({ ...prev, [c.key]: "0" })); continue; }
        fetchPromise = fetchUsdcBalance(c.key, evmAddr);
      } else {
        if (!evmAddr) { setChainBalances(prev => ({ ...prev, [c.key]: "0" })); continue; }
        fetchPromise = fetchEvmBalance(c.key, evmAddr);
      }
      fetchPromise.then(b => {
        if (!cancelled) setChainBalances(prev => ({
          ...prev,
          [c.key]: b ? Number(b.native).toFixed(c.isUsdc || c.isEurc ? 2 : 4) : "0",
        }));
      });
    }
    return () => { cancelled = true; };
  }, [evmAddr, solAddr, xrpAddr, quote]);

  // Reset chain selection when quote changes
  useEffect(() => {
    setSelectedChainKey(takerChains[0]?.key ?? "");
  }, [quote]);

  const submit = async () => {
    setMsg(null);
    setErr(null);
    if (!u) { setErr("Unlock the wallet first"); return; }
    const priceUsd   = Number(priceStr);
    const amountOmni = Number(amountStr);
    if (!Number.isFinite(priceUsd)   || priceUsd   <= 0) { setErr("Price must be > 0");  return; }
    if (!Number.isFinite(amountOmni) || amountOmni <= 0) { setErr("Amount must be > 0"); return; }

    // Resolve which slot to trade FROM. Header dropdown sets active slot via
    // use-active-slot. If user unlocked from mnemonic we can derive any
    // slot's key on the fly; otherwise fall back to the unlocked wallet's
    // own key (active slot must match walletIndex in that case).
    const slotKey = activeSlot === u.walletIndex
      ? { privateKey: u.privateKey, publicKey: "", address: u.address }
      : deriveSlotKey(activeSlot);
    if (!slotKey) {
      setErr(`Slot #${activeSlot} requires re-unlocking with the mnemonic to sign — current unlock is for slot #${u.walletIndex} only.`);
      return;
    }
    const traderAddr = slotKey.address;

    const priceMicroUsd = Math.round(priceUsd * MICRO_PER_USD);
    const amountSat     = Math.round(amountOmni * SAT_PER_OMNI);
    const nonce         = nextNonce();

    // For OMNI/<EVM-token> pairs, BUY must lock funds on the EVM
    // contract BEFORE the matching engine accepts the order. We do this
    // automatically so the user sees ONE button "Buy" instead of a
    // two-step flow. For SELL we just attach the seller's EVM address so
    // dex_settler can pay out the quote leg at fill time.
    //
    // Supported cross-chain pairs:
    //   pair_id 0  → OMNI/USDC on Sepolia (ERC-20 approve + placeBuyOrder)
    //   pair_id 6  → OMNI/ETH  on Sepolia (placeBuyOrderNative, msg.value)
    const isOmniUsdc = pairId === 0;
    const isOmniEth  = pairId === 6;
    const isOmniEvm  = isOmniUsdc || isOmniEth;
    let evmOrderId: bigint = 0n;
    let sellerEvm: string | undefined;
    let extraPayload: Record<string, unknown> = {};

    setBusy(true);
    try {
      if (isOmniEvm && side === "buy") {
        // Resolve the slot's EVM private key so we can sign the escrow tx.
        const sk = deriveSlotKey(activeSlot);
        const evmPriv = sk?.evmPrivateKey;
        if (!evmPriv) {
          setErr("Cannot derive EVM private key for this slot — re-unlock with mnemonic.");
          setBusy(false);
          return;
        }
        const omniCommit = keccak256(toUtf8Bytes(traderAddr));
        evmOrderId = BigInt(Date.now()) * 1000n + BigInt(Math.floor(Math.random() * 1000));
        const expiresAt = Math.floor(Date.now() / 1000) + 24 * 3600;

        if (isOmniEth) {
          // Native ETH escrow. quote leg = price * amount in ETH wei.
          const ethSpend = parseEther((priceUsd * amountOmni).toFixed(18));
          setMsg("Locking ETH on Sepolia… (~12s)");
          const txHash = await placeBuyOrderNativeOnDex({
            chainId: 11155111,
            amountWei: ethSpend,
            orderId: evmOrderId,
            omniRecipientHex32: omniCommit as `0x${string}`,
            expiresAt,
            signerPrivKey: evmPriv,
          });
          setMsg(`ETH locked (tx ${txHash.slice(0, 10)}…). Placing BID…`);
        } else {
          // USDC (ERC-20) escrow on Sepolia. quote = price * amount in USDC
          // 6-decimals smallest unit.
          const usdcAddr = USDC_CONTRACT.SEPOLIA as `0x${string}`;
          // amount in USDC-smallest-units (6 dec). Round to avoid float drift.
          const usdcAmount = BigInt(Math.round(priceUsd * amountOmni * MICRO_PER_USD));
          setMsg("Approving USDC allowance on Sepolia…");
          await ensureAllowance({
            chainId: 11155111,
            token: usdcAddr,
            amountWei: usdcAmount,
            signerPrivKey: evmPriv,
          });
          setMsg("Locking USDC on Sepolia… (~12s)");
          const txHash = await placeBuyOrderOnDex({
            chainId: 11155111,
            token: usdcAddr,
            amountWei: usdcAmount,
            orderId: evmOrderId,
            omniRecipientHex32: omniCommit as `0x${string}`,
            expiresAt,
            signerPrivKey: evmPriv,
          });
          setMsg(`USDC locked (tx ${txHash.slice(0, 10)}…). Placing BID…`);
        }
        extraPayload.evmOrderId = evmOrderId.toString();
      } else if (isOmniEvm && side === "sell") {
        // For SELL we just attach the seller's EVM address so settler
        // can deliver the quote leg on fill. No tx required — the OMNI
        // is debited on the chain side at match time.
        const sk = deriveSlotKey(activeSlot);
        sellerEvm = sk?.evmAddress;
        if (!sellerEvm) {
          setErr("Cannot derive EVM address — re-unlock with mnemonic.");
          setBusy(false);
          return;
        }
        extraPayload.sellerEvm = sellerEvm;
      }

      const { signature, publicKey } = signPlaceOrderPayload({
        privateKeyHex: slotKey.privateKey,
        trader: traderAddr,
        side,
        pairId,
        priceMicroUsd,
        amountSat,
        nonce,
      });

      const res = await rpc.exchangePlaceOrder({
        trader: traderAddr,
        side,
        pairId,
        price: priceMicroUsd,
        amount: amountSat,
        nonce,
        signature,
        publicKey,
        mode: traderMode,
        // Pass preferred taker chain so backend can route HTLC
        taker_chain: side === "buy" ? selectedChainKey : undefined,
        ...extraPayload,
      });
      // Include the slot index + truncated OMNI address so the user can
      // tell exactly which derived child key signed this order — matters
      // when they have 19 slots with different balances and want to audit
      // the trade in their wallet history.
      const traderShort = `${midTrunc(traderAddr, 8, 4)}`;
      if (!res) {
        setErr("Order submitted but no response — check the orderbook for your order");
      } else {
        setMsg(
          `${(res.status ?? "submitted").toString().toUpperCase()} — order #${res.orderId ?? "?"}, filled ${
            (res.filled ?? 0) / SAT_PER_OMNI
          } / ${(res.amount ?? amountSat) / SAT_PER_OMNI} ${base} · from slot #${activeSlot} (${traderShort})`,
        );
      }
      setPriceStr("");
      setAmountStr("");
      onPlaced?.();
    } catch (e: any) {
      setErr(e?.message || "Place failed");
    } finally {
      setBusy(false);
    }
  };

  const notional = (() => {
    const p = Number(priceStr);
    const a = Number(amountStr);
    if (!Number.isFinite(p) || !Number.isFinite(a) || p <= 0 || a <= 0) return 0;
    return p * a;
  })();

  const selectedChain = takerChains.find(c => c.key === selectedChainKey);

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-3 sm:p-4">
      <div className="flex items-center justify-between mb-3">
        <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          Place order — {pairLabel}
        </h3>
        <span className={`px-2 py-0.5 rounded text-[10px] font-semibold ${
          traderMode === "real"
            ? "bg-mempool-green/20 text-mempool-green"
            : "bg-yellow-500/20 text-yellow-300"
        }`}>
          {traderMode === "real" ? "💰 Real" : "🎮 Paper"}
        </span>
      </div>

      {/* From-slot picker — the BIP-44 OMNI slot the order will be signed
          from. Mirrors the Header dropdown but in-context so users see
          exactly which address gets debited at fill. Changing here also
          updates the global active slot (same singleton). */}
      {u && (u.allAddresses?.length ?? 0) > 1 && (
        <div className="mb-2 p-2 rounded border border-mempool-border/50 bg-mempool-bg text-[11px]">
          <div className="flex items-center justify-between gap-2 mb-1">
            <span className="text-[9px] uppercase tracking-wider text-mempool-text-dim">From slot</span>
            <select
              value={activeSlot}
              onChange={(e) => setActiveSlot(Number(e.target.value))}
              className="bg-mempool-bg-elev border border-mempool-border rounded px-2 py-0.5 text-[11px] text-mempool-text hover:border-mempool-blue cursor-pointer font-mono"
            >
              {(u.allAddresses ?? []).map((a) => {
                const row = allSlots.slots.find((s) => s.index === a.index);
                const bal = row ? (row.wallet_sat / SAT_PER_OMNI).toFixed(2) : "—";
                return (
                  <option key={a.index} value={a.index}>
                    #{a.index} · {bal} OMNI
                  </option>
                );
              })}
            </select>
          </div>
          <div className="flex items-center gap-1 font-mono text-[10px] text-mempool-text-dim truncate">
            <span className="text-mempool-blue">OMNI</span>
            <span className="truncate" title={omniAddr}>{omniAddr}</span>
          </div>
          {evmAddr && (
            <div className="flex items-center gap-1 font-mono text-[10px] text-mempool-text-dim truncate">
              <span className="text-mempool-purple">EVM</span>
              <span className="truncate" title={evmAddr}>{evmAddr}</span>
            </div>
          )}
        </div>
      )}

      {/* Wallet balance — Free / In orders / Total */}
      <TradePairBalances base={base} quote={quote} exchBalances={exchBalances} />

      {/* Side toggle */}
      <div className="grid grid-cols-2 gap-1 mb-3 bg-mempool-bg rounded p-0.5">
        <button onClick={() => setSide("buy")}
          className={`py-1.5 text-xs font-semibold rounded transition-colors ${
            side === "buy" ? "bg-green-500/30 text-green-200" : "text-mempool-text-dim hover:text-mempool-text"
          }`}>
          BUY {base}
        </button>
        <button onClick={() => setSide("sell")}
          className={`py-1.5 text-xs font-semibold rounded transition-colors ${
            side === "sell" ? "bg-orange-500/30 text-orange-200" : "text-mempool-text-dim hover:text-mempool-text"
          }`}>
          SELL {base}
        </button>
      </div>

      {/* Pay with chain selector — only for BUY */}
      {side === "buy" && takerChains.length > 0 && (
        <div className="mb-3">
          <label className="block text-[9px] uppercase tracking-wider text-mempool-text-dim mb-1.5">
            Pay {quote} from chain
          </label>
          <div className="flex flex-wrap gap-1">
            {takerChains.map(c => {
              const bal = chainBalances[c.key];
              const hasFunds = bal && Number(bal) > 0;
              const isSelected = selectedChainKey === c.key;
              return (
                <button key={c.key}
                  onClick={() => setSelectedChainKey(c.key)}
                  className={`flex flex-col items-center px-2 py-1 rounded text-[9px] border transition-all ${
                    isSelected
                      ? "border-mempool-blue bg-mempool-blue/20 text-mempool-blue"
                      : hasFunds
                        ? "border-green-500/40 bg-green-500/10 text-mempool-text hover:border-green-500/70"
                        : "border-mempool-border/40 text-mempool-text-dim/50 hover:border-mempool-border"
                  }`}>
                  <span className="font-semibold">{c.label}</span>
                  <span className={`font-mono ${hasFunds ? "text-green-400" : "text-mempool-text-dim/40"}`}>
                    {bal === undefined ? "…" : `${bal} ${c.symbol}`}
                  </span>
                </button>
              );
            })}
          </div>
          {selectedChain && (
            <p className="text-[9px] text-mempool-text-dim mt-1">
              Settlement: {quote} moves from <span className="text-mempool-text">{selectedChain.label}</span> via HTLC → {base} moves on OmniBus chain
            </p>
          )}
        </div>
      )}

      {/* Price */}
      <label className="block text-[9px] uppercase tracking-wider text-mempool-text-dim mb-1">
        Price ({quote})
      </label>
      <input type="number" step="any" min="0" value={priceStr}
        onChange={(e) => setPriceStr(e.target.value)}
        placeholder="0.10"
        className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text font-mono text-sm mb-3 focus:outline-none focus:border-mempool-blue" />

      {/* Amount */}
      <label className="block text-[9px] uppercase tracking-wider text-mempool-text-dim mb-1">
        Amount ({base})
      </label>
      <input type="number" step="any" min="0" value={amountStr}
        onChange={(e) => setAmountStr(e.target.value)}
        placeholder="1.0"
        className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text font-mono text-sm mb-3 focus:outline-none focus:border-mempool-blue" />

      {/* Notional */}
      <div className="flex justify-between text-[11px] text-mempool-text-dim mb-3">
        <span>Total {quote}</span>
        <span className="font-mono text-mempool-text">
          {notional > 0
            ? notional.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 })
            : "—"} {quote}
        </span>
      </div>

      {/* Submit */}
      <button onClick={submit} disabled={busy || !u}
        className={`w-full py-2 text-sm font-semibold rounded transition-colors ${
          side === "buy"
            ? "bg-green-500/80 hover:bg-green-500 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
            : "bg-orange-500/80 hover:bg-orange-500 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
        }`}>
        {busy ? "Signing & sending…"
          : !u ? "Unlock wallet first"
          : side === "buy"
            ? `Place BUY — pay via ${selectedChain?.label ?? quote}`
            : `Place SELL — receive ${quote}`}
      </button>

      {msg && (
        <div className="mt-3 p-2 rounded bg-green-500/10 border border-green-500/30 text-[11px] text-green-200">
          {msg}
        </div>
      )}
      {err && (
        <div className="mt-3 p-2 rounded bg-red-500/10 border border-red-500/30 text-[11px] text-red-300">
          {err}
        </div>
      )}
    </div>
  );
}
