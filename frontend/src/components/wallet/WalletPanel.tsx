import { useState } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import OmniBusRpcClient from "../../api/rpc-client";

const rpc = new OmniBusRpcClient("/api");

const PQ_ADDRESSES = [
  { prefix: "ob1q", algo: "ML-DSA-87 + KEM", bits: 256, color: "text-mempool-blue" },
  { prefix: "ob_k1_", algo: "ML-DSA-87", bits: 256, color: "text-mempool-purple" },
  { prefix: "ob_f5_", algo: "Falcon-512", bits: 192, color: "text-mempool-green" },
  { prefix: "ob_d5_", algo: "Dilithium-5", bits: 256, color: "text-mempool-orange" },
  { prefix: "ob_s3_", algo: "SLH-DSA-256s", bits: 256, color: "text-mempool-text" },
];

export function WalletPanel() {
  const { state } = useBlockchain();
  const [sendTo, setSendTo] = useState("");
  const [sendAmount, setSendAmount] = useState("");
  const [sending, setSending] = useState(false);
  const [sendResult, setSendResult] = useState<string | null>(null);
  const [showAddresses, setShowAddresses] = useState(false);
  const [copied, setCopied] = useState<string | null>(null);

  const handleSend = async () => {
    if (!sendTo || !sendAmount) return;
    setSending(true);
    setSendResult(null);
    try {
      const amountSat = Math.floor(parseFloat(sendAmount) * 1e9);
      const result: any = await rpc.sendTransaction(sendTo, amountSat);
      const txid = typeof result === "object" ? result?.txid : result;
      setSendResult(`TX sent: ${(txid || "ok").toString().slice(0, 16)}...`);
      setSendTo("");
      setSendAmount("");
    } catch (err: any) {
      setSendResult(`Error: ${err.message}`);
    } finally {
      setSending(false);
    }
  };

  const copyAddress = (addr: string) => {
    navigator.clipboard.writeText(addr);
    setCopied(addr);
    setTimeout(() => setCopied(null), 2000);
  };

  return (
    <div className="bg-mempool-card rounded-lg border border-mempool-border">
      <div className="px-4 py-3 border-b border-mempool-border">
        <h3 className="text-sm font-semibold text-mempool-text-dim uppercase tracking-wider">
          Wallet
        </h3>
      </div>

      <div className="p-4 space-y-4">
        {/* Balance */}
        <div className="text-center py-2">
          <p className="text-3xl font-mono font-bold text-mempool-green">
            {state.balanceOMNI}
          </p>
          <p className="text-xs text-mempool-text-dim mt-1">
            OMNI ({state.balance.toLocaleString()} SAT)
          </p>
        </div>

        {/* Address */}
        <div
          className="bg-mempool-bg rounded-lg p-3 cursor-pointer hover:bg-mempool-bg-light transition-colors"
          onClick={() => copyAddress(state.address)}
        >
          <p className="text-[10px] text-mempool-text-dim">Your Address</p>
          <p className="text-xs font-mono text-mempool-blue truncate">
            {state.address || "Loading..."}
          </p>
          {copied === state.address && (
            <p className="text-[10px] text-mempool-green mt-1">Copied!</p>
          )}
        </div>

        {/* PQ Addresses Toggle */}
        <button
          onClick={() => setShowAddresses(!showAddresses)}
          className="w-full text-left text-xs text-mempool-text-dim hover:text-mempool-blue transition-colors flex items-center gap-1"
        >
          <span className={`transform transition-transform ${showAddresses ? "rotate-90" : ""}`}>
            ▶
          </span>
          5 Post-Quantum Addresses
        </button>

        {showAddresses && (
          <div className="space-y-2 animate-fadeIn">
            {PQ_ADDRESSES.map((pq) => (
              <div
                key={pq.prefix}
                className="bg-mempool-bg rounded p-2 cursor-pointer hover:bg-mempool-bg-light transition-colors"
                onClick={() => copyAddress(pq.prefix + state.address.slice(8))}
              >
                <div className="flex items-center justify-between">
                  <span className={`text-xs font-mono ${pq.color}`}>
                    {pq.prefix}...
                  </span>
                  <span className="text-[10px] text-mempool-text-dim">
                    {pq.algo} ({pq.bits}b)
                  </span>
                </div>
              </div>
            ))}
          </div>
        )}

        {/* Send Form */}
        <div className="space-y-2 pt-2 border-t border-mempool-border/50">
          <p className="text-xs text-mempool-text-dim font-semibold uppercase">
            Send OMNI
          </p>
          <input
            type="text"
            placeholder="Recipient address"
            value={sendTo}
            onChange={(e) => setSendTo(e.target.value)}
            className="w-full bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-xs font-mono text-mempool-text placeholder-mempool-text-dim/50 focus:outline-none focus:border-mempool-blue"
          />
          <input
            type="number"
            placeholder="Amount (OMNI)"
            value={sendAmount}
            onChange={(e) => setSendAmount(e.target.value)}
            step="0.0001"
            min="0"
            className="w-full bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-xs font-mono text-mempool-text placeholder-mempool-text-dim/50 focus:outline-none focus:border-mempool-blue"
          />
          <button
            onClick={handleSend}
            disabled={sending || !sendTo || !sendAmount}
            className="w-full bg-mempool-blue hover:bg-mempool-blue/80 disabled:opacity-40 disabled:cursor-not-allowed text-white text-xs font-semibold rounded-lg py-2.5 transition-colors"
          >
            {sending ? "Sending..." : "Send Transaction"}
          </button>
          {sendResult && (
            <p
              className={`text-xs ${
                sendResult.startsWith("Error")
                  ? "text-mempool-red"
                  : "text-mempool-green"
              }`}
            >
              {sendResult}
            </p>
          )}
        </div>
      </div>
    </div>
  );
}
