import { useEffect, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import { AddressLabel } from "../common/AddressLabel";

const rpc = new OmniBusRpcClient();
const SAT_PER_OMNI = 1_000_000_000;

type TxKind =
  | "coinbase"
  | "faucet"
  | "registrar"
  | "exchange"
  | "stake"
  | "demo_grant"
  | "transfer"
  | string;

type AddressTx = {
  txid: string;
  from: string;
  to: string;
  amount: number;
  fee: number;
  confirmations: number;
  blockHeight: number | null;
  direction: "sent" | "received";
  kind: TxKind;
  status: "pending" | "confirmed";
};

type AddressHistory = {
  address: string;
  transactions: AddressTx[];
  count: number;
  totalReceived: number;
  totalSent: number;
};

const KIND_STYLE: Record<string, string> = {
  coinbase: "bg-yellow-500/20 text-yellow-300",
  faucet: "bg-cyan-500/20 text-cyan-300",
  registrar: "bg-purple-500/20 text-purple-300",
  exchange: "bg-blue-500/20 text-blue-300",
  stake: "bg-green-500/20 text-green-300",
  unstake:        "bg-amber-500/20 text-amber-300",
  ns_claim:       "bg-violet-500/20 text-violet-300",
  agent_register: "bg-indigo-500/20 text-indigo-300",
  notarize:       "bg-rose-500/20 text-rose-300",
  demo_grant:     "bg-pink-500/20 text-pink-300",
  transfer:       "bg-gray-700/40 text-gray-300",
};

const omniFmt = (sat: number) => (sat / SAT_PER_OMNI).toFixed(8);

export function AddressDetail({
  address,
  onBack,
}: {
  address: string;
  onBack: () => void;
}) {
  const [data, setData] = useState<AddressHistory | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<TxKind | "all">("all");

  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      try {
        const r = (await rpc.request_raw("getaddresshistory", [
          address,
        ])) as AddressHistory;
        if (!cancelled) {
          setData(r);
          setError(null);
        }
      } catch (e: any) {
        if (!cancelled) setError(e?.message || "RPC error");
      } finally {
        if (!cancelled) setLoading(false);
      }
    };
    refresh();
    const id = setInterval(refresh, 8000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [address]);

  const txs = data?.transactions ?? [];
  const kinds = Array.from(new Set(txs.map((t) => t.kind)));
  const filteredTxs = filter === "all" ? txs : txs.filter((t) => t.kind === filter);
  const net = data ? data.totalReceived - data.totalSent : 0;

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      <button
        onClick={onBack}
        className="text-mempool-blue text-sm mb-4 hover:underline"
      >
        ← Back to rich list
      </button>

      <h1 className="text-2xl font-bold text-mempool-text mb-2">Address</h1>
      <div className="font-mono text-sm text-mempool-blue mb-6 break-all">
        {address}
        <button
          onClick={() => navigator.clipboard.writeText(address)}
          className="ml-2 text-xs text-mempool-text-dim hover:text-mempool-text"
          title="Copy"
        >
          [copy]
        </button>
      </div>

      {data && (
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
          <Metric label="TX count" value={data.count.toLocaleString()} />
          <Metric label="Received" value={`${omniFmt(data.totalReceived)} OMNI`} />
          <Metric label="Sent" value={`${omniFmt(data.totalSent)} OMNI`} />
          <Metric
            label="Net"
            value={`${net >= 0 ? "+" : ""}${omniFmt(net)} OMNI`}
          />
        </div>
      )}

      {kinds.length > 1 && (
        <div className="flex flex-wrap items-center gap-2 mb-4">
          <span className="text-xs text-mempool-text-dim">Filter by type:</span>
          <button
            onClick={() => setFilter("all")}
            className={`px-2 py-1 text-xs rounded transition-colors ${
              filter === "all"
                ? "bg-mempool-blue text-white"
                : "bg-mempool-bg-elev text-mempool-text-dim hover:text-mempool-text"
            }`}
          >
            all ({txs.length})
          </button>
          {kinds.map((k) => {
            const count = txs.filter((t) => t.kind === k).length;
            return (
              <button
                key={k}
                onClick={() => setFilter(k)}
                className={`px-2 py-1 text-xs rounded transition-colors ${
                  filter === k
                    ? "bg-mempool-blue text-white"
                    : "bg-mempool-bg-elev text-mempool-text-dim hover:text-mempool-text"
                }`}
              >
                {k} ({count})
              </button>
            );
          })}
        </div>
      )}

      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-hidden">
        {loading && !data && (
          <div className="p-8 text-center text-mempool-text-dim text-sm">
            Loading address history…
          </div>
        )}
        {error && (
          <div className="p-4 text-red-400 text-sm">RPC error: {error}</div>
        )}
        {data && filteredTxs.length === 0 && (
          <div className="p-8 text-center text-mempool-text-dim text-sm">
            No transactions yet.
          </div>
        )}
        {filteredTxs.length > 0 && (
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-mempool-border bg-mempool-bg/50">
                <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-20">
                  Block
                </th>
                <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">
                  TXID
                </th>
                <th className="text-center px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-24">
                  Type
                </th>
                <th className="text-center px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-16">
                  Dir
                </th>
                <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">
                  Counterparty
                </th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">
                  Amount
                </th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-20">
                  Conf
                </th>
              </tr>
            </thead>
            <tbody>
              {filteredTxs.map((tx) => {
                const counterparty = tx.direction === "sent" ? tx.to : tx.from;
                const sign = tx.direction === "sent" ? "-" : "+";
                const signColor =
                  tx.direction === "sent" ? "text-red-300" : "text-green-300";
                const kindClass =
                  KIND_STYLE[tx.kind] ?? "bg-gray-700/40 text-gray-300";
                return (
                  <tr
                    key={tx.txid}
                    className="border-b border-mempool-border/40 hover:bg-mempool-bg/30"
                  >
                    <td className="px-3 py-2 font-mono text-xs text-mempool-text-dim">
                      {tx.blockHeight !== null ? (
                        <button
                          onClick={() => { window.location.hash = `#/block/${tx.blockHeight}`; }}
                          className="text-mempool-blue hover:underline"
                        >
                          #{tx.blockHeight.toLocaleString()}
                        </button>
                      ) : "—"}
                    </td>
                    <td className="px-3 py-2 font-mono text-xs">
                      <button
                        onClick={() => { window.location.hash = `#/tx/${tx.txid}`; }}
                        className="text-mempool-blue hover:underline"
                        title={tx.txid}
                      >
                        {tx.txid.slice(0, 10)}…{tx.txid.slice(-6)}
                      </button>
                    </td>
                    <td className="px-3 py-2 text-center">
                      <span
                        className={`inline-block px-2 py-0.5 text-[10px] uppercase tracking-wider rounded ${kindClass}`}
                      >
                        {tx.kind}
                      </span>
                    </td>
                    <td className="px-3 py-2 text-center text-xs text-mempool-text-dim">
                      {tx.direction === "sent" ? "out" : "in"}
                    </td>
                    <td className="px-3 py-2 font-mono text-xs">
                      {counterparty.length === 0 ? (
                        <span className="text-mempool-text-dim italic">
                          (coinbase)
                        </span>
                      ) : (
                        <button
                          onClick={() => { window.location.hash = `#/address/${counterparty}`; }}
                          className="text-mempool-blue hover:underline transition-colors"
                          title={counterparty}
                        >
                          <AddressLabel address={counterparty} showEmoji truncate={{ left: 8, right: 6 }} />
                        </button>
                      )}
                    </td>
                    <td
                      className={`px-3 py-2 text-right font-mono ${signColor}`}
                    >
                      {sign}
                      {omniFmt(tx.amount)} OMNI
                    </td>
                    <td className="px-3 py-2 text-right text-xs text-mempool-text-dim">
                      {tx.status === "pending" ? (
                        <span className="text-yellow-400">pending</span>
                      ) : (
                        tx.confirmations.toLocaleString()
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>

      <div className="mt-6 text-xs text-mempool-text-dim">
        <p>
          <span className="font-semibold text-mempool-text">TX types:</span>{" "}
          coinbase = block reward · faucet = testnet faucet drip · registrar =
          treasury wallet operation · exchange = DEX matching engine fill ·
          stake = staking op · demo_grant = paper-trading bootstrap · transfer
          = regular P2PKH/SegWit transfer.
        </p>
        <p className="mt-2">
          <span className="font-semibold text-mempool-text">Refresh:</span>{" "}
          auto every 8s.
        </p>
      </div>
    </div>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-3">
      <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">
        {label}
      </div>
      <div className="text-sm font-mono text-mempool-text">{value}</div>
    </div>
  );
}
