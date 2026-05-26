import { useEffect, useState } from "react";
import { OmniBusRpcClient } from "../../api/rpc-client";
import { AddressLabel } from "../common/AddressLabel";

const rpc = new OmniBusRpcClient();
const SAT = 1e9;

function fmtSat(sat: number) {
  return (sat / SAT).toFixed(8) + " OMNI";
}
function midTrunc(s: string | undefined | null, h = 14, t = 12): string {
  if (!s) return "—";
  if (s.length <= h + t + 3) return s;
  return s.slice(0, h) + "…" + s.slice(-t);
}

const KIND_STYLE: Record<string, string> = {
  coinbase: "bg-yellow-500/20 text-yellow-300",
  faucet: "bg-cyan-500/20 text-cyan-300",
  registrar: "bg-purple-500/20 text-purple-300",
  exchange: "bg-blue-500/20 text-blue-300",
  stake: "bg-green-500/20 text-green-300",
  unstake:       "bg-amber-500/20 text-amber-300",
  ns_claim:      "bg-violet-500/20 text-violet-300",
  agent_register:"bg-indigo-500/20 text-indigo-300",
  notarize:      "bg-rose-500/20 text-rose-300",
  demo_grant:    "bg-pink-500/20 text-pink-300",
  transfer:      "bg-gray-700/40 text-gray-300",
};

function KindBadge({ kind }: { kind: string }) {
  const cls = KIND_STYLE[kind] ?? "bg-gray-700/40 text-gray-300";
  return (
    <span className={`inline-block px-2 py-0.5 rounded text-[11px] uppercase tracking-wide font-mono ${cls}`}>
      {kind}
    </span>
  );
}

function SchemeTag({ scheme }: { scheme: string }) {
  const isPQ = scheme.includes("ML-DSA") || scheme.includes("Falcon") || scheme.includes("SLH-DSA") || scheme.includes("Hybrid");
  const isSoulbound = scheme.includes("soulbound");
  const cls = isSoulbound
    ? "bg-purple-400/10 text-purple-300 border-purple-400/30"
    : isPQ
    ? "bg-blue-400/10 text-blue-300 border-blue-400/30"
    : "bg-green-400/10 text-green-300 border-green-400/30";
  return (
    <span className={`inline-block px-2 py-0.5 rounded border text-[11px] font-mono ${cls}`}>
      {isPQ ? "🔒 " : "🔑 "}{scheme}
    </span>
  );
}

function CopyBtn({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      className="flex-shrink-0 text-mempool-text-dim hover:text-mempool-blue text-xs transition-colors"
      onClick={() => { navigator.clipboard.writeText(text); setCopied(true); setTimeout(() => setCopied(false), 1500); }}
    >
      {copied ? "✓" : "⧉"}
    </button>
  );
}

interface Props {
  hash: string;
  onNavigate: (h: string) => void;
}

