import { useEffect, useState } from "react";
import OmniBusRpcClient, { ExchangeBalance } from "../../api/rpc-client";
import {
  signDepositPayload,
  signWithdrawPayload,
} from "../../api/exchange-sign";
import { getUnlocked, nextNonce, subscribeWallet } from "../../api/wallet-keystore";

const rpc = new OmniBusRpcClient();
const SAT_PER_OMNI = 1_000_000_000;

const SUPPORTED_TOKENS = ["OMNI", "BTC", "LCX", "ETH"] as const;

/**
 * Internal exchange balances + deposit/withdraw widget.
 *
 * Testnet: deposit just credits the internal pool (no on-chain transfer
 * needed — it's a test). On mainnet this would require an on-chain TX
 * to an escrow address, which the chain would credit after seeing the
 * confirmed transfer.
 */
export function BalancesPanel() {
  const [, force] = useState(0);
  useEffect(() => subscribeWallet(() => force((n) => n + 1)), []);
  const u = getUnlocked();

  const [balances, setBalances] = useState<ExchangeBalance[]>([]);
  const [chainBalance, setChainBalance] = useState<number>(0);
  const [token, setToken] = useState<string>("OMNI");
  const [amountStr, setAmountStr] = useState("");
  const [busy, setBusy] = useState<"deposit" | "withdraw" | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!u) {
      setBalances([]);
      setChainBalance(0);
      return;
    }
    let cancelled = false;
    const refresh = async () => {
      const [list, chainBal] = await Promise.all([
        rpc.exchangeGetBalances(u.address),
        // On-chain wallet balance (same RPC the Wallet tab uses).
        // We surface it here so the user sees their mining rewards
        // alongside the internal exchange pool balance.
        rpc.request_raw("getbalance", [u.address]).then((r: any) => r?.balance ?? 0).catch(() => 0),
      ]);
      if (!cancelled) {
        setBalances(list);
        setChainBalance(chainBal);
      }
    };
    refresh();
    const id = setInterval(refresh, 5000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [u?.address]);

  const move = async (kind: "deposit" | "withdraw") => {
    if (!u) return;
    setMsg(null);
    setErr(null);
    const v = Number(amountStr);
    if (!Number.isFinite(v) || v <= 0) {
      setErr("Amount must be > 0");
      return;
    }
    const amount = Math.round(v * SAT_PER_OMNI);
    const nonce = nextNonce();
    const sigArgs = {
      privateKeyHex: u.privateKey,
      owner: u.address,
      token,
      amount,
      nonce,
    };
    const { signature, publicKey } = kind === "deposit"
      ? signDepositPayload(sigArgs)
      : signWithdrawPayload(sigArgs);
    setBusy(kind);
    try {
      const fn = kind === "deposit" ? rpc.exchangeDeposit : rpc.exchangeWithdraw;
      const r = await fn.call(rpc, {
        owner: u.address,
        token,
        amount,
        nonce,
        signature,
        publicKey,
      });
      setMsg(
        `${kind.toUpperCase()} ${(amount / SAT_PER_OMNI).toFixed(4)} ${token} — available now ${(
          r.available / SAT_PER_OMNI
        ).toFixed(4)}`,
      );
      setAmountStr("");
      // Refresh balances
      setBalances(await rpc.exchangeGetBalances(u.address));
    } catch (e: any) {
      setErr(e?.message || `${kind} failed`);
    } finally {
      setBusy(null);
    }
  };

  if (!u) {
    return (
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
        <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider mb-2">
          Exchange balances
        </h3>
        <p className="text-xs text-mempool-text-dim">Connect a wallet to see balances.</p>
      </div>
    );
  }

  const fmt = (sat: number) => (sat / SAT_PER_OMNI).toFixed(8);

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 space-y-3">
      <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
        Balances
      </h3>

      {/* On-chain (real OMNI in your wallet) — shown above the internal
          exchange balances so the user sees mining rewards immediately. */}
      <div className="rounded border border-mempool-blue/30 bg-mempool-blue/5 px-3 py-2 flex items-center justify-between">
        <div>
          <div className="text-[10px] uppercase tracking-wider text-mempool-blue/80">
            On-chain wallet (mining rewards live here)
          </div>
          <div className="text-[10px] text-mempool-text-dim font-mono truncate max-w-[36ch]" title={u.address}>
            {u.address}
          </div>
        </div>
        <div className="text-right">
          <div className="font-mono text-sm text-mempool-blue">
            {(chainBalance / SAT_PER_OMNI).toFixed(4)} OMNI
          </div>
          <div className="text-[10px] text-mempool-text-dim">deposit to trade →</div>
        </div>
      </div>

      <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mt-2">
        Internal exchange balance (locked in orders + available)
      </div>

      {balances.length === 0 ? (
        <p className="text-xs text-mempool-text-dim">No internal balance yet — deposit OMNI below to start trading.</p>
      ) : (
        <div className="space-y-1">
          <div className="grid grid-cols-3 gap-1 text-[10px] uppercase tracking-wider text-mempool-text-dim px-1">
            <span>Token</span>
            <span className="text-right">Available</span>
            <span className="text-right">Locked</span>
          </div>
          {balances.map((b) => (
            <div key={b.token} className="grid grid-cols-3 gap-1 text-xs font-mono py-1 px-1 hover:bg-mempool-bg/40 rounded">
              <span className="text-mempool-text">{b.token}</span>
              <span className="text-right text-mempool-green">{fmt(b.available)}</span>
              <span className="text-right text-mempool-text-dim">{fmt(b.locked)}</span>
            </div>
          ))}
        </div>
      )}

      <div className="border-t border-mempool-border pt-3 space-y-2">
        <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Deposit / Withdraw
        </div>
        <div className="flex gap-2">
          <select
            value={token}
            onChange={(e) => setToken(e.target.value)}
            className="bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-mempool-text text-xs"
          >
            {SUPPORTED_TOKENS.map((t) => (
              <option key={t} value={t}>{t}</option>
            ))}
          </select>
          <input
            type="number"
            step="any"
            placeholder="Amount"
            value={amountStr}
            onChange={(e) => setAmountStr(e.target.value)}
            className="flex-1 bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-mempool-text font-mono text-xs focus:outline-none focus:border-mempool-blue"
          />
          <button
            onClick={() => move("deposit")}
            disabled={busy !== null || !amountStr}
            className="px-3 py-1.5 text-xs rounded bg-green-500/80 hover:bg-green-500 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
          >
            {busy === "deposit" ? "…" : "Deposit"}
          </button>
          <button
            onClick={() => move("withdraw")}
            disabled={busy !== null || !amountStr}
            className="px-3 py-1.5 text-xs rounded bg-orange-500/80 hover:bg-orange-500 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
          >
            {busy === "withdraw" ? "…" : "Withdraw"}
          </button>
        </div>
        {msg && (
          <div className="p-2 rounded bg-green-500/10 border border-green-500/30 text-[11px] text-green-200">
            {msg}
          </div>
        )}
        {err && (
          <div className="p-2 rounded bg-red-500/10 border border-red-500/30 text-[11px] text-red-300">
            {err}
          </div>
        )}
        <p className="text-[10px] text-mempool-text-dim">
          Testnet only — deposit credits internal balance immediately. On mainnet you'll first
          send OMNI to an escrow address, then the chain credits this balance after confirmation.
        </p>
      </div>
    </div>
  );
}
