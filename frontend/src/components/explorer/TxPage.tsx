import { useEffect, useState } from "react";
import { OmniBusRpcClient } from "../../api/rpc-client";
import { AddressLabel } from "../common/AddressLabel";
import { CopyButton } from "../common/CopyButton";
import { KindBadge, SchemeTag } from "../common/TxBadges";

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
              <CopyButton text={tx.txid} />
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

        {/* Raw JSON */}
        <RawJsonSection tx={tx} />
      </div>
    </div>
  );
}

function RawJsonSection({ tx }: { tx: any }) {
  const [open, setOpen] = useState(false);
  const [copied, setCopied] = useState(false);
  const raw = JSON.stringify(tx, null, 2);
  const copyRaw = () => {
    navigator.clipboard.writeText(raw);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };
  return (
    <div className="border-t border-mempool-border pt-4">
      <div className="flex items-center justify-between">
        <button
          onClick={() => setOpen((v) => !v)}
          className="text-[10px] uppercase tracking-wider text-mempool-text-dim hover:text-mempool-blue transition-colors flex items-center gap-1"
        >
          <span>{open ? "▾" : "▸"}</span>
          Raw JSON
        </button>
        {open && (
          <button
            onClick={copyRaw}
            className="text-[10px] text-mempool-text-dim hover:text-mempool-blue transition-colors"
          >
            {copied ? "✓ Copied" : "⧉ Copy"}
          </button>
        )}
      </div>
      {open && (
        <pre className="mt-2 text-[10px] font-mono text-mempool-text-dim bg-mempool-bg rounded p-3 overflow-x-auto max-h-80 leading-relaxed">
          {raw}
        </pre>
      )}
    </div>
  );
}