export function TxPage({ hash, onNavigate }: Props) {
  const [tx, setTx] = useState<any>(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");

  useEffect(() => {
    setLoading(true);
    setErr("");
    setTx(null);
    rpc.getTransactionDetail(hash)
      .then((data) => {
        if (!data) setErr("Transaction not found");
        else setTx(data);
      })
      .catch((e) => setErr(e.message))
      .finally(() => setLoading(false));
  }, [hash]);

  if (loading) {
    return (
      <div className="max-w-7xl mx-auto px-4 py-8 text-mempool-text-dim animate-pulse text-sm">
        Loading transaction…
      </div>
    );
  }

  if (err || !tx) {
    return (
      <div className="max-w-7xl mx-auto px-4 py-8 space-y-4">
        <button onClick={() => onNavigate("#/blocks")} className="text-mempool-blue hover:underline text-sm">
          ← Explorer
        </button>
        <p className="text-red-400">{err || "Transaction not found"}</p>
      </div>
    );
  }

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-4">
      {/* Breadcrumb */}
      <div className="flex items-center gap-2 text-sm flex-wrap">
        <button onClick={() => onNavigate("#/blocks")} className="text-mempool-blue hover:underline">
          ← Explorer
        </button>
        <span className="text-mempool-text-dim">/</span>
        <span className="text-mempool-text font-medium font-mono text-xs">{midTrunc(hash, 14, 12)}</span>
      </div>

      {/* Status badge + title */}
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-5 space-y-5">
        <div className="flex items-start justify-between gap-4 flex-wrap">
          <h1 className="text-xl font-bold text-mempool-text">Transaction</h1>
          <span className={`px-3 py-1 rounded-full text-xs font-semibold ${
            tx.status === "confirmed"
              ? "bg-green-400/10 text-green-400"
              : "bg-yellow-400/10 text-yellow-400"
          }`}>
            {tx.status === "confirmed"
              ? `✓ Confirmed (${tx.confirmations} conf)`
              : "⏳ Pending"}
          </span>
        </div>

        {/* Fields */}
        <div className="grid sm:grid-cols-2 gap-4 text-sm">
          {/* TX hash full */}
          <div className="sm:col-span-2">
            <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-0.5">TX Hash</div>
            <div className="flex items-center gap-2 font-mono text-xs text-mempool-text break-all">
              <span>{tx.txid}</span>
              <CopyBtn text={tx.txid} />
            </div>
          </div>

          {tx.blockHeight !== undefined && tx.blockHeight >= 0 && (
            <div>
              <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-0.5">Block</div>
              <button onClick={() => onNavigate(`#/block/${tx.blockHeight}`)}
                className="text-mempool-blue hover:underline text-sm font-mono">
                #{tx.blockHeight.toLocaleString()}
              </button>
            </div>
          )}

          <div>
            <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-0.5">Amount</div>
            <div className="text-mempool-orange font-mono font-semibold">{fmtSat(tx.amount)}</div>
          </div>

          <div>
            <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-0.5">Fee</div>
            <div className="text-mempool-text font-mono">{fmtSat(tx.fee)}</div>
          </div>

          {tx.nonce !== undefined && (
            <div>
              <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-0.5">Nonce</div>
              <div className="text-mempool-text font-mono">{tx.nonce}</div>
            </div>
          )}

          {tx.timestamp !== undefined && tx.timestamp > 0 && (
            <div>
              <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-0.5">Timestamp</div>
              <div className="text-mempool-text font-mono text-xs">
                {new Date(tx.timestamp < 1e12 ? tx.timestamp * 1000 : tx.timestamp).toLocaleString()}
              </div>
            </div>
          )}

          {tx.kind && (
            <div>
              <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-0.5">Type</div>
              <KindBadge kind={tx.kind} />
            </div>
          )}

          {tx.scheme && (
            <div>
              <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-0.5">Signing Scheme</div>
              <SchemeTag scheme={tx.scheme} />
            </div>
          )}

          {tx.locktime !== undefined && tx.locktime > 0 && (
            <div>
              <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-0.5">Locktime</div>
              <div className="text-mempool-text font-mono">{tx.locktime.toLocaleString()}</div>
            </div>
          )}
        </div>

        {/* From → To */}
        <div className="border-t border-mempool-border pt-4">
          <h2 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim mb-3">Transfer</h2>
          <div className="flex flex-col sm:flex-row items-stretch sm:items-center gap-3">
            <div className="flex-1 bg-mempool-bg-light rounded-lg p-3 min-w-0">
              <div className="text-xs text-mempool-text-dim mb-1 flex items-center gap-1">
                <span className="w-2 h-2 rounded-full bg-orange-400 inline-block" />
                From
              </div>
              <button onClick={() => onNavigate(`#/address/${tx.from}`)}
                className="font-mono text-xs text-mempool-blue hover:underline break-all text-left w-full">
                <AddressLabel address={tx.from} showRawAddress showEmoji
                  truncate={{ left: 10, right: 8 }} />
              </button>
            </div>

            <div className="text-2xl text-mempool-text-dim flex-shrink-0 text-center">→</div>

            <div className="flex-1 bg-mempool-bg-light rounded-lg p-3 min-w-0">
              <div className="text-xs text-mempool-text-dim mb-1 flex items-center gap-1">
                <span className="w-2 h-2 rounded-full bg-green-400 inline-block" />
                To
              </div>
              <button onClick={() => onNavigate(`#/address/${tx.to}`)}
                className="font-mono text-xs text-mempool-blue hover:underline break-all text-left w-full">
                <AddressLabel address={tx.to} showRawAddress showEmoji
                  truncate={{ left: 10, right: 8 }} />
              </button>
            </div>
          </div>
        </div>

        {/* OP_RETURN */}
        {tx.op_return && (
          <div className="border-t border-mempool-border pt-4">
            <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">OP_RETURN</div>
            <div className="font-mono text-xs text-mempool-text bg-mempool-bg-light rounded p-3 break-all">
              {tx.op_return}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
