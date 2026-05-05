import { useState, useEffect } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import OmniBusRpcClient from "../../api/rpc-client";
import { useWallet } from "../../api/use-wallet";
import { lockWallet, type PqOmniSlot, PQ_OMNI_SCHEMES } from "../../api/wallet-keystore";
import {
  useNamesOwnedBy,
  useNameForAddress,
  getPrimaryName,
  setPrimaryName,
  MAX_NAMES_PER_WALLET,
} from "../../api/use-names";
import { AddressLabel } from "../common/AddressLabel";
import { TxHashLink } from "../common/TxHashLink";
import type { FeeEstimate } from "../../types";

const rpc = new OmniBusRpcClient();

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
  const memo = (tx.op_return || "").toLowerCase();
  const isFromMe = tx.from && tx.from === myAddress;

  if (memo.startsWith("ns_claim:")) {
    return { label: "NS Claim", badgeClass: "bg-purple-500/20 text-purple-300", isCredit: false };
  }
  if (memo.startsWith("deposit:")) {
    return { label: "DEX Deposit", badgeClass: "bg-cyan-500/20 text-cyan-300", isCredit: !isFromMe };
  }
  if (memo.startsWith("withdraw:")) {
    return { label: "DEX Withdraw", badgeClass: "bg-cyan-500/20 text-cyan-300", isCredit: !isFromMe };
  }
  if (memo.startsWith("open_order:") || memo.startsWith("place_order:")) {
    return { label: "Open Order", badgeClass: "bg-blue-500/20 text-blue-300", isCredit: false };
  }
  if (memo.startsWith("close_order:") || memo.startsWith("cancel_order:")) {
    return { label: "Cancel Order", badgeClass: "bg-blue-500/20 text-blue-300", isCredit: true };
  }
  if (memo.startsWith("stake:") || memo.startsWith("delegate:")) {
    return { label: "Stake", badgeClass: "bg-amber-500/20 text-amber-300", isCredit: false };
  }
  if (memo.startsWith("unstake:") || memo.startsWith("undelegate:")) {
    return { label: "Unstake", badgeClass: "bg-amber-500/20 text-amber-300", isCredit: true };
  }
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
  const myName = useNameForAddress(unlocked?.address); // e.g. "savacazan.omnibus"
  const [balance, setBalance] = useState({ sat: 0, omni: "0.0000" });
  const [transactions, setTransactions] = useState<any[]>([]);
  const [sendTo, setSendTo] = useState("");
  const [sendAmount, setSendAmount] = useState("");
  const [sendFee, setSendFee] = useState("");
  const [sending, setSending] = useState(false);
  const [sendResult, setSendResult] = useState<{ ok: boolean; msg: string; txid?: string } | null>(null);
  const [copied, setCopied] = useState<string | null>(null);
  const [feeEstimate, setFeeEstimate] = useState<FeeEstimate | null>(null);
  const [walletNonce, setWalletNonce] = useState<number | null>(null);
  const [txFilter, setTxFilter] = useState<string>("All");
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
        const bal: any = await rpc.getBalance();
        setBalance({
          sat: bal?.balance || 0,
          omni: bal?.balanceOMNI || "0.0000",
        });
      } catch {}

      try {
        const listResult = await rpc.listTransactions(50);
        setTransactions(listResult?.transactions || []);
      } catch {
        try {
          const fallback = await rpc.request_raw("gettransactions");
          setTransactions(fallback?.transactions || []);
        } catch {}
      }

      try {
        const fee = await rpc.estimateFee();
        if (fee) setFeeEstimate(fee);
      } catch {}

      try {
        const nonceResult = await rpc.getNonce(unlocked.address);
        if (nonceResult && typeof nonceResult.nonce === "number") {
          setWalletNonce(nonceResult.nonce);
        } else if (typeof nonceResult === "number") {
          setWalletNonce(nonceResult);
        }
      } catch {}

      // Reputation cups for the OMNI address (love / food / rent / vacation).
      try {
        const rep: any = await rpc.request_raw("getreputation", [unlocked.address]);
        if (rep) setReputation(rep);
      } catch {}

      // UTXO list — Bitcoin-style "unspent outputs" the wallet can spend.
      // getbalance includes utxos[] in our chain (see core/rpc_server handlers).
      try {
        const bal: any = await rpc.getBalance();
        if (bal?.utxos) setUtxos(bal.utxos);
      } catch {}
    };
    refresh();
    const id = setInterval(refresh, 5000);
    return () => clearInterval(id);
  }, [unlocked]);

  const handleLogout = () => {
    // Disconnect the global session — every subscriber (this page, Exchange,
    // Names, Faucet, Reputation, Header pill) re-renders to its locked state.
    lockWallet();
  };

  const handleSend = async () => {
    if (!sendTo || !sendAmount) return;
    setSending(true);
    setSendResult(null);
    try {
      const amountSat = Math.floor(parseFloat(sendAmount) * 1e9);
      if (amountSat <= 0) throw new Error("Amount must be > 0");
      if (amountSat > balance.sat) throw new Error("Insufficient balance");
      const result: any = await rpc.sendTransaction(sendTo, amountSat);
      const txid = typeof result === "object" ? result?.txid : result;
      setSendResult({ ok: true, msg: `TX signed & sent`, txid: (txid || "").toString() });
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
      <div className="max-w-lg mx-auto px-4 py-12">
        <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-6 text-center space-y-4">
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
    <div className="max-w-4xl mx-auto px-4 py-6 space-y-6">
      {/* Header with logout */}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-lg font-bold text-mempool-text">My Wallet</h2>
          {myName && (
            <p className="text-xs text-mempool-blue font-semibold mt-0.5">{myName}</p>
          )}
        </div>
        <button
          onClick={handleLogout}
          className="text-xs text-mempool-text-dim hover:text-mempool-red transition-colors px-3 py-1.5 rounded border border-mempool-border hover:border-mempool-red"
        >
          Lock Wallet
        </button>
      </div>

      {/* Balance Card */}
      <div className="bg-gradient-to-br from-mempool-card to-mempool-bg-light rounded-xl border border-mempool-border p-6">
        <div className="flex items-center justify-between">
          <div>
            <p className="text-xs text-mempool-text-dim uppercase tracking-wider mb-1">Total Balance</p>
            <p className="text-4xl font-mono font-bold text-mempool-green">{balance.omni}</p>
            <p className="text-sm text-mempool-text-dim mt-1">
              OMNI = {balance.sat.toLocaleString()} SAT
            </p>
          </div>
          {walletNonce !== null && (
            <div className="text-right">
              <p className="text-[10px] text-mempool-text-dim uppercase">Nonce</p>
              <p className="text-lg font-mono text-mempool-blue">{walletNonce}</p>
            </div>
          )}
        </div>
      </div>

      {/* Two columns */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Send Transaction */}
        <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-5 space-y-4">
          <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
            Send OMNI
          </h3>
          <div className="space-y-3">
            <div>
              <label className="text-[10px] text-mempool-text-dim uppercase">Recipient Address</label>
              <input
                type="text"
                value={sendTo}
                onChange={(e) => setSendTo(e.target.value)}
                placeholder="ob1q..."
                className="w-full bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2.5 text-sm font-mono text-mempool-text placeholder-mempool-text-dim/40 focus:outline-none focus:border-mempool-blue mt-1"
              />
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
                <span className="text-mempool-blue">secp256k1 ECDSA</span>
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
        <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-5 space-y-4">
          <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
            Addresses
          </h3>

          {/* ── 1. OMNI Primary (secp256k1) ── */}
          <div>
            <p className="text-[9px] uppercase tracking-wider text-mempool-text-dim/60 mb-1.5">🔑 OMNI Primary — secp256k1 ECDSA (Bitcoin-compatible)</p>
            <PrimaryAddressCard
              address={unlocked.address}
              name={myName}
              balance={balance}
              utxos={utxos}
              nonce={walletNonce}
              copied={copied === unlocked.address}
              onCopy={() => copyAddr(unlocked.address)}
            />
            {copied === unlocked.address && (
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

          {/* ── 3. BIP-44 all addresses (index 0..18) ── */}
          {unlocked.allAddresses && unlocked.allAddresses.length > 0 && (
            <div className="pt-3 border-t border-mempool-border/40">
              <p className="text-[9px] uppercase tracking-wider text-mempool-text-dim/60 mb-1.5">
                📋 Toate adresele BIP-44 — m/44'/777'/0'/0/0..18
              </p>
              <AllAddressesPanel addresses={unlocked.allAddresses} currentIndex={unlocked.walletIndex} />
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
        address={unlocked.address}
        publicKey={unlocked.publicKey}
        privateKey={unlocked.privateKey}
        walletIndex={unlocked.walletIndex}
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
      <MyNamesPanel address={unlocked.address} />

      {/* Transaction History */}
      <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border overflow-hidden">
        <div className="px-5 py-3 border-b border-mempool-border flex flex-col gap-2">
          <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
            Transaction History
          </h3>
          {/* Type filter pills — driven by classifyTx() result. "All" shows
              everything, including types that may not be present yet. */}
          <div className="flex flex-wrap gap-1">
            {["All", "Sent", "Received", "Mining Reward", "NS Claim", "DEX Deposit", "DEX Withdraw", "Open Order", "Cancel Order", "Stake", "Unstake"].map((type) => {
              const count = type === "All"
                ? transactions.length
                : transactions.filter((t) => classifyTx(t, unlocked.address).label === type).length;
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
            <div className="px-5 py-8 text-center text-sm text-mempool-text-dim">
              No transactions yet. Mine blocks or receive OMNI to see history.
            </div>
          ) : (
            transactions
              .filter((tx) => txFilter === "All" || classifyTx(tx, unlocked.address).label === txFilter)
              .map((tx: any, i: number) => {
                const cls = classifyTx(tx, unlocked.address);
                return (
              <div key={tx.txid || i} className="px-5 py-3 flex items-center gap-3">
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
                    {tx.from && <AddressLabel address={tx.from} truncate={{ left: 12, right: 6 }} />} → {tx.to && <AddressLabel address={tx.to} truncate={{ left: 12, right: 6 }} />}
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
                    {cls.isCredit ? "+" : "-"}{((tx.amount || 0) / 1e9).toFixed(8)}
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
    <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-5 space-y-3">
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

// ── PQDomainCard ────────────────────────────────────────────────────────────
//
// Click to expand. Shows everything we know about this PQ domain for the
// current wallet: algorithm + bit strength, address prefix, reputation cup
// score (if any), and a placeholder for the actual ob_k1_/ob_f5_/ob_d5_/
// ob_s3_ address — those need the user to derive an isolated mnemonic per
// project_omnibus_5_isolated_wallets memory. For now we surface what we
// have; full multi-mnemonic UI is its own session.

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
  const meta = SOULBOUND_COLORS[tier] ?? { text: "text-white", dot: "bg-gray-400", emoji: "🔒", desc: "" };
  const cupVal = parseFloat(repCup ?? "0");
  const hasAddr = address && !address.includes("<");

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
            {hasAddr ? address : `${prefix}…`}
          </span>
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
                    <span className="text-mempool-text">{((u.amount ?? u.value ?? 0) / 1e9).toFixed(4)} OMNI</span>
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
      <div className="px-5 py-3 border-b border-mempool-border flex items-center justify-between">
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
          <div className="px-5 py-3 bg-red-500/5 border-b border-red-500/20">
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
      const amountSat = Math.round(parseFloat(amountOmni) * 1e9);
      if (!amountSat || amountSat <= 0) throw new Error("Amount must be > 0");
      if (amountSat > balanceSat) throw new Error("Insufficient balance");

      // 1. Fetch nonce for this address
      const nonceRes: any = await rpc.request_raw("getnonce", [slot.address]);
      const nonce: number = typeof nonceRes === "number" ? nonceRes
        : typeof nonceRes?.nonce === "number" ? nonceRes.nonce : 0;

      const txId = Math.floor(Math.random() * 0x7fffffff);
      const timestamp = Math.floor(Date.now() / 1000);
      const schemeCode = Object.keys(PQ_OMNI_SCHEME_NAMES).indexOf(slot.scheme) + 9;

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
        const r: any = await rpc.request_raw("getaddressbalance", [slot.address]);
        if (!cancelled && r && typeof r.balance === "number") {
          setBalanceSat(r.balance);
        }
      } catch { /* RPC may not exist on every node — silent fallback */ }
    };
    refresh();
    const id = setInterval(refresh, 8000);
    return () => { cancelled = true; clearInterval(id); };
  }, [slot.address]);

  const balanceOmni = balanceSat !== null ? (balanceSat / 1e9).toFixed(4) : "—";

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
