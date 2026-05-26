import { StatsBar } from "./StatsBar";
import { BlockTimeBand } from "./BlockTimeBand";
import { MempoolBlockStrip } from "./MempoolBlockStrip";
import { RecentTransactions } from "./RecentTransactions";
import { MinerTable } from "../network/MinerTable";
import ArbitrageOpportunities from "./ArbitrageOpportunities";
import AllPricesGrid from "./AllPricesGrid";

// Note: <ExchangePrices /> removed from the dashboard. Prices are now
// embedded INTO each mined block (timestamp + bid/ask per exchange) and
// displayed inline in BlockDetail / BlocksPage. The oracle feed still
// runs in the node and logs to console.
export function Dashboard() {
  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-6">
      {/* Stats Bar */}
      <StatsBar />

      {/* Block time health band — sparkline of last N inter-block deltas */}
      <BlockTimeBand />

      {/* MempoolBlockStrip with Plasma ambient on the right — no border,
           no card chrome around the plasma; the orange core sits visually
           just past the rightmost mined block, antennae reaching toward
           the page edge. Plasma is positioned absolute over the row's
           right third so the swarm and the block cards blend into one
           continuous band. pointer-events-none keeps the cards clickable. */}
      <MempoolBlockStrip />

      {/* Cross-exchange arbitrage opportunities */}
      <ArbitrageOpportunities />

      {/* Recent Activity (full width) */}
      <RecentTransactions />

      {/* Miner Table */}
      <MinerTable />

      {/* Full market feed — bid/ask grid across exchanges */}
      <AllPricesGrid />
    </div>
  );
}
