import { useEffect, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import { useWallet } from "../../api/use-wallet";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsNewBlockEvent } from "../../types";

const rpc = new OmniBusRpcClient();
const SAT_PER_OMNI = 1_000_000_000;

type FaucetStatus = {
  enabled: boolean;
  address: string;
  balance: number;
  grantPerClaim: number;
  cooldownHours: number;
  declaration_hash: string;
  declaration_text: string;
};

type ClaimResult = {
  txid: string;
  recipient: string;
  amount: number;
  declaration: string;
  status: string;
  message: string;
};

export function FaucetPage() {
  const wallet = useWallet();
  const [status, setStatus] = useState<FaucetStatus | null>(null);
  const [statusLoading, setStatusLoading] = useState(true);
  const [recipient, setRecipient] = useState("");
  const [claiming, setClaiming] = useState(false);
  const [result, setResult] = useState<ClaimResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [showDeclaration, setShowDeclaration] = useState(false);

  useEffect(() => {
    setRecipient(wallet ? wallet.address : "");
  }, [wallet]);

  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      try {
        const s = await rpc.getFaucetStatus();
        if (!cancelled) setStatus(s);
      } finally {
        if (!cancelled) setStatusLoading(false);
      }
    };
    refresh();
    // Live refresh on every new block (faucet balance changes on claims/rewards).
    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", () => { void refresh(); });
    // Slow fallback poll for when WS is disconnected.
    const id = setInterval(refresh, 60_000);
    return () => { cancelled = true; clearInterval(id); unsub(); };
  }, []);

  const isOmniBusAddr = (a: string) =>
    a.startsWith("ob1") ||
    a.startsWith("obk1_") || a.startsWith("obf5_") ||
    a.startsWith("obd5_") || a.startsWith("obs3_") ||
    a.startsWith("ob_k1_") || a.startsWith("ob_f5_") ||
    a.startsWith("ob_d5_") || a.startsWith("ob_s3_");

  const claim = async () => {
    setError(null);
    setResult(null);
    const addr = recipient.trim();
    if (!isOmniBusAddr(addr)) {
      setError("Address must be an OmniBus native address (ob1… / obk1_/obf5_/obd5_/obs3_ / ob_k1_/ob_f5_/ob_d5_/ob_s3_).");
      return;
    }
    if (addr.length < 20 || addr.length > 90) {
      setError("Address length looks wrong.");
      return;
    }
    if (!status?.declaration_hash) {
      setError("Could not fetch declaration hash from node.");
      return;
    }
    setClaiming(true);
    try {
      const r = await rpc.claimFaucet(addr, status.declaration_hash);
      setResult(r);
      rpc.getFaucetStatus().then(setStatus).catch(() => {});
    } catch (e: any) {
      setError(e?.message || "Claim failed");
    } finally {
      setClaiming(false);
    }
  };

  const omniFmt = (sat: number) => (sat / SAT_PER_OMNI).toFixed(4);
  const canClaim = !!wallet && !!status?.enabled && (status.balance >= status.grantPerClaim);

  return (
    <div className="max-w-3xl mx-auto px-3 sm:px-4 py-4 sm:py-8">
      <h1 className="text-lg sm:text-2xl font-bold text-mempool-text mb-2">OmniBus Onboarding Faucet</h1>
      <p className="text-mempool-text-dim text-sm mb-6">
        Get {status ? omniFmt(status.grantPerClaim) : "0.001"} OMNI to activate your address on-chain.
        After claiming, complete <code>pq_attest</code> to unlock full ecosystem access
        (mining, exchange, governance).
      </p>

      {/* Status card */}
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 mb-6">
        <div className="text-xs uppercase tracking-wider text-mempool-text-dim mb-2">
          Faucet status
        </div>
        {statusLoading && <div className="text-mempool-text-dim text-sm">Loading…</div>}
        {!statusLoading && !status && (
          <div className="text-red-400 text-sm">RPC unreachable</div>
        )}
        {status && !status.enabled && (
          <div className="text-yellow-400 text-sm">
            Faucet temporarily offline — balance depleted. Community donations welcome at{" "}
            <span className="font-mono text-xs">{status.address}</span>
          </div>
        )}
        {status?.enabled && (
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-3 text-sm">
            <div>
              <div className="text-mempool-text-dim text-xs">Balance</div>
              <div className="text-mempool-blue font-mono">{omniFmt(status.balance)} OMNI</div>
            </div>
            <div>
              <div className="text-mempool-text-dim text-xs">Per claim</div>
              <div className="text-mempool-text font-mono">{omniFmt(status.grantPerClaim)} OMNI</div>
            </div>
            <div>
              <div className="text-mempool-text-dim text-xs">Cooldown</div>
              <div className="text-mempool-text font-mono">{status.cooldownHours}h per IP</div>
            </div>
          </div>
        )}
      </div>

      {/* Declaration of Honesty */}
      {status?.declaration_text && (
        <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 mb-6">
          <div className="flex items-center justify-between mb-2">
            <div className="text-xs uppercase tracking-wider text-mempool-text-dim">
              Declaration of Honesty
            </div>
            <button
              onClick={() => setShowDeclaration(v => !v)}
              className="text-xs text-mempool-blue hover:underline"
            >
              {showDeclaration ? "Hide" : "Read"}
            </button>
          </div>
          {showDeclaration && (
            <p className="text-mempool-text text-sm leading-relaxed mb-3">
              {status.declaration_text}
            </p>
          )}
          <div className="text-xs text-mempool-text-dim font-mono break-all">
            SHA-256: {status.declaration_hash}
          </div>
          <p className="text-xs text-mempool-text-dim mt-2">
            By claiming, you sign this declaration with your wallet key. It is recorded
            permanently on-chain as proof of agreement. Violations may result in
            stake slashing and validator exclusion.
          </p>
        </div>
      )}

      {/* Claim form */}
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
        <label className="block text-xs uppercase tracking-wider text-mempool-text-dim mb-2">
          Your OmniBus address
          {wallet && (
            <span className="ml-2 text-[10px] text-mempool-green normal-case tracking-normal">
              — locked to your connected wallet
            </span>
          )}
        </label>
        <input
          type="text"
          value={recipient}
          readOnly
          disabled={!wallet}
          placeholder={wallet ? "" : "Connect a wallet from the header to claim"}
          className="w-full bg-mempool-bg/50 border border-mempool-border rounded px-3 py-2 text-mempool-text-dim font-mono text-sm mb-3 cursor-not-allowed select-all"
          spellCheck={false}
        />
        <div className="flex flex-col sm:flex-row sm:items-center gap-2">
        <button
          onClick={claim}
          disabled={claiming || !canClaim}
          className="w-full sm:w-auto px-4 py-2 bg-mempool-blue hover:bg-blue-600 disabled:bg-mempool-bg disabled:text-mempool-text-dim disabled:cursor-not-allowed text-white text-sm font-medium rounded transition-colors"
        >
          {claiming ? "Signing declaration…" : "Claim & sign declaration"}
        </button>
        {status?.enabled && status.balance < status.grantPerClaim && (
          <span className="text-xs text-yellow-400">Faucet drained — wait for refill</span>
        )}
        {!wallet && (
          <span className="text-xs text-mempool-text-dim">Connect wallet to claim</span>
        )}
        </div>
      </div>

      {/* Result */}
      {result && (
        <div className="mt-4 rounded-lg border border-green-600 bg-mempool-bg-elev p-4">
          <div className="text-green-400 font-medium mb-2">✓ {result.message}</div>
          <div className="text-xs text-mempool-text-dim space-y-1">
            <div>TX:{" "}
              <button
                onClick={() => { window.location.hash = `#/tx/${result.txid}`; }}
                className="font-mono text-mempool-blue hover:underline"
              >
                {result.txid}
              </button>
            </div>
            <div>Amount: <span className="font-mono">{omniFmt(result.amount)} OMNI</span></div>
            <div>Declaration: <span className="text-green-400">{result.declaration}</span></div>
          </div>
          <p className="mt-3 text-xs text-mempool-text-dim">
            Next step: complete <code>pq_attest</code> in the Wallet section to link your
            4 soulbound domains and unlock full ecosystem access.
          </p>
        </div>
      )}

      {/* Error */}
      {error && (
        <div className="mt-4 rounded-lg border border-red-600 bg-mempool-bg-elev p-3 text-red-400 text-sm">
          {error}
        </div>
      )}
    </div>
  );
}
