/**
 * HtlcTradePanel — Full atomic swap UI for OmniBus DEX
 *
 * Flow SELL OMNI (maker):
 *   1. Maker calls htlc_init on OmniBus chain → OMNI locked, gets hash_lock
 *   2. Taker sees pending HTLC → locks USDC/ETH on EVM via OmnibusHTLC.sol
 *   3. Maker claims EVM funds (reveals preimage)
 *   4. Taker claims OMNI with same preimage
 *
 * Flow BUY OMNI (taker):
 *   1. Sees open OMNI HTLCs listed → picks one
 *   2. Locks USDC/ETH on Sepolia via MetaMask
 *   3. Waits for maker to claim (reveals preimage)
 *   4. Claims OMNI
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { BrowserProvider, JsonRpcSigner, ethers } from "ethers";

import type { Eip1193Provider } from "ethers";

declare global {
  interface Window { ethereum?: Eip1193Provider; }
}
import { rpc } from "../../api/rpc-client";
import { SAT_PER_OMNI, MICRO_PER_USD, midTrunc } from "../../utils/fmt";
import { getUnlocked, subscribeWallet } from "../../api/wallet-keystore";
import {
  HTLC_CONTRACTS, lockEth, claimEth,
} from "../../api/htlc-eth";


// USDC contract on Sepolia
const USDC_SEPOLIA = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";
const USDC_ABI_MIN = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
];
const SEPOLIA_CHAIN_ID = 11155111;
const HTLC_CONTRACT_SEPOLIA = HTLC_CONTRACTS[SEPOLIA_CHAIN_ID];

type Step =
  | "idle"
  | "omni_locking"      // htlc_init on OmniBus
  | "omni_locked"       // OMNI locked, waiting taker
  | "evm_approving"     // approve USDC on Sepolia
  | "evm_locking"       // lockEth tx pending
  | "evm_locked"        // EVM HTLC created, waiting maker claim
  | "omni_claiming"     // htlc_claim (taker claiming OMNI)
  | "evm_claiming"      // maker claiming EVM (auto)
  | "done"
  | "error";

interface HtlcState {
  step: Step;
  omniHtlcId?: string;
  omniTxHash?: string;
  hashLock?: string;       // 64 hex chars, no 0x
  preimage?: string;       // 64 hex chars — revealed after EVM claim
  evmHtlcId?: string;
  evmTxHash?: string;
  omniAmount?: number;     // OMNI, human
  usdcAmount?: number;     // USDC, human
  error?: string;
  log: string[];
}

function ts() { return new Date().toLocaleTimeString(); }

function addLog(s: HtlcState, msg: string): HtlcState {
  return { ...s, log: [...s.log, `[${ts()}] ${msg}`] };
}

// Get MetaMask signer on Sepolia
async function getEvmSigner(): Promise<JsonRpcSigner> {
  const eth = window.ethereum;
  if (!eth) throw new Error("MetaMask not found");
  const provider = new BrowserProvider(eth);
  await provider.send("eth_requestAccounts", []);
  const network = await provider.getNetwork();
  if (Number(network.chainId) !== SEPOLIA_CHAIN_ID) {
    await provider.send("wallet_switchEthereumChain", [
      { chainId: "0x" + SEPOLIA_CHAIN_ID.toString(16) },
    ]);
  }
  return provider.getSigner();
}

export function HtlcTradePanel() {
  const [, tick] = useState(0);
  useEffect(() => subscribeWallet(() => tick(n => n + 1)), []);
  const u = getUnlocked();

  const [omniAmt, setOmniAmt]   = useState("1");
  const [usdcAmt, setUsdcAmt]   = useState("0.20");
  const [timelock, setTimelock] = useState("200"); // blocks
  const [state, setState] = useState<HtlcState>({ step: "idle", log: [] });
  const logRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight;
  }, [state.log]);

  const log = (msg: string) => setState(s => addLog(s, msg));
  const setErr = (msg: string) => setState(s => ({ ...s, step: "error", error: msg, log: [...s.log, `[${ts()}] ❌ ${msg}`] }));

  const evmAddr = u?.allAddresses?.[0]?.evmAddress
    ?? u?.multichainAddresses?.find(a => a.chain === "ETH")?.address ?? "";

  // ── STEP 1: Maker locks OMNI on OmniBus chain ──────────────────────────
  async function step1_lockOmni() {
    if (!u) return setErr("Wallet not unlocked");
    const omni = Number(omniAmt);
    const usdc = Number(usdcAmt);
    if (!omni || !usdc) return setErr("Invalid amounts");

    setState(s => ({ ...addLog(s, "Step 1: Locking OMNI on OmniBus chain…"), step: "omni_locking",
      omniAmount: omni, usdcAmount: usdc }));

    try {
      // Generate a random preimage + hash_lock
      const preimageBytes = crypto.getRandomValues(new Uint8Array(32));
      const preimageHex = Array.from(preimageBytes).map(b => b.toString(16).padStart(2, "0")).join("");

      // sha256 of preimage bytes (OmnibusHTLC uses sha256)
      const hashBytes = await crypto.subtle.digest("SHA-256", preimageBytes);
      const hashHex = Array.from(new Uint8Array(hashBytes)).map(b => b.toString(16).padStart(2, "0")).join("");

      log(`Preimage: ${preimageHex.slice(0, 16)}… (kept secret)`);
      log(`HashLock: ${hashHex.slice(0, 16)}…`);

      const timelockBlocks = Number(timelock);
      const blockRes = await rpc.request_raw("getblockcount", []);
      const currentBlock: number = typeof blockRes === "number" ? blockRes : (blockRes?.count ?? blockRes?.blocks ?? 0);
      const timelockBlock = currentBlock + timelockBlocks;

      log(`Current block: ${currentBlock}, timelock at: ${timelockBlock}`);

      const res = await rpc.request_raw("htlc_init", [{
        receiver: evmAddr.toLowerCase(), // taker's EVM address as receiver placeholder — OmniBus uses ob1q but store note
        amount_sat: Math.round(omni * SAT_PER_OMNI),
        hash_lock: hashHex,
        timelock_block: timelockBlock,
      }]);

      log(`OMNI HTLC created: tx=${res.tx_hash?.slice(0, 12)}… htlc_id=${res.htlc_id?.slice(0, 12)}…`);

      setState(s => ({
        ...addLog(s, "✅ OMNI locked. Waiting for taker to lock USDC on Sepolia."),
        step: "omni_locked",
        omniHtlcId: res.htlc_id,
        omniTxHash: res.tx_hash,
        hashLock: hashHex,
        preimage: preimageHex,
      }));
    } catch (e: any) {
      setErr(`htlc_init failed: ${e?.message ?? e}`);
    }
  }

  // ── STEP 2: Taker locks USDC on Sepolia ────────────────────────────────
  async function step2_lockUsdc() {
    if (!state.hashLock) return setErr("No hash_lock — run step 1 first");
    if (!HTLC_CONTRACT_SEPOLIA || HTLC_CONTRACT_SEPOLIA === "0x0000000000000000000000000000000000000000")
      return setErr("HTLC contract not deployed on Sepolia");

    const usdc = Number(usdcAmt);
    setState(s => ({ ...addLog(s, "Step 2: Approving USDC on Sepolia…"), step: "evm_approving" }));

    try {
      const signer = await getEvmSigner();
      const takerAddr = await signer.getAddress();
      log(`Taker EVM: ${takerAddr}`);

      const usdcContract = new ethers.Contract(USDC_SEPOLIA, USDC_ABI_MIN, signer);
      const usdcRaw = BigInt(Math.round(usdc * MICRO_PER_USD));

      // Check balance
      const bal = await usdcContract.balanceOf(takerAddr);
      log(`USDC balance: ${Number(bal) / MICRO_PER_USD} USDC`);
      if (bal < usdcRaw) return setErr(`Insufficient USDC: have ${Number(bal)/1e6}, need ${usdc}`);

      // Approve HTLC contract to spend USDC
      const allowance = await usdcContract.allowance(takerAddr, HTLC_CONTRACT_SEPOLIA);
      if (allowance < usdcRaw) {
        log("Approving USDC…");
        const approveTx = await usdcContract.approve(HTLC_CONTRACT_SEPOLIA, usdcRaw);
        log(`Approve tx: ${approveTx.hash}`);
        await approveTx.wait();
        log("USDC approved ✅");
      } else {
        log("USDC already approved ✅");
      }

      setState(s => ({ ...addLog(s, "Step 2b: Locking USDC in HTLC on Sepolia…"), step: "evm_locking" }));

      // Get current Sepolia block for timelock
      const provider = signer.provider!;
      const sepoliaBlock = await provider.getBlockNumber();
      const evmTimelock = BigInt(sepoliaBlock + 100); // 100 Sepolia blocks ~20 min

      // Lock USDC — we lock ETH equivalent as collateral (or use ERC20 variant)
      // For now: lock ETH amount equal to USDC value (placeholder until ERC20 HTLC deployed)
      // Real: need ERC20 HTLC. For now we lock a small ETH dust to prove flow.
      // TODO: deploy ERC20 HTLC contract

      // Lock ETH as value proxy (0.0001 ETH per USDC as placeholder)
      const ethValue = BigInt(Math.round(usdc * 1e14)); // tiny ETH
      const hashLock32 = "0x" + state.hashLock;
      const makerEvmAddr = evmAddr; // maker claims this

      log(`Locking ${ethers.formatEther(ethValue)} ETH in HTLC (hash_lock: ${state.hashLock!.slice(0,12)}…)`);

      const { txHash, htlcId } = await lockEth({
        contractAddr: HTLC_CONTRACT_SEPOLIA,
        recipient: makerEvmAddr,
        hashLock: hashLock32,
        timelock: evmTimelock,
        amountWei: ethValue,
        signer,
      });

      log(`EVM HTLC tx: ${txHash.slice(0, 12)}…`);
      log(`EVM HTLC id: ${htlcId.slice(0, 12)}…`);

      setState(s => ({
        ...addLog(s, "✅ EVM HTLC locked. Maker can now claim by revealing preimage."),
        step: "evm_locked",
        evmHtlcId: htlcId,
        evmTxHash: txHash,
      }));
    } catch (e: any) {
      setErr(`EVM lock failed: ${e?.message ?? e}`);
    }
  }

  // ── STEP 3: Maker claims EVM funds (reveals preimage) ──────────────────
  async function step3_claimEvm() {
    if (!state.evmHtlcId || !state.preimage) return setErr("No EVM HTLC or preimage");

    setState(s => ({ ...addLog(s, "Step 3: Maker claiming EVM funds (reveals preimage)…"), step: "evm_claiming" }));

    try {
      const signer = await getEvmSigner();
      const txHash = await claimEth({
        contractAddr: HTLC_CONTRACT_SEPOLIA,
        htlcId: state.evmHtlcId!,
        preimage: "0x" + state.preimage,
        signer,
      });

      log(`EVM claim tx: ${txHash.slice(0, 12)}… ✅`);
      log("Preimage revealed on-chain. Taker can now claim OMNI.");

      setState(s => ({ ...addLog(s, "✅ EVM claimed. Now claiming OMNI for taker…"), step: "omni_claiming" }));

      // Auto-claim OMNI (taker side — in real flow taker does this)
      if (state.omniHtlcId) {
        await step4_claimOmni();
      }
    } catch (e: any) {
      setErr(`EVM claim failed: ${e?.message ?? e}`);
    }
  }

  // ── STEP 4: Taker claims OMNI with revealed preimage ───────────────────
  async function step4_claimOmni() {
    if (!state.omniHtlcId || !state.preimage) return setErr("No OMNI HTLC or preimage");

    try {
      const res = await rpc.request_raw("htlc_claim", [{
        htlc_id: state.omniHtlcId,
        preimage: state.preimage,
      }]);

      log(`OMNI claim tx: ${res.tx_hash?.slice(0, 12)}… ✅`);
      setState(s => ({
        ...addLog(s, "🎉 SWAP COMPLETE — OMNI claimed by taker, EVM funds claimed by maker!"),
        step: "done",
      }));
    } catch (e: any) {
      setErr(`OMNI claim failed: ${e?.message ?? e}`);
    }
  }

  // ── List pending HTLCs ──────────────────────────────────────────────────
  const [htlcs, setHtlcs] = useState<any[]>([]);
  const [loadingHtlcs, setLoadingHtlcs] = useState(false);
  const [htlcErr, setHtlcErr] = useState<string | null>(null);

  async function loadHtlcs() {
    if (!u) return;
    setLoadingHtlcs(true);
    setHtlcErr(null);
    try {
      const res = await rpc.request_raw("htlc_listByAddress", [{ address: u.address }]) as unknown[];
      setHtlcs(Array.isArray(res) ? res : []);
    } catch (e: any) {
      setHtlcs([]);
      setHtlcErr(e?.message ?? String(e));
    }
    setLoadingHtlcs(false);
  }

  useEffect(() => { loadHtlcs(); }, [u?.address]);

  const stepLabel: Record<Step, string> = {
    idle: "Ready",
    omni_locking: "Locking OMNI…",
    omni_locked: "OMNI locked ✅ — waiting for EVM lock",
    evm_approving: "Approving USDC…",
    evm_locking: "Locking on Sepolia…",
    evm_locked: "EVM locked ✅ — maker to claim",
    evm_claiming: "Maker claiming EVM…",
    omni_claiming: "Taker claiming OMNI…",
    done: "✅ Swap complete!",
    error: "❌ Error",
  };

  const stepColor: Record<Step, string> = {
    idle: "text-mempool-text-dim",
    omni_locking: "text-yellow-400 animate-pulse",
    omni_locked: "text-blue-400",
    evm_approving: "text-yellow-400 animate-pulse",
    evm_locking: "text-yellow-400 animate-pulse",
    evm_locked: "text-blue-400",
    evm_claiming: "text-yellow-400 animate-pulse",
    omni_claiming: "text-yellow-400 animate-pulse",
    done: "text-green-400",
    error: "text-red-400",
  };

  const busy = ["omni_locking","evm_approving","evm_locking","evm_claiming","omni_claiming"].includes(state.step);

  if (!u) {
    return (
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
        <p className="text-xs text-mempool-text-dim">Unlock wallet to use HTLC swap.</p>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-3 sm:p-4">
        <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider mb-1">
          Atomic Swap — HTLC
        </h3>
        <p className="text-[10px] text-mempool-text-dim mb-3">
          OMNI (OmniBus chain) ↔ ETH/USDC (Sepolia). Funds move on-chain atomically via hash time-locked contracts.
          Contract: <a href={`https://sepolia.etherscan.io/address/${HTLC_CONTRACT_SEPOLIA}`}
            target="_blank" rel="noopener noreferrer"
            className="text-mempool-blue hover:underline font-mono text-[9px]">
            {HTLC_CONTRACT_SEPOLIA?.slice(0, 12)}…
          </a>
        </p>

        {/* Status bar */}
        <div className={`text-[11px] font-semibold mb-4 ${stepColor[state.step]}`}>
          Status: {stepLabel[state.step]}
          {state.error && <span className="ml-2 font-normal text-red-300">{state.error}</span>}
        </div>

        {/* Swap parameters */}
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 mb-4">
          <div>
            <label className="block text-[9px] uppercase tracking-wider text-mempool-text-dim mb-1">OMNI to lock</label>
            <input type="number" step="any" min="0" value={omniAmt} onChange={e => setOmniAmt(e.target.value)}
              disabled={busy || state.step !== "idle"}
              className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-sm font-mono text-mempool-text focus:outline-none focus:border-mempool-blue disabled:opacity-50" />
          </div>
          <div>
            <label className="block text-[9px] uppercase tracking-wider text-mempool-text-dim mb-1">USDC to receive</label>
            <input type="number" step="any" min="0" value={usdcAmt} onChange={e => setUsdcAmt(e.target.value)}
              disabled={busy || state.step !== "idle"}
              className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-sm font-mono text-mempool-text focus:outline-none focus:border-mempool-blue disabled:opacity-50" />
          </div>
          <div>
            <label className="block text-[9px] uppercase tracking-wider text-mempool-text-dim mb-1">Timelock (blocks)</label>
            <input type="number" min="1" value={timelock} onChange={e => setTimelock(e.target.value)}
              disabled={busy || state.step !== "idle"}
              className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-sm font-mono text-mempool-text focus:outline-none focus:border-mempool-blue disabled:opacity-50" />
          </div>
        </div>

        {/* Step buttons */}
        <div className="flex flex-wrap gap-2">
          {/* Step 1 */}
          <button onClick={step1_lockOmni}
            disabled={busy || state.step !== "idle"}
            className="px-3 py-1.5 text-xs rounded bg-mempool-blue/80 hover:bg-mempool-blue text-white font-semibold disabled:opacity-40 disabled:cursor-not-allowed">
            1. Lock OMNI (maker)
          </button>

          {/* Step 2 */}
          <button onClick={step2_lockUsdc}
            disabled={busy || state.step !== "omni_locked"}
            className="px-3 py-1.5 text-xs rounded bg-purple-500/80 hover:bg-purple-500 text-white font-semibold disabled:opacity-40 disabled:cursor-not-allowed">
            2. Lock ETH on Sepolia (taker)
          </button>

          {/* Step 3 */}
          <button onClick={step3_claimEvm}
            disabled={busy || state.step !== "evm_locked"}
            className="px-3 py-1.5 text-xs rounded bg-green-600/80 hover:bg-green-600 text-white font-semibold disabled:opacity-40 disabled:cursor-not-allowed">
            3. Claim EVM + OMNI
          </button>

          {/* Reset */}
          {(state.step === "done" || state.step === "error") && (
            <button onClick={() => setState({ step: "idle", log: [] })}
              className="px-3 py-1.5 text-xs rounded bg-mempool-bg border border-mempool-border text-mempool-text-dim hover:text-mempool-text">
              Reset
            </button>
          )}
        </div>

        {/* HTLC IDs */}
        {(state.omniHtlcId || state.evmHtlcId) && (
          <div className="mt-3 p-2 rounded bg-mempool-bg text-[9px] font-mono space-y-0.5">
            {state.omniHtlcId && <div><span className="text-mempool-text-dim">OMNI HTLC: </span><span className="text-mempool-text">{state.omniHtlcId}</span></div>}
            {state.evmHtlcId  && <div><span className="text-mempool-text-dim">EVM  HTLC: </span><span className="text-mempool-text">{state.evmHtlcId}</span></div>}
            {state.hashLock   && <div><span className="text-mempool-text-dim">Hash lock: </span><span className="text-yellow-300">{state.hashLock}</span></div>}
          </div>
        )}
      </div>

      {/* Activity log */}
      {state.log.length > 0 && (
        <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-3">
          <div className="text-[9px] uppercase tracking-wider text-mempool-text-dim mb-2">Activity Log</div>
          <div ref={logRef} className="space-y-0.5 max-h-48 overflow-y-auto">
            {state.log.map((l, i) => (
              <div key={i} className="text-[10px] font-mono text-mempool-text-dim">{l}</div>
            ))}
          </div>
        </div>
      )}

      {/* Pending HTLCs for this wallet */}
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-3 sm:p-4">
        <div className="flex items-center justify-between mb-3">
          <h4 className="text-xs font-semibold text-mempool-text uppercase tracking-wider">My HTLCs</h4>
          <div className="flex items-center gap-2">
            {htlcs.length > 0 && (
              <button
                onClick={() => {
                  const rows = [
                    ["htlc_id","amount_omni","state","timelock_block","sender","receiver"].join(","),
                    ...htlcs.map((h: any) => [
                      `"${h.htlc_id ?? ""}"`,
                      ((h.amount_sat ?? 0) / SAT_PER_OMNI).toFixed(8),
                      h.state ?? "",
                      h.timelock_block ?? "",
                      `"${h.sender ?? ""}"`,
                      `"${h.receiver ?? ""}"`,
                    ].join(",")),
                  ].join("\n");
                  const blob = new Blob([rows], { type: "text/csv" });
                  const url = URL.createObjectURL(blob);
                  const a = document.createElement("a");
                  a.href = url; a.download = "omnibus-htlcs.csv";
                  a.click(); URL.revokeObjectURL(url);
                }}
                className="px-2 py-0.5 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue"
              >
                ⬇ CSV
              </button>
            )}
            <button onClick={loadHtlcs} disabled={loadingHtlcs}
              className="text-[10px] text-mempool-blue hover:underline disabled:opacity-50">
              {loadingHtlcs ? "Loading…" : "Refresh"}
            </button>
          </div>
        </div>
        {htlcErr && (
          <p className="text-[10px] text-red-400 font-mono">{htlcErr}</p>
        )}
        {!htlcErr && htlcs.length === 0 ? (
          <p className="text-[10px] text-mempool-text-dim">No HTLCs found for this address.</p>
        ) : (
          <div className="space-y-2">
            {htlcs.map((h) => (
              <div key={h.htlc_id} className="rounded bg-mempool-bg p-2 text-[10px] font-mono space-y-0.5">
                <div className="flex justify-between">
                  <span className="text-mempool-text-dim">ID</span>
                  <span className="text-mempool-text">{midTrunc(h.htlc_id, 16, 6)}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-mempool-text-dim">Amount</span>
                  <span className="text-green-400">{(h.amount_sat / SAT_PER_OMNI).toFixed(4)} OMNI</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-mempool-text-dim">State</span>
                  <span className={h.state === "active" ? "text-yellow-400" : h.state === "claimed" ? "text-green-400" : "text-mempool-text-dim"}>
                    {h.state}
                  </span>
                </div>
                <div className="flex justify-between">
                  <span className="text-mempool-text-dim">Timelock block</span>
                  <span className="text-mempool-text">{h.timelock_block}</span>
                </div>
                {h.state === "active" && h.recipient === u.address && state.preimage && (
                  <button onClick={step4_claimOmni}
                    className="mt-1 w-full py-1 bg-green-600/60 hover:bg-green-600 text-white text-[10px] rounded">
                    Claim this OMNI
                  </button>
                )}
                {h.state === "active" && h.sender === u.address && (
                  <button onClick={async () => {
                    log(`Refunding HTLC ${h.htlc_id?.slice(0,8)}…`);
                    try {
                      const res = await rpc.request_raw("htlc_refund", [{ htlc_id: h.htlc_id }]);
                      log(`Refund tx: ${res.tx_hash?.slice(0,12)}… ✅`);
                      loadHtlcs();
                    } catch(e: any) { log(`Refund failed: ${e.message}`); }
                  }}
                  className="mt-1 w-full py-1 bg-red-600/40 hover:bg-red-600/70 text-red-200 text-[10px] rounded">
                    Refund (if expired)
                  </button>
                )}
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

// ── HTLC Lookup panel (htlc_get) ──────────────────────────────────────────

interface HtlcEntry {
  htlc_id: string;
  sender: string;
  receiver: string;
  amount_sat: number;
  hash_lock: string;
  timelock_block: number;
  state: string;
  preimage?: string;
  tx_hash?: string;
  claim_tx_hash?: string;
}

export function HtlcLookupPanel() {
  const [htlcId, setHtlcId] = useState("");
  const [entry, setEntry] = useState<HtlcEntry | null>(null);
  const [err, setErr] = useState("");
  const [loading, setLoading] = useState(false);

  const lookup = useCallback(async () => {
    const id = htlcId.trim();
    if (!id) { setErr("Enter HTLC ID"); return; }
    setLoading(true); setErr(""); setEntry(null);
    try {
      const r = await rpc.request_raw("htlc_get", [{ htlc_id: id }]) as HtlcEntry;
      if (r && typeof r === "object" && "htlc_id" in r) setEntry(r);
      else setErr("HTLC not found");
    } catch (e) { setErr(String(e)); }
    finally { setLoading(false); }
  }, [htlcId]);

  const stateColor = (s: string) => {
    if (s === "active") return "text-green-400";
    if (s === "claimed") return "text-mempool-blue";
    if (s === "refunded") return "text-yellow-400";
    if (s === "expired") return "text-red-400";
    return "text-mempool-text-dim";
  };

  return (
    <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev p-4 space-y-3">
      <h3 className="text-xs font-semibold text-mempool-text-dim uppercase tracking-wider">
        HTLC Lookup (htlc_get)
      </h3>
      <div className="flex gap-2">
        <input
          value={htlcId}
          onChange={(e) => setHtlcId(e.target.value)}
          placeholder="64-hex HTLC ID"
          className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-1.5 text-xs font-mono text-mempool-text"
        />
        <button
          onClick={lookup}
          disabled={loading || !htlcId}
          className="px-4 py-1.5 text-xs font-medium bg-mempool-blue/20 hover:bg-mempool-blue/40 text-mempool-blue border border-mempool-blue/30 rounded disabled:opacity-50"
        >
          {loading ? "…" : "Lookup"}
        </button>
      </div>
      {err && <p className="text-xs text-red-400">{err}</p>}
      {entry && (
        <div className="rounded-lg border border-mempool-border bg-mempool-bg/50 p-3 space-y-1.5 text-xs">
          <div className="flex items-center gap-2 mb-2">
            <span className="font-semibold text-mempool-text">HTLC</span>
            <span className="font-mono text-mempool-text-dim">{entry.htlc_id.slice(0, 16)}…</span>
            <span className={`ml-auto font-semibold ${stateColor(entry.state)}`}>{entry.state}</span>
          </div>
          {[
            ["Sender", entry.sender],
            ["Receiver", entry.receiver],
            ["Amount", `${(entry.amount_sat / SAT_PER_OMNI).toFixed(9)} OMNI`],
            ["Hash lock", entry.hash_lock.slice(0, 32) + "…"],
            ["Timelock block", String(entry.timelock_block)],
            ...(entry.tx_hash ? [["Init TX", entry.tx_hash.slice(0, 16) + "…"]] : []),
            ...(entry.claim_tx_hash ? [["Claim TX", entry.claim_tx_hash.slice(0, 16) + "…"]] : []),
            ...(entry.preimage ? [["Preimage", entry.preimage.slice(0, 16) + "…"]] : []),
          ].map(([k, v]) => (
            <div key={k} className="flex justify-between gap-2">
              <span className="text-mempool-text-dim">{k}</span>
              <span className="font-mono text-mempool-text break-all text-right">{v}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

