import { useEffect, useState, useMemo } from "react";
import { rpc } from "../../api/rpc-client";
import { AddressLabel } from "../common/AddressLabel";
import { CopyButton } from "../common/CopyButton";
import { KindBadge, SchemeTag } from "../common/TxBadges";
import { fmtSat, midTrunc, SAT_PER_OMNI, fmtAge, fmtUsd } from "../../utils/fmt";


function fmtTs(ts: number) {
  const ms = ts < 1e10 ? ts * 1000 : ts;
  return `${fmtAge(ms)} · ${new Date(ms).toLocaleString()}`;
}


function Field({
  label,
  value,
  mono,
  copy,
  highlight,
  onClick,
  badge,
}: {
  label: string;
  value: string;
  mono?: boolean;
  copy?: boolean;
  highlight?: boolean;
  onClick?: () => void;
  badge?: { text: string; color: "green" | "yellow" | "red" };
}) {
  const badgeCls = badge
    ? ({ green: "bg-green-400/10 text-green-400", yellow: "bg-yellow-400/10 text-yellow-400", red: "bg-red-400/10 text-red-400" } as const)[badge.color]
    : "";
  return (
    <div>
      <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-0.5">{label}</div>
      <div className={`flex items-center gap-1.5 min-w-0 ${mono ? "font-mono text-xs" : "text-sm"} ${highlight ? "text-mempool-orange font-semibold" : "text-mempool-text"}`}>
        {onClick ? (
          <button onClick={onClick} className="text-mempool-blue hover:underline truncate max-w-full text-left">{value}</button>
        ) : (
          <span className="truncate max-w-full break-all">{value}</span>
        )}
        {copy && <CopyButton text={value} />}
        {badge && <span className={`text-[10px] px-1.5 py-0.5 rounded-full flex-shrink-0 font-medium ${badgeCls}`}>{badge.text}</span>}
      </div>
    </div>
  );
}

interface Props {
  height: number;
  onNavigate: (hash: string) => void;
}

