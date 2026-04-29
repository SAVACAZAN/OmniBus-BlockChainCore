import { useEffect, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import { useWallet } from "../../api/use-wallet";

const rpc = new OmniBusRpcClient();
const SAT_PER_OMNI = 1_000_000_000;

type FaucetStatus = {
  enabled: boolean;
  address: string;
  balance: number;
  grantPerClaim: number;
  claimsServed: number;
};

type ClaimResult = {
  txid: string;
  recipient: string;
  amount: number;
  fee: number;
  status: string;
};

export function FaucetPage() {
  const wallet = useWallet();
  const [status, setStatus] = useState<FaucetStatus | null>(null);
  const [statusLoading, setStatusLoading] = useState(true);
  const [recipient, setRecipient] = useState("");
  const [claiming, setClaiming] = useState(false);
  const [result, setResult] = useState<ClaimResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Auto-fill recipient with connected wallet — user can still override.
  useEffect(() => {
    if (wallet && !recipient) setRecipient(wallet.address);
  }, [wallet, recipient]);

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
    const id = setInterval(refresh, 6000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, []);

  const claim = async () => {
    setError(null);
    setResult(null);
    const addr = recipient.trim();
    if (!addr.startsWith("ob1")) {
      setError("Address must start with ob1 (OmniBus native).");
      return;
    }
    if (addr.length < 20 || addr.length > 64) {
      setError("Address length looks wrong.");
      return;
    }
    setClaiming(true);
    try {
      const r = await rpc.claimFaucet(addr);
      setResult(r);
      // Refresh status so balance/claimsServed update right away.
      rpc.getFaucetStatus().then(setStatus).catch(() => {});
    } catch (e: any) {
      setError(e?.message || "Claim failed");
    } finally {
      setClaiming(false);
    }
  };

  const omniFmt = (sat: number) => (sat / SAT_PER_OMNI).toFixed(8);

  return (
    <div className="max-w-3xl mx-auto px-4 py-8">
      <h1 className="text-2xl font-bold text-mempool-text mb-2">OmniBus Faucet</h1>
      <p className="text-mempool-text-dim text-sm mb-6">
        Get 0.1 OMNI to your address so it crosses the validator threshold and
        can start mining. One grant per address. Testnet only — no real value.
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
            Faucet disabled on this node (no <code>--faucet-mode</code>).
          </div>
        )}
        {status?.enabled && (
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 text-sm">
            <div>
              <div className="text-mempool-text-dim text-xs">Balance</div>
              <div className="text-mempool-blue font-mono">{omniFmt(status.balance)} OMNI</div>
            </div>
            <div>
              <div className="text-mempool-text-dim text-xs">Per claim</div>
              <div className="text-mempool-text font-mono">{omniFmt(status.grantPerClaim)} OMNI</div>
            </div>
            <div>
              <div className="text-mempool-text-dim text-xs">Served</div>
              <div className="text-mempool-text font-mono">{status.claimsServed}</div>
            </div>
            <div>
              <div className="text-mempool-text-dim text-xs">Address</div>
              <div className="text-mempool-text font-mono text-xs truncate" title={status.address}>
                {status.address.slice(0, 12)}…{status.address.slice(-6)}
              </div>
            </div>
          </div>
        )}
      </div>

      {/* Claim form */}
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
        <label className="block text-xs uppercase tracking-wider text-mempool-text-dim mb-2">
          Your OmniBus address
        </label>
        <input
          type="text"
          value={recipient}
          onChange={(e) => setRecipient(e.target.value)}
          placeholder="ob1q..."
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text font-mono text-sm mb-3 focus:outline-none focus:border-mempool-blue"
          spellCheck={false}
        />
        <button
          onClick={claim}
          disabled={claiming || !status?.enabled || (status?.balance ?? 0) < (status?.grantPerClaim ?? 0)}
          className="px-4 py-2 bg-mempool-blue hover:bg-blue-600 disabled:bg-mempool-bg disabled:text-mempool-text-dim disabled:cursor-not-allowed text-white text-sm font-medium rounded transition-colors"
        >
          {claiming ? "Sending…" : "Get 0.1 OMNI"}
        </button>
        {status?.enabled && (status.balance < status.grantPerClaim) && (
          <span className="ml-3 text-xs text-yellow-400">Faucet drained — wait for refill</span>
        )}
      </div>

      {/* Result */}
      {error && (
        <div className="mt-4 rounded-lg border border-red-500/30 bg-red-500/10 p-3 text-sm text-red-300">
          {error}
        </div>
      )}
      {result && (
        <div className="mt-4 rounded-lg border border-green-500/30 bg-green-500/10 p-3 text-sm">
          <div className="text-green-300 font-medium mb-2">Claim accepted</div>
          <div className="grid grid-cols-1 gap-1 font-mono text-xs">
            <div>
              <span className="text-mempool-text-dim">txid:</span>{" "}
              <span className="text-mempool-text break-all">{result.txid}</span>
            </div>
            <div>
              <span className="text-mempool-text-dim">amount:</span>{" "}
              <span className="text-mempool-text">{omniFmt(result.amount)} OMNI</span>
            </div>
            <div>
              <span className="text-mempool-text-dim">recipient:</span>{" "}
              <span className="text-mempool-text break-all">{result.recipient}</span>
            </div>
          </div>
          <div className="mt-2 text-xs text-mempool-text-dim">
            TX is in the mempool. It will confirm in the next block (~1-3 seconds on testnet).
          </div>
        </div>
      )}

      <div className="mt-8 text-xs text-mempool-text-dim">
        <p>
          <span className="font-semibold text-mempool-text">How it works:</span> the faucet wallet
          holds a small balance and signs a transfer of 0.1 OMNI to the address you submit. Your
          address must reach 0.1 OMNI to be eligible as a validator (slot leader rotation).
        </p>
        <p className="mt-2">
          Anti-Sybil: 1 grant per address, ever. The faucet refills automatically from the
          operator&apos;s mining wallet when its balance dips below 0.5 OMNI.
        </p>
      </div>
    </div>
  );
}
