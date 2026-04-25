import { StatsBar } from "./StatsBar";
import { MempoolBlockStrip } from "./MempoolBlockStrip";
import { RecentTransactions } from "./RecentTransactions";
import { MinerTable } from "../network/MinerTable";
import ExchangePrices from "./ExchangePrices";

export function Dashboard() {
  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-6">
      {/* Stats Bar */}
      <StatsBar />

      {/* Live exchange feed (BTC/LCX × 3 venues) */}
      <ExchangePrices />

      {/* Mempool Block Strip — the star feature */}
      <MempoolBlockStrip />

      {/* Recent Activity (full width) */}
      <RecentTransactions />

      {/* Miner Table */}
      <MinerTable />
    </div>
  );
}
