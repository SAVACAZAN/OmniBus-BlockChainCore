/**
 * MultisigPanel.tsx — M-of-N multisig wallet interface.
 *
 * Create a multisig address (P2MS) from N public keys requiring M signatures,
 * then send from it by supplying M private keys inline. The generated address
 * starts with "ob1m…" on OmniBus.
 *
 * RPCs used:
 *   createmultisig  { m, pubkeys }
 *   sendmultisig    { from, to, amount_sat, fee_sat, privkeys }
 *
 * WARNING: Private keys are transmitted to the node over the configured RPC
 * connection. Only use this on a trusted local or VPN-secured node.
 */

import { useCallback, useState } from "react";
import { Users, Send, Plus, X, AlertTriangle, Copy, RefreshCw } from "lucide-react";
import { rpc } from "../../api/clients/rpc-client";
import { SAT_PER_OMNI, satToOmni } from "../../utils/fmt";




type SubTab = "create" | "send" | "balance";

const MULTISIG_TABS: { id: SubTab; label: string }[] = [
  { id: "create",  label: "Create Multisig" },
  { id: "send",    label: "Send from Multisig" },
  { id: "balance", label: "Balance" },
];

export function MultisigPanel() {
  const [tab, setTab] = useState<SubTab>("create");

  return (
    <div className="space-y-4">
      {/* Info box */}
      <div className="bg-mempool-blue/5 border border-mempool-blue/20 rounded p-3 text-xs text-mempool-text-dim leading-relaxed">
        <Users className="inline w-3.5 h-3.5 mr-1 text-mempool-blue -mt-0.5" />
        M-of-N multisig requires M out of N participants to sign a transaction.
        Funds cannot be spent without the required signatures — ideal for shared treasuries,
        2FA self-custody, or team wallets.
      </div>

      {/* Sub-tabs */}
      <div className="flex gap-1 border-b border-mempool-border overflow-x-auto scrollbar-none">
        {MULTISIG_TABS.map((t) => {
          const active = tab === t.id;
          return (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={
                "relative flex-shrink-0 px-3 py-2.5 text-xs font-medium uppercase tracking-wider transition-colors " +
                (active
                  ? "text-mempool-blue"
                  : "text-mempool-text-dim hover:text-mempool-text")
              }
            >
              {t.label}
              {active && (
                <span className="absolute left-0 right-0 -bottom-px h-0.5 bg-mempool-blue" />
              )}
            </button>
          );
        })}
      </div>

      {tab === "create"  && <CreateMultisigTab />}
      {tab === "send"    && <SendMultisigTab />}
      {tab === "balance" && <BalanceTab />}
    </div>
  );
}

// ── Create Multisig ───────────────────────────────────────────────────────

