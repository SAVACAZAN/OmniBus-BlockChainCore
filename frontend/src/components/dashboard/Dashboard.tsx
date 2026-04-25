import { StatsBar } from "./StatsBar";
import { MempoolBlockStrip } from "./MempoolBlockStrip";
import { RecentTransactions } from "./RecentTransactions";
import { MinerTable } from "../network/MinerTable";

// Note: <ExchangePrices /> removed from the dashboard. Prices are now
// embedded INTO each mined block (timestamp + bid/ask per exchange) and
// displayed inline in BlockDetail / BlocksPage. The oracle feed still
// runs in the node and logs to console.
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
