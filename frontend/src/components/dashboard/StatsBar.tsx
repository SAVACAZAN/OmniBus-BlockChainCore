import { useBlockchain } from "../../stores/useBlockchainStore";

interface StatCardProps {
  label: string;
  value: string | number;
  sub?: string;
  color?: string;
}

function StatCard({ label, value, sub, color = "text-mempool-text" }: StatCardProps) {
  return (
    <div className="bg-mempool-card rounded-lg p-4 border border-mempool-border">
      <p className="text-xs text-mempool-text-dim uppercase tracking-wider mb-1">
        {label}
      </p>
      <p className={`text-xl font-mono font-bold ${color}`}>
        {typeof value === "number" ? value.toLocaleString() : value}
      </p>
      {sub && <p className="text-xs text-mempool-text-dim mt-1">{sub}</p>}
    </div>
  );
}

export function StatsBar() {
  const { state } = useBlockchain();

  const rewardPerBlock = state.networkInfo?.blockRewardSAT
    ? (state.networkInfo.blockRewardSAT / 1e9).toFixed(4)
    : "0.0083";

  return (
    <div className="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-5 gap-3">
      <StatCard
        label="Block Height"
        value={state.blockCount}
        sub="1s block time"
        color="text-mempool-blue"
      />
      <StatCard
        label="Mempool"
        value={state.mempoolSize}
        sub={
          state.mempoolStats
            ? `${(state.mempoolStats.bytes / 1024).toFixed(1)} KB`
            : "pending TXs"
        }
        color={state.mempoolSize > 0 ? "text-mempool-orange" : "text-mempool-text"}
      />
      <StatCard
        label="Difficulty"
        value={state.difficulty}
        sub="PoW leading zeros"
      />
      <StatCard
        label="Balance"
        value={`${state.balanceOMNI} OMNI`}
        sub={`${state.balance.toLocaleString()} SAT`}
        color="text-mempool-green"
      />
      <StatCard
        label="Reward/Block"
        value={`${rewardPerBlock} OMNI`}
        sub="halving every 126M blocks"
        color="text-mempool-purple"
      />
    </div>
  );
}