function CreateMultisigTab() {
  const [m, setM] = useState(2);
  const [pubkeys, setPubkeys] = useState<string[]>(["", "", ""]);
  const [result, setResult] = useState<{ address: string; redeemScript: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  const n = pubkeys.length;

  const addKey = () => setPubkeys((prev) => [...prev, ""]);
  const updateKey = (idx: number, val: string) =>
    setPubkeys((prev) => prev.map((v, i) => (i === idx ? val : v)));
  const removeKey = (idx: number) => {
    setPubkeys((prev) => prev.filter((_, i) => i !== idx));
    if (m > pubkeys.length - 1) setM(pubkeys.length - 1);
  };

  const handleCreate = async () => {
    const validKeys = pubkeys.map((k) => k.trim()).filter(Boolean);
    if (validKeys.length < 2 || m < 1 || m > validKeys.length) {
      setErr("Need at least 2 public keys, and M must be between 1 and N.");
      return;
    }
    setBusy(true);
    setErr(null);
    setResult(null);
    try {
      const res = await rpc.createMultisig(m, validKeys) as { address?: string; redeemScript?: string } | null;
      if (res?.address) {
        setResult({ address: res.address, redeemScript: res.redeemScript ?? "" });
      } else {
        setErr("Node returned no address. Check pubkeys.");
      }
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const copyAddress = () => {
    if (!result?.address) return;
    void navigator.clipboard.writeText(result.address);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="space-y-4">
      {/* M selector */}
      <div className="space-y-1">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Required signers (M) — {m} of {n}
        </label>
        <div className="flex items-center gap-3">
          <input
            type="range"
            min={1}
            max={Math.max(n, 1)}
            value={m}
            onChange={(e) => setM(parseInt(e.target.value, 10))}
            className="flex-1 accent-mempool-blue"
          />
          <span className="font-mono text-sm text-mempool-text w-8 text-right">{m}</span>
        </div>
      </div>

      {/* Public keys */}
      <div className="space-y-2">
        <div className="flex items-center justify-between">
          <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
            Public keys ({n} total)
          </label>
          <button
            type="button"
            onClick={addKey}
            className="flex items-center gap-1 px-2 py-1 text-[10px] rounded border border-mempool-blue/30 text-mempool-blue hover:bg-mempool-blue/10"
          >
            <Plus className="w-3 h-3" />
            Add key
          </button>
        </div>
        {pubkeys.map((key, idx) => (
          <div key={idx} className="flex gap-2">
            <input
              type="text"
              value={key}
              onChange={(e) => updateKey(idx, e.target.value)}
              placeholder={`Public key ${idx + 1} (compressed hex)`}
              className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
            />
            {pubkeys.length > 2 && (
              <button
                type="button"
                onClick={() => removeKey(idx)}
                className="px-2 text-mempool-orange hover:text-mempool-orange/70"
              >
                <X className="w-3.5 h-3.5" />
              </button>
            )}
          </div>
        ))}
      </div>

      {err && <p className="text-xs text-mempool-orange font-mono">{err}</p>}

      <button
        onClick={() => void handleCreate()}
        disabled={busy}
        className="w-full px-4 py-2.5 rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25 disabled:opacity-40 text-xs font-medium uppercase tracking-wider"
      >
        {busy ? "Generating…" : "Generate Multisig Address"}
      </button>

      {result && (
        <div className="bg-mempool-green/5 border border-mempool-green/30 rounded p-4 space-y-3">
          <div className="flex items-center justify-between">
            <span className="text-[10px] uppercase tracking-wider text-mempool-green">
              Address generated ({m}-of-{n})
            </span>
            <button
              onClick={copyAddress}
              className="flex items-center gap-1 px-2 py-1 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-text"
            >
              <Copy className="w-3 h-3" />
              {copied ? "Copied!" : "Copy"}
            </button>
          </div>
          <div className="font-mono text-sm text-mempool-text break-all">{result.address}</div>
          {result.redeemScript && (
            <div>
              <div className="text-[9px] uppercase tracking-wider text-mempool-text-dim mb-1">
                Redeem script (save this!)
              </div>
              <div className="font-mono text-[10px] text-mempool-text-dim break-all bg-mempool-bg rounded p-2">
                {result.redeemScript}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// ── Send from Multisig ────────────────────────────────────────────────────

function SendMultisigTab() {
  const [fromAddr, setFromAddr] = useState("");
  const [toAddr, setToAddr] = useState("");
  const [amountStr, setAmountStr] = useState("");
  const [feeStr, setFeeStr] = useState("0.0001");
  const [mRequired, setMRequired] = useState(2);
  const [privkeys, setPrivkeys] = useState<string[]>(["", ""]);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const updatePrivkey = (idx: number, val: string) =>
    setPrivkeys((prev) => prev.map((v, i) => (i === idx ? val : v)));

  const syncPrivkeyCount = (newM: number) => {
    setMRequired(newM);
    setPrivkeys((prev) => {
      if (prev.length < newM) return [...prev, ...Array(newM - prev.length).fill("")];
      return prev.slice(0, newM);
    });
  };

  const handleSend = async () => {
    const validKeys = privkeys.map((k) => k.trim()).filter(Boolean);
    const amountSat = Math.floor((parseFloat(amountStr) || 0) * SAT_PER_OMNI);
    const feeSat = Math.floor((parseFloat(feeStr) || 0) * SAT_PER_OMNI);
    if (!fromAddr.trim() || !toAddr.trim() || amountSat <= 0 || validKeys.length < mRequired) {
      setErr(`Fill all fields and provide ${mRequired} private key(s).`);
      return;
    }
    setBusy(true);
    setErr(null);
    setResult(null);
    try {
      const res = await rpc.sendMultisig({
        from: fromAddr.trim(),
        to: toAddr.trim(),
        amount_sat: amountSat,
        fee_sat: feeSat,
        privkeys: validKeys,
      }) as { txid?: string } | null;
      setResult(res?.txid ?? "OK");
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-4">
      {/* Security warning */}
      <div className="flex items-start gap-2 bg-mempool-orange/10 border border-mempool-orange/30 rounded p-3 text-[10px] text-mempool-orange leading-relaxed">
        <AlertTriangle className="w-3.5 h-3.5 flex-shrink-0 mt-0.5" />
        <span>
          Private keys are sent to the node to construct and broadcast the transaction.
          Only use this on a trusted local node or a VPN-secured connection. Never use
          on a public or shared RPC endpoint.
        </span>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div className="space-y-1">
          <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
            From (multisig address)
          </label>
          <input
            type="text"
            value={fromAddr}
            onChange={(e) => setFromAddr(e.target.value)}
            placeholder="ob1m…"
            className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
        </div>
        <div className="space-y-1">
          <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
            To
          </label>
          <input
            type="text"
            value={toAddr}
            onChange={(e) => setToAddr(e.target.value)}
            placeholder="ob1q…"
            className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-1">
          <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
            Amount (OMNI)
          </label>
          <input
            type="number"
            min="0"
            step="0.0001"
            value={amountStr}
            onChange={(e) => setAmountStr(e.target.value)}
            placeholder="0.0000"
            className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
        </div>
        <div className="space-y-1">
          <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
            Fee (OMNI)
          </label>
          <input
            type="number"
            min="0"
            step="0.0001"
            value={feeStr}
            onChange={(e) => setFeeStr(e.target.value)}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text focus:outline-none focus:border-mempool-blue"
          />
        </div>
      </div>

      {/* M selector + private keys */}
      <div className="space-y-2">
        <div className="flex items-center gap-3">
          <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
            Required signatures (M)
          </label>
          <input
            type="number"
            min={1}
            max={15}
            value={mRequired}
            onChange={(e) => syncPrivkeyCount(parseInt(e.target.value, 10) || 1)}
            className="w-16 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs font-mono text-mempool-text focus:outline-none focus:border-mempool-blue"
          />
        </div>
        {privkeys.map((key, idx) => (
          <div key={idx} className="space-y-0.5">
            <label className="text-[9px] uppercase tracking-wider text-mempool-text-dim">
              Key {idx + 1} of {mRequired}
            </label>
            <input
              type="password"
              value={key}
              onChange={(e) => updatePrivkey(idx, e.target.value)}
              placeholder="Private key (hex)"
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
            />
          </div>
        ))}
      </div>

      {err && <p className="text-xs text-mempool-orange font-mono">{err}</p>}

      {result && (
        <div className="bg-mempool-green/5 border border-mempool-green/30 rounded p-3">
          <div className="text-[10px] uppercase tracking-wider text-mempool-green mb-1">Transaction sent</div>
          <div className="font-mono text-xs text-mempool-text break-all">txid: {result}</div>
        </div>
      )}

      <button
        onClick={() => void handleSend()}
        disabled={busy}
        className="w-full flex items-center justify-center gap-2 px-4 py-2.5 rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25 disabled:opacity-40 text-xs font-medium uppercase tracking-wider"
      >
        <Send className="w-4 h-4" />
        {busy ? "Signing & broadcasting…" : "Send from Multisig"}
      </button>
    </div>
  );
}

// ── Balance ───────────────────────────────────────────────────────────────

function BalanceTab() {
  const [addr, setAddr] = useState("");
  const [balance, setBalance] = useState<number | null>(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const fetchBalance = useCallback(async () => {
    const a = addr.trim();
    if (!a) return;
    setLoading(true);
    setErr(null);
    setBalance(null);
    try {
      const res = await rpc.getAddressBalance(a);
      const sat = res?.balance ?? 0;
      setBalance(sat);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [addr]);

  return (
    <div className="space-y-4">
      <div className="space-y-1">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Multisig address
        </label>
        <div className="flex gap-2">
          <input
            type="text"
            value={addr}
            onChange={(e) => setAddr(e.target.value)}
            placeholder="ob1m…"
            className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
          <button
            onClick={() => void fetchBalance()}
            disabled={loading || !addr.trim()}
            className="flex items-center gap-1.5 px-4 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-50"
          >
            <RefreshCw className={`w-3.5 h-3.5 ${loading ? "animate-spin" : ""}`} />
            Check
          </button>
        </div>
      </div>

      {err && <p className="text-xs text-mempool-orange font-mono">{err}</p>}

      {balance !== null && (
        <div className="bg-mempool-bg border border-mempool-border rounded p-4">
          <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">Balance</div>
          <div className="text-2xl font-mono text-mempool-text">
            {satToOmni(balance, 4)}
            <span className="text-sm text-mempool-text-dim ml-2">OMNI</span>
          </div>
          <div className="text-[10px] font-mono text-mempool-text-dim mt-1">
            {balance.toLocaleString()} sat
          </div>
        </div>
      )}
    </div>
  );
}
