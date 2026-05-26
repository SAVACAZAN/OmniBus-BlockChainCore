import { useState, useEffect, useMemo } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import { rpc } from "../../api/rpc-client";
import { useWallet } from "../../api/use-wallet";
import { useGlobalBalance, formatOmni } from "../../api/use-global-balance";
import { useAllSlotsBalance } from "../../api/use-all-slots-balance";
import { useActiveSlot, setActiveSlot } from "../../api/use-active-slot";
import { lockWallet, type PqOmniSlot, PQ_OMNI_SCHEMES, buildPqAttestPayload, nextNonce } from "../../api/wallet-keystore";
import {
  useNamesOwnedBy,
  useNameForAddress,
  getPrimaryName,
  setPrimaryName,
  MAX_NAMES_PER_WALLET,
} from "../../api/use-names";
import { AddressLabel } from "../common/AddressLabel";
import { TxHashLink } from "../common/TxHashLink";
import { NameManagePanel } from "../names/NameManagePanel";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { FeeEstimate, WsNewBlockEvent, WsNewTxEvent } from "../../types";
import { SAT_PER_OMNI, midTrunc } from "../../utils/fmt";


// Each PQ domain corresponds to a reputation cup (vezi
// memory/project_omnibus_reputation_economy.md). Emoji + tier label apar in UI
// langa cripto-algoritm asa user-ul vede LIMPEDE ce reprezinta fiecare adresa.
//   ob1q   = OMNI / primary  (no cup, base wallet)
//   ob_k1_ = LOVE   ❤️       (uptime / continuitate)
//   ob_f5_ = FOOD   🥖       (work util — mining + oracle + agents)
//   ob_d5_ = RENT   🏠       (capital angajat — stake + LP + hold)
//   ob_s3_ = VACATION 🏖️    (longevitate — zile pe retea)
const PQ_DOMAINS = [
  { prefix: "ob1q", algo: "ML-DSA-87 + KEM", bits: 256, color: "text-mempool-blue",   emoji: "🔑", tier: "OMNI" },
  { prefix: "ob_k1_", algo: "ML-DSA-87",     bits: 256, color: "text-mempool-purple", emoji: "❤️",  tier: "LOVE" },
  { prefix: "ob_f5_", algo: "Falcon-512",    bits: 192, color: "text-mempool-green",  emoji: "🥖", tier: "FOOD" },
  { prefix: "ob_d5_", algo: "Dilithium-5",   bits: 256, color: "text-mempool-orange", emoji: "🏠", tier: "RENT" },
  { prefix: "ob_s3_", algo: "SLH-DSA-256s",  bits: 256, color: "text-mempool-text",   emoji: "🏖️", tier: "VACATION" },
];

// Wallet state used to live here as a local useState. Now everything comes
// from the global wallet-keystore singleton via useWallet() — connecting from
// the Header button instantly lights up this page (and every other tab).
// Side benefit: no more mnemonic stored as plain string in component state.

// Map raw chain TX into a labelled type so the history list shows
// "NS Claim", "Mining Reward", "Exchange Deposit" instead of generic
// in/out arrows. Detection rules — pure data, no chain change needed:
//   * op_return = "ns_claim:..."  → NS Claim
//   * op_return = "deposit:..."   → Exchange Deposit (matching engine)
//   * op_return = "withdraw:..."  → Exchange Withdraw
//   * op_return = "open_order:..."  → Order placed
//   * op_return = "close_order:..." → Order cancelled
//   * from = "0000…coinbase"      → Mining Reward
//   * direction === "received"    → Received
//   * else                         → Sent
function classifyTx(tx: any, myAddress: string): {
  label: string;
  badgeClass: string;
  isCredit: boolean;
} {
  // Backend (rpc_server.zig handleGetAddressHistory + listtransactions) sets
  // tx.kind based on op_return prefix detection. Prefer that if present;
  // fall back to op_return string for older RPC responses.
  const kind = (tx.kind || "").toLowerCase();
  const memo = (tx.op_return || "").toLowerCase();
  const isFromMe = tx.from && tx.from === myAddress;

  // Match either kind (preferred) or memo prefix
  const isStake   = kind === "stake"      || memo.startsWith("stake:")    || memo.startsWith("delegate:");
  const isUnstake = kind === "unstake"    || memo.startsWith("unstake:")  || memo.startsWith("undelegate:");
  const isOpenOrder  = kind === "place_order"  || memo.startsWith("open_order:") || memo.startsWith("place_order:");
  const isCancelOrder= kind === "cancel_order" || memo.startsWith("close_order:")|| memo.startsWith("cancel_order:");
  const isDeposit  = kind === "deposit"  || memo.startsWith("deposit:");
  const isWithdraw = kind === "withdraw" || memo.startsWith("withdraw:");
  const isNsClaim  = kind === "ns_claim" || memo.startsWith("ns_claim:");
  const isAgentReg = kind === "agent_register" || memo.startsWith("agent:register");
  const isNotarize = kind === "notarize"  || memo.startsWith("notarize:");

  if (isNsClaim)      return { label: "NS Claim",      badgeClass: "bg-purple-500/20 text-purple-300", isCredit: false };
  if (isDeposit)      return { label: "DEX Deposit",   badgeClass: "bg-cyan-500/20 text-cyan-300",     isCredit: !isFromMe };
  if (isWithdraw)     return { label: "DEX Withdraw",  badgeClass: "bg-cyan-500/20 text-cyan-300",     isCredit: !isFromMe };
  if (isOpenOrder)    return { label: "Open Order",    badgeClass: "bg-blue-500/20 text-blue-300",     isCredit: false };
  if (isCancelOrder)  return { label: "Cancel Order",  badgeClass: "bg-blue-500/20 text-blue-300",     isCredit: true };
  if (isStake)        return { label: "Stake",         badgeClass: "bg-amber-500/20 text-amber-300",   isCredit: false };
  if (isUnstake)      return { label: "Unstake",       badgeClass: "bg-amber-500/20 text-amber-300",   isCredit: true };
  if (isAgentReg)     return { label: "Agent Register",badgeClass: "bg-indigo-500/20 text-indigo-300", isCredit: false };
  if (isNotarize)     return { label: "Notarize",      badgeClass: "bg-pink-500/20 text-pink-300",     isCredit: false };

  // Coinbase: from address is all-zeros (or special "coinbase" marker).
  if (!tx.from || tx.from === "" || /^0+$/.test(tx.from) || tx.from === "coinbase") {
    return { label: "Mining Reward", badgeClass: "bg-mempool-green/20 text-mempool-green", isCredit: true };
  }
  if (tx.direction === "received" || !isFromMe) {
    return { label: "Received", badgeClass: "bg-mempool-green/20 text-mempool-green", isCredit: true };
  }
  return { label: "Sent", badgeClass: "bg-mempool-orange/20 text-mempool-orange", isCredit: false };
}

