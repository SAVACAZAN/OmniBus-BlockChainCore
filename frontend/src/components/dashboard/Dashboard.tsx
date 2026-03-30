import { StatsBar } from "./StatsBar";
import { MempoolBlockStrip } from "./MempoolBlockStrip";
import { RecentTransactions } from "./RecentTransactions";
import { MinerTable } from "../network/MinerTable";

export function Dashboard() {
  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-6">
      {/* Stats Bar */}
      <StatsBar />

      {/* Mempool Block Strip — the star feature */}
      <MempoolBlockStrip />

      {/* Recent Activity (full width) */}
      <RecentTransactions />

      {/* Miner Table */}
      <MinerTable />
    </div>
  );
}