export function BlockPage({ height, onNavigate }: Props) {
  const [block, setBlock] = useState<any>(null);
  const [txs, setTxs] = useState<any[]>([]);
  const [tip, setTip] = useState(0);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");

  useEffect(() => {
    setLoading(true);
    setErr("");
    setBlock(null);
    setTxs([]);
    Promise.all([rpc.getBlock(height), rpc.getBlockCount()])
      .then(async ([b, count]) => {
        if (!b) { setErr("Block not found"); return; }
        setBlock(b);
        const countObj = count as unknown as { blockCount?: number } | number;
        const liveCount = typeof countObj === "number" ? countObj : (countObj?.blockCount ?? 0);
        setTip(typeof liveCount === "number" ? liveCount : 0);
        const txids: string[] = b.transactions || b.tx_ids || b.txids || [];
        if (txids.length > 0) {
          const settled = await Promise.allSettled(
            txids.slice(0, 100).map((id: string) => rpc.getTransactionDetail(id))
          );
          setTxs(
            settled
              .filter((r): r is PromiseFulfilledResult<any> => r.status === "fulfilled" && !!r.value)
              .map((r) => r.value)
          );
        }
      })
      .catch((e) => setErr(e.message))
      .finally(() => setLoading(false));
  }, [height]);

  if (loading) {
    return (
      <div className="max-w-7xl mx-auto px-4 py-8 text-mempool-text-dim animate-pulse text-sm">
        Loading block #{height.toLocaleString()}…
      </div>
    );
  }

  if (err || !block) {
    return (
      <div className="max-w-7xl mx-auto px-4 py-8 space-y-4">
        <button onClick={() => onNavigate("#/blocks")} className="text-mempool-blue hover:underline text-sm">← Blocks</button>
        <p className="text-red-400">{err || "Block not found"}</p>
      </div>
    );
  }

  const totalFeesSat = txs.reduce((s: number, tx: any) => s + (tx.fee || 0), 0);
  const burned = Math.floor(totalFeesSat / 2);
  const minerFees = totalFeesSat - burned;
  const confirmations = tip > height ? tip - height : 0;

  const schemeCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const tx of txs) {
      if (tx.scheme) counts[tx.scheme] = (counts[tx.scheme] ?? 0) + 1;
    }
    return Object.entries(counts).sort((a, b) => b[1] - a[1]);
  }, [txs]);

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-4">
      {/* Breadcrumb + prev/next */}
      <div className="flex items-center gap-2 text-sm flex-wrap">
        <button onClick={() => onNavigate("#/blocks")} className="text-mempool-blue hover:underline flex items-center gap-1">
          ← Blocks
        </button>
        <span className="text-mempool-text-dim">/</span>
        <span className="text-mempool-text font-medium">Block #{height.toLocaleString()}</span>
        <div className="ml-auto flex gap-2">
          {height > 0 && (
            <button onClick={() => onNavigate(`#/block/${height - 1}`)}
              className="text-xs px-2 py-1 rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue transition-colors">
              ← Prev
            </button>
          )}
          {height < tip - 1 && (
            <button onClick={() => onNavigate(`#/block/${height + 1}`)}
              className="text-xs px-2 py-1 rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue transition-colors">
              Next →
            </button>
          )}
        </div>
      </div>

      {/* Block header card */}
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-5">
        <h1 className="text-xl font-bold text-mempool-text mb-4">
          Block <span className="text-mempool-blue">#{height.toLocaleString()}</span>
        </h1>
        <div className="grid sm:grid-cols-2 gap-4">
          <Field label="Hash" value={block.hash || "—"} mono copy />
          {block.previousHash && (
            <Field label="Previous Hash" value={block.previousHash} mono copy
              onClick={height > 0 ? () => onNavigate(`#/block/${height - 1}`) : undefined} />
          )}
          <Field label="Timestamp" value={block.timestamp ? fmtTs(block.timestamp) : "—"} />
          <Field label="Nonce" value={(block.nonce ?? 0).toLocaleString()} />
          <Field label="Transactions" value={String(block.txCount ?? txs.length)} />
          {block.miner && (
            <div>
              <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-0.5">Miner</div>
              <div className="flex items-center gap-1.5 min-w-0 text-sm text-mempool-text">
                <button onClick={() => onNavigate(`#/address/${block.miner}`)}
                  className="text-mempool-blue hover:underline text-xs font-mono">
                  <AddressLabel address={block.miner} showRawAddress showEmoji
                    truncate={{ left: 12, right: 10 }} />
                </button>
                <CopyButton text={block.miner} />
              </div>
            </div>
          )}
          <Field label="Block Reward" value={fmtSat(block.rewardSAT || 0)} highlight />
          {(block.totalFees ?? 0) > 0 && (
            <Field label="Total Fees" value={fmtSat(block.totalFees)} />
          )}
          <Field label="Confirmations" value={String(confirmations)} />
          {block.difficulty !== undefined && (
            <Field label="Difficulty" value={Number(block.difficulty).toLocaleString()} />
          )}
          {block.pricesRoot && (
            <Field label="Prices Root" value={block.pricesRoot} mono copy
              badge={block.pricesValidated
                ? { text: "✓ Verified", color: "green" }
                : { text: "⚠ Unverified", color: "yellow" }} />
          )}
        </div>
      </div>

      {/* Fee summary */}
      {totalFeesSat > 0 && (
        <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
          <h2 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim mb-3">Fee Summary</h2>
          <div className="grid grid-cols-3 gap-4 text-center text-sm">
            <div>
              <div className="text-mempool-text font-mono">{fmtSat(totalFeesSat)}</div>
              <div className="text-mempool-text-dim text-xs mt-0.5">Total Fees</div>
            </div>
            <div>
              <div className="text-green-400 font-mono">{fmtSat(minerFees)}</div>
              <div className="text-mempool-text-dim text-xs mt-0.5">Miner (50%)</div>
            </div>
            <div>
              <div className="text-orange-400 font-mono">{fmtSat(burned)}</div>
              <div className="text-mempool-text-dim text-xs mt-0.5">Burned (50%)</div>
            </div>
          </div>
        </div>
      )}

      {/* Oracle prices */}
      {block.prices && block.prices.length > 0 && (
        <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
          <h2 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim mb-3">Oracle Prices</h2>
          <div className="overflow-x-auto">
            <table className="w-full text-xs min-w-[320px]">
              <thead>
                <tr className="text-mempool-text-dim border-b border-mempool-border">
                  <th className="text-left pb-2 pr-4">Exchange</th>
                  <th className="text-left pb-2 pr-4">Pair</th>
                  <th className="text-right pb-2 pr-4">Bid</th>
                  <th className="text-right pb-2">Ask</th>
                </tr>
              </thead>
              <tbody>
                {block.prices.map((p: any) => (
                  <tr key={`${p.exchange}${p.pair}`} className="border-b border-mempool-border/30 last:border-0 hover:bg-mempool-bg-light/30 transition-colors">
                    <td className="py-2 pr-4 text-mempool-text">{p.exchange}</td>
                    <td className="py-2 pr-4 text-mempool-text-dim">{p.pair}</td>
                    <td className="py-2 pr-4 text-right text-green-400">{fmtUsd(p.bidMicroUsd)}</td>
                    <td className="py-2 text-right text-red-400">{fmtUsd(p.askMicroUsd)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* Transactions */}
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
        <div className="flex items-start justify-between gap-4 mb-3 flex-wrap">
          <div className="flex items-center gap-2">
            <h2 className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim">
              Transactions ({block.txCount ?? txs.length})
            </h2>
            {txs.length > 0 && (
              <button
                onClick={() => {
                  const rows = [
                    ["txid", "from", "to", "amount_omni", "fee_omni", "kind", "scheme", "status"].join(","),
                    ...txs.map((tx: any) => [
                      `"${tx.txid ?? ""}"`,
                      `"${tx.from ?? ""}"`,
                      `"${tx.to ?? ""}"`,
                      ((tx.amount || 0) / SAT_PER_OMNI).toFixed(8),
                      ((tx.fee || 0) / SAT_PER_OMNI).toFixed(8),
                      tx.kind ?? "transfer",
                      tx.scheme ?? "",
                      tx.status ?? "",
                    ].join(",")),
                  ].join("\n");
                  const blob = new Blob([rows], { type: "text/csv" });
                  const url = URL.createObjectURL(blob);
                  const a = document.createElement("a");
                  a.href = url; a.download = `omnibus-block-${block.height}-txs.csv`;
                  a.click(); URL.revokeObjectURL(url);
                }}
                className="px-2 py-0.5 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue font-mono"
              >
                ⬇ CSV
              </button>
            )}
          </div>
          {schemeCounts.length > 0 && (
            <div className="flex flex-wrap gap-1.5">
              {schemeCounts.map(([scheme, n]) => (
                <span key={scheme} className="text-[10px] text-mempool-text-dim">
                  <SchemeTag scheme={scheme} /> ×{n}
                </span>
              ))}
            </div>
          )}
        </div>
        <div className="space-y-2">
          {/* Coinbase */}
          <div className="bg-mempool-bg-light border border-yellow-400/20 rounded-lg p-3 text-xs">
            <div className="flex items-center justify-between gap-2">
              <span className="text-yellow-400 font-semibold">⛏ Coinbase — Block Reward</span>
              <span className="text-green-400 font-mono flex-shrink-0">+{fmtSat(block.rewardSAT || 0)}</span>
            </div>
            {block.miner && (
              <div className="mt-1 text-mempool-text-dim">
                →{" "}
                <button onClick={() => onNavigate(`#/address/${block.miner}`)}
                  className="text-mempool-blue hover:underline font-mono">
                  <AddressLabel address={block.miner} showEmoji truncate={{ left: 14, right: 12 }} />
                </button>
              </div>
            )}
          </div>

          {/* User TXs */}
          {txs.length === 0 && (block.txCount ?? 0) > 0 && (
            <div className="text-mempool-text-dim text-xs py-2 text-center">
              Transaction details not indexed for this block.
            </div>
          )}
          {txs.map((tx: any) => (
            <div key={tx.txid} className="bg-mempool-bg-light border border-mempool-border/40 rounded-lg p-3 text-xs space-y-1.5">
              <div className="flex items-center justify-between gap-2">
                <button onClick={() => onNavigate(`#/tx/${tx.txid}`)}
                  className="font-mono text-mempool-blue hover:underline truncate">
                  {midTrunc(tx.txid, 14, 12)}
                </button>
                <span className={`px-1.5 py-0.5 rounded text-[10px] font-medium flex-shrink-0 ${
                  tx.status === "confirmed"
                    ? "bg-green-400/10 text-green-400"
                    : "bg-yellow-400/10 text-yellow-400"
                }`}>{tx.status}</span>
              </div>
              <div className="flex flex-wrap gap-x-4 gap-y-0.5 text-mempool-text-dim">
                <span>
                  From:{" "}
                  <button onClick={() => onNavigate(`#/address/${tx.from}`)}
                    className="text-mempool-blue hover:underline font-mono">
                    <AddressLabel address={tx.from ?? ""} showEmoji truncate={{ left: 10, right: 8 }} />
                  </button>
                </span>
                <span>
                  →{" "}
                  <button onClick={() => onNavigate(`#/address/${tx.to}`)}
                    className="text-mempool-blue hover:underline font-mono">
                    <AddressLabel address={tx.to ?? ""} showEmoji truncate={{ left: 10, right: 8 }} />
                  </button>
                </span>
              </div>
              <div className="flex flex-wrap gap-x-4 gap-y-0.5 items-center">
                <span className="text-mempool-text font-mono">{fmtSat(tx.amount)}</span>
                <span className="text-mempool-text-dim">Fee: {fmtSat(tx.fee)}</span>
                {tx.nonce !== undefined && (
                  <span className="text-mempool-text-dim">nonce: <span className="font-mono text-mempool-text">{tx.nonce}</span></span>
                )}
                {tx.confirmations !== undefined && (
                  <span className="text-mempool-text-dim">{tx.confirmations} conf</span>
                )}
                {tx.kind && <KindBadge kind={tx.kind} />}
                {tx.scheme && <SchemeTag scheme={tx.scheme} />}
              </div>
              {tx.op_return && (
                <div className="text-mempool-text-dim font-mono break-all border-t border-mempool-border/30 pt-1.5 mt-1">
                  OP_RETURN: {tx.op_return}
                </div>
              )}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