export function WalletPage() {
  const { state: chainState } = useBlockchain();
  const unlocked = useWallet(); // null when locked, { address, privateKey, publicKey, walletIndex } when unlocked
  // Atomic snapshot of wallet/staked/in_orders/available shared with Exchange
  // and Stake pages — single source of truth so the four numbers don't drift.
  const globalBal = useGlobalBalance();
  // Aggregate snapshot across all 19 BIP-44 slots so the user sees the
  // wallet's full picture (mainnet often spreads balance across slots
  // when the user has been mining + staking + parking).
  const allSlots = useAllSlotsBalance();
  const activeSlot = useActiveSlot();

  // === SLOT-AWARE ANCHORS =================================================
  // The entire WalletPage used to render against `unlocked.address` — the
  // BIP-44 slot the user originally unlocked with (default slot 0). When the
  // user changed slot via the Header dropdown, nothing on this page updated.
  //
  // `activeAddress` is the OMNI address derived for the currently selected
  // BIP-44 slot. Use it as the canonical "this is the wallet view" address
  // for: balance breakdowns, TX history, nonce, reputation, send-from,
  // primary name lookup, on-chain PQ identity, address QR / detail card.
  //
  // `unlocked.address` should only survive in two places:
  //   1. The session-anchor for unlock state (wallet keystore lifecycle).
  //   2. UI strings that say "you connected as ob1q..." (rare; usually we
  //      want activeAddress there too).
  const activeRow = unlocked?.allAddresses?.find(a => a.index === activeSlot)
    ?? unlocked?.allAddresses?.[0];
  const activeAddress = activeRow?.address ?? unlocked?.address ?? "";
  const myName = useNameForAddress(activeAddress); // primary NS name for the SELECTED slot
  const [balance, setBalance] = useState({ sat: 0, omni: "0.0000" });
  const [transactions, setTransactions] = useState<any[]>([]);
  const [sendTo, setSendTo] = useState("");
  const [sendAmount, setSendAmount] = useState("");
  const [sendFee, setSendFee] = useState("");
  // Source address selector — defaults to OMNI primary, can switch to any of the
  // 4 transferable PQ-OMNI addresses (obk1_/obf5_/obd5_/obs3_).
  const [sendFromScheme, setSendFromScheme] = useState<string>("omni_ecdsa");
  const [sending, setSending] = useState(false);
  const [sendResult, setSendResult] = useState<{ ok: boolean; msg: string; txid?: string } | null>(null);
  const [copied, setCopied] = useState<string | null>(null);
  const [feeEstimate, setFeeEstimate] = useState<FeeEstimate | null>(null);
  const [walletNonce, setWalletNonce] = useState<number | null>(null);
  const [txFilter, setTxFilter] = useState<string>("All");
  const txCountByType = useMemo(() => {
    const counts: Record<string, number> = { All: transactions.length };
    for (const tx of transactions) {
      const label = classifyTx(tx, activeAddress).label;
      counts[label] = (counts[label] ?? 0) + 1;
    }
    return counts;
  }, [transactions, activeAddress]);
  const filteredTxs = useMemo(() =>
    txFilter === "All" ? transactions : transactions.filter((tx) => classifyTx(tx, activeAddress).label === txFilter),
  [transactions, txFilter, activeAddress]);

  const [reputation, setReputation] = useState<{
    cups: { love: string; food: string; rent: string; vacation: string };
    total: number;
    tier: string;
    satoshi_badge: boolean;
    is_zen?: boolean;
    total_blocks_mined: number;
    uptime_blocks: number;
    first_active_block: number;
  } | null>(null);
  const [utxos, setUtxos] = useState<any[]>([]);
  // Bumped by WS new_block/new_tx events to trigger an out-of-band refresh.
  const [refreshCounter, setRefreshCounter] = useState(0);

  // Subscribe to WS events that signal new chain activity so the balance +
  // transaction list update in ~1 s instead of waiting up to 5 s for the poll.
  useEffect(() => {
    if (!unlocked || !activeAddress) return;
    const bump = () => setRefreshCounter((n) => n + 1);
    const unsubBlock = wsSubscribe<WsNewBlockEvent>("new_block", bump);
    // new_tx: only refresh if this wallet is directly involved.
    const unsubTx = wsSubscribe<WsNewTxEvent>("new_tx", (ev) => {
      if (ev.from === activeAddress) bump();
    });
    return () => { unsubBlock(); unsubTx(); };
  }, [unlocked, activeAddress]);

  // Auto-refresh balance + fetch fee estimate + nonce when wallet is unlocked.
  useEffect(() => {
    if (!unlocked) {
      // Reset derived state when the user disconnects.
      setBalance({ sat: 0, omni: "0.0000" });
      setTransactions([]);
      setFeeEstimate(null);
      setWalletNonce(null);
      setSendResult(null);
      return;
    }
    const refresh = async () => {
      try {
        // Use getaddressbalance for the SELECTED slot, not getBalance() which
        // hits the unlocked-session primary address. Old code rendered slot
        // 0 balance regardless of Header slot selector.
        const balRes = await rpc.getAddressBalance(activeAddress);
        const sat = balRes?.balance ?? 0;
        const omni = (sat / SAT_PER_OMNI).toFixed(4);
        setBalance({ sat, omni });
      } catch {}

      try {
        const histResult = await rpc.getAddressHistory(activeAddress);
        setTransactions(histResult?.transactions || []);
      } catch {
        try {
          const fallback = await rpc.listTransactions(50);
          setTransactions(fallback?.transactions || []);
        } catch {
          try {
            const last = await rpc.request_raw("gettransactions");
            setTransactions(last?.transactions || []);
          } catch {}
        }
      }

      try {
        const fee = await rpc.estimateFee();
        if (fee) setFeeEstimate(fee);
      } catch {}

      try {
        const nonceResult = await rpc.getNonce(activeAddress);
        setWalletNonce(nonceResult);
      } catch {}

      // Reputation cups for the SELECTED slot.
      try {
        const rep: any = await rpc.request_raw("getreputation", [activeAddress]);
        if (rep) setReputation(rep);
      } catch {}

      // UTXO list — use listunspent on the SELECTED slot. The old getBalance()
      // path returned utxos[] for the unlock-session address only, leaving
      // the UTXO column empty whenever the user switched slots.
      try {
        const ulist: any = await rpc.request_raw("listunspent", [activeAddress]);
        if (Array.isArray(ulist?.utxos)) setUtxos(ulist.utxos);
        else if (Array.isArray(ulist)) setUtxos(ulist);
      } catch {}
    };
    void refresh();
    // Keep a slow fallback poll (30 s). Real-time updates come from the WS
    // subscription above (new_block/new_tx → refreshCounter bump).
    const id = setInterval(() => { void refresh(); }, 30_000);
    return () => clearInterval(id);
  }, [unlocked, activeAddress, refreshCounter]);

  const handleLogout = () => {
    // Disconnect the global session — every subscriber (this page, Exchange,
    // Names, Faucet, Reputation, Header pill) re-renders to its locked state.
    lockWallet();
  };

  const handleResetAll = () => {
    const ok = window.confirm(
      "⚠ Reset complet?\n\n" +
      "Aceasta va șterge TOATE datele wallet din browser:\n" +
      "  • Mnemonic encriptat (vault)\n" +
      "  • PIN-ul salvat\n" +
      "  • Sesiunea curentă\n" +
      "  • Cache local (chain selector, etc.)\n\n" +
      "Vei putea reconecta cu mnemonic-ul tău (asigură-te că-l ai notat).\n" +
      "OMNI tăi rămân pe blockchain — doar accesul local se resetează.\n\n" +
      "Continui?"
    );
    if (!ok) return;
    try {
      lockWallet();
    } catch {}
    try { localStorage.clear(); } catch {}
    try { sessionStorage.clear(); } catch {}
    // Hard reload bypassing cache
    window.location.replace(window.location.pathname + "?reset=" + Date.now());
  };

  const handleSend = async () => {
    if (!sendTo || !sendAmount) return;
    setSending(true);
    setSendResult(null);
    try {
      const amountSat = Math.floor(parseFloat(sendAmount) * SAT_PER_OMNI);
      if (amountSat <= 0) throw new Error("Amount must be > 0");

      // Phase 2 — resolve <name>.<tld> via the chain's send-routing helper.
      // `ns_resolveForSend` returns the address the chain wants funds delivered
      // to (honouring `preferred_slot` when the matching PQ slot is populated)
      // plus the kind tag, so we can show the user *why* the address changed.
      const looksLikeName = /^[a-z][a-z0-9_]{2,24}\.(omnibus|arbitraje|quantum|bank|gov|mil|fin|edu|org|dev)$/i.test(sendTo.trim());
      let resolvedTo = sendTo.trim();
      let routeKind = "ecdsa";
      let routeSlot = 0;
      const fullLabelInput = sendTo.trim().toLowerCase();
      if (looksLikeName) {
        const [n, t] = fullLabelInput.split(".");
        const r: any = await rpc.request_raw("ns_resolveforsend", [n, t]).catch(() => null);
        if (!r || !r.found) {
          throw new Error(`Name "${sendTo}" not registered on chain`);
        }
        resolvedTo = r.route_address || r.primary_address;
        routeKind  = r.route_address_kind || "ecdsa";
        routeSlot  = r.route_slot ?? 0;

        // If the chain re-routed to a PQ address, surface this to the user
        // before broadcasting. `preferred_slot` is now functional, not
        // cosmetic — but the user should still see *what* they are signing.
        if (routeSlot > 0 && resolvedTo !== r.primary_address) {
          const kindLabel = ({
            ml_dsa:    "PQ-1 (ML-DSA-87)",
            falcon:    "PQ-2 (Falcon-512)",
            dilithium: "PQ-3 (Dilithium-5)",
            slh_dsa:   "PQ-4 (SLH-DSA-256s)",
          } as Record<string, string>)[routeKind] ?? `PQ-${routeSlot}`;
          const ok = window.confirm(
            `${fullLabelInput} prefers ${kindLabel}.\n\n` +
            `Sending to ${resolvedTo}\ninstead of ${r.primary_address}.\n\n` +
            `Continue?`
          );
          if (!ok) {
            setSending(false);
            return;
          }
        }
      }
      // Mutate sendTo for the rest of the flow — every downstream call uses it.
      const sendToOriginal = sendTo;
      void sendToOriginal;
      // Replace closure binding by shadowing — assign back into the outer var
      // through setSendTo so the UI also reflects the resolved address.
      if (resolvedTo !== sendTo) {
        // Note: setSendTo is async; the rest of this function uses `resolvedTo`.
      }

      // ── PQ-OMNI path ────────────────────────────────────────────────────
      // If user chose a transferable PQ-OMNI source, sign with the matching
      // post-quantum scheme and route via pq_send RPC.
      if (sendFromScheme !== "omni_ecdsa") {
        const slot = unlocked?.pqOmni?.find(s => s.scheme === sendFromScheme);
        if (!slot) throw new Error("PQ-OMNI slot not derived — re-unlock from mnemonic");
        if (!slot.secretKey?.length) throw new Error("PQ secret key missing — re-unlock from mnemonic");

        const nonce: number = await rpc.getNonce(slot.address).catch(() => 0);
        const txId = Math.floor(Math.random() * 0x7fffffff);
        const timestamp = Math.floor(Date.now() / 1000);
        const fee = sendFee ? parseInt(sendFee, 10) : (feeEstimate?.medianFee ?? 1);

        const { hexToBytes: hToB, bytesToHex: bToH, buildTxHash, pqSign } =
          await import("../../api/pq-sign");
        const pubKeyBytes: Uint8Array = hToB(slot.publicKey);
        // Scheme code: enum order from core/transaction.zig:
        //   pq_omni_ml_dsa=5, pq_omni_falcon=6, pq_omni_dilithium=7, pq_omni_slh_dsa=8
        // PQ_OMNI_SCHEMES order in keystore matches: [ml_dsa_87, falcon_512, dilithium_5, slh_dsa_256s] → +5.
        // CRITICAL: param names must match buildTxHash signature exactly:
        //   - `schemeCode` (NOT `scheme`)
        //   - `opReturn`   (NOT `op_return`)
        //   - `publicKeyBytes` MUST be passed — backend includes it in hash recipe.
        const msgHash = buildTxHash({
          id: txId,
          from: slot.address,
          to: resolvedTo,
          amount: amountSat,
          fee,
          timestamp,
          nonce,
          schemeCode: Object.keys(PQ_OMNI_SCHEMES).indexOf(slot.scheme) + 5,
          publicKeyBytes: pubKeyBytes,
          opReturn: "",
        });
        const sigBytes = await pqSign(slot.scheme, hToB(slot.secretKey), msgHash);

        // Backend uses canonical scheme names "pq_omni_ml_dsa" / "pq_omni_falcon" / etc.
        // Frontend slot.scheme is short ("ml_dsa_87"). Map before sending.
        const SCHEME_MAP: Record<string, string> = {
          ml_dsa_87:    "pq_omni_ml_dsa",
          falcon_512:   "pq_omni_falcon",
          dilithium_5:  "pq_omni_dilithium",
          slh_dsa_256s: "pq_omni_slh_dsa",
        };
        const wireScheme = SCHEME_MAP[slot.scheme] ?? slot.scheme;

        const result: any = await rpc.pqSend({
          from: slot.address, to: resolvedTo, amount: amountSat, fee,
          scheme: wireScheme, signature: bToH(sigBytes), public_key: bToH(pubKeyBytes),
          id: txId, timestamp, nonce, op_return: "",
        });
        const txid = typeof result === "object" ? result?.txid : result;
        setSendResult({ ok: true, msg: `PQ TX signed & sent (${slot.scheme})`, txid: (txid || "").toString() });
      } else {
        // ── Classic OMNI primary path (secp256k1 ECDSA) ──────────────────
        if (amountSat > balance.sat) throw new Error("Insufficient balance");
        const result: any = await rpc.sendTransaction(resolvedTo, amountSat);
        const txid = typeof result === "object" ? result?.txid : result;
        setSendResult({ ok: true, msg: `TX signed & sent`, txid: (txid || "").toString() });
      }
      setSendTo("");
      setSendAmount("");
      setSendFee("");
    } catch (err: any) {
      setSendResult({ ok: false, msg: err.message || "Transaction failed" });
    } finally {
      setSending(false);
    }
  };

  const copyAddr = (addr: string) => {
    navigator.clipboard.writeText(addr);
    setCopied(addr);
    setTimeout(() => setCopied(null), 2000);
  };

  const effectiveFee = sendFee
    ? parseInt(sendFee, 10)
    : feeEstimate?.medianFee ?? 1;

  // ── LOCKED SCREEN ─────────────────────────────────────────────────────
  // Login lives in the global Header button now (WalletConnectButton). Once
  // the user unlocks there, this whole page lights up — same singleton.
  if (!unlocked) {
    return (
      <div className="max-w-lg mx-auto px-3 sm:px-4 py-8 sm:py-12">
        <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4 sm:p-6 text-center space-y-4">
          <div className="w-16 h-16 mx-auto rounded-full bg-mempool-bg flex items-center justify-center">
            <svg width="32" height="32" viewBox="0 0 24 24" fill="none" className="text-mempool-blue">
              <rect x="3" y="11" width="18" height="11" rx="2" stroke="currentColor" strokeWidth="2" />
              <path d="M7 11V7a5 5 0 0110 0v4" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
            </svg>
          </div>
          <h2 className="text-xl font-bold text-mempool-text">Wallet locked</h2>
          <p className="text-sm text-mempool-text-dim">
            Click the <span className="text-mempool-blue font-semibold">Connect Wallet</span>{" "}
            button in the top-right header to unlock with your mnemonic, private
            key, or saved PIN. One unlock covers every tab — Exchange, Names,
            Faucet, Reputation and this page all share the same session.
          </p>
          <p className="text-[10px] text-mempool-text-dim">
            Keys never leave this browser. Signing is done client-side (secp256k1
            ECDSA). Post-Quantum secured with 5 address domains (ML-DSA, Falcon,
            Dilithium, SLH-DSA).
          </p>
          <div className="pt-2 border-t border-mempool-border/40">
            <button
              onClick={handleResetAll}
              title="Șterge vault local, PIN, cache. OMNI rămân pe blockchain."
              className="text-[10px] text-mempool-text-dim hover:text-red-400 transition-colors"
            >
              🗑 Reset all local data (vault corupt? folosește asta)
            </button>
          </div>
        </div>

        {/* Node status */}
        <div className="mt-4 text-center text-xs text-mempool-text-dim">
          Node: {chainState.wsConnected ? (
            <span className="text-mempool-green">Connected</span>
          ) : (
            <span className="text-mempool-red">Disconnected</span>
          )}
          {" | "}Block #{chainState.blockCount}
        </div>
      </div>
    );
  }

  // ── WALLET DASHBOARD ──────────────────────────────────────────────────
  return (
    <div className="max-w-4xl mx-auto px-3 sm:px-4 py-4 sm:py-6 space-y-4 sm:space-y-6">
      {/* Header with logout */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
        <div>
          <h2 className="text-base sm:text-lg font-bold text-mempool-text">My Wallet</h2>
          {myName && (
            <p className="text-xs text-mempool-blue font-semibold mt-0.5">{myName}</p>
          )}
        </div>
        <div className="flex items-center gap-2 flex-wrap">
          <button
            onClick={handleLogout}
            className="text-xs text-mempool-text-dim hover:text-mempool-red transition-colors px-3 py-1.5 rounded border border-mempool-border hover:border-mempool-red"
          >
            Lock Wallet
          </button>
          <button
            onClick={handleResetAll}
            title="Șterge mnemonic encriptat + PIN + cache local. OMNI rămân pe blockchain."
            className="text-xs text-mempool-text-dim hover:text-red-400 transition-colors px-3 py-1.5 rounded border border-mempool-border hover:border-red-400"
          >
            🗑 Reset All
          </button>
        </div>
      </div>

      {/* Soulbound Hero — 4 domains showcased on top, animated bars */}
      <SoulboundHero cups={reputation?.cups} tier={reputation?.tier} satoshi={reputation?.satoshi_badge} />

      {/* Balance + quick stats — single full-width gradient card */}
      <div className="bg-gradient-to-br from-mempool-card via-mempool-bg-elev to-mempool-bg-light rounded-2xl border border-mempool-border overflow-hidden">
        <div className="p-4 sm:p-6 grid grid-cols-2 sm:grid-cols-4 gap-3 sm:gap-4">
          <div className="col-span-2 sm:col-span-2">
            <p className="text-[10px] text-mempool-text-dim uppercase tracking-widest mb-1">Total Balance</p>
            <p className="text-2xl sm:text-4xl font-mono font-bold text-mempool-green tracking-tight break-all">{balance.omni}</p>
            <p className="text-xs text-mempool-text-dim mt-1">
              OMNI · {balance.sat.toLocaleString()} SAT
            </p>
          </div>
          <div>
            <p className="text-[10px] text-mempool-text-dim uppercase tracking-widest mb-1">Nonce</p>
            <p className="text-lg sm:text-2xl font-mono text-mempool-blue">{walletNonce ?? "—"}</p>
            <p className="text-[10px] text-mempool-text-dim/60 mt-1">UTXO: {utxos.length}</p>
          </div>
          <div>
            <p className="text-[10px] text-mempool-text-dim uppercase tracking-widest mb-1">Tier</p>
            <p className={`text-lg sm:text-2xl font-bold ${reputation?.satoshi_badge ? "text-mempool-orange" : "text-mempool-text"}`}>
              {reputation?.tier ?? "OMNI"}
            </p>
            {reputation?.satoshi_badge && <p className="text-[10px] text-mempool-orange mt-1">★ Satoshi</p>}
          </div>
        </div>
        {/* Balance breakdown — same singleton as Exchange + Stake tabs. We
            always show the four cells so the user can see "0 staked" and
            "0 in orders" explicitly instead of wondering why a number is
            missing. Refreshes every 8 s via useGlobalBalance hook. */}
        {globalBal.address === activeAddress && (
          <div className="border-t border-mempool-border bg-mempool-bg/30 px-4 sm:px-6 py-3 grid grid-cols-2 sm:grid-cols-4 gap-3 text-xs">
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase tracking-wider mb-0.5">Available</p>
              <p className="font-mono font-semibold text-mempool-green">{formatOmni(globalBal.available_sat)}</p>
              <p className="text-[9px] text-mempool-text-dim/70">spendable now</p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase tracking-wider mb-0.5">Staked</p>
              <p className="font-mono font-semibold text-mempool-purple">{formatOmni(globalBal.staked_sat)}</p>
              <p className="text-[9px] text-mempool-text-dim/70">
                {globalBal.stakes.length > 0 ? `${globalBal.stakes.length} lock${globalBal.stakes.length > 1 ? "s" : ""}` : "no locks"}
              </p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase tracking-wider mb-0.5">In Orders</p>
              <p className="font-mono font-semibold text-mempool-blue">{formatOmni(globalBal.in_orders_sat)}</p>
              <p className="text-[9px] text-mempool-text-dim/70">resting sells</p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase tracking-wider mb-0.5">On Chain</p>
              <p className="font-mono font-semibold text-mempool-text">{formatOmni(globalBal.wallet_sat)}</p>
              <p className="text-[9px] text-mempool-text-dim/70">
                {globalBal.fetched_at > 0 ? `block #${globalBal.block_height}` : "loading…"}
              </p>
            </div>
          </div>
        )}
      </div>

      {/* All 19 BIP-44 slots — aggregate + per-slot drill-down. Useful when
          the user has spread balance across multiple slots (mining rewards
          land on slot 0; staking from another; trading from a third). */}
      {allSlots.slots.length > 0 && (
        <div className="bg-mempool-bg-elev rounded-2xl border border-mempool-border overflow-hidden">
          <div className="p-4 sm:p-5 grid grid-cols-2 sm:grid-cols-4 gap-3 sm:gap-4 border-b border-mempool-border bg-gradient-to-r from-mempool-bg-elev to-mempool-bg-light">
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase tracking-wider mb-0.5">All-slot total</p>
              <p className="font-mono font-bold text-lg sm:text-xl text-mempool-green">{formatOmni(allSlots.total_wallet_sat)}</p>
              <p className="text-[9px] text-mempool-text-dim/70">OMNI across {allSlots.slots.length} slots</p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase tracking-wider mb-0.5">Staked</p>
              <p className="font-mono font-semibold text-mempool-purple">{formatOmni(allSlots.total_staked_sat)}</p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase tracking-wider mb-0.5">In Orders</p>
              <p className="font-mono font-semibold text-mempool-blue">{formatOmni(allSlots.total_in_orders_sat)}</p>
            </div>
            <div>
              <p className="text-[10px] text-mempool-text-dim uppercase tracking-wider mb-0.5">Available</p>
              <p className="font-mono font-semibold text-mempool-text">{formatOmni(allSlots.total_available_sat)}</p>
            </div>
          </div>
          <div className="max-h-72 overflow-y-auto">
            <table className="w-full text-xs">
              <thead className="bg-mempool-bg/40 text-[10px] uppercase tracking-wider text-mempool-text-dim">
                <tr>
                  <th className="text-left px-3 py-1.5">Slot</th>
                  <th className="text-left px-3 py-1.5">Address</th>
                  <th className="text-right px-3 py-1.5">Wallet</th>
                  <th className="text-right px-3 py-1.5">Staked</th>
                  <th className="text-right px-3 py-1.5">Orders</th>
                  <th className="text-right px-3 py-1.5">Available</th>
                </tr>
              </thead>
              <tbody>
                {allSlots.slots.map((s) => {
                  const isActive = s.index === activeSlot;
                  return (
                    <tr
                      key={s.index}
                      onClick={() => setActiveSlot(s.index)}
                      className={`border-t border-mempool-border/30 cursor-pointer hover:bg-mempool-bg/40 ${isActive ? "bg-mempool-blue/10" : ""}`}
                      title="Click to make this the active slot for Trade / Send / Stake"
                    >
                      <td className="px-3 py-1.5 font-mono text-mempool-text-dim">
                        {isActive ? <span className="text-mempool-blue font-semibold">▶ #{s.index}</span> : `#${s.index}`}
                      </td>
                      <td className="px-3 py-1.5 font-mono text-[10px] text-mempool-text-dim truncate max-w-[200px]" title={s.address}>
                        {midTrunc(s.address, 10, 6)}
                      </td>
                      <td className="px-3 py-1.5 text-right font-mono">{formatOmni(s.wallet_sat)}</td>
                      <td className="px-3 py-1.5 text-right font-mono text-mempool-purple/80">{formatOmni(s.staked_sat)}</td>
                      <td className="px-3 py-1.5 text-right font-mono text-mempool-blue/80">{formatOmni(s.in_orders_sat)}</td>
                      <td className="px-3 py-1.5 text-right font-mono">{formatOmni(s.available_sat)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          {allSlots.fetched_at === 0 && (
            <p className="text-[10px] text-mempool-text-dim/70 text-center py-2">Loading per-slot balances…</p>
          )}
        </div>
      )}

      {/* Two columns */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 sm:gap-6">
        {/* Send Transaction */}
        <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-3 sm:p-5 space-y-4">
          <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
            Send OMNI
          </h3>
          <div className="space-y-3">
            {/* From — source address selector */}
            <div>
              <label className="text-[10px] text-mempool-text-dim uppercase">From</label>
              <select
                value={sendFromScheme}
                onChange={(e) => setSendFromScheme(e.target.value)}
                className="w-full bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2.5 text-sm font-mono text-mempool-text focus:outline-none focus:border-mempool-blue mt-1"
              >
                <option value="omni_ecdsa">
                  🔑 OMNI Slot #{activeSlot} (ECDSA) — {midTrunc(activeAddress, 14, 6)}
                </option>
                {unlocked.pqOmni && unlocked.pqOmni.map((slot) => (
                  <option key={slot.scheme} value={slot.scheme}>
                    {slot.scheme === "ml_dsa_87"   && "🛡 PQ ML-DSA-87"}
                    {slot.scheme === "falcon_512"  && "🛡 PQ Falcon-512"}
                    {slot.scheme === "dilithium_5" && "🛡 PQ Dilithium-5"}
                    {slot.scheme === "slh_dsa_256s"&& "🛡 PQ SLH-DSA-256s"}
                    {" — "}{midTrunc(slot.address, 14, 6)}
                  </option>
                ))}
              </select>
              {sendFromScheme !== "omni_ecdsa" && (
                <p className="text-[9px] text-mempool-blue mt-1">
                  Post-quantum signed — uses {sendFromScheme} secret key (RAM only)
                </p>
              )}
            </div>
            <div>
              <label className="text-[10px] text-mempool-text-dim uppercase">
                Recipient Address or Name
                <span className="ml-1 text-mempool-text-dim/60 normal-case">
                  (e.g. <span className="font-mono text-mempool-blue">alice.bank</span> or <span className="font-mono">ob1q…</span>)
                </span>
              </label>
              <input
                type="text"
                value={sendTo}
                onChange={(e) => setSendTo(e.target.value)}
                placeholder="alice.bank or ob1q..."
                className="w-full bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2.5 text-sm font-mono text-mempool-text placeholder-mempool-text-dim/40 focus:outline-none focus:border-mempool-blue mt-1"
              />
              <SendNamePreview rawInput={sendTo} onResolve={(addr) => {
                // If preview resolved a name to a different address, replace
                // the input transparently so handleSend uses the chain address.
                if (addr && addr !== sendTo && /^ob[1_]/.test(addr)) {
                  // Don't auto-replace — show preview only. User confirms with click.
                }
              }} />
            </div>
            <div>
              <label className="text-[10px] text-mempool-text-dim uppercase">Amount (OMNI)</label>
              <input
                type="number"
                value={sendAmount}
                onChange={(e) => setSendAmount(e.target.value)}
                placeholder="0.0000"
                step="0.0001"
                min="0"
                className="w-full bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2.5 text-sm font-mono text-mempool-text placeholder-mempool-text-dim/40 focus:outline-none focus:border-mempool-blue mt-1"
              />
            </div>
            <div>
              <label className="text-[10px] text-mempool-text-dim uppercase">
                Fee (SAT)
                {feeEstimate && (
                  <span className="text-mempool-blue ml-1 normal-case">
                    -- estimated: {feeEstimate.medianFee} SAT
                  </span>
                )}
              </label>
              <input
                type="number"
                value={sendFee}
                onChange={(e) => setSendFee(e.target.value)}
                placeholder={feeEstimate ? `${feeEstimate.medianFee} (estimated)` : "1"}
                min="0"
                className="w-full bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2.5 text-sm font-mono text-mempool-text placeholder-mempool-text-dim/40 focus:outline-none focus:border-mempool-blue mt-1"
              />
            </div>
            <div className="bg-mempool-bg rounded-lg p-3 text-[10px] text-mempool-text-dim space-y-1">
              <div className="flex justify-between">
                <span>Signing:</span>
                <span className="text-mempool-blue">
                  {sendFromScheme === "omni_ecdsa"   && "secp256k1 ECDSA"}
                  {sendFromScheme === "ml_dsa_87"    && "ML-DSA-87 (PQ)"}
                  {sendFromScheme === "falcon_512"   && "Falcon-512 (PQ)"}
                  {sendFromScheme === "dilithium_5"  && "Dilithium-5 (PQ)"}
                  {sendFromScheme === "slh_dsa_256s" && "SLH-DSA-256s (PQ)"}
                </span>
              </div>
              <div className="flex justify-between">
                <span>Fee:</span>
                <span className="text-mempool-orange">{effectiveFee} SAT</span>
              </div>
              {feeEstimate && (
                <>
                  <div className="flex justify-between">
                    <span>Min Fee:</span>
                    <span>{feeEstimate.minFee} SAT</span>
                  </div>
                  <div className="flex justify-between">
                    <span>Fee Burn:</span>
                    <span className="text-mempool-red">{feeEstimate.burnPct}%</span>
                  </div>
                </>
              )}
              <div className="flex justify-between">
                <span>Confirmation:</span>
                <span>~1s (10 sub-blocks)</span>
              </div>
            </div>
            <button
              onClick={handleSend}
              disabled={sending || !sendTo || !sendAmount}
              className="w-full bg-mempool-blue hover:bg-mempool-blue/80 disabled:opacity-30 disabled:cursor-not-allowed text-white text-sm font-semibold rounded-lg py-3 transition-colors"
            >
              {sending ? "Signing & Broadcasting..." : "Sign & Send"}
            </button>
            {sendResult && (
              <p className={`text-xs ${sendResult.ok ? "text-mempool-green" : "text-mempool-red"}`}>
                {sendResult.msg}
                {sendResult.txid && (
                  <>
                    {": "}
                    <TxHashLink txid={sendResult.txid} truncate={{ left: 12, right: 6 }} />
                  </>
                )}
              </p>
            )}
          </div>
        </div>

        {/* Addresses */}
        <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-3 sm:p-5 space-y-4">
          <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
            Addresses
          </h3>

          {/* ── 1. OMNI Slot #N (secp256k1) ── */}
          <div>
            <p className="text-[9px] uppercase tracking-wider text-mempool-text-dim/60 mb-1.5">
              🔑 OMNI Slot #{activeSlot} — secp256k1 ECDSA (Bitcoin-compatible)
            </p>
            <PrimaryAddressCard
              address={activeAddress}
              name={myName}
              balance={balance}
              utxos={utxos}
              nonce={walletNonce}
              copied={copied === activeAddress}
              onCopy={() => copyAddr(activeAddress)}
            />
            {copied === activeAddress && (
              <span className="text-[10px] text-mempool-green pl-1">Copied!</span>
            )}
          </div>

          {/* ── 2. PQ-OMNI Transferable (ob_q1_..ob_q4_) — same mnemonic ── */}
          <div className="pt-3 border-t border-mempool-border/40">
            <p className="text-[9px] uppercase tracking-wider text-mempool-text-dim/60 mb-1.5">
              🛡 PQ-OMNI — Transferable, post-quantum signed
              <span className="normal-case tracking-normal text-mempool-blue ml-1">(obk1_/obf5_/obd5_/obs3_, derivate din același mnemonic)</span>
            </p>
            {unlocked.pqOmni && unlocked.pqOmni.length > 0 ? (
              <div className="space-y-2">
                {unlocked.pqOmni.map((slot) => (
                  <PqOmniSlotCard key={slot.scheme} slot={slot} />
                ))}
              </div>
            ) : (
              <div className="text-[10px] text-mempool-text-dim/60 bg-mempool-bg rounded p-2">
                Derivare în curs… (necesită unlock din mnemonic)
              </div>
            )}
          </div>

          {/* ── 3. Multichain addresses (24 chains) ── */}
          {unlocked.multichainAddresses && unlocked.multichainAddresses.length > 0 && (
            <div className="pt-3 border-t border-mempool-border/40">
              <p className="text-[9px] uppercase tracking-wider text-mempool-text-dim/60 mb-1.5">
                🌐 Multi-Chain Addresses — same mnemonic, BIP-44 standard
              </p>
              <MultichainPanel addresses={unlocked.multichainAddresses} />
            </div>
          )}

          {/* ── 4. Soulbound reputation domains — LOVE/FOOD/RENT/VACATION ── */}
          <div className="pt-3 border-t border-mempool-border/40">
            <p className="text-[9px] uppercase tracking-wider text-mempool-text-dim/60 mb-1.5">
              🔒 Soulbound — reward-only, nu pot trimite
            </p>
            <div className="space-y-2">
              {(unlocked.soulboundAddresses && unlocked.soulboundAddresses.length > 0
                ? unlocked.soulboundAddresses
                : PQ_DOMAINS.filter((pq) => pq.prefix !== "ob1q").map((pq) => ({
                    tier: pq.tier, prefix: pq.prefix, address: "", algo: pq.algo, bits: pq.bits,
                  }))
              ).map((sb) => (
                <SoulboundCard
                  key={sb.prefix}
                  tier={sb.tier}
                  prefix={sb.prefix}
                  address={sb.address}
                  algo={sb.algo}
                  bits={sb.bits}
                  repCup={reputation?.cups?.[sb.tier.toLowerCase() as "love"|"food"|"rent"|"vacation"]}
                />
              ))}
            </div>
            <p className="text-[9px] text-mempool-text-dim/50 mt-2">
              <span className="text-mempool-orange/90">100/100/100/100 = Satoshi badge</span>
              {" · "}Chain blochează orice TX cu from = ob_k1_/ob_f5_/ob_d5_/ob_s3_
            </p>
            {/* Register Identity button */}
            {unlocked.soulboundAddresses && unlocked.soulboundAddresses.length === 4 && (
              <PqAttestButton unlocked={unlocked} />
            )}
          </div>

          {/* Public key — useful for verifying signatures off-chain */}
          <div className="pt-2 border-t border-mempool-border/50">
            <p className="text-[10px] text-mempool-text-dim uppercase mb-1">
              Public key (compressed, 33 bytes)
            </p>
            <p className="text-[10px] font-mono text-mempool-text-dim break-all">
              {unlocked.publicKey}
            </p>
          </div>
        </div>
      </div>

      {/* Wallet metadata — JSON snapshot, Bitcoin-wallet-export style.
          Shows everything the UI knows about this identity. Mnemonic + xprv
          are present ONLY when the user unlocked via mnemonic this session
          (RAM-only, never persisted). On reload they're gone — the user
          re-pastes if they need to see them again. */}
      <WalletMetadataPanel
        address={activeAddress}
        publicKey={unlocked.publicKey}
        privateKey={unlocked.privateKey}
        walletIndex={activeSlot}
        mnemonic={unlocked.mnemonic}
        xprv={unlocked.xprv}
        xpub={unlocked.xpub}
        pqOmni={unlocked.pqOmni}
        name={myName}
        balance={balance}
        nonce={walletNonce}
        utxoCount={utxos.length}
        reputation={reputation}
        chainName={"testnet"}
      />

      {/* My .omnibus names — pick which one represents me globally */}
      <MyNamesPanel address={activeAddress} />

      {/* Phase 2 NS: per-name management (PQ slots, category badge, preferred slot) */}
      <OwnedNameManageWrapper ownerAddress={activeAddress} />

      {/* Bottom split: 2/3 transaction history, 1/3 rewards legend (sticky) */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
      {/* Transaction History — 2/3 width */}
      <div className="lg:col-span-2 bg-mempool-bg-elev rounded-xl border border-mempool-border overflow-hidden">
        <div className="px-3 sm:px-5 py-3 border-b border-mempool-border flex flex-col gap-2">
          <div className="flex items-center justify-between">
            <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
              Transaction History
            </h3>
            {transactions.length > 0 && (
              <button
                onClick={() => {
                  const csvEsc = (v: string) => `"${String(v ?? "").replace(/"/g, '""')}"`;
                  const rows = [
                    ["txid", "type", "direction", "amount_omni", "fee_omni", "from", "to", "confirmations", "status", "memo", "timestamp"].join(","),
                    ...transactions.map((tx: any) => {
                      const cls = classifyTx(tx, activeAddress);
                      return [
                        csvEsc(tx.txid || ""),
                        csvEsc(cls.label),
                        cls.isCredit ? "in" : "out",
                        ((tx.amount ?? 0) / SAT_PER_OMNI).toFixed(8),
                        ((tx.fee ?? 0) / SAT_PER_OMNI).toFixed(8),
                        csvEsc(tx.from || ""),
                        csvEsc(tx.to || ""),
                        tx.confirmations ?? "",
                        csvEsc(tx.status || ""),
                        csvEsc(tx.op_return || ""),
                        tx.timestamp ? new Date(tx.timestamp * 1000).toISOString() : "",
                      ].join(",");
                    }),
                  ].join("\n");
                  const blob = new Blob([rows], { type: "text/csv" });
                  const url = URL.createObjectURL(blob);
                  const a = document.createElement("a");
                  a.href = url;
                  a.download = `omnibus-${activeAddress.slice(0, 12)}-wallet-txs.csv`;
                  a.click();
                  URL.revokeObjectURL(url);
                }}
                className="text-[10px] px-2 py-1 bg-mempool-bg-elev border border-mempool-border rounded text-mempool-text-dim hover:text-mempool-text transition-colors font-mono"
              >
                ⬇ CSV
              </button>
            )}
          </div>
          {/* Type filter pills — driven by classifyTx() result. "All" shows
              everything, including types that may not be present yet. */}
          <div className="flex flex-wrap gap-1">
            {["All", "Sent", "Received", "Mining Reward", "Stake", "Unstake", "Open Order", "Cancel Order", "DEX Deposit", "DEX Withdraw", "NS Claim", "Agent Register", "Notarize"].map((type) => {
              const count = txCountByType[type] ?? 0;
              if (type !== "All" && count === 0) return null; // hide empty filters
              return (
                <button
                  key={type}
                  onClick={() => setTxFilter(type)}
                  className={`text-[10px] px-2 py-0.5 rounded transition-colors ${
                    txFilter === type
                      ? "bg-mempool-blue text-white font-semibold"
                      : "bg-mempool-bg text-mempool-text-dim hover:text-mempool-text"
                  }`}
                >
                  {type} {count > 0 && `(${count})`}
                </button>
              );
            })}
          </div>
        </div>
        <div className="divide-y divide-mempool-border/30 max-h-96 overflow-y-auto">
          {transactions.length === 0 ? (
            <div className="px-3 sm:px-5 py-8 text-center text-sm text-mempool-text-dim">
              No transactions yet. Mine blocks or receive OMNI to see history.
            </div>
          ) : (
            filteredTxs.map((tx: any, i: number) => {
                const cls = classifyTx(tx, activeAddress);
                return (
              <div key={tx.txid || i} className="px-3 sm:px-5 py-3 flex items-center gap-3">
                <div className={`w-2 h-2 rounded-full flex-shrink-0 ${
                  cls.isCredit ? "bg-mempool-green" : "bg-mempool-orange"
                }`} />
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 flex-wrap">
                    <span className={`text-[10px] px-1.5 py-0.5 rounded font-semibold ${cls.badgeClass}`}>
                      {cls.label}
                    </span>
                    {tx.txid && <TxHashLink txid={tx.txid} truncate={{ left: 14, right: 6 }} className="text-xs" />}
                  </div>
                  <p className="text-[10px] text-mempool-text-dim mt-0.5">
                    {tx.from && <AddressLabel address={tx.from} truncate={{ left: 12, right: 6 }} showCategory />} → {tx.to && <AddressLabel address={tx.to} truncate={{ left: 12, right: 6 }} showCategory />}
                  </p>
                  {tx.op_return && (
                    <p className="text-[10px] text-mempool-orange/80 mt-0.5 font-mono break-all">
                      memo: {tx.op_return}
                    </p>
                  )}
                </div>
                {/* Confirmations */}
                <div className="flex-shrink-0">
                  {tx.confirmations != null ? (
                    <span className={`text-[10px] px-1.5 py-0.5 rounded-full font-mono ${
                      tx.confirmations >= 6
                        ? "bg-mempool-green/20 text-mempool-green"
                        : tx.confirmations >= 1
                        ? "bg-mempool-orange/20 text-mempool-orange"
                        : "bg-mempool-red/20 text-mempool-red"
                    }`}>
                      {tx.confirmations >= 1 ? `${tx.confirmations} conf` : "pending"}
                    </span>
                  ) : (
                    <span className="text-[10px] px-1.5 py-0.5 rounded bg-mempool-orange/20 text-mempool-orange">
                      {tx.status || "pending"}
                    </span>
                  )}
                </div>
                <div className="text-right flex-shrink-0">
                  <p className={`text-xs font-mono ${
                    cls.isCredit ? "text-mempool-green" : "text-mempool-orange"
                  }`}>
                    {cls.isCredit ? "+" : "-"}{((tx.amount || 0) / SAT_PER_OMNI).toFixed(8)}
                  </p>
                  {tx.fee != null && tx.fee > 0 && (
                    <p className="text-[9px] text-mempool-text-dim font-mono">
                      fee: {tx.fee} SAT
                    </p>
                  )}
                </div>
              </div>
                );
              })
          )}
        </div>
      </div>

      {/* Rewards Legend — 1/3 width sticky sidebar (right column) */}
      <div className="lg:col-span-1">
        <div className="lg:sticky lg:top-4 space-y-3">
          <RewardsLegendCard cups={reputation?.cups} />
        </div>
      </div>
      </div>
    </div>
  );
}

// ── RewardsLegendCard — bottom-right sidebar replacement ────────────────────
// Compact, always-visible legend showing how each cup grows.
// Replaces the old collapsible RewardsBreakdownPanel (still used elsewhere).

function RewardsLegendCard({ cups }: { cups?: { love: string; food: string; rent: string; vacation: string } }) {
  return (
    <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border overflow-hidden">
      <div className="px-4 py-3 border-b border-mempool-border bg-gradient-to-r from-purple-900/20 to-transparent">
        <h3 className="text-xs font-bold text-mempool-text uppercase tracking-wider">🎁 Rewards Legend</h3>
        <p className="text-[10px] text-mempool-text-dim mt-0.5">How each soulbound cup fills</p>
      </div>
      <div className="p-3 space-y-2.5">
        {(["LOVE", "FOOD", "RENT", "VACATION"] as const).map((tier) => {
          const r = REWARD_RULES[tier];
          const cup = cups?.[tier.toLowerCase() as "love"|"food"|"rent"|"vacation"] ?? "0.00";
          return (
            <div key={tier} className="rounded-lg bg-mempool-bg/50 border border-mempool-border/30 p-2.5">
              <div className="flex items-baseline justify-between mb-1.5">
                <span className={`text-[11px] font-bold ${r.color}`}>
                  {r.emoji} {tier}
                </span>
                <span className="text-[10px] font-mono text-mempool-text-dim">{cup}/100</span>
              </div>
              <div className="space-y-0.5">
                {r.earn.map((rule) => (
                  <div key={rule.what} className="flex items-center justify-between text-[9px] gap-2">
                    <span className="text-mempool-text-dim/80 truncate flex-1">{rule.what}</span>
                    <span className="font-mono text-mempool-green font-semibold whitespace-nowrap">{rule.pts}</span>
                  </div>
                ))}
                {r.penalty?.map((p, i) => (
                  <div key={`p${i}`} className="flex items-center justify-between text-[9px] gap-2">
                    <span className="text-mempool-text-dim/60 truncate flex-1">{p.what}</span>
                    <span className="font-mono text-red-400 font-semibold whitespace-nowrap">{p.pts}</span>
                  </div>
                ))}
              </div>
            </div>
          );
        })}
        <p className="text-[9px] text-mempool-text-dim/60 leading-snug px-1 pt-1">
          Hit <span className="text-mempool-orange">100/100</span> in all 4 → Satoshi badge (Zen tier).
        </p>
      </div>
    </div>
  );
}

// ── MyNamesPanel ────────────────────────────────────────────────────────────
//
// All `<label>.omnibus` / `<label>.arbitraje` names that resolve back to this
// wallet, capped at MAX_NAMES_PER_WALLET. The user picks which one is
// "primary" — that's what shows up in the Header pill, in NamesPage tables,
// in faucet/exchange status, etc. Selection is per-browser (localStorage).
function MyNamesPanel({ address }: { address: string }) {
  const names = useNamesOwnedBy(address);
  const currentPrimary = useNameForAddress(address);
  const [savedPrimary, setSavedPrimary] = useState(() => getPrimaryName(address));

  useEffect(() => {
    setSavedPrimary(getPrimaryName(address));
  }, [address]);

  return (
    <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-3 sm:p-5 space-y-3">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          My .omnibus names
        </h3>
        <span className="text-[10px] text-mempool-text-dim">
          {names.length} / {MAX_NAMES_PER_WALLET}
        </span>
      </div>

      {names.length === 0 ? (
        <p className="text-xs text-mempool-text-dim">
          No names registered. Go to <span className="text-mempool-blue">.omnibus</span> tab to
          claim one — your name then shows up everywhere instead of the
          ob1q… address.
        </p>
      ) : (
        <>
          <p className="text-[11px] text-mempool-text-dim">
            Pick which name represents you across the explorer (header pill,
            faucet, exchange, reputation). The choice is local to this
            browser — change it any time.
          </p>
          <div className="space-y-1.5">
            {names.map((entry) => {
              const isPrimary = (savedPrimary ?? currentPrimary) === entry.fullLabel;
              return (
                <label
                  key={entry.fullLabel}
                  className={`flex items-center gap-3 p-2.5 rounded-lg cursor-pointer border transition-colors ${
                    isPrimary
                      ? "bg-mempool-blue/15 border-mempool-blue/50"
                      : "bg-mempool-bg border-mempool-border hover:border-mempool-blue/30"
                  }`}
                >
                  <input
                    type="radio"
                    name="primary-name"
                    checked={isPrimary}
                    onChange={() => {
                      setPrimaryName(address, entry.fullLabel);
                      setSavedPrimary(entry.fullLabel);
                    }}
                    className="accent-mempool-blue"
                  />
                  <div className="flex-1 min-w-0">
                    <div className="text-sm font-semibold text-mempool-text">
                      {entry.fullLabel}
                    </div>
                    <div className="text-[10px] text-mempool-text-dim font-mono">
                      registered block #{entry.registeredAtBlock} · expires #{entry.expiresAtBlock}
                    </div>
                  </div>
                  {isPrimary && (
                    <span className="text-[10px] uppercase tracking-wider text-mempool-blue font-bold">
                      Primary
                    </span>
                  )}
                </label>
              );
            })}
          </div>
          {savedPrimary && (
            <button
              onClick={() => {
                setPrimaryName(address, null);
                setSavedPrimary(null);
              }}
              className="text-[10px] text-mempool-text-dim hover:text-mempool-orange"
            >
              Clear primary (auto-pick first)
            </button>
          )}
        </>
      )}
    </div>
  );
}

// ── SendNamePreview ─────────────────────────────────────────────────────────
//
// Phase 2 NS — when user types `<name>.<tld>` in the recipient box, we run
// resolvename in the background (debounced 300ms) and surface category +
// preferred slot + final routed address. Helps the user verify they're
// sending to the right entity (e.g. "alice.bank — BANK badge — pref ML-DSA").
function SendNamePreview({ rawInput, onResolve }: {
  rawInput: string;
  onResolve: (addr: string | null) => void;
}) {
  const [data, setData] = useState<any | null>(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    const txt = rawInput.trim().toLowerCase();
    const isName = /^[a-z][a-z0-9_]{2,24}\.(omnibus|arbitraje|quantum|bank|gov|mil|fin|edu|org|dev)$/.test(txt);
    if (!isName) {
      setData(null);
      setErr(null);
      return;
    }
    let cancelled = false;
    const id = setTimeout(async () => {
      setLoading(true);
      setErr(null);
      try {
        const [n, t] = txt.split(".");
        // Use the chain's authoritative send-routing helper so the preview
        // matches exactly what `handleSend` will broadcast.
        const r: any = await rpc.request_raw("ns_resolveforsend", [n, t]);
        if (cancelled) return;
        if (!r?.found) {
          setErr(`${txt} — not registered`);
          setData(null);
          onResolve(null);
        } else {
          // Also fetch the full entry for category badge — `ns_resolveforsend`
          // intentionally omits category to keep the contract narrow.
          const full: any = await rpc.request_raw("resolvename", [n, t]).catch(() => null);
          setData({ ...r, category: full?.category });
          onResolve(r.route_address || r.primary_address);
        }
      } catch (e: any) {
        if (!cancelled) setErr(e?.message ?? "lookup failed");
      } finally {
        if (!cancelled) setLoading(false);
      }
    }, 300);
    return () => { cancelled = true; clearTimeout(id); };
  }, [rawInput, onResolve]);

  if (!rawInput.trim()) return null;
  if (loading) return <p className="text-[10px] text-mempool-text-dim mt-1">Resolving name…</p>;
  if (err) return <p className="text-[10px] text-amber-400 mt-1">{err}</p>;
  if (!data) return null;

  // Chain-driven routing — fields come straight from `ns_resolveforsend` so
  // the preview is byte-identical to what `handleSend` will sign against.
  const routeSlot: number = data.route_slot ?? 0;
  const routed: string    = data.route_address || data.primary_address;
  const fellBack: boolean = !!data.fell_back_to_primary;
  const slotName = ["primary (ECDSA)", "ML-DSA-87", "Falcon-512", "Dilithium-5", "SLH-DSA-256s"][routeSlot];
  const isPq = routeSlot > 0;

  return (
    <div className={`mt-1 p-2 rounded text-[10px] border ${isPq ? "bg-mempool-blue/10 border-mempool-blue/40" : "bg-green-500/10 border-green-500/30"}`}>
      <p className={isPq ? "text-mempool-blue" : "text-green-300"}>
        <span className="font-semibold">✓ {data.fullLabel}</span>
        {data.category && data.category !== "none" && (
          <span className="ml-2 px-1 rounded bg-mempool-blue/30 text-mempool-blue uppercase tracking-wider">
            {data.category}
          </span>
        )}
        {isPq ? (
          <span className="ml-2 px-1 rounded bg-mempool-blue/30 text-mempool-blue font-semibold uppercase tracking-wider">
            via PQ-{routeSlot} ({slotName})
          </span>
        ) : (
          <span className="ml-2 text-mempool-text-dim">routes to {slotName}</span>
        )}
      </p>
      {fellBack && (
        <p className="text-amber-400 mt-0.5">
          owner declared a PQ preference but never published the slot — falling back to primary
        </p>
      )}
      <p className="font-mono text-mempool-text-dim mt-1 break-all">→ {routed}</p>
    </div>
  );
}

// ── OwnedNameManageWrapper ──────────────────────────────────────────────────
//
// Bridges useNamesOwnedBy() (whose entries shape lives in api/use-names.ts)
// into the NameManagePanel which expects {fullLabel, name, tld,
// registeredAtBlock} only. Keeps the panel decoupled from the concrete
// hook so the same panel can be reused outside Wallet (e.g. NamesPage).
function OwnedNameManageWrapper({ ownerAddress }: { ownerAddress: string }) {
  const names = useNamesOwnedBy(ownerAddress);
  const owned = names.map((n) => ({
    fullLabel: n.fullLabel,
    name: n.name,
    tld: n.tld,
    registeredAtBlock: n.registeredAtBlock,
  }));
  return <NameManagePanel ownerAddress={ownerAddress} ownedNames={owned} />;
}

// ── PQDomainCard ────────────────────────────────────────────────────────────
//
// Click to expand. Shows everything we know about this PQ domain for the
// current wallet: algorithm + bit strength, address prefix, reputation cup
// score (if any), and a placeholder for the actual ob_k1_/ob_f5_/ob_d5_/
// ob_s3_ address — those need the user to derive an isolated mnemonic per
// project_omnibus_5_isolated_wallets memory. For now we surface what we
// have; full multi-mnemonic UI is its own session.

// ── OnboardingFaucetButton ───────────────────────────────────────────────────
// Step 1 of onboarding: claim ~0.001 OMNI from the protocol faucet so the
// address can pay the small fee for pq_attest_v1. The button is hidden when
// the wallet already has any OMNI balance, or when the faucet is empty.

function OnboardingFaucetButton({ address, balanceSat }: { address: string; balanceSat: number }) {
  const [status, setStatus] = useState<"idle"|"sending"|"ok"|"err"|"loading">("loading");
  const [msg, setMsg] = useState("");
  const [faucetEnabled, setFaucetEnabled] = useState(false);
  const [declHash, setDeclHash] = useState("");

  useEffect(() => {
    rpc.getFaucetStatus().then(s => {
      if (s) {
        setFaucetEnabled(!!s.enabled);
        setDeclHash(s.declaration_hash);
      }
      setStatus("idle");
    }).catch(() => setStatus("idle"));
  }, []);

  async function claim() {
    if (!declHash) { setMsg("Faucet status unavailable"); setStatus("err"); return; }
    setStatus("sending");
    try {
      const r = await rpc.claimFaucet(address, declHash);
      setStatus("ok");
      setMsg(`TX: ${r.txid?.slice(0, 16)}…`);
    } catch (e: any) {
      setStatus("err");
      setMsg(e?.message ?? "Claim failed");
    }
  }

  // Hide when wallet already has funds or faucet is offline.
  if (balanceSat > 0) return null;
  if (status === "loading") return null;
  if (!faucetEnabled) return (
    <div className="mt-2 text-[9px] text-yellow-400">
      ⚠ Faucet temporary offline — needs community refill
    </div>
  );
  if (status === "ok") return (
    <div className="mt-2 text-[9px] text-mempool-green font-semibold">
      ✓ Faucet sent · {msg} · Now click Register Identity below
    </div>
  );

  return (
    <div className="mt-2 flex items-center gap-2">
      <button
        type="button"
        onClick={claim}
        disabled={status === "sending"}
        className="text-[9px] px-2.5 py-1 rounded bg-mempool-orange/20 border border-mempool-orange/40 text-mempool-orange hover:bg-mempool-orange/30 disabled:opacity-50 font-semibold"
      >
        {status === "sending" ? "Claiming…" : "🚰 Step 1: Claim Onboarding Faucet"}
      </button>
      {status === "err" && <span className="text-[9px] text-red-400">{msg}</span>}
    </div>
  );
}

// ── SoulboundHero — top of wallet, big animated showcase ────────────────────
// 4 cards (LOVE / FOOD / RENT / VACATION) with animated progress bars. The
// fill animation runs once per value change, smooth 1s ease-out. When all 4
// are 100/100, the whole hero glows orange + shows the Satoshi badge.

const SOULBOUND_HERO: { tier: "LOVE" | "FOOD" | "RENT" | "VACATION"; emoji: string; label: string; subtitle: string; gradient: string; bar: string; ring: string }[] = [
  {
    tier: "LOVE",
    emoji: "❤️",
    label: "LOVE",
    subtitle: "Uptime · loyalty",
    gradient: "from-purple-900/40 via-purple-800/20 to-mempool-bg-elev",
    bar: "from-purple-500 to-fuchsia-400",
    ring: "ring-purple-500/30",
  },
  {
    tier: "FOOD",
    emoji: "🥖",
    label: "FOOD",
    subtitle: "Useful work",
    gradient: "from-emerald-900/40 via-green-800/20 to-mempool-bg-elev",
    bar: "from-emerald-500 to-green-400",
    ring: "ring-green-500/30",
  },
  {
    tier: "RENT",
    emoji: "🏠",
    label: "RENT",
    subtitle: "Capital committed",
    gradient: "from-orange-900/40 via-amber-800/20 to-mempool-bg-elev",
    bar: "from-orange-500 to-amber-400",
    ring: "ring-orange-500/30",
  },
  {
    tier: "VACATION",
    emoji: "🏖️",
    label: "VACATION",
    subtitle: "Longevity",
    gradient: "from-sky-900/40 via-cyan-800/20 to-mempool-bg-elev",
    bar: "from-sky-400 to-cyan-300",
    ring: "ring-sky-500/30",
  },
];

function SoulboundHero({
  cups,
  tier,
  satoshi,
}: {
  cups?: { love: string; food: string; rent: string; vacation: string };
  tier?: string;
  satoshi?: boolean;
}) {
  // Animate from 0 to actual value on mount + on value change.
  const [animated, setAnimated] = useState({ love: 0, food: 0, rent: 0, vacation: 0 });

  useEffect(() => {
    // Two-frame trick — render at 0 first, then push to real values so CSS
    // transition-all animates the fill.
    const t = setTimeout(() => {
      setAnimated({
        love:     parseFloat(cups?.love     ?? "0"),
        food:     parseFloat(cups?.food     ?? "0"),
        rent:     parseFloat(cups?.rent     ?? "0"),
        vacation: parseFloat(cups?.vacation ?? "0"),
      });
    }, 50);
    return () => clearTimeout(t);
  }, [cups?.love, cups?.food, cups?.rent, cups?.vacation]);

  const totalRep = (animated.love + animated.food + animated.rent + animated.vacation) * 2500;
  const isZen = !!satoshi;

  return (
    <div className={`rounded-2xl border ${isZen ? "border-mempool-orange/60 shadow-[0_0_40px_rgba(249,115,22,0.15)]" : "border-mempool-border"} bg-mempool-bg-elev p-3 sm:p-5`}>
      {/* Header strip — tier + total + Zen badge */}
      <div className="flex flex-wrap items-center justify-between gap-2 mb-4">
        <div>
          <p className="text-[10px] uppercase tracking-widest text-mempool-text-dim">Soulbound Identity</p>
          <p className="text-sm text-mempool-text mt-0.5">
            <span className="text-mempool-text-dim">Tier:</span>{" "}
            <span className={`font-bold ${isZen ? "text-mempool-orange" : "text-mempool-blue"}`}>
              {tier ?? "OMNI"}
            </span>
            {isZen && <span className="ml-2 text-mempool-orange">★ Satoshi</span>}
          </p>
        </div>
        <div className="text-right">
          <p className="text-[10px] uppercase tracking-widest text-mempool-text-dim">Reputation</p>
          <p className={`text-lg sm:text-2xl font-mono font-bold ${isZen ? "text-mempool-orange" : "text-mempool-text"}`}>
            {Math.round(totalRep).toLocaleString()}
            <span className="text-xs text-mempool-text-dim ml-1">/ 1M</span>
          </p>
        </div>
      </div>

      {/* 4 cards grid */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
        {SOULBOUND_HERO.map((d) => {
          const val = animated[d.tier.toLowerCase() as "love"|"food"|"rent"|"vacation"];
          const pct = Math.min(100, Math.max(0, val));
          const filled = pct >= 99.9;
          return (
            <div
              key={d.tier}
              className={`relative overflow-hidden rounded-xl border border-mempool-border/50 bg-gradient-to-br ${d.gradient} p-4 transition-all hover:scale-[1.02] hover:border-mempool-border ${filled ? `ring-2 ${d.ring}` : ""}`}
            >
              {/* Filled-checkmark in corner when 100/100 */}
              {filled && (
                <div className="absolute top-2 right-2 text-mempool-orange text-xs">✓ MAX</div>
              )}

              {/* Emoji + label */}
              <div className="flex items-baseline justify-between mb-2">
                <div className="flex items-center gap-2">
                  <span className="text-2xl">{d.emoji}</span>
                  <div>
                    <p className="text-xs font-bold tracking-wider text-mempool-text">{d.label}</p>
                    <p className="text-[9px] text-mempool-text-dim">{d.subtitle}</p>
                  </div>
                </div>
              </div>

              {/* Big animated value */}
              <div className="flex items-baseline gap-1 mb-2">
                <span className="text-xl sm:text-3xl font-mono font-bold text-mempool-text tabular-nums">
                  {val.toFixed(2)}
                </span>
                <span className="text-xs text-mempool-text-dim">/ 100</span>
              </div>

              {/* Animated progress bar */}
              <div className="h-2 rounded-full bg-mempool-bg/80 overflow-hidden">
                <div
                  className={`h-full rounded-full bg-gradient-to-r ${d.bar} transition-all duration-1000 ease-out`}
                  style={{ width: `${pct}%` }}
                />
              </div>

              {/* Tiny subtle pulse when at 100 */}
              {filled && (
                <div className={`absolute inset-0 pointer-events-none rounded-xl bg-gradient-to-r ${d.bar} opacity-5 animate-pulse`} />
              )}
            </div>
          );
        })}
      </div>

      {/* Footer hint */}
      <p className="text-[10px] text-mempool-text-dim/60 mt-3 text-center">
        Earn rewards by mining, staking, oracle pushes, agent decisions, uptime &amp; longevity.
        Hit <span className="text-mempool-orange">100/100</span> in all four → unlock the Satoshi badge (Zen tier).
      </p>
    </div>
  );
}

// ── RewardsBreakdownPanel ────────────────────────────────────────────────────
// Shows the user EXACTLY how each soulbound cup is earned (and what costs them).
// Mirrors the constants in core/reputation.zig — keep in sync if those change.
//
// All values are in "stored" units (×100). Display dividing by 100 to show OMNI-ish
// fractional points. CUP_CAP = 10000 stored = 100.00 displayed.

const REWARD_RULES: Record<string, {
  label: string; emoji: string; color: string;
  earn: { what: string; per: string; pts: string }[];
  penalty?: { what: string; pts: string }[];
}> = {
  LOVE: {
    label: "LOVE — Uptime & loyalty",
    emoji: "❤️",
    color: "text-mempool-purple",
    earn: [
      { what: "Online minute (heartbeat)",        per: "per minute",   pts: "+0.01" },
      { what: "Daily streak (24h continuous)",     per: "per day",      pts: "+0.50" },
      { what: "Weekly clean (no violations)",      per: "per week",     pts: "+2.00" },
    ],
    penalty: [
      { what: "Inactivity decay (after 7d offline)", pts: "−0.10/day" },
    ],
  },
  FOOD: {
    label: "FOOD — Useful work",
    emoji: "🥖",
    color: "text-mempool-green",
    earn: [
      { what: "Block mined",                       per: "per block",    pts: "+1.00" },
      { what: "PoUW work report (ML/research)",    per: "per report",   pts: "+0.50" },
      { what: "Oracle price push",                 per: "per update",   pts: "+0.20" },
      { what: "Agent decision (validated)",        per: "per decision", pts: "+0.30" },
      { what: "Arbitrage profit reported",         per: "per fill",     pts: "+0.40" },
    ],
    penalty: [
      { what: "Invalid PoUW/oracle report",         pts: "−1.00" },
    ],
  },
  RENT: {
    label: "RENT — Capital committed",
    emoji: "🏠",
    color: "text-mempool-orange",
    earn: [
      { what: "OMNI staked (per OMNI × day)",      per: "per OMNI/day", pts: "+0.01" },
      { what: "LP liquidity (per OMNI × day)",     per: "per OMNI/day", pts: "+0.02" },
      { what: "Hold > 90d (long-term lock)",       per: "per OMNI/day", pts: "+0.005" },
    ],
    penalty: [
      { what: "Stake withdrawn before maturity",    pts: "−5.00" },
    ],
  },
  VACATION: {
    label: "VACATION — Longevity",
    emoji: "🏖️",
    color: "text-mempool-text",
    earn: [
      { what: "Day on network (since first activity)", per: "per day", pts: "+0.10" },
      { what: "Year milestone (365d, 730d…)",      per: "per year",     pts: "+5.00" },
    ],
  },
};

function RewardsBreakdownPanel({ cups }: { cups?: { love: string; food: string; rent: string; vacation: string } }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="mt-3 rounded-lg bg-mempool-bg/60 border border-mempool-border/40">
      <button
        onClick={() => setOpen(v => !v)}
        className="w-full text-left px-3 py-2 flex items-center justify-between hover:bg-mempool-bg-light/30 transition-colors rounded-lg"
      >
        <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          🎁 How rewards are earned (4 domains)
        </span>
        <span className="text-[10px] text-mempool-text-dim">{open ? "▾" : "▸"}</span>
      </button>
      {open && (
        <div className="px-3 pb-3 space-y-3">
          {(["LOVE", "FOOD", "RENT", "VACATION"] as const).map((tier) => {
            const r = REWARD_RULES[tier];
            const cup = cups?.[tier.toLowerCase() as "love"|"food"|"rent"|"vacation"] ?? "0.00";
            const cupVal = parseFloat(cup);
            const pct = Math.min(100, Math.max(0, cupVal));
            return (
              <div key={tier} className="rounded bg-mempool-bg-elev/60 p-2.5 border border-mempool-border/30">
                <div className="flex items-center justify-between mb-1.5">
                  <span className={`text-[10px] font-semibold ${r.color}`}>
                    {r.emoji} {r.label}
                  </span>
                  <span className="text-[10px] font-mono text-mempool-text-dim">
                    {cup}/100
                  </span>
                </div>
                {/* progress bar */}
                <div className="h-1 rounded-full bg-mempool-bg overflow-hidden mb-2">
                  <div
                    className={`h-full transition-all ${
                      tier === "LOVE"     ? "bg-mempool-purple" :
                      tier === "FOOD"     ? "bg-mempool-green" :
                      tier === "RENT"     ? "bg-mempool-orange" :
                                            "bg-gray-400"
                    }`}
                    style={{ width: `${pct}%` }}
                  />
                </div>
                <div className="space-y-1">
                  {r.earn.map((rule) => (
                    <div key={rule.what} className="flex items-center justify-between text-[9px]">
                      <span className="text-mempool-text-dim">
                        {rule.what} <span className="text-mempool-text-dim/50">({rule.per})</span>
                      </span>
                      <span className="font-mono text-mempool-green font-semibold">{rule.pts}</span>
                    </div>
                  ))}
                  {r.penalty && r.penalty.map((p, i) => (
                    <div key={`p${i}`} className="flex items-center justify-between text-[9px]">
                      <span className="text-mempool-text-dim/80">{p.what}</span>
                      <span className="font-mono text-red-400 font-semibold">{p.pts}</span>
                    </div>
                  ))}
                </div>
              </div>
            );
          })}
          <p className="text-[9px] text-mempool-text-dim/60 leading-relaxed">
            Toate paharele se umplu până la <span className="text-mempool-text">100/100</span>.
            Reputația totală agregată e <span className="text-mempool-text">0–1,000,000</span>.
            Când ai 100 în toate 4 → <span className="text-mempool-orange">Satoshi badge (Zen tier)</span>.
            Sursă: <code className="text-mempool-blue">core/reputation.zig</code>
          </p>
        </div>
      )}
    </div>
  );
}

// ── PqAttestButton ───────────────────────────────────────────────────────────
// One-click "Register Identity" — builds + signs pq_attest_v1 TX and sends
// via sendpqattest RPC. First-claim wins on chain.

function PqAttestButton({ unlocked }: { unlocked: import("../../api/wallet-keystore").Unlocked }) {
  const [status, setStatus] = useState<"idle"|"checking"|"sending"|"ok"|"err"|"already">("checking");
  const [msg, setMsg] = useState("");
  const [txid, setTxid] = useState("");

  // On mount: check if this address already has a pq_attest registered on-chain.
  // If yes, hide the button — first-claim wins, no need to retry.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        // Local cache — instant feedback if user just attested.
        const cached = localStorage.getItem(`pqAttest:${unlocked.address}`);
        if (cached) {
          if (!cancelled) {
            setStatus("already");
            setTxid(cached);
          }
          return;
        }
        // Authoritative check via chain RPC.
        const res: any = await rpc.request_raw("getpqidentity", [unlocked.address]);
        if (!cancelled && res && res.omni_address) {
          setStatus("already");
          setTxid(res.attest_tx ?? "");
          localStorage.setItem(`pqAttest:${unlocked.address}`, res.attest_tx ?? "registered");
        } else if (!cancelled) {
          setStatus("idle");
        }
      } catch {
        if (!cancelled) setStatus("idle");
      }
    })();
    return () => { cancelled = true; };
  }, [unlocked.address]);

  async function register() {
    if (status === "sending" || status === "ok" || status === "already") return; // hard guard
    if (!unlocked.soulboundAddresses || !unlocked.privateKey) return;
    const sb = unlocked.soulboundAddresses;
    const love     = sb.find(s => s.tier === "LOVE")?.address     ?? "";
    const food     = sb.find(s => s.tier === "FOOD")?.address     ?? "";
    const rent     = sb.find(s => s.tier === "RENT")?.address     ?? "";
    const vacation = sb.find(s => s.tier === "VACATION")?.address ?? "";
    if (!love || !food || !rent || !vacation) { setMsg("Adresele soulbound lipsesc"); setStatus("err"); return; }

    const mc = unlocked.multichainAddresses;
    const btc = mc?.find(a => a.chain === "BTC_NATIVE")?.address ?? "";
    const eth = mc?.find(a => a.chain === "ETH")?.address ?? "";

    setStatus("sending");
    try {
      const payload = buildPqAttestPayload({
        privateKey: unlocked.privateKey,
        from: unlocked.address,
        love, food, rent, vacation, btc, eth,
        nonce: nextNonce(),
      });
      const res: any = await rpc.request_raw("sendpqattest", [payload]);
      if (res && (res.status === "queued" || res.txid)) {
        setStatus("ok");
        const tx = res.txid ?? "";
        setTxid(tx);
        setMsg(`TX queued: ${tx.slice(0, 16)}…`);
        // Persist so a re-render doesn't bring the button back.
        localStorage.setItem(`pqAttest:${unlocked.address}`, tx || "queued");
      } else if (res?.error?.code === -32001 || (res?.error?.message ?? "").includes("already")) {
        // First-claim violation — treat as "already registered"
        setStatus("already");
        localStorage.setItem(`pqAttest:${unlocked.address}`, "already");
      } else {
        setStatus("err");
        setMsg(res?.error?.message ?? "TX rejected by node");
      }
    } catch (e: any) {
      const errMsg = e?.message ?? "Eroare";
      // The chain may return error -32001 inside the thrown RPC error.
      if (errMsg.includes("already") || errMsg.includes("first-claim")) {
        setStatus("already");
        localStorage.setItem(`pqAttest:${unlocked.address}`, "already");
        return;
      }
      setStatus("err");
      setMsg(errMsg);
    }
  }

  if (status === "checking") return (
    <div className="mt-2 text-[9px] text-mempool-text-dim/60 italic">
      Checking identity status…
    </div>
  );

  if (status === "already") return (
    <div className="mt-2 text-[9px] text-mempool-green font-semibold">
      ✓ Identitate deja înregistrată on-chain {txid && `· TX: ${txid.slice(0, 16)}…`}
    </div>
  );

  if (status === "ok") return (
    <div className="mt-2 text-[9px] text-mempool-green font-semibold">
      ✓ Identitate înregistrată on-chain · {msg}
    </div>
  );

  return (
    <div className="mt-2 flex items-center gap-2">
      <button
        type="button"
        onClick={register}
        disabled={status === "sending"}
        className="text-[9px] px-2.5 py-1 rounded bg-mempool-blue/20 border border-mempool-blue/40 text-mempool-blue hover:bg-mempool-blue/30 disabled:opacity-50 font-semibold"
      >
        {status === "sending" ? "Se trimite…" : "🔐 Register Identity (pq_attest)"}
      </button>
      {status === "err" && <span className="text-[9px] text-red-400">{msg}</span>}
    </div>
  );
}

const SOULBOUND_COLORS: Record<string, { text: string; dot: string; emoji: string; desc: string }> = {
  LOVE:     { text: "text-mempool-purple", dot: "bg-mempool-purple", emoji: "❤️",  desc: "Uptime · mining · continuitate" },
  FOOD:     { text: "text-mempool-green",  dot: "bg-mempool-green",  emoji: "🥖", desc: "Muncă utilă · tranzacții · oracle" },
  RENT:     { text: "text-mempool-orange", dot: "bg-mempool-orange", emoji: "🏠", desc: "Capital angajat · staking · holding" },
  VACATION: { text: "text-mempool-text",   dot: "bg-gray-400",       emoji: "🏖️", desc: "Longevitate · zile active pe rețea" },
};

function SoulboundCard({
  tier, prefix, address, algo, bits, repCup,
}: {
  tier: string; prefix: string; address: string; algo: string; bits: number; repCup?: string;
}) {
  const [expanded, setExpanded] = useState(false);
  const [copied, setCopied] = useState(false);
  const [balanceSat, setBalanceSat] = useState<number | null>(null);
  const meta = SOULBOUND_COLORS[tier] ?? { text: "text-white", dot: "bg-gray-400", emoji: "🔒", desc: "" };
  const cupVal = parseFloat(repCup ?? "0");
  const hasAddr = address && !address.includes("<");

  useEffect(() => {
    if (!hasAddr) return;
    let cancelled = false;
    const poll = async () => {
      try {
        const r = await rpc.getAddressBalance(address);
        if (!cancelled && r && typeof r.balance === "number") setBalanceSat(r.balance);
      } catch {}
    };
    void poll();
    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", () => { void poll(); });
    const id = setInterval(() => { void poll(); }, 60_000);
    return () => { cancelled = true; clearInterval(id); unsub(); };
  }, [address, hasAddr]);

  return (
    <div className="bg-mempool-bg rounded-lg border border-mempool-border/40 overflow-hidden">
      <button
        type="button"
        onClick={() => setExpanded((v) => !v)}
        className="w-full p-2.5 hover:bg-mempool-bg-light transition-colors text-left"
      >
        <div className="flex items-center gap-2">
          <span className={`w-1.5 h-1.5 rounded-full flex-shrink-0 ${meta.dot}`} />
          <span className={`text-[10px] font-bold uppercase w-16 flex-shrink-0 ${meta.text}`}>{tier}</span>
          <span className="text-[9px] bg-red-500/20 text-red-300 px-1.5 py-0.5 rounded font-semibold">SOULBOUND</span>
          <span className={`font-mono text-[10px] flex-1 truncate ${meta.text}`}>
            {hasAddr ? `${midTrunc(address, 12, 6)}` : `${prefix}…`}
          </span>
          {balanceSat !== null && balanceSat > 0 && (
            <span className="text-[9px] font-mono text-mempool-green font-semibold">
              {(balanceSat / SAT_PER_OMNI).toFixed(4)} OMNI
            </span>
          )}
          <span className="text-[9px] text-mempool-text-dim">{bits}-bit</span>
          <span className="text-[9px] text-mempool-text-dim">{expanded ? "▾" : "▸"}</span>
        </div>
      </button>
      {expanded && (
        <div className="px-3 pb-3 pt-1 space-y-1.5 border-t border-mempool-border/30 bg-gray-900/40">
          <div className="flex gap-2 text-[10px]">
            <span className="text-mempool-text-dim w-20">Algorithm</span>
            <span className={meta.text}>{algo} ({bits}-bit)</span>
          </div>
          <div className="flex gap-2 text-[10px]">
            <span className="text-mempool-text-dim w-20">Rol</span>
            <span className="text-mempool-text-dim">{meta.desc}</span>
          </div>
          {repCup !== undefined && (
            <div className="flex gap-2 text-[10px] items-center">
              <span className="text-mempool-text-dim w-20">Reputație</span>
              <span className={`font-mono font-semibold ${meta.text}`}>{repCup}/100</span>
              <div className="flex-1 h-1 bg-mempool-bg-elev rounded overflow-hidden">
                <div className={`h-full ${meta.dot}/60`} style={{ width: `${Math.min(cupVal,100)}%` }} />
              </div>
            </div>
          )}
          {hasAddr && (
            <div className="space-y-1">
              <div className="flex items-center gap-1 bg-mempool-bg-elev rounded px-2 py-1.5">
                <span className={`font-mono text-[10px] flex-1 break-all ${meta.text}`}>{address}</span>
                <button
                  type="button"
                  onClick={() => { navigator.clipboard.writeText(address); setCopied(true); setTimeout(() => setCopied(false), 2000); }}
                  className="text-[9px] px-1.5 py-0.5 bg-mempool-bg rounded text-mempool-text-dim hover:text-mempool-text"
                >
                  {copied ? "✓" : "copy"}
                </button>
              </div>
              <div className="flex items-center justify-between px-2 py-1 bg-mempool-bg-elev rounded text-[10px]">
                <span className="text-mempool-text-dim uppercase tracking-wider">Rewards acumulate</span>
                <span className="font-mono text-mempool-green font-semibold">
                  {balanceSat !== null ? `${(balanceSat / SAT_PER_OMNI).toFixed(8)} OMNI` : "…"}
                </span>
              </div>
            </div>
          )}
          <p className="text-[9px] text-red-300/70 pt-1">
            🔒 Chain blochează orice TX outbound din această adresă. Fondurile sunt permanente — primești rewards, nu poți trimite.
          </p>
        </div>
      )}
    </div>
  );
}

function PQDomainCard({
  pq,
  repCup,
  repTier,
  repTotal,
}: {
  pq: typeof PQ_DOMAINS[number];
  repCup: string | undefined;
  repTier: string | undefined;
  repTotal: number | undefined;
}) {
  const [expanded, setExpanded] = useState(false);
  const cupValue = parseFloat(repCup ?? "0");
  const isCurrentTier = repTier === pq.tier;

  return (
    <div className="bg-mempool-bg rounded-lg border border-mempool-border/40 overflow-hidden">
      <button
        type="button"
        onClick={() => setExpanded((v) => !v)}
        className="w-full p-2.5 hover:bg-mempool-bg-light transition-colors text-left"
        title={`${pq.tier} cup — ${pq.algo} (${pq.bits}-bit)`}
      >
        <div className="flex items-center justify-between gap-2">
          <span className={`text-xs font-mono ${pq.color} flex items-center gap-2`}>
            <span className="text-base leading-none">{pq.emoji}</span>
            <span className="font-semibold">{pq.tier}</span>
            <span className="text-mempool-text-dim/70">·</span>
            <span>{pq.prefix}…</span>
            {isCurrentTier && (
              <span className="ml-1 text-[9px] uppercase tracking-wider bg-mempool-blue/20 text-mempool-blue px-1.5 py-0.5 rounded">Current tier</span>
            )}
          </span>
          <span className="text-[10px] text-mempool-text-dim flex items-center gap-2">
            {repCup !== undefined && (
              <span className="font-mono font-semibold text-mempool-text">{repCup}/100</span>
            )}
            <span>{expanded ? "▾" : "▸"}</span>
          </span>
        </div>
      </button>

      {expanded && (
        <div className="px-3 pb-3 pt-1 space-y-2 text-[11px] border-t border-mempool-border/30">
          <div className="grid grid-cols-2 gap-2 text-mempool-text-dim">
            <div>
              <div className="uppercase text-[9px] text-mempool-text-dim/60">Algorithm</div>
              <div className="text-mempool-text">{pq.algo}</div>
            </div>
            <div>
              <div className="uppercase text-[9px] text-mempool-text-dim/60">Security</div>
              <div className="text-mempool-text">{pq.bits}-bit</div>
            </div>
            <div>
              <div className="uppercase text-[9px] text-mempool-text-dim/60">Address prefix</div>
              <div className="text-mempool-text font-mono">{pq.prefix}…</div>
            </div>
            <div>
              <div className="uppercase text-[9px] text-mempool-text-dim/60">Reputation cup</div>
              <div className="text-mempool-text">
                {repCup ?? "0.00"} / 100
                {repTotal !== undefined && (
                  <span className="text-mempool-text-dim/70"> · total {repTotal.toLocaleString()}</span>
                )}
              </div>
            </div>
          </div>

          {/* Cup-specific description */}
          <div className="text-mempool-text-dim italic text-[10px]">
            {pq.tier === "LOVE" && "Uptime + continuitate — fed by every block your node sees online."}
            {pq.tier === "FOOD" && "Useful work — mining, oracle reports, agent tasks."}
            {pq.tier === "RENT" && "Capital committed — staking, LP positions, long-term holding."}
            {pq.tier === "VACATION" && "Network longevity — cumulative days active on chain."}
          </div>

          {/* Cup score bar */}
          <div className="h-1.5 bg-mempool-bg-elev rounded overflow-hidden">
            <div
              className={`h-full ${pq.color.replace("text-", "bg-")}/60`}
              style={{ width: `${Math.min(cupValue, 100)}%` }}
            />
          </div>

          <div className="text-[9px] text-mempool-text-dim/60 pt-1 border-t border-mempool-border/30">
            Independent isolated wallet. Per the 5-mnemonic security model, the
            actual {pq.prefix}… address is derived from a separate seed phrase
            (see Isolated Wallets tab in the desktop app).
          </div>
        </div>
      )}
    </div>
  );
}

// ── PrimaryAddressCard ──────────────────────────────────────────────────────
//
// Expandable Bitcoin-style address card. Click anywhere on the row to copy
// the bech32; click the chevron / "Show details" to expand and see the full
// metadata bundle: balance, nonce, UTXO list (Bitcoin parity — each unspent
// output is listed with its TX hash + vout + amount, clickable to drill into
// the source TX), associated names, last-seen block.
function PrimaryAddressCard({
  address,
  name,
  balance,
  utxos,
  nonce,
  copied,
  onCopy,
}: {
  address: string;
  name: string | null;
  balance: { sat: number; omni: string };
  utxos: any[];
  nonce: number | null;
  copied: boolean;
  onCopy: () => void;
}) {
  const [expanded, setExpanded] = useState(false);
  void copied;
  return (
    <div className="bg-mempool-bg rounded-lg border border-mempool-border/40 overflow-hidden">
      <div className="p-3">
        <div className="flex items-center justify-between">
          <span className="text-[10px] text-mempool-text-dim uppercase flex items-center gap-1">
            <span>🔑</span>
            <span>Primary — OMNI (secp256k1 ECDSA, Bitcoin-compatible)</span>
          </span>
          <button
            type="button"
            onClick={() => setExpanded((v) => !v)}
            className="text-[10px] text-mempool-text-dim hover:text-mempool-text"
          >
            {expanded ? "Hide details ▾" : "Show details ▸"}
          </button>
        </div>
        <button
          type="button"
          onClick={onCopy}
          className="block text-left w-full mt-1"
          title="Click to copy address"
        >
          {name && (
            <p className="text-base font-bold text-mempool-blue">{name}</p>
          )}
          <p className={`font-mono break-all hover:text-mempool-orange ${name ? "text-[10px] text-mempool-text-dim" : "text-xs text-mempool-blue"}`}>
            {address}
          </p>
        </button>
      </div>

      {expanded && (
        <div className="border-t border-mempool-border/30 p-3 space-y-3 text-[11px]">
          {/* Balance + nonce summary */}
          <div className="grid grid-cols-3 gap-2">
            <div>
              <div className="uppercase text-[9px] text-mempool-text-dim/60">Balance</div>
              <div className="text-mempool-green font-mono font-semibold">{balance.omni}</div>
              <div className="text-[9px] text-mempool-text-dim">{balance.sat.toLocaleString()} SAT</div>
            </div>
            <div>
              <div className="uppercase text-[9px] text-mempool-text-dim/60">Nonce</div>
              <div className="text-mempool-blue font-mono font-semibold">{nonce ?? "—"}</div>
              <div className="text-[9px] text-mempool-text-dim">tx counter</div>
            </div>
            <div>
              <div className="uppercase text-[9px] text-mempool-text-dim/60">UTXOs</div>
              <div className="text-mempool-text font-mono font-semibold">{utxos.length}</div>
              <div className="text-[9px] text-mempool-text-dim">unspent outputs</div>
            </div>
          </div>

          {/* UTXO list — Bitcoin parity. Each row is a spendable output. */}
          {utxos.length > 0 && (
            <div>
              <div className="uppercase text-[9px] text-mempool-text-dim/60 mb-1">Unspent outputs (Bitcoin-style)</div>
              <div className="bg-mempool-bg-elev rounded p-2 max-h-48 overflow-y-auto space-y-1">
                {utxos.slice(0, 50).map((u: any, idx: number) => (
                  <div key={`${u.txid}-${u.vout ?? idx}`} className="flex items-center justify-between gap-2 text-[10px] font-mono">
                    <div className="flex-1 min-w-0">
                      {u.txid ? (
                        <TxHashLink txid={u.txid} truncate={{ left: 12, right: 6 }} />
                      ) : (
                        <span className="text-mempool-text-dim">(no txid)</span>
                      )}
                      <span className="text-mempool-text-dim/70"> #{u.vout ?? 0}</span>
                    </div>
                    <span className="text-mempool-text">{((u.amount ?? u.value ?? 0) / SAT_PER_OMNI).toFixed(4)} OMNI</span>
                  </div>
                ))}
                {utxos.length > 50 && (
                  <div className="text-[9px] text-mempool-text-dim text-center pt-1">
                    + {utxos.length - 50} more…
                  </div>
                )}
              </div>
            </div>
          )}

          <div className="text-[9px] text-mempool-text-dim/70 pt-1 border-t border-mempool-border/30">
            This is your secp256k1 ECDSA address — Bitcoin-compatible signature
            scheme. UTXO model: every payment you receive is an unspent output
            you can later combine into outgoing transactions, exactly like BTC.
          </div>
        </div>
      )}
    </div>
  );
}

// ── WalletMetadataPanel ─────────────────────────────────────────────────────
//
// OmniBus wallet identity in Bitcoin-wallet-export shape. Same JSON layout a
// classic BTC wallet uses (wallet_info / crypto / security / addresses[])
// but populated with OmniBus-native fields: 5 PQ schemes, OmniBus bech32
// prefixes (ob1q / ob_k1_ / ob_f5_ / ob_d5_ / ob_s3_), reputation snapshot,
// canonical genesis name. Click "Copy JSON" to grab it as a single payload
// for support tickets, backup auditing, etc. Private keys are NEVER
// included — only public material, exactly like an "xpub-only" export.
function WalletMetadataPanel({
  address,
  publicKey,
  privateKey,
  walletIndex,
  mnemonic,
  xprv,
  xpub,
  pqOmni,
  name,
  balance,
  nonce,
  utxoCount,
  reputation,
  chainName,
}: {
  address: string;
  publicKey: string;
  privateKey: string;
  walletIndex: number;
  mnemonic: string | undefined;
  xprv: string | undefined;
  xpub: string | undefined;
  pqOmni: PqOmniSlot[] | undefined;
  name: string | null;
  balance: { sat: number; omni: string };
  nonce: number | null;
  utxoCount: number;
  reputation: any;
  chainName: string;
}) {
  const [expanded, setExpanded] = useState(false);
  const [showSecrets, setShowSecrets] = useState(false);
  const [copiedField, setCopiedField] = useState<string | null>(null);

  const REDACTED = "•••••••••• click Show secrets to reveal ••••••••••";

  // Public-only metadata — safe to copy to clipboard / share with support.
  const safeMetadata = {
    wallet_info: {
      name: name ?? "(unnamed)",
      version: "1.0",
      network: chainName,
      genesis_name: name,
      created_via: "OmniBus BlockChain Explorer",
    },
    crypto: {
      derivation_path: `m/44'/777'/0'/0/${walletIndex}`,
      wallet_index: walletIndex,
      public_key: publicKey,
      xpub: xpub ?? "(unlock via mnemonic to expose)",
      // mnemonic / xprv intentionally absent from the safe payload.
    },
    security: {
      signing: "secp256k1 ECDSA (Bitcoin-compatible)",
      vault: "AES-GCM + PBKDF2-SHA256 (200k iters, browser-local)",
      compressed_pubkey: true,
    },
    chain_state: {
      balance_omni: balance.omni,
      balance_sat: balance.sat,
      nonce: nonce ?? 0,
      utxo_count: utxoCount,
    },
    reputation: reputation
      ? {
          tier: reputation.tier,
          total: reputation.total,
          satoshi_badge: reputation.satoshi_badge,
          cups: reputation.cups,
          uptime_blocks: reputation.uptime_blocks,
          blocks_mined: reputation.total_blocks_mined,
        }
      : null,
    addresses: [
      {
        addr: address,
        label: name ?? "Primary",
        scheme: "OMNI",
        algo: "secp256k1 ECDSA",
        bits: 256,
        prefix: "ob1q",
        type: "SegWit-compatible bech32 (Bitcoin parity)",
        transferable: true,
      },
      ...["LOVE", "FOOD", "RENT", "VACATION"].map((tier) => {
        const meta = PQ_DOMAINS.find((d) => d.tier === tier)!;
        return {
          addr: null,
          label: `${tier} (soulbound reputation cup)`,
          scheme: tier,
          algo: meta.algo,
          bits: meta.bits,
          prefix: meta.prefix,
          type: "Reputation domain (NOT transferable)",
          transferable: false,
        };
      }),
      // PQ-OMNI wallets — transferable, post-quantum protected, separate
      // from BTC-compatible primary. 4 algorithms, 4 distinct accounts.
      ...(pqOmni ?? []).map((slot) => {
        const m = PQ_OMNI_SCHEMES.find((s) => s.scheme === slot.scheme)!;
        return {
          addr: slot.address,
          label: `PQ-OMNI ${m.algo}`,
          scheme: slot.scheme,
          algo: m.algo,
          bits: m.bits,
          prefix: slot.prefix,
          type: "Transferable OMNI wallet, post-quantum signing",
          transferable: true,
          derivation_path: slot.derivationPath,
          public_key: slot.publicKey,
        };
      }),
    ],
  };

  // Full backup payload — only shown when the user explicitly clicks
  // "Show secrets". Includes mnemonic + xprv + raw privkey for paper backup.
  const backupMetadata = {
    ...safeMetadata,
    crypto: {
      ...safeMetadata.crypto,
      mnemonic: mnemonic ?? "(not available — unlocked from privkey/vault, not mnemonic)",
      private_key_hex: privateKey,
      xprv: xprv ?? "(not available — unlocked from privkey/vault)",
    },
  };

  const json = JSON.stringify(showSecrets ? backupMetadata : safeMetadata, null, 2);

  const copyToClipboard = (label: string, payload: string) => {
    navigator.clipboard.writeText(payload);
    setCopiedField(label);
    setTimeout(() => setCopiedField(null), 2000);
  };

  return (
    <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border overflow-hidden">
      <div className="px-3 sm:px-5 py-3 border-b border-mempool-border flex items-center justify-between">
        <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          Wallet metadata
          <span className="ml-2 text-[10px] text-mempool-text-dim normal-case tracking-normal">
            Bitcoin-export style · OmniBus-native fields
          </span>
        </h3>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => copyToClipboard("json", json)}
            className="text-[10px] px-2 py-1 bg-mempool-bg rounded hover:bg-mempool-bg-light text-mempool-text-dim hover:text-mempool-text"
          >
            {copiedField === "json" ? "Copied!" : "Copy JSON"}
          </button>
          <button
            type="button"
            onClick={() => setExpanded((v) => !v)}
            className="text-[10px] text-mempool-text-dim hover:text-mempool-text"
          >
            {expanded ? "Collapse ▾" : "Expand ▸"}
          </button>
        </div>
      </div>

      {expanded && (
        <div>
          {/* Backup secrets — explicit reveal with red warning */}
          <div className="px-3 sm:px-5 py-3 bg-red-500/5 border-b border-red-500/20">
            <div className="flex items-start justify-between gap-3">
              <div className="flex-1">
                <p className="text-[11px] font-semibold text-red-300">
                  ⚠ Backup material
                </p>
                <p className="text-[10px] text-mempool-text-dim mt-0.5 leading-relaxed">
                  Your mnemonic, extended private key (xprv) and raw private key
                  give full control of this wallet. Anyone with these can drain
                  every OMNI you own. Write the mnemonic on paper, store in 3
                  separate physical locations, never paste into a website you
                  don't fully control.
                </p>
              </div>
              <button
                type="button"
                onClick={() => setShowSecrets((v) => !v)}
                className={`text-[10px] px-3 py-1.5 rounded font-semibold whitespace-nowrap ${
                  showSecrets
                    ? "bg-red-500/30 text-red-200 hover:bg-red-500/40"
                    : "bg-mempool-bg text-mempool-text hover:bg-mempool-bg-light"
                }`}
              >
                {showSecrets ? "Hide secrets" : "Show secrets"}
              </button>
            </div>

            {showSecrets && (
              <div className="mt-3 space-y-2">
                <BackupRow
                  label="Mnemonic (12/24 words)"
                  value={mnemonic ?? "(not available — unlock via mnemonic to see)"}
                  copyable={!!mnemonic}
                  copyKey="mnemonic"
                  copiedField={copiedField}
                  onCopy={copyToClipboard}
                />
                <BackupRow
                  label="Extended private key (xprv, account level m/44'/777'/0')"
                  value={xprv ?? "(not available — unlock via mnemonic to see)"}
                  copyable={!!xprv}
                  copyKey="xprv"
                  copiedField={copiedField}
                  onCopy={copyToClipboard}
                />
                <BackupRow
                  label="Raw private key (leaf, hex)"
                  value={privateKey}
                  copyable
                  copyKey="privkey"
                  copiedField={copiedField}
                  onCopy={copyToClipboard}
                />
                <BackupRow
                  label="Extended public key (xpub, share-safe)"
                  value={xpub ?? "(not available — unlock via mnemonic to see)"}
                  copyable={!!xpub}
                  copyKey="xpub"
                  copiedField={copiedField}
                  onCopy={copyToClipboard}
                />
                {!mnemonic && (
                  <p className="text-[10px] text-amber-300 mt-2">
                    Mnemonic + xprv aren't in memory because you unlocked
                    from a private key or saved vault. To see them, log out
                    and unlock again with your 12/24 word phrase. Mnemonic
                    is held in RAM only and never persisted, so a page
                    reload also clears it.
                  </p>
                )}
              </div>
            )}
          </div>

          <pre className="p-4 text-[10px] text-mempool-text font-mono overflow-x-auto whitespace-pre max-h-96 overflow-y-auto leading-relaxed">
            {showSecrets ? json : json.replace(
              /(mnemonic|private_key_hex|xprv)":\s*"[^"]+"/g,
              `$1": "${REDACTED}"`,
            )}
          </pre>
        </div>
      )}
    </div>
  );
}

function BackupRow({
  label, value, copyable, copyKey, copiedField, onCopy,
}: {
  label: string;
  value: string;
  copyable: boolean;
  copyKey: string;
  copiedField: string | null;
  onCopy: (label: string, payload: string) => void;
}) {
  return (
    <div className="bg-mempool-bg rounded p-2.5">
      <div className="flex items-center justify-between gap-2 mb-1">
        <p className="text-[9px] uppercase tracking-wider text-mempool-text-dim">{label}</p>
        {copyable && (
          <button
            type="button"
            onClick={() => onCopy(copyKey, value)}
            className="text-[9px] px-2 py-0.5 bg-mempool-bg-elev rounded hover:bg-mempool-bg-light text-mempool-text-dim hover:text-mempool-text"
          >
            {copiedField === copyKey ? "Copied!" : "Copy"}
          </button>
        )}
      </div>
      <p className="text-[10px] font-mono text-mempool-text break-all leading-relaxed">{value}</p>
    </div>
  );
}

// ── MultichainPanel ─────────────────────────────────────────────────────────
// 24 multichain addresses grouped by network family (BTC / EVM / LTC / DOGE /
// BCH / OTHER). Collapsed by default, expand per group. Watch-only — copy only.

const CHAIN_COLORS: Record<string, string> = {
  BTC:   "text-amber-400",
  EVM:   "text-blue-400",
  LTC:   "text-gray-300",
  DOGE:  "text-yellow-300",
  BCH:   "text-green-400",
  OTHER: "text-mempool-text-dim",
};
const CHAIN_ICONS: Record<string, string> = {
  BTC: "₿", EVM: "Ξ", LTC: "Ł", DOGE: "Ð", BCH: "Ƀ", OTHER: "◈",
};

function MultichainPanel({ addresses }: { addresses: { chain: string; address: string; path: string; group: string }[] }) {
  const [openGroups, setOpenGroups] = useState<Record<string, boolean>>({});
  const [copied, setCopied] = useState<string | null>(null);
  const [balances, setBalances] = useState<Record<string, { native: string; symbol: string } | null>>({});
  const [refreshing, setRefreshing] = useState<string | null>(null);

  const groups = addresses.reduce((acc, a) => {
    (acc[a.group] ??= []).push(a);
    return acc;
  }, {} as Record<string, typeof addresses>);

  function copy(addr: string) {
    navigator.clipboard.writeText(addr);
    setCopied(addr);
    setTimeout(() => setCopied(null), 2000);
  }

  async function refreshBalance(chain: string, address: string) {
    setRefreshing(chain);
    try {
      const { fetchChainBalance } = await import("../../api/multichain-balances");
      const bal = await fetchChainBalance(chain, address);
      setBalances(b => ({ ...b, [chain]: bal ? { native: bal.native, symbol: bal.symbol } : null }));
    } catch {
      setBalances(b => ({ ...b, [chain]: null }));
    } finally {
      setRefreshing(null);
    }
  }

  // Auto-fetch balances when a group is opened — only chains we don't have yet.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { fetchChainBalance } = await import("../../api/multichain-balances");
      for (const [group, items] of Object.entries(groups)) {
        if (!openGroups[group]) continue;
        for (const { chain, address } of items) {
          if (cancelled) return;
          if (chain in balances) continue; // already fetched
          const bal = await fetchChainBalance(chain, address);
          if (cancelled) return;
          setBalances(b => ({ ...b, [chain]: bal ? { native: bal.native, symbol: bal.symbol } : null }));
        }
      }
    })();
    return () => { cancelled = true; };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [openGroups]);

  async function openSendLink(chain: string, address: string) {
    const { getSendDeepLink } = await import("../../api/multichain-balances");
    const url = getSendDeepLink(chain, address);
    window.open(url, "_blank", "noopener,noreferrer");
  }

  return (
    <div className="space-y-1.5">
      {Object.entries(groups).map(([group, items]) => (
        <div key={group} className="bg-mempool-bg rounded-lg border border-mempool-border/40 overflow-hidden">
          <button
            type="button"
            onClick={() => setOpenGroups(g => ({ ...g, [group]: !g[group] }))}
            className="w-full flex items-center gap-2 px-2.5 py-2 hover:bg-mempool-bg-light transition-colors text-left"
          >
            <span className={`text-[11px] font-bold w-5 text-center ${CHAIN_COLORS[group] ?? "text-white"}`}>
              {CHAIN_ICONS[group] ?? "◈"}
            </span>
            <span className={`text-[10px] font-bold w-14 ${CHAIN_COLORS[group] ?? "text-white"}`}>{group}</span>
            <span className="text-[9px] text-mempool-text-dim">{items.length} addresses</span>
            <span className="ml-auto text-[9px] text-mempool-text-dim">{openGroups[group] ? "▾" : "▸"}</span>
          </button>
          {openGroups[group] && (
            <div className="border-t border-mempool-border/30 bg-gray-900/40 divide-y divide-mempool-border/20">
              {items.map(({ chain, address }) => {
                const bal = balances[chain];
                const isLoading = refreshing === chain || !(chain in balances);
                return (
                  <div key={chain} className="px-2.5 py-2 text-[10px] space-y-1.5">
                    <div className="flex items-center gap-2">
                      <span className={`font-bold w-20 shrink-0 ${CHAIN_COLORS[group] ?? "text-white"}`}>{chain}</span>
                      <span className="font-mono text-mempool-text flex-1 truncate" title={address}>{address}</span>
                      <button
                        type="button"
                        onClick={() => copy(address)}
                        className="text-[8px] text-mempool-text-dim hover:text-mempool-text shrink-0 px-1"
                      >
                        {copied === address ? "✓" : "copy"}
                      </button>
                    </div>
                    <div className="flex items-center gap-2 ml-[5.5rem]">
                      <span className="text-[9px] text-mempool-text-dim">Balance:</span>
                      {isLoading ? (
                        <span className="text-[9px] text-mempool-text-dim/50 italic">loading…</span>
                      ) : bal ? (
                        <span className={`text-[9px] font-mono font-semibold ${parseFloat(bal.native) > 0 ? "text-mempool-green" : "text-mempool-text-dim"}`}>
                          {bal.native} {bal.symbol}
                        </span>
                      ) : (
                        <span className="text-[9px] text-mempool-text-dim/50">unavailable</span>
                      )}
                      <button
                        type="button"
                        onClick={() => refreshBalance(chain, address)}
                        disabled={refreshing === chain}
                        title="Refresh balance"
                        className="text-[8px] text-mempool-text-dim hover:text-mempool-blue ml-1 disabled:opacity-30"
                      >
                        ⟳
                      </button>
                      <button
                        type="button"
                        onClick={() => openSendLink(chain, address)}
                        title="Open this address in the chain's official block explorer (preview balance + history; signing happens in your wallet of choice)"
                        className="ml-auto text-[9px] px-2 py-0.5 rounded border border-mempool-blue/40 text-mempool-blue hover:bg-mempool-blue/10 transition-colors"
                      >
                        Send ↗
                      </button>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      ))}
      <p className="text-[9px] text-mempool-text-dim/60 mt-2 leading-relaxed">
        Balances pulled live from public block explorers (blockchair, etherscan, solscan etc).
        Send button opens the chain's explorer — to actually move funds, paste the address into your hardware wallet
        or chain-specific app. Cross-chain signing in this UI is on the roadmap.
      </p>
    </div>
  );
}

// ── AllAddressesPanel ───────────────────────────────────────────────────────
// Shows BIP-44 addresses m/44'/777'/0'/0/0 .. /0/18 in a collapsible list.
// The active wallet index is highlighted.

function AllAddressesPanel({
  addresses,
  currentIndex,
}: {
  addresses: { index: number; address: string; path: string }[];
  currentIndex: number;
}) {
  const [expanded, setExpanded] = useState(false);
  const [copied, setCopied] = useState<string | null>(null);

  function copy(addr: string) {
    navigator.clipboard.writeText(addr);
    setCopied(addr);
    setTimeout(() => setCopied(null), 2000);
  }

  return (
    <div>
      <button
        type="button"
        onClick={() => setExpanded((v) => !v)}
        className="flex items-center justify-between w-full text-left mb-1"
      >
        <span className="text-[10px] text-mempool-text-dim">{expanded ? "▾ Ascunde" : `▸ Arată toate ${addresses.length} adrese`}</span>
      </button>
      {expanded && (
        <div className="space-y-1">
          {addresses.map(({ index, address, path }) => (
            <div
              key={index}
              className={`flex items-center gap-2 rounded px-2 py-1 text-[10px] font-mono ${
                index === currentIndex
                  ? "bg-mempool-blue/10 border border-mempool-blue/30"
                  : "bg-mempool-bg"
              }`}
            >
              <span className="text-mempool-text-dim/60 w-5 text-right shrink-0">{index}</span>
              <span className="text-mempool-text flex-1 break-all">{address}</span>
              {index === currentIndex && (
                <span className="text-[8px] text-mempool-blue shrink-0">active</span>
              )}
              <button
                type="button"
                onClick={() => copy(address)}
                className="text-[8px] text-mempool-text-dim hover:text-mempool-text shrink-0"
              >
                {copied === address ? "✓" : "copy"}
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// ── PqSendForm ──────────────────────────────────────────────────────────────
//
// Send OMNI from a PQ-OMNI address using a real post-quantum signature.
// Flow: collect to+amount → fetch nonce → buildTxHash → pqSign → pq_send RPC.
// The secret key is RAM-only (from PqOmniSlot.secretKey, never persisted).

const PQ_OMNI_SCHEME_NAMES: Record<string, string> = {
  ml_dsa_87:    "pq_omni_ml_dsa",
  falcon_512:   "pq_omni_falcon",
  dilithium_5:  "pq_omni_dilithium",
  slh_dsa_256s: "pq_omni_slh_dsa",
};

function PqSendForm({ slot, balanceSat }: { slot: PqOmniSlot; balanceSat: number }) {
  const [to, setTo] = useState("");
  const [amountOmni, setAmountOmni] = useState("");
  const [status, setStatus] = useState<"idle" | "signing" | "sending" | "ok" | "err">("idle");
  const [txid, setTxid] = useState("");
  const [errMsg, setErrMsg] = useState("");

  const canSend = slot.secretKey.length > 0;

  async function handleSend() {
    setStatus("signing");
    setErrMsg("");
    setTxid("");
    try {
      const toAddr = to.trim();
      if (!toAddr) throw new Error("Destination address required");
      const amountSat = Math.round(parseFloat(amountOmni) * SAT_PER_OMNI);
      if (!amountSat || amountSat <= 0) throw new Error("Amount must be > 0");
      if (amountSat > balanceSat) throw new Error("Insufficient balance");

      // 1. Fetch nonce for this address
      const nonce: number = await rpc.getNonce(slot.address).catch(() => 0);

      const txId = Math.floor(Math.random() * 0x7fffffff);
      const timestamp = Math.floor(Date.now() / 1000);
      // PQ-OMNI scheme codes from core/transaction.zig: ml_dsa=5, falcon=6, dilithium=7, slh_dsa=8.
      // PQ_OMNI_SCHEME_NAMES key order matches that enum order, so +5 (not +9 = hybrid).
      const schemeCode = Object.keys(PQ_OMNI_SCHEME_NAMES).indexOf(slot.scheme) + 5;

      const { hexToBytes: hToB, bytesToHex: bToH, buildTxHash, pqSign } = await import("../../api/pq-sign");
      const pubKeyBytes: Uint8Array = hToB(slot.publicKey);

      // 3. Build canonical TX hash — must match core/transaction.zig:calculateHash()
      const msgHash = buildTxHash({
        id: txId,
        from: slot.address,
        to: toAddr,
        amount: amountSat,
        timestamp,
        nonce,
        schemeCode,
        publicKeyBytes: pubKeyBytes,
      });

      // 4. Sign with PQ key
      const secretKeyBytes: Uint8Array = hToB(slot.secretKey);
      const sigBytes: Uint8Array = await pqSign(slot.scheme, secretKeyBytes, msgHash);
      const sigHex: string = bToH(sigBytes);

      setStatus("sending");

      // 5. Submit to chain
      const schemeName = PQ_OMNI_SCHEME_NAMES[slot.scheme];
      const res = await rpc.pqSend({
        from: slot.address,
        to: toAddr,
        amount: amountSat,
        scheme: schemeName,
        signature: sigHex,
        public_key: slot.publicKey,
        id: txId,
        timestamp,
        nonce,
      });
      setTxid(res?.txid ?? res?.hash ?? "submitted");
      setStatus("ok");
    } catch (e: any) {
      setErrMsg(e?.message ?? String(e));
      setStatus("err");
    }
  }

  if (!canSend) {
    return (
      <div className="text-[9px] text-mempool-text-dim/60 bg-mempool-bg-elev rounded p-2">
        Secret key not in memory — unlock wallet from mnemonic to enable sending.
      </div>
    );
  }

  return (
    <div className="bg-mempool-bg-elev rounded p-2 space-y-2">
      <div className="text-[9px] uppercase tracking-wider text-mempool-text-dim">Send from this PQ-OMNI address</div>
      <div className="space-y-1.5">
        <input
          className="w-full text-[10px] font-mono bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-mempool-text placeholder:text-mempool-text-dim/40 focus:outline-none focus:border-mempool-blue"
          placeholder="Destination address (ob1q… or obk1_/obf5_/obd5_/obs3_…)"
          value={to}
          onChange={(e) => setTo(e.target.value)}
          disabled={status === "signing" || status === "sending"}
        />
        <div className="flex gap-2 items-center">
          <input
            className="flex-1 text-[10px] font-mono bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-mempool-text placeholder:text-mempool-text-dim/40 focus:outline-none focus:border-mempool-blue"
            placeholder="Amount (OMNI)"
            type="number"
            min="0"
            step="0.0001"
            value={amountOmni}
            onChange={(e) => setAmountOmni(e.target.value)}
            disabled={status === "signing" || status === "sending"}
          />
          <button
            type="button"
            onClick={handleSend}
            disabled={status === "signing" || status === "sending" || !to || !amountOmni}
            className="text-[10px] px-3 py-1 bg-mempool-blue rounded text-white font-semibold hover:bg-mempool-blue/80 disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
          >
            {status === "signing" ? "Signing…" : status === "sending" ? "Sending…" : "Send"}
          </button>
        </div>
      </div>
      {status === "ok" && (
        <div className="text-[9px] text-mempool-green font-mono break-all">
          TX submitted: {txid}
        </div>
      )}
      {status === "err" && (
        <div className="text-[9px] text-red-400 break-all">
          {errMsg}
        </div>
      )}
    </div>
  );
}

// ── PqOmniSlotCard ──────────────────────────────────────────────────────────
//
// One quantum-protected OMNI wallet slot (ML-DSA-87, Falcon-512, Dilithium-5,
// or SLH-DSA-256s). Click to expand: shows full address, balance pulled from
// chain (PQ-OMNI addresses ARE balanceable on-chain — the chain treats every
// `ob_q*_…` exactly like an `ob1q…` for receive). Sending from a PQ-OMNI
// requires the chain to verify a PQ signature (Phase 2 — backend) and the
// browser to produce one (Phase 3 — WASM signer). Until those land the Send
// button is disabled with a clear "coming soon" tooltip.
function PqOmniSlotCard({ slot }: { slot: PqOmniSlot }) {
  const meta = PQ_OMNI_SCHEMES.find((s) => s.scheme === slot.scheme)!;
  const [expanded, setExpanded] = useState(false);
  const [balanceSat, setBalanceSat] = useState<number | null>(null);
  const [copied, setCopied] = useState(false);

  // Pull balance for this PQ-OMNI address. Chain accepts any address as
  // a payee, so even before Phase 2 lands the receive side works — and we
  // want the user to see incoming OMNI immediately.
  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      try {
        const r = await rpc.getAddressBalance(slot.address);
        if (!cancelled && r && typeof r.balance === "number") {
          setBalanceSat(r.balance);
        }
      } catch { /* RPC may not exist on every node — silent fallback */ }
    };
    void refresh();
    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", () => { void refresh(); });
    const id = setInterval(() => { void refresh(); }, 60_000);
    return () => { cancelled = true; clearInterval(id); unsub(); };
  }, [slot.address]);

  const balanceOmni = balanceSat !== null ? (balanceSat / SAT_PER_OMNI).toFixed(4) : "—";

  return (
    <div className="bg-mempool-bg rounded-lg border border-mempool-border/40 overflow-hidden">
      <button
        type="button"
        onClick={() => setExpanded((v) => !v)}
        className="w-full p-2.5 hover:bg-mempool-bg-light transition-colors text-left"
      >
        <div className="flex items-center justify-between gap-2">
          <span className="text-xs font-mono text-mempool-text flex items-center gap-2">
            <span className="text-base leading-none">🛡</span>
            <span className="font-semibold text-mempool-blue">PQ-OMNI</span>
            <span className="text-mempool-text-dim/70">·</span>
            <span className="text-mempool-text-dim">{meta.algo}</span>
          </span>
          <span className="text-[10px] text-mempool-text-dim flex items-center gap-2">
            {balanceSat !== null && (
              <span className="font-mono text-mempool-green">{balanceOmni} OMNI</span>
            )}
            <span>{expanded ? "▾" : "▸"}</span>
          </span>
        </div>
        <p className="text-[10px] font-mono text-mempool-text-dim mt-1 break-all">
          {slot.address}
        </p>
      </button>

      {expanded && (
        <div className="px-3 pb-3 pt-1 space-y-2 text-[11px] border-t border-mempool-border/30">
          <div className="grid grid-cols-2 gap-2 text-mempool-text-dim">
            <div>
              <div className="uppercase text-[9px] text-mempool-text-dim/60">Algorithm</div>
              <div className="text-mempool-text">{meta.algo}</div>
            </div>
            <div>
              <div className="uppercase text-[9px] text-mempool-text-dim/60">Security</div>
              <div className="text-mempool-text">{meta.bits}-bit (post-quantum)</div>
            </div>
            <div>
              <div className="uppercase text-[9px] text-mempool-text-dim/60">Address prefix</div>
              <div className="text-mempool-text font-mono">{slot.prefix}</div>
            </div>
            <div>
              <div className="uppercase text-[9px] text-mempool-text-dim/60">BIP-44 path</div>
              <div className="text-mempool-text font-mono">{slot.derivationPath}</div>
            </div>
          </div>

          {/* Full address with copy */}
          <div className="bg-mempool-bg-elev rounded p-2">
            <div className="flex items-center justify-between gap-2 mb-1">
              <span className="text-[9px] uppercase tracking-wider text-mempool-text-dim">Receive address</span>
              <button
                type="button"
                onClick={() => {
                  navigator.clipboard.writeText(slot.address);
                  setCopied(true);
                  setTimeout(() => setCopied(false), 2000);
                }}
                className="text-[9px] px-2 py-0.5 bg-mempool-bg rounded hover:bg-mempool-bg-light text-mempool-text-dim hover:text-mempool-text"
              >
                {copied ? "Copied!" : "Copy"}
              </button>
            </div>
            <p className="text-[10px] font-mono text-mempool-text break-all">{slot.address}</p>
          </div>

          {/* Balance + send (send disabled until Phase 2/3) */}
          <div className="bg-mempool-bg-elev rounded p-2">
            <div className="flex items-center justify-between text-[10px]">
              <span className="text-mempool-text-dim uppercase tracking-wider">Balance</span>
              <span className="font-mono text-mempool-green font-semibold">{balanceOmni} OMNI</span>
            </div>
          </div>

          <PqSendForm slot={slot} balanceSat={balanceSat ?? 0} />

          <p className="text-[9px] text-mempool-text-dim/70">
            Phase-3 status: signing live (@noble/post-quantum), chain
            verifier live since the testnet deploy. Sending FROM this
            wallet uses {meta.algo} signatures end-to-end.
          </p>

          <div className="text-[9px] text-mempool-text-dim/70 pt-1 border-t border-mempool-border/30 leading-relaxed">
            This is a transferable OMNI wallet protected by post-quantum
            cryptography. Same chain semantics as your <span className="text-mempool-blue">ob1q…</span> primary
            (you can receive OMNI here today, exchanges can pay you here),
            but sending requires a {meta.algo} signature instead of secp256k1.
            Backup: same mnemonic as your primary OMNI — derived at{" "}
            <span className="font-mono">{slot.derivationPath}</span>. Lose the
            mnemonic, lose this wallet too.
          </div>

          <div className="text-[9px] text-mempool-text-dim/50 pt-1 border-t border-mempool-border/30">
            Public key (real {meta.algo}, hash160 → base58check → prefix
            recipe matching the chain verifier):
          </div>
          <div className="text-[8px] font-mono text-mempool-text-dim break-all bg-mempool-bg-elev rounded p-1.5 max-h-12 overflow-hidden">
            {slot.publicKey ? slot.publicKey.slice(0, 96) + (slot.publicKey.length > 96 ? "…" : "") : "(not derived)"}
          </div>
        </div>
      )}
    </div>
  );
}
