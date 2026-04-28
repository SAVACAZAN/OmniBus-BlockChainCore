import { useEffect, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";

const rpc = new OmniBusRpcClient();
const SAT_PER_OMNI = 1_000_000_000;

type RichEntry = {
  rank: number;
  address: string;
  balance: number;
  isValidator: boolean;
  blocksMined: number;
};

type RichListResp = {
  entries: RichEntry[];
  total: number;
  shown: number;
  totalSupply: number;
};

type ChainMetrics = {
  height: number;
  tipHash: string;
  totalSupply: number;
  addressesWithBalance: number;
  validators: number;
  validatorSetSize: number;
  minValidatorBalance: number;
  mempoolSize: number;
  peerCount: number;
  currentBlockReward: number;
  satPerOmni: number;
};

export function RichListPage() {
  const [list, setList] = useState<RichListResp | null>(null);
  const [metrics, setMetrics] = useState<ChainMetrics | null>(null);
  const [loading, setLoading] = useState(true);
  const [limit, setLimit] = useState(100);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      try {
        const [rl, m] = await Promise.all([
          rpc.request_raw("getrichlist", [limit]) as Promise<RichListResp>,
          rpc.request_raw("getchainmetrics", []) as Promise<ChainMetrics>,
        ]);
        if (!cancelled) {
          setList(rl);
          setMetrics(m);
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
  }, [limit]);

  const omniFmt = (sat: number) => (sat / SAT_PER_OMNI).toFixed(8);

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      <h1 className="text-2xl font-bold text-mempool-text mb-2">Rich List</h1>
      <p className="text-mempool-text-dim text-sm mb-6">
        All addresses with a positive balance, sorted descending. Validators
        (≥ {metrics ? omniFmt(metrics.minValidatorBalance) : "0.10"} OMNI) are
        eligible to mine via slot-leader rotation.
      </p>

      {/* Metrics row */}
      {metrics && (
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
          <Metric label="Height" value={metrics.height.toLocaleString()} />
          <Metric label="Total supply" value={`${omniFmt(metrics.totalSupply)} OMNI`} />
          <Metric label="Addresses" value={metrics.addressesWithBalance.toLocaleString()} />
          <Metric label="Validators" value={`${metrics.validators} / ${metrics.validatorSetSize}`} />
          <Metric label="Mempool" value={metrics.mempoolSize.toString()} />
          <Metric label="Peers" value={metrics.peerCount.toString()} />
          <Metric label="Block reward" value={`${omniFmt(metrics.currentBlockReward)} OMNI`} />
          <Metric label="Min validator" value={`${omniFmt(metrics.minValidatorBalance)} OMNI`} />
        </div>
      )}

      {/* Limit selector */}
      <div className="flex items-center gap-2 mb-4">
        <span className="text-xs text-mempool-text-dim">Show:</span>
        {[50, 100, 250, 500].map((n) => (
          <button
            key={n}
            onClick={() => setLimit(n)}
            className={`px-2 py-1 text-xs rounded transition-colors ${
              limit === n
                ? "bg-mempool-blue text-white"
                : "bg-mempool-bg-elev text-mempool-text-dim hover:text-mempool-text"
            }`}
          >
            top {n}
          </button>
        ))}
        {list && (
          <span className="ml-auto text-xs text-mempool-text-dim">
            showing {list.shown} of {list.total}
          </span>
        )}
      </div>

      {/* Table */}
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-hidden">
        {loading && !list && (
          <div className="p-8 text-center text-mempool-text-dim text-sm">Loading rich list…</div>
        )}
        {error && (
          <div className="p-4 text-red-400 text-sm">RPC error: {error}</div>
        )}
        {list && list.entries.length === 0 && (
          <div className="p-8 text-center text-mempool-text-dim text-sm">
            No addresses with balance yet — chain is fresh.
          </div>
        )}
        {list && list.entries.length > 0 && (
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-mempool-border bg-mempool-bg/50">
                <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-12">#</th>
                <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Address</th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Balance</th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-20">Share</th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-24">Mined</th>
                <th className="text-center px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-20">Status</th>
              </tr>
            </thead>
            <tbody>
              {list.entries.map((e) => {
                const sharePct = list.totalSupply > 0
                  ? ((e.balance / list.totalSupply) * 100).toFixed(2)
                  : "0.00";
                return (
                  <tr key={e.address} className="border-b border-mempool-border/40 hover:bg-mempool-bg/30">
                    <td className="px-3 py-2 text-mempool-text-dim font-mono text-xs">{e.rank}</td>
                    <td className="px-3 py-2 font-mono text-xs">
                      <button
                        onClick={() => navigator.clipboard.writeText(e.address)}
                        className="text-mempool-blue hover:underline"
                        title="Click to copy"
                      >
                        {e.address.slice(0, 12)}…{e.address.slice(-8)}
                      </button>
                    </td>
                    <td className="px-3 py-2 text-right font-mono text-mempool-text">
                      {omniFmt(e.balance)} OMNI
                    </td>
                    <td className="px-3 py-2 text-right text-xs text-mempool-text-dim">{sharePct}%</td>
                    <td className="px-3 py-2 text-right text-xs text-mempool-text">
                      {e.blocksMined.toLocaleString()}
                    </td>
                    <td className="px-3 py-2 text-center">
                      {e.isValidator ? (
                        <span className="inline-block px-2 py-0.5 text-[10px] uppercase tracking-wider bg-green-500/20 text-green-300 rounded">
                          validator
                        </span>
                      ) : (
                        <span className="inline-block px-2 py-0.5 text-[10px] uppercase tracking-wider bg-gray-700/40 text-gray-400 rounded">
                          holder
                        </span>
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
          <span className="font-semibold text-mempool-text">Validator status:</span> any address
          holding ≥ {metrics ? omniFmt(metrics.minValidatorBalance) : "0.10"} OMNI is automatically
          included in slot-leader rotation. No registration required — the chain derives the active
          validator set from current balances each block.
        </p>
        <p className="mt-2">
          <span className="font-semibold text-mempool-text">Refresh:</span> auto every 8s.
        </p>
      </div>
    </div>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-3">
      <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">{label}</div>
      <div className="text-sm font-mono text-mempool-text">{value}</div>
    </div>
  );
}
