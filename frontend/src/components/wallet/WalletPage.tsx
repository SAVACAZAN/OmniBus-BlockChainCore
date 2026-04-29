import { useState, useEffect } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import OmniBusRpcClient from "../../api/rpc-client";
import { useWallet } from "../../api/use-wallet";
import { lockWallet } from "../../api/wallet-keystore";
import {
  useNamesOwnedBy,
  useNameForAddress,
  getPrimaryName,
  setPrimaryName,
  MAX_NAMES_PER_WALLET,
} from "../../api/use-names";
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

export function WalletPage() {
  const { state: chainState } = useBlockchain();
  const unlocked = useWallet(); // null when locked, { address, privateKey, publicKey, walletIndex } when unlocked
  const [balance, setBalance] = useState({ sat: 0, omni: "0.0000" });
  const [transactions, setTransactions] = useState<any[]>([]);
  const [sendTo, setSendTo] = useState("");
  const [sendAmount, setSendAmount] = useState("");
  const [sendFee, setSendFee] = useState("");
  const [sending, setSending] = useState(false);
  const [sendResult, setSendResult] = useState<{ ok: boolean; msg: string } | null>(null);
  const [copied, setCopied] = useState<string | null>(null);
  const [feeEstimate, setFeeEstimate] = useState<FeeEstimate | null>(null);
  const [walletNonce, setWalletNonce] = useState<number | null>(null);

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
      setSendResult({ ok: true, msg: `TX signed & sent: ${(txid || "").toString().slice(0, 24)}...` });
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
        <h2 className="text-lg font-bold text-mempool-text">My Wallet</h2>
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
              </p>
            )}
          </div>
        </div>

        {/* Addresses */}
        <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-5 space-y-4">
          <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
            Addresses (5 PQ Domains)
          </h3>

          {/* Primary address */}
          <div
            className="bg-mempool-bg rounded-lg p-3 cursor-pointer hover:bg-mempool-bg-light transition-colors"
            onClick={() => copyAddr(unlocked.address)}
          >
            <div className="flex items-center justify-between">
              <span className="text-[10px] text-mempool-text-dim uppercase flex items-center gap-1">
                <span>🔑</span>
                <span>Primary — OMNI (ML-DSA-87 + KEM)</span>
              </span>
              <span className="text-[10px] text-mempool-green">
                {copied === unlocked.address ? "Copied!" : "Click to copy"}
              </span>
            </div>
            <p className="text-xs font-mono text-mempool-blue mt-1 break-all">
              {unlocked.address}
            </p>
          </div>

          {/* PQ domain addresses — fiecare = 1 pahar reputation soulbound */}
          {PQ_DOMAINS.filter((pq) => pq.prefix !== "ob1q").map((pq) => {
            const addr = pq.prefix + unlocked.address.slice(unlocked.address.indexOf("_", 3) + 1);
            return (
              <div
                key={pq.prefix}
                className="bg-mempool-bg rounded-lg p-2.5 cursor-pointer hover:bg-mempool-bg-light transition-colors"
                onClick={() => copyAddr(addr)}
                title={`${pq.tier} cup — ${pq.algo} (${pq.bits}-bit). Click to copy ${pq.prefix} address.`}
              >
                <div className="flex items-center justify-between gap-2">
                  <span className={`text-xs font-mono ${pq.color} flex items-center gap-2`}>
                    <span className="text-base leading-none">{pq.emoji}</span>
                    <span className="font-semibold">{pq.tier}</span>
                    <span className="text-mempool-text-dim/70">·</span>
                    <span>{pq.prefix}...</span>
                  </span>
                  <span className="text-[10px] text-mempool-text-dim">
                    {pq.algo} ({pq.bits}b)
                  </span>
                </div>
              </div>
            );
          })}

          {/* Reputation legend — explica ce reprezinta paharele */}
          <div className="pt-2 border-t border-mempool-border/40 mt-2">
            <p className="text-[10px] text-mempool-text-dim leading-relaxed">
              <span className="font-semibold text-mempool-text">Reputation cups</span> (soulbound,
              0–100 each):{" "}
              <span title="Uptime + continuitate">❤️ LOVE</span>{" "}
              <span className="opacity-60">·</span>{" "}
              <span title="Work util — mining, oracle, agents">🥖 FOOD</span>{" "}
              <span className="opacity-60">·</span>{" "}
              <span title="Capital angajat — stake / LP / hold">🏠 RENT</span>{" "}
              <span className="opacity-60">·</span>{" "}
              <span title="Longevitate pe retea">🏖️ VACATION</span>{" "}
              <span className="opacity-60">·</span>{" "}
              <span className="text-mempool-orange/90">100/100/100/100 = Satoshi badge</span>
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

      {/* My .omnibus names — pick which one represents me globally */}
      <MyNamesPanel address={unlocked.address} />

      {/* Transaction History */}
      <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border overflow-hidden">
        <div className="px-5 py-3 border-b border-mempool-border">
          <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
            Transaction History
          </h3>
        </div>
        <div className="divide-y divide-mempool-border/30 max-h-96 overflow-y-auto">
          {transactions.length === 0 ? (
            <div className="px-5 py-8 text-center text-sm text-mempool-text-dim">
              No transactions yet. Mine blocks or receive OMNI to see history.
            </div>
          ) : (
            transactions.map((tx: any, i: number) => (
              <div key={tx.txid || i} className="px-5 py-3 flex items-center gap-3">
                <div className={`w-2 h-2 rounded-full flex-shrink-0 ${
                  tx.direction === "received" ? "bg-mempool-green" : "bg-mempool-orange"
                }`} />
                <div className="flex-1 min-w-0">
                  <p className="text-xs font-mono text-mempool-text truncate">
                    {tx.txid?.slice(0, 24)}...
                  </p>
                  <p className="text-[10px] text-mempool-text-dim">
                    {tx.from?.slice(0, 16)} -&gt; {tx.to?.slice(0, 16)}
                  </p>
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
                    tx.direction === "received" ? "text-mempool-green" : "text-mempool-orange"
                  }`}>
                    {tx.direction === "received" ? "+" : "-"}{((tx.amount || 0) / 1e9).toFixed(8)}
                  </p>
                  {tx.fee != null && tx.fee > 0 && (
                    <p className="text-[9px] text-mempool-text-dim font-mono">
                      fee: {tx.fee} SAT
                    </p>
                  )}
                </div>
              </div>
            ))
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
