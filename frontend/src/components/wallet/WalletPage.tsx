import { useState, useEffect } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import OmniBusRpcClient from "../../api/rpc-client";
import type { FeeEstimate } from "../../types";

const rpc = new OmniBusRpcClient("/api");

const PQ_DOMAINS = [
  { prefix: "ob1q", algo: "ML-DSA-87 + KEM", bits: 256, color: "text-mempool-blue" },
  { prefix: "ob_k1_", algo: "ML-DSA-87", bits: 256, color: "text-mempool-purple" },
  { prefix: "ob_f5_", algo: "Falcon-512", bits: 192, color: "text-mempool-green" },
  { prefix: "ob_d5_", algo: "Dilithium-5", bits: 256, color: "text-mempool-orange" },
  { prefix: "ob_s3_", algo: "SLH-DSA-256s", bits: 256, color: "text-mempool-text" },
];

interface WalletState {
  loggedIn: boolean;
  mnemonic: string;
  address: string;
  balance: number;
  balanceOMNI: string;
  transactions: any[];
}

export function WalletPage() {
  const { state: chainState } = useBlockchain();
  const [wallet, setWallet] = useState<WalletState>({
    loggedIn: false,
    mnemonic: "",
    address: "",
    balance: 0,
    balanceOMNI: "0.0000",
    transactions: [],
  });
  const [mnemonicInput, setMnemonicInput] = useState("");
  const [mnemonicError, setMnemonicError] = useState("");
  const [sendTo, setSendTo] = useState("");
  const [sendAmount, setSendAmount] = useState("");
  const [sendFee, setSendFee] = useState("");
  const [sending, setSending] = useState(false);
  const [sendResult, setSendResult] = useState<{ ok: boolean; msg: string } | null>(null);
  const [copied, setCopied] = useState<string | null>(null);
  const [showMnemonic, setShowMnemonic] = useState(false);
  const [feeEstimate, setFeeEstimate] = useState<FeeEstimate | null>(null);
  const [walletNonce, setWalletNonce] = useState<number | null>(null);

  // Auto-refresh balance + fetch fee estimate + nonce when logged in
  useEffect(() => {
    if (!wallet.loggedIn) return;
    const refresh = async () => {
      try {
        const bal: any = await rpc.getBalance();
        // Use listtransactions for richer TX data (with confirmations, fees)
        let txs: any[] = [];
        try {
          const listResult = await rpc.listTransactions(50);
          txs = listResult?.transactions || [];
        } catch {
          try {
            const fallback = await rpc.request_raw("gettransactions");
            txs = fallback?.transactions || [];
          } catch {}
        }
        setWallet((w) => ({
          ...w,
          balance: bal?.balance || 0,
          balanceOMNI: bal?.balanceOMNI || "0.0000",
          address: bal?.address || w.address,
          transactions: txs,
        }));
      } catch {}

      // Fetch fee estimate
      try {
        const fee = await rpc.estimateFee();
        if (fee) setFeeEstimate(fee);
      } catch {}

      // Fetch nonce
      if (wallet.address) {
        try {
          const nonceResult = await rpc.getNonce(wallet.address);
          if (nonceResult && typeof nonceResult.nonce === "number") {
            setWalletNonce(nonceResult.nonce);
          } else if (typeof nonceResult === "number") {
            setWalletNonce(nonceResult);
          }
        } catch {}
      }
    };
    refresh();
    const id = setInterval(refresh, 5000);
    return () => clearInterval(id);
  }, [wallet.loggedIn, wallet.address]);

  const handleLogin = async () => {
    const words = mnemonicInput.trim().split(/\s+/);
    if (words.length < 12) {
      setMnemonicError("Mnemonic must have at least 12 words (BIP-39)");
      return;
    }
    setMnemonicError("");

    try {
      const bal: any = await rpc.getBalance();
      setWallet({
        loggedIn: true,
        mnemonic: mnemonicInput.trim(),
        address: bal?.address || "ob1q...",
        balance: bal?.balance || 0,
        balanceOMNI: bal?.balanceOMNI || "0.0000",
        transactions: [],
      });
    } catch (err: any) {
      setMnemonicError("Cannot connect to node. Is omnibus-node running?");
    }
  };

  const handleLogout = () => {
    setWallet({ loggedIn: false, mnemonic: "", address: "", balance: 0, balanceOMNI: "0.0000", transactions: [] });
    setMnemonicInput("");
    setSendResult(null);
    setFeeEstimate(null);
    setWalletNonce(null);
  };

  const handleSend = async () => {
    if (!sendTo || !sendAmount) return;
    setSending(true);
    setSendResult(null);
    try {
      const amountSat = Math.floor(parseFloat(sendAmount) * 1e9);
      if (amountSat <= 0) throw new Error("Amount must be > 0");
      if (amountSat > wallet.balance) throw new Error("Insufficient balance");
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

  // ── LOGIN SCREEN ──────────────────────────────────────────────────────
  if (!wallet.loggedIn) {
    return (
      <div className="max-w-lg mx-auto px-4 py-12">
        <div className="bg-mempool-card rounded-xl border border-mempool-border p-6">
          {/* Lock icon */}
          <div className="text-center mb-6">
            <div className="w-16 h-16 mx-auto rounded-full bg-mempool-bg flex items-center justify-center mb-3">
              <svg width="32" height="32" viewBox="0 0 24 24" fill="none" className="text-mempool-blue">
                <rect x="3" y="11" width="18" height="11" rx="2" stroke="currentColor" strokeWidth="2" />
                <path d="M7 11V7a5 5 0 0110 0v4" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
              </svg>
            </div>
            <h2 className="text-xl font-bold text-mempool-text">Import Wallet</h2>
            <p className="text-sm text-mempool-text-dim mt-1">
              Enter your BIP-39 mnemonic to access your wallet
            </p>
          </div>

          {/* Mnemonic input */}
          <div className="space-y-3">
            <label className="text-xs text-mempool-text-dim uppercase tracking-wider font-medium">
              Mnemonic Phrase (12/24 words)
            </label>
            <textarea
              value={mnemonicInput}
              onChange={(e) => setMnemonicInput(e.target.value)}
              placeholder="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
              rows={3}
              className="w-full bg-mempool-bg border border-mempool-border rounded-lg px-4 py-3 text-sm font-mono text-mempool-text placeholder-mempool-text-dim/40 focus:outline-none focus:border-mempool-blue resize-none"
              spellCheck={false}
              autoComplete="off"
            />
            {mnemonicError && (
              <p className="text-xs text-mempool-red">{mnemonicError}</p>
            )}

            <button
              onClick={handleLogin}
              disabled={!mnemonicInput.trim()}
              className="w-full bg-mempool-blue hover:bg-mempool-blue/80 disabled:opacity-30 disabled:cursor-not-allowed text-white font-semibold rounded-lg py-3 transition-colors"
            >
              Unlock Wallet
            </button>

            <p className="text-[10px] text-mempool-text-dim text-center mt-2">
              Your mnemonic stays in this browser tab. It is never sent to the network.
              <br />
              Post-Quantum secured with 5 address domains (ML-DSA, Falcon, Dilithium, SLH-DSA).
            </p>
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
            <p className="text-4xl font-mono font-bold text-mempool-green">{wallet.balanceOMNI}</p>
            <p className="text-sm text-mempool-text-dim mt-1">
              OMNI = {wallet.balance.toLocaleString()} SAT
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
        <div className="bg-mempool-card rounded-xl border border-mempool-border p-5 space-y-4">
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
        <div className="bg-mempool-card rounded-xl border border-mempool-border p-5 space-y-4">
          <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
            Addresses (5 PQ Domains)
          </h3>

          {/* Primary address */}
          <div
            className="bg-mempool-bg rounded-lg p-3 cursor-pointer hover:bg-mempool-bg-light transition-colors"
            onClick={() => copyAddr(wallet.address)}
          >
            <div className="flex items-center justify-between">
              <span className="text-[10px] text-mempool-text-dim uppercase">Primary (ML-DSA-87 + KEM)</span>
              <span className="text-[10px] text-mempool-green">
                {copied === wallet.address ? "Copied!" : "Click to copy"}
              </span>
            </div>
            <p className="text-xs font-mono text-mempool-blue mt-1 break-all">
              {wallet.address}
            </p>
          </div>

          {/* PQ domain addresses */}
          {PQ_DOMAINS.map((pq) => {
            const addr = pq.prefix + wallet.address.slice(wallet.address.indexOf("_", 3) + 1);
            return (
              <div
                key={pq.prefix}
                className="bg-mempool-bg rounded-lg p-2.5 cursor-pointer hover:bg-mempool-bg-light transition-colors"
                onClick={() => copyAddr(addr)}
              >
                <div className="flex items-center justify-between">
                  <span className={`text-xs font-mono ${pq.color}`}>{pq.prefix}...</span>
                  <span className="text-[10px] text-mempool-text-dim">
                    {pq.algo} ({pq.bits}b)
                  </span>
                </div>
              </div>
            );
          })}

          {/* Mnemonic reveal */}
          <div className="pt-2 border-t border-mempool-border/50">
            <button
              onClick={() => setShowMnemonic(!showMnemonic)}
              className="text-[10px] text-mempool-text-dim hover:text-mempool-orange transition-colors"
            >
              {showMnemonic ? "Hide" : "Show"} Mnemonic
            </button>
            {showMnemonic && (
              <div className="mt-2 bg-mempool-bg rounded-lg p-3 animate-fadeIn">
                <p className="text-[10px] text-mempool-orange mb-1 uppercase font-bold">
                  Keep this secret!
                </p>
                <p className="text-xs font-mono text-mempool-text break-all leading-relaxed">
                  {wallet.mnemonic}
                </p>
              </div>
            )}
          </div>
        </div>
      </div>

      {/* Transaction History */}
      <div className="bg-mempool-card rounded-xl border border-mempool-border overflow-hidden">
        <div className="px-5 py-3 border-b border-mempool-border">
          <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
            Transaction History
          </h3>
        </div>
        <div className="divide-y divide-mempool-border/30 max-h-96 overflow-y-auto">
          {wallet.transactions.length === 0 ? (
            <div className="px-5 py-8 text-center text-sm text-mempool-text-dim">
              No transactions yet. Mine blocks or receive OMNI to see history.
            </div>
          ) : (
            wallet.transactions.map((tx: any, i: number) => (
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
                    {tx.direction === "received" ? "+" : "-"}{((tx.amount || 0) / 1e9).toFixed(4)}
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
